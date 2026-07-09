use serde::{Deserialize, Serialize};

use crate::{DoppelbangerError, PairDiffV1, Result, TrackAnalysisV1};

pub const PROCESSOR_VERSION: &str = "linear-eq-gain-v1";
pub const TRUE_PEAK_CEILING_DBTP: f64 = -1.0;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EqFilterKindV1 {
    LowShelf,
    Bell,
    HighShelf,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct EqFilterV1 {
    pub kind: EqFilterKindV1,
    pub frequency_hz: f64,
    pub q: f64,
    pub gain_db: f64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct MasteringPlanV1 {
    pub schema_version: u32,
    pub analyzer_version: String,
    pub processor_version: String,
    pub reference_sha256: String,
    pub target_sha256: String,
    pub bypass: bool,
    pub desired_gain_db: f64,
    pub applied_gain_db: f64,
    pub loudness_shortfall_db: f64,
    pub true_peak_ceiling_dbtp: f64,
    pub eq: Vec<EqFilterV1>,
}

pub fn generate_plan(
    reference: &TrackAnalysisV1,
    target: &TrackAnalysisV1,
    diff: &PairDiffV1,
) -> Result<MasteringPlanV1> {
    if reference.analyzer_version != target.analyzer_version {
        return Err(DoppelbangerError::InvalidPlan(format!(
            "analyzer version mismatch: reference={}, target={}",
            reference.analyzer_version, target.analyzer_version
        )));
    }

    let bypass = reference.metadata.source_sha256 == target.metadata.source_sha256
        && diff.is_zero(f64::EPSILON);
    let eq_gains = if bypass {
        [0.0; 3]
    } else {
        [
            average(&diff.spectral_relative_db[0..3]),
            average(&diff.spectral_relative_db[3..7]),
            average(&diff.spectral_relative_db[7..9]),
        ]
        .map(|gain| (gain * 0.5).clamp(-3.0, 3.0))
    };
    let eq = fixed_eq(eq_gains);
    let desired_gain_db = if bypass {
        0.0
    } else {
        diff.integrated_lufs.clamp(-12.0, 12.0)
    };
    let safe_max_gain = safe_max_gain(target, &eq);
    let applied_gain_db = if bypass {
        0.0
    } else {
        desired_gain_db.min(safe_max_gain).clamp(-12.0, 12.0)
    };
    let plan = MasteringPlanV1 {
        schema_version: 1,
        analyzer_version: target.analyzer_version.clone(),
        processor_version: PROCESSOR_VERSION.to_string(),
        reference_sha256: reference.metadata.source_sha256.clone(),
        target_sha256: target.metadata.source_sha256.clone(),
        bypass,
        desired_gain_db,
        applied_gain_db,
        loudness_shortfall_db: (desired_gain_db - applied_gain_db).max(0.0),
        true_peak_ceiling_dbtp: TRUE_PEAK_CEILING_DBTP,
        eq,
    };

    validate_plan(&plan, target)?;
    Ok(plan)
}

pub fn validate_plan(plan: &MasteringPlanV1, target: &TrackAnalysisV1) -> Result<()> {
    if plan.schema_version != 1 {
        return invalid("schema_version must be 1");
    }
    if plan.analyzer_version != target.analyzer_version {
        return invalid(format!(
            "analyzer_version={} does not match target analyzer {}",
            plan.analyzer_version, target.analyzer_version
        ));
    }
    if plan.processor_version != PROCESSOR_VERSION {
        return invalid(format!(
            "processor_version must be {PROCESSOR_VERSION}, got {}",
            plan.processor_version
        ));
    }
    if plan.target_sha256 != target.metadata.source_sha256 {
        return invalid("target_sha256 does not match the decoded target file");
    }
    if (plan.true_peak_ceiling_dbtp - TRUE_PEAK_CEILING_DBTP).abs() > f64::EPSILON {
        return invalid(format!(
            "true_peak_ceiling_dbtp must be {TRUE_PEAK_CEILING_DBTP}"
        ));
    }
    check_range("desired_gain_db", plan.desired_gain_db, -12.0, 12.0)?;
    check_range("applied_gain_db", plan.applied_gain_db, -12.0, 12.0)?;
    if plan.eq.len() != 3 {
        return invalid(format!("eq must contain 3 filters, got {}", plan.eq.len()));
    }

    let expected = [
        (EqFilterKindV1::LowShelf, 120.0, 0.707),
        (EqFilterKindV1::Bell, 1_000.0, 0.5),
        (EqFilterKindV1::HighShelf, 6_000.0, 0.707),
    ];
    for (index, (filter, &(kind, frequency_hz, q))) in plan.eq.iter().zip(&expected).enumerate() {
        if filter.kind != kind
            || (filter.frequency_hz - frequency_hz).abs() > f64::EPSILON
            || (filter.q - q).abs() > f64::EPSILON
        {
            return invalid(format!(
                "eq[{index}] topology must remain kind={kind:?}, frequency_hz={frequency_hz}, q={q}"
            ));
        }
        check_range(&format!("eq[{index}].gain_db"), filter.gain_db, -3.0, 3.0)?;
        if filter.frequency_hz >= target.metadata.sample_rate_hz as f64 * 0.5 {
            return invalid(format!(
                "eq[{index}].frequency_hz={} must be below target Nyquist frequency",
                filter.frequency_hz
            ));
        }
    }

    let safe_max = safe_max_gain(target, &plan.eq);
    if plan.applied_gain_db > safe_max + 1e-9 {
        return invalid(format!(
            "applied_gain_db={} exceeds conservative true-peak headroom {safe_max:.6}",
            plan.applied_gain_db
        ));
    }
    let expected_shortfall = (plan.desired_gain_db - plan.applied_gain_db).max(0.0);
    if (plan.loudness_shortfall_db - expected_shortfall).abs() > 1e-6 {
        return invalid(format!(
            "loudness_shortfall_db must be {expected_shortfall:.6} for the selected gains"
        ));
    }
    if plan.bypass
        && (plan.desired_gain_db != 0.0
            || plan.applied_gain_db != 0.0
            || plan.eq.iter().any(|filter| filter.gain_db != 0.0))
    {
        return invalid("bypass plans must have zero gain and zero EQ");
    }

    Ok(())
}

fn fixed_eq(gains: [f64; 3]) -> Vec<EqFilterV1> {
    vec![
        EqFilterV1 {
            kind: EqFilterKindV1::LowShelf,
            frequency_hz: 120.0,
            q: 0.707,
            gain_db: gains[0],
        },
        EqFilterV1 {
            kind: EqFilterKindV1::Bell,
            frequency_hz: 1_000.0,
            q: 0.5,
            gain_db: gains[1],
        },
        EqFilterV1 {
            kind: EqFilterKindV1::HighShelf,
            frequency_hz: 6_000.0,
            q: 0.707,
            gain_db: gains[2],
        },
    ]
}

fn safe_max_gain(target: &TrackAnalysisV1, eq: &[EqFilterV1]) -> f64 {
    let maximum_eq_boost: f64 = eq.iter().map(|filter| filter.gain_db.max(0.0)).sum();
    TRUE_PEAK_CEILING_DBTP - target.loudness.true_peak_dbtp - maximum_eq_boost
}

fn average(values: &[f64]) -> f64 {
    values.iter().sum::<f64>() / values.len().max(1) as f64
}

fn check_range(field: &str, value: f64, min: f64, max: f64) -> Result<()> {
    if value.is_finite() && (min..=max).contains(&value) {
        Ok(())
    } else {
        invalid(format!("{field}={value} is outside {min}..={max}"))
    }
}

fn invalid<T>(message: impl Into<String>) -> Result<T> {
    Err(DoppelbangerError::InvalidPlan(message.into()))
}
