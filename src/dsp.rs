use std::fmt;
#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};

use biquad::{Biquad, Coefficients, DirectForm2Transposed, ToHertz, Type};

use crate::{
    DoppelbangerError, EqFilterKindV1, EqFilterV1, MasteringPlanV1, PROCESSOR_VERSION, Result,
};

const EQ_AUTOMATION_STEPS: usize = 601;
const OUTPUT_AUTOMATION_STEPS: usize = 2_401;
const EQ_ZERO_INDEX: usize = 300;
const OUTPUT_ZERO_INDEX: usize = 1_200;

#[cfg(test)]
static COEFFICIENT_DESIGN_COUNT: AtomicUsize = AtomicUsize::new(0);

#[cfg(test)]
pub(crate) fn coefficient_design_count_for_tests() -> usize {
    COEFFICIENT_DESIGN_COUNT.load(Ordering::Relaxed)
}

pub struct MasteringProcessor {
    filters: [StereoBiquad; 3],
    current: ProcessorTargets,
    target: ProcessorTargets,
    ramp_samples: u32,
    ramp_remaining: u32,
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

        let targets = ProcessorTargets::new(
            plan.bypass,
            plan.applied_gain_db,
            [filters[0].gain_db, filters[1].gain_db, filters[2].gain_db],
            sample_rate_hz,
        )?;

