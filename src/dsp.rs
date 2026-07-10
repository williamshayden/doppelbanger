use std::fmt;

use biquad::{Biquad, Coefficients, DirectForm2Transposed, ToHertz, Type};

use crate::{
    DoppelbangerError, EqFilterKindV1, EqFilterV1, MasteringPlanV1, PROCESSOR_VERSION, Result,
};

pub struct MasteringProcessor {
    filters: [StereoBiquad; 3],
    gain: f32,
    bypass: bool,
}

impl MasteringProcessor {
    pub fn new(plan: &MasteringPlanV1, sample_rate_hz: u32) -> Result<Self> {
        validate_runtime_plan(plan, sample_rate_hz)?;
        let filters: &[EqFilterV1; 3] = plan.eq.as_slice().try_into().map_err(|_| {
            DoppelbangerError::InvalidPlan(format!(
                "eq must contain 3 filters, got {}",
                plan.eq.len()
            ))
        })?;

        Ok(Self {
            filters: [
                StereoBiquad::new(&filters[0], sample_rate_hz)?,
                StereoBiquad::new(&filters[1], sample_rate_hz)?,
                StereoBiquad::new(&filters[2], sample_rate_hz)?,
            ],
            gain: 10.0_f32.powf(plan.applied_gain_db as f32 / 20.0),
            bypass: plan.bypass,
        })
    }

    pub fn process_interleaved(
        &mut self,
        samples: &mut [f32],
    ) -> std::result::Result<(), ProcessError> {
        if !samples.len().is_multiple_of(2) {
            return Err(ProcessError::OddSampleCount);
        }
        if self.bypass {
            if samples.iter().any(|sample| !sample.is_finite()) {
                samples.fill(0.0);
                return Err(ProcessError::NonFiniteOutput);
            }
            return Ok(());
        }

        for frame in samples.chunks_exact_mut(2) {
            match self.process_frame(frame[0], frame[1]) {
                Some((left, right)) => {
                    frame[0] = left;
                    frame[1] = right;
                }
                None => {
                    samples.fill(0.0);
                    return Err(ProcessError::NonFiniteOutput);
                }
            }
        }
        Ok(())
    }

    pub fn process_planar(
        &mut self,
        left: &mut [f32],
        right: &mut [f32],
    ) -> std::result::Result<(), ProcessError> {
        if left.len() != right.len() {
            return Err(ProcessError::ChannelLengthMismatch);
        }
        if self.bypass {
            if left
                .iter()
                .chain(right.iter())
                .any(|sample| !sample.is_finite())
            {
                left.fill(0.0);
                right.fill(0.0);
                return Err(ProcessError::NonFiniteOutput);
            }
            return Ok(());
        }

        for index in 0..left.len() {
            match self.process_frame(left[index], right[index]) {
                Some((processed_left, processed_right)) => {
                    left[index] = processed_left;
                    right[index] = processed_right;
                }
                None => {
                    left.fill(0.0);
                    right.fill(0.0);
                    return Err(ProcessError::NonFiniteOutput);
                }
            }
        }
        Ok(())
    }

    pub fn reset(&mut self) {
        for filter in &mut self.filters {
            filter.left.reset_state();
            filter.right.reset_state();
        }
    }

    pub const fn latency_samples(&self) -> u32 {
        0
    }

    fn process_frame(&mut self, mut left: f32, mut right: f32) -> Option<(f32, f32)> {
        for filter in &mut self.filters {
            left = filter.left.run(left);
            right = filter.right.run(right);
        }
        left *= self.gain;
        right *= self.gain;
        (left.is_finite() && right.is_finite()).then_some((left, right))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProcessError {
    OddSampleCount,
    ChannelLengthMismatch,
    NonFiniteOutput,
}

impl fmt::Display for ProcessError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::OddSampleCount => {
                formatter.write_str("stereo interleaved buffers require an even sample count")
            }
            Self::ChannelLengthMismatch => {
                formatter.write_str("planar stereo channels require equal frame counts")
            }
            Self::NonFiniteOutput => formatter.write_str("processor produced a non-finite sample"),
        }
    }
}

impl std::error::Error for ProcessError {}

struct StereoBiquad {
    left: DirectForm2Transposed<f32>,
    right: DirectForm2Transposed<f32>,
}

impl StereoBiquad {
    fn new(filter: &EqFilterV1, sample_rate_hz: u32) -> Result<Self> {
        let filter_type = match filter.kind {
            EqFilterKindV1::LowShelf => Type::LowShelf(filter.gain_db as f32),
            EqFilterKindV1::Bell => Type::PeakingEQ(filter.gain_db as f32),
            EqFilterKindV1::HighShelf => Type::HighShelf(filter.gain_db as f32),
        };
        let coefficients = Coefficients::<f32>::from_params(
            filter_type,
            (sample_rate_hz as f32).hz(),
            (filter.frequency_hz as f32).hz(),
            filter.q as f32,
        )
        .map_err(|error| {
            DoppelbangerError::InvalidPlan(format!(
                "cannot create {:?} filter at {} Hz: {error:?}",
                filter.kind, filter.frequency_hz
            ))
        })?;
        Ok(Self {
            left: DirectForm2Transposed::new(coefficients),
            right: DirectForm2Transposed::new(coefficients),
        })
    }
}

fn validate_runtime_plan(plan: &MasteringPlanV1, sample_rate_hz: u32) -> Result<()> {
    if sample_rate_hz == 0 {
        return Err(DoppelbangerError::InvalidPlan(
            "sample_rate_hz must be greater than zero".to_string(),
        ));
    }
    if plan.schema_version != 1 {
        return Err(DoppelbangerError::InvalidPlan(
            "schema_version must be 1".to_string(),
        ));
    }
    if plan.processor_version != PROCESSOR_VERSION {
        return Err(DoppelbangerError::InvalidPlan(format!(
            "processor_version must be {PROCESSOR_VERSION}, got {}",
            plan.processor_version
        )));
    }
    if !plan.applied_gain_db.is_finite() || !(-12.0..=12.0).contains(&plan.applied_gain_db) {
        return Err(DoppelbangerError::InvalidPlan(format!(
            "applied_gain_db={} is outside -12..=12",
            plan.applied_gain_db
        )));
    }
    if plan.eq.len() != 3 {
        return Err(DoppelbangerError::InvalidPlan(format!(
            "eq must contain 3 filters, got {}",
            plan.eq.len()
        )));
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
            return Err(DoppelbangerError::InvalidPlan(format!(
                "eq[{index}] topology must remain kind={kind:?}, frequency_hz={frequency_hz}, q={q}"
            )));
        }
        if !filter.frequency_hz.is_finite()
            || filter.frequency_hz <= 0.0
            || filter.frequency_hz >= sample_rate_hz as f64 * 0.5
            || !filter.q.is_finite()
            || filter.q <= 0.0
            || !filter.gain_db.is_finite()
            || !(-3.0..=3.0).contains(&filter.gain_db)
        {
            return Err(DoppelbangerError::InvalidPlan(format!(
                "eq[{index}] is invalid for sample_rate_hz={sample_rate_hz}"
            )));
        }
    }
    if plan.bypass
        && (plan.applied_gain_db != 0.0 || plan.eq.iter().any(|filter| filter.gain_db != 0.0))
    {
        return Err(DoppelbangerError::InvalidPlan(
            "bypass plans must have zero gain and zero EQ".to_string(),
        ));
    }
    Ok(())
}