        Ok(Self {
            filters: [
                StereoBiquad::new(targets.filter_coefficients[0]),
                StereoBiquad::new(targets.filter_coefficients[1]),
                StereoBiquad::new(targets.filter_coefficients[2]),
            ],
            current: targets,
            target: targets,
            ramp_samples: (sample_rate_hz / 100).max(1),
            ramp_remaining: 0,
        })
    }

    pub(crate) fn prepare_runtime_targets(
        &self,
        bypass: bool,
        applied_gain_db: f64,
        eq_gains_db: [f64; 3],
        sample_rate_hz: u32,
    ) -> Result<ProcessorTargets> {
        ProcessorTargets::new(bypass, applied_gain_db, eq_gains_db, sample_rate_hz)
    }

    pub(crate) fn apply_runtime_targets(&mut self, targets: ProcessorTargets) {
        self.target = targets;
        self.ramp_remaining = self.ramp_samples;
    }

    pub fn process_interleaved(
        &mut self,
        samples: &mut [f32],
    ) -> std::result::Result<(), ProcessError> {
        if !samples.len().is_multiple_of(2) {
            return Err(ProcessError::OddSampleCount);
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

    fn process_frame(&mut self, left: f32, right: f32) -> Option<(f32, f32)> {
        if !left.is_finite() || !right.is_finite() {
            return None;
        }
        self.advance_ramp();
        if self.current.wet == 0.0 {
            return Some((left, right));
        }

        let dry_left = left;
        let dry_right = right;
        let mut left = left;
        let mut right = right;
        for filter in &mut self.filters {
            left = filter.left.run(left);
            right = filter.right.run(right);
        }
        left *= self.current.gain;
        right *= self.current.gain;
        if self.current.wet != 1.0 {
            left = dry_left + self.current.wet * (left - dry_left);
            right = dry_right + self.current.wet * (right - dry_right);
        }
        (left.is_finite() && right.is_finite()).then_some((left, right))
    }

    fn advance_ramp(&mut self) {
        if self.ramp_remaining == 0 {
            return;
        }
        if self.ramp_remaining == 1 {
            self.current = self.target;
        } else {
            self.current = self
                .current
                .step_toward(self.target, self.ramp_remaining as f32);
        }
        self.ramp_remaining -= 1;
        for (filter, coefficients) in self
            .filters
            .iter_mut()
            .zip(self.current.filter_coefficients)
        {
            filter.update_coefficients(coefficients);
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) struct ProcessorTargets {
    filter_coefficients: [Coefficients<f32>; 3],
    gain: f32,
    wet: f32,
}

impl ProcessorTargets {
    pub(crate) fn new(
        bypass: bool,
        applied_gain_db: f64,
        eq_gains_db: [f64; 3],
        sample_rate_hz: u32,
    ) -> Result<Self> {
        Ok(Self {
            filter_coefficients: [
                StereoBiquad::coefficients(
                    EqFilterKindV1::LowShelf,
                    120.0,
                    0.707,
                    eq_gains_db[0],
                    sample_rate_hz,
                )?,
                StereoBiquad::coefficients(
                    EqFilterKindV1::Bell,
                    1_000.0,
                    0.5,
                    eq_gains_db[1],
                    sample_rate_hz,
                )?,
                StereoBiquad::coefficients(
                    EqFilterKindV1::HighShelf,
                    6_000.0,
                    0.707,
                    eq_gains_db[2],
                    sample_rate_hz,
                )?,
            ],
            gain: 10.0_f32.powf(applied_gain_db as f32 / 20.0),
            wet: if bypass { 0.0 } else { 1.0 },
        })
    }

    fn step_toward(self, target: Self, remaining: f32) -> Self {
        Self {
            filter_coefficients: [
                step_coefficients(
                    self.filter_coefficients[0],
                    target.filter_coefficients[0],
                    remaining,
                ),
                step_coefficients(
                    self.filter_coefficients[1],
                    target.filter_coefficients[1],
                    remaining,
                ),
                step_coefficients(
                    self.filter_coefficients[2],
                    target.filter_coefficients[2],
                    remaining,
                ),
            ],
            gain: step(self.gain, target.gain, remaining),
            wet: step(self.wet, target.wet, remaining),
        }
    }

    pub(crate) fn from_components(filter_coefficients: [[f32; 5]; 3], gain: f32, wet: f32) -> Self {
        Self {
            filter_coefficients: filter_coefficients.map(coefficients_from_array),
            gain,
            wet,
        }
    }

    pub(crate) fn components(self) -> ([[f32; 5]; 3], f32, f32) {
        (
            self.filter_coefficients.map(coefficients_to_array),
            self.gain,
            self.wet,
        )
    }
}

pub(crate) struct SteppedAutomationTables {
    low_eq: Box<[Coefficients<f32>]>,
    mid_eq: Box<[Coefficients<f32>]>,
    high_eq: Box<[Coefficients<f32>]>,
    output_gain: Box<[f32]>,
    base: ProcessorTargets,
}

impl SteppedAutomationTables {
    pub(crate) fn new(sample_rate_hz: u32) -> Result<Self> {
        let low_eq = coefficient_table(EqFilterKindV1::LowShelf, 120.0, 0.707, sample_rate_hz)?;
        let mid_eq = coefficient_table(EqFilterKindV1::Bell, 1_000.0, 0.5, sample_rate_hz)?;
        let high_eq = coefficient_table(EqFilterKindV1::HighShelf, 6_000.0, 0.707, sample_rate_hz)?;
        let output_gain: Box<[f32]> = (-1_200..=1_200)
            .map(|centibel| {
                let gain_db = centibel as f64 / 100.0;
                10.0_f32.powf(gain_db as f32 / 20.0)
            })
            .collect::<Vec<_>>()
            .into_boxed_slice();
        debug_assert_eq!(low_eq.len(), EQ_AUTOMATION_STEPS);
        debug_assert_eq!(mid_eq.len(), EQ_AUTOMATION_STEPS);
        debug_assert_eq!(high_eq.len(), EQ_AUTOMATION_STEPS);
        debug_assert_eq!(output_gain.len(), OUTPUT_AUTOMATION_STEPS);
        let base = ProcessorTargets {
            filter_coefficients: [
                low_eq[EQ_ZERO_INDEX],
                mid_eq[EQ_ZERO_INDEX],
                high_eq[EQ_ZERO_INDEX],
            ],
            gain: output_gain[OUTPUT_ZERO_INDEX],
            wet: 1.0,
        };
        Ok(Self {
            low_eq,
            mid_eq,
            high_eq,
            output_gain,
            base,
        })
    }

    pub(crate) fn targets(
        &self,
        bypass: bool,
        output_index: usize,
        eq_indices: [usize; 3],
    ) -> ProcessorTargets {
        let mut targets = self.base;
        targets.filter_coefficients = [
            self.low_eq[eq_indices[0]],
            self.mid_eq[eq_indices[1]],
            self.high_eq[eq_indices[2]],
        ];
        targets.gain = self.output_gain[output_index];
        targets.wet = if bypass { 0.0 } else { 1.0 };
        targets
    }
}

fn coefficient_table(
    kind: EqFilterKindV1,
    frequency_hz: f64,
    q: f64,
    sample_rate_hz: u32,
) -> Result<Box<[Coefficients<f32>]>> {
    (-300..=300)
        .map(|centibel| {
            StereoBiquad::coefficients(
                kind,
                frequency_hz,
                q,
                centibel as f64 / 100.0,
                sample_rate_hz,
            )
        })
        .collect::<Result<Vec<_>>>()
        .map(Vec::into_boxed_slice)
}

fn coefficients_to_array(coefficients: Coefficients<f32>) -> [f32; 5] {
    [
        coefficients.a1,
        coefficients.a2,
        coefficients.b0,
        coefficients.b1,
        coefficients.b2,
    ]
}

fn coefficients_from_array(values: [f32; 5]) -> Coefficients<f32> {
    Coefficients {
        a1: values[0],
        a2: values[1],
        b0: values[2],
        b1: values[3],
        b2: values[4],
    }
}

fn step_coefficients(
    current: Coefficients<f32>,
    target: Coefficients<f32>,
    remaining: f32,
) -> Coefficients<f32> {
    Coefficients {
        a1: step(current.a1, target.a1, remaining),
        a2: step(current.a2, target.a2, remaining),
        b0: step(current.b0, target.b0, remaining),
        b1: step(current.b1, target.b1, remaining),
        b2: step(current.b2, target.b2, remaining),
    }
}

fn step(current: f32, target: f32, remaining: f32) -> f32 {
    current + (target - current) / remaining
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
    fn new(coefficients: Coefficients<f32>) -> Self {
        Self {
            left: DirectForm2Transposed::new(coefficients),
            right: DirectForm2Transposed::new(coefficients),
        }
    }

    fn coefficients(
        kind: EqFilterKindV1,
        frequency_hz: f64,
        q: f64,
        gain_db: f64,
        sample_rate_hz: u32,
    ) -> Result<Coefficients<f32>> {
        #[cfg(test)]
        COEFFICIENT_DESIGN_COUNT.fetch_add(1, Ordering::Relaxed);
        let filter_type = match kind {
            EqFilterKindV1::LowShelf => Type::LowShelf(gain_db as f32),
            EqFilterKindV1::Bell => Type::PeakingEQ(gain_db as f32),
            EqFilterKindV1::HighShelf => Type::HighShelf(gain_db as f32),
        };
        Coefficients::<f32>::from_params(
            filter_type,
            (sample_rate_hz as f32).hz(),
            (frequency_hz as f32).hz(),
            q as f32,
        )
        .map_err(|error| {
            DoppelbangerError::InvalidPlan(format!(
                "cannot create {kind:?} filter at {frequency_hz} Hz: {error:?}"
            ))
        })
    }

    fn update_coefficients(&mut self, coefficients: Coefficients<f32>) {
        self.left.update_coefficients(coefficients);
        self.right.update_coefficients(coefficients);
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
