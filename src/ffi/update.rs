use std::mem::size_of;
use std::ptr;

use crate::dsp::ProcessorTargets;

use super::{
    DB_ABI_VERSION, DB_PROCESSOR_VERSION, DbProcessor, DbRuntimePlanV1, DbStatus, ffi_guard,
    runtime_plan_version_is_compatible, supported_sample_rate,
};

const MAX_ABS_FILTER_COEFFICIENT: f32 = 8.0;
const MIN_PREPARED_GAIN: f32 = 0.25;
const MAX_PREPARED_GAIN: f32 = 4.0;

#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct DbPreparedRuntimeTargetsV1 {
    pub struct_size: u32,
    pub abi_version: u32,
    pub processor_version: u32,
    pub sample_rate_hz: u32,
    /// Coefficient order for each filter is `[a1, a2, b0, b1, b2]`.
    pub filter_coefficients: [[f32; 5]; 3],
    pub gain: f32,
    pub wet: f32,
    pub reserved: u32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct DbMeterSnapshotV1 {
    pub struct_size: u32,
    pub abi_version: u32,
    pub processor_version: u32,
    pub reserved: u32,
    pub input_peak: [f32; 2],
    pub output_peak: [f32; 2],
}

#[unsafe(no_mangle)]
/// Designs one complete fixed-layout target without accessing a processor handle.
///
/// This function performs coefficient design and is not realtime safe. `output` is written only
/// after the complete plan and sample rate have been validated and all targets are prepared.
///
/// # Safety
///
/// `plan` must point to a readable `struct_size`. When that value matches `DbRuntimePlanV1`, the
/// full structure must be readable. `output` must point to writable target storage.
pub unsafe extern "C" fn db_prepare_runtime_plan_v1(
    plan: *const DbRuntimePlanV1,
    sample_rate_hz: f64,
    output: *mut DbPreparedRuntimeTargetsV1,
) -> DbStatus {
    ffi_guard(|| {
        if output.is_null() {
            return DbStatus::NullPointer;
        }
        let plan = match unsafe { read_runtime_plan(plan) } {
            Ok(plan) => plan,
            Err(status) => return status,
        };
        if !runtime_plan_values_are_valid(&plan) {
            return DbStatus::InvalidConfiguration;
        }
        let Some(sample_rate_hz) = supported_sample_rate(sample_rate_hz) else {
            return DbStatus::InvalidConfiguration;
        };
        let Ok(targets) = ProcessorTargets::new(
            plan.bypass == 1,
            plan.applied_gain_db,
            plan.eq_gains_db,
            sample_rate_hz,
        ) else {
            return DbStatus::InvalidConfiguration;
        };
        let prepared = prepared_from_targets(targets, sample_rate_hz);
        // SAFETY: The caller guarantees writable storage and preparation is complete.
        unsafe { ptr::write_unaligned(output, prepared) };
        DbStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Applies an already designed fixed target and begins the existing bounded ramp.
///
/// This call performs only fixed validation and copies. It performs no coefficient design,
/// allocation, lock, wait, I/O, logging, reset, pointer replacement, or destruction.
///
/// # Safety
///
/// `processor` must be a live handle returned by `db_processor_create`. `targets` must point to a
/// readable `struct_size`; a matching size requires the complete target to be readable. The call
/// must not overlap another call on the same handle.
pub unsafe extern "C" fn db_processor_apply_prepared_v1(
    processor: *mut DbProcessor,
    targets: *const DbPreparedRuntimeTargetsV1,
) -> DbStatus {
    ffi_guard(|| {
        if processor.is_null() {
            return DbStatus::NullPointer;
        }
        let targets = match unsafe { read_prepared_targets(targets) } {
            Ok(targets) => targets,
            Err(status) => return status,
        };
        if !prepared_values_are_valid(&targets) {
            return DbStatus::InvalidConfiguration;
        }
        // SAFETY: The caller owns a live handle returned by db_processor_create.
        let processor = unsafe { &mut *processor };
        if targets.sample_rate_hz != processor.sample_rate_hz {
            return DbStatus::InvalidConfiguration;
        }
        processor
            .processor
            .apply_runtime_targets(targets_from_prepared(targets));
        DbStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Applies a plan constrained to the public 0.01 dB grid from immutable Rust-owned tables.
///
/// The tables are built when the processor is created and remain immutable until it is destroyed
/// after processing stops. This call performs no coefficient design, transcendental math,
/// allocation, lock, wait, I/O, logging, table mutation, pointer replacement, or destruction.
///
/// # Safety
///
/// `processor` must be a live handle returned by `db_processor_create`. `plan` must point to a
/// readable `struct_size`; a matching size requires the complete plan to be readable. The call
/// must not overlap another call on the same handle.
pub unsafe extern "C" fn db_processor_apply_stepped_plan_v1(
    processor: *mut DbProcessor,
    plan: *const DbRuntimePlanV1,
) -> DbStatus {
    ffi_guard(|| {
        if processor.is_null() {
            return DbStatus::NullPointer;
        }
        let plan = match unsafe { read_runtime_plan(plan) } {
            Ok(plan) => plan,
            Err(status) => return status,
        };
        if !runtime_plan_values_are_valid(&plan) {
            return DbStatus::InvalidConfiguration;
        }
        let Some((output_index, eq_indices)) = stepped_indices(&plan) else {
            return DbStatus::InvalidConfiguration;
        };
        // SAFETY: The caller owns a live handle returned by db_processor_create.
        let processor = unsafe { &mut *processor };
        let targets =
            processor
                .stepped_automation
                .targets(plan.bypass == 1, output_index, eq_indices);
        processor.processor.apply_runtime_targets(targets);
        DbStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Prepares and replaces the processor's numeric targets after validating the complete V1 plan.
///
/// This compatibility call performs coefficient design and transcendental math. It is not safe to
/// call from an audio callback; realtime callers use one of the two apply functions above.
///
/// # Safety
///
/// `processor` must be a live handle returned by `db_processor_create` and `plan` must point to a
/// readable `struct_size`. When that value matches `DbRuntimePlanV1`, the full structure must be
/// readable. The call must not overlap another call on the same handle.
pub unsafe extern "C" fn db_processor_set_plan_v1(
    processor: *mut DbProcessor,
    plan: *const DbRuntimePlanV1,
) -> DbStatus {
    ffi_guard(|| {
        if processor.is_null() {
            return DbStatus::NullPointer;
        }
        let plan = match unsafe { read_runtime_plan(plan) } {
            Ok(plan) => plan,
            Err(status) => return status,
        };
        if !runtime_plan_values_are_valid(&plan) {
            return DbStatus::InvalidConfiguration;
        }

        // SAFETY: The caller owns a live handle returned by db_processor_create.
        let processor = unsafe { &mut *processor };
        let Ok(targets) = processor.processor.prepare_runtime_targets(
            plan.bypass == 1,
            plan.applied_gain_db,
            plan.eq_gains_db,
            processor.sample_rate_hz,
        ) else {
            return DbStatus::InvalidConfiguration;
        };
        processor.processor.apply_runtime_targets(targets);
        DbStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Copies the most recent successful block's finite stereo input and output peaks.
///
/// # Safety
///
/// `processor` must be a live handle returned by `db_processor_create`. `output` must point to a
/// writable `DbMeterSnapshotV1` whose version fields are initialized. The call must not overlap
/// another call on the same handle.
pub unsafe extern "C" fn db_processor_get_meter_v1(
    processor: *const DbProcessor,
    output: *mut DbMeterSnapshotV1,
) -> DbStatus {
    ffi_guard(|| {
        if processor.is_null() || output.is_null() {
            return DbStatus::NullPointer;
        }
        // SAFETY: The caller initializes the four fixed-width request-header fields. The peak
        // payload is output-only and is not read.
        let (struct_size, abi_version, processor_version, reserved) =
            unsafe { read_meter_request_header(output) };
        if struct_size as usize != size_of::<DbMeterSnapshotV1>() {
            return DbStatus::IncompatibleVersion;
        }
        if abi_version != DB_ABI_VERSION
            || processor_version != DB_PROCESSOR_VERSION
            || reserved != 0
        {
            return DbStatus::IncompatibleVersion;
        }
        // SAFETY: The caller owns a live readable handle and writable snapshot storage.
        let processor = unsafe { &*processor };
        let snapshot = DbMeterSnapshotV1 {
            struct_size: size_of::<DbMeterSnapshotV1>() as u32,
            abi_version: DB_ABI_VERSION,
            processor_version: DB_PROCESSOR_VERSION,
            reserved: 0,
            input_peak: processor.input_peak,
            output_peak: processor.output_peak,
        };
        // SAFETY: The caller guarantees writable storage for a matching V1 structure.
        unsafe { ptr::write_unaligned(output, snapshot) };
        DbStatus::Ok
    })
}

unsafe fn read_meter_request_header(output: *const DbMeterSnapshotV1) -> (u32, u32, u32, u32) {
    let words = output.cast::<u32>();
    // SAFETY: The caller guarantees four initialized, readable u32 request-header fields. Reading
    // them separately avoids materializing the output-only peak payload.
    unsafe {
        (
            ptr::read_unaligned(words),
            ptr::read_unaligned(words.add(1)),
            ptr::read_unaligned(words.add(2)),
            ptr::read_unaligned(words.add(3)),
        )
    }
}

unsafe fn read_runtime_plan(
    plan: *const DbRuntimePlanV1,
) -> std::result::Result<DbRuntimePlanV1, DbStatus> {
    if plan.is_null() {
        return Err(DbStatus::NullPointer);
    }
    // SAFETY: The caller guarantees the first u32 is readable. A shorter layout fails before the
    // complete current structure is accessed.
    let struct_size = unsafe { ptr::read_unaligned(plan.cast::<u32>()) };
    if struct_size as usize != size_of::<DbRuntimePlanV1>() {
        return Err(DbStatus::IncompatibleVersion);
    }
    // SAFETY: A matching struct_size requires the full current structure to be readable.
    let plan = unsafe { ptr::read_unaligned(plan) };
    if !runtime_plan_version_is_compatible(&plan) {
        return Err(DbStatus::IncompatibleVersion);
    }
    Ok(plan)
}

unsafe fn read_prepared_targets(
    targets: *const DbPreparedRuntimeTargetsV1,
) -> std::result::Result<DbPreparedRuntimeTargetsV1, DbStatus> {
    if targets.is_null() {
        return Err(DbStatus::NullPointer);
    }
    // SAFETY: The caller guarantees the first u32 is readable. A shorter layout fails before the
    // complete current structure is accessed.
    let struct_size = unsafe { ptr::read_unaligned(targets.cast::<u32>()) };
    if struct_size as usize != size_of::<DbPreparedRuntimeTargetsV1>() {
        return Err(DbStatus::IncompatibleVersion);
    }
    // SAFETY: A matching struct_size requires the full current structure to be readable.
    let targets = unsafe { ptr::read_unaligned(targets) };
    if targets.abi_version != DB_ABI_VERSION
        || targets.processor_version != DB_PROCESSOR_VERSION
        || targets.reserved != 0
    {
        return Err(DbStatus::IncompatibleVersion);
    }
    Ok(targets)
}

fn prepared_from_targets(
    targets: ProcessorTargets,
    sample_rate_hz: u32,
) -> DbPreparedRuntimeTargetsV1 {
    let (filter_coefficients, gain, wet) = targets.components();
    DbPreparedRuntimeTargetsV1 {
        struct_size: size_of::<DbPreparedRuntimeTargetsV1>() as u32,
        abi_version: DB_ABI_VERSION,
        processor_version: DB_PROCESSOR_VERSION,
        sample_rate_hz,
        filter_coefficients,
        gain,
        wet,
        reserved: 0,
    }
}

fn targets_from_prepared(targets: DbPreparedRuntimeTargetsV1) -> ProcessorTargets {
    ProcessorTargets::from_components(targets.filter_coefficients, targets.gain, targets.wet)
}

fn prepared_values_are_valid(targets: &DbPreparedRuntimeTargetsV1) -> bool {
    targets
        .filter_coefficients
        .iter()
        .flatten()
        .all(|coefficient| {
            coefficient.is_finite() && coefficient.abs() <= MAX_ABS_FILTER_COEFFICIENT
        })
        && targets.gain.is_finite()
        && (MIN_PREPARED_GAIN..=MAX_PREPARED_GAIN).contains(&targets.gain)
        && (targets.wet == 0.0 || targets.wet == 1.0)
}

fn stepped_indices(plan: &DbRuntimePlanV1) -> Option<(usize, [usize; 3])> {
    Some((
        centibel_index(plan.applied_gain_db, -1_200, 1_200)?,
        [
            centibel_index(plan.eq_gains_db[0], -300, 300)?,
            centibel_index(plan.eq_gains_db[1], -300, 300)?,
            centibel_index(plan.eq_gains_db[2], -300, 300)?,
        ],
    ))
}

fn centibel_index(value: f64, minimum: i32, maximum: i32) -> Option<usize> {
    let scaled = value * 100.0;
    let rounded = scaled.round();
    if !scaled.is_finite() || (scaled - rounded).abs() > 1.0e-8 {
        return None;
    }
    let centibels = rounded as i32;
    if !(minimum..=maximum).contains(&centibels) {
        return None;
    }
    Some((centibels - minimum) as usize)
}

fn runtime_plan_values_are_valid(plan: &DbRuntimePlanV1) -> bool {
    plan.bypass <= 1
        && plan.applied_gain_db.is_finite()
        && (-12.0..=12.0).contains(&plan.applied_gain_db)
        && plan
            .eq_gains_db
            .iter()
            .all(|gain| gain.is_finite() && (-3.0..=3.0).contains(gain))
        && (plan.bypass == 0
            || (plan.applied_gain_db == 0.0 && plan.eq_gains_db.iter().all(|gain| *gain == 0.0)))
}

#[cfg(test)]
mod tests {
    use std::mem::{MaybeUninit, size_of};
    use std::ptr;

    use super::*;
    use crate::dsp::coefficient_design_count_for_tests;
    use crate::ffi::{DB_PLAN_SCHEMA_VERSION, db_processor_create, db_processor_destroy};

    #[test]
    fn meter_request_header_reader_does_not_require_initialized_peaks() {
        let mut storage = MaybeUninit::<DbMeterSnapshotV1>::uninit();
        let output = storage.as_mut_ptr();
        // SAFETY: Only the four public request-header fields are initialized, exactly as required
        // by the C ABI. The peak payload intentionally remains uninitialized.
        unsafe {
            ptr::addr_of_mut!((*output).struct_size).write(size_of::<DbMeterSnapshotV1>() as u32);
            ptr::addr_of_mut!((*output).abi_version).write(DB_ABI_VERSION);
            ptr::addr_of_mut!((*output).processor_version).write(DB_PROCESSOR_VERSION);
            ptr::addr_of_mut!((*output).reserved).write(0);
        }

        // SAFETY: The helper contract permits an uninitialized payload after a valid header.
        let header = unsafe { read_meter_request_header(output) };
        assert_eq!(
            header,
            (
                size_of::<DbMeterSnapshotV1>() as u32,
                DB_ABI_VERSION,
                DB_PROCESSOR_VERSION,
                0,
            )
        );
    }

    #[test]
    fn realtime_apply_paths_never_design_coefficients() {
        let plan = DbRuntimePlanV1 {
            struct_size: size_of::<DbRuntimePlanV1>() as u32,
            abi_version: DB_ABI_VERSION,
            plan_schema_version: DB_PLAN_SCHEMA_VERSION,
            processor_version: DB_PROCESSOR_VERSION,
            bypass: 0,
            reserved: 0,
            applied_gain_db: 1.25,
            eq_gains_db: [0.5, -1.5, 2.0],
        };
        let mut processor = ptr::null_mut();
        assert_eq!(
            unsafe { db_processor_create(&plan, 48_000.0, 64, &mut processor) },
            DbStatus::Ok
        );
        let mut prepared = MaybeUninit::<DbPreparedRuntimeTargetsV1>::uninit();
        assert_eq!(
            unsafe { db_prepare_runtime_plan_v1(&plan, 48_000.0, prepared.as_mut_ptr()) },
            DbStatus::Ok
        );
        // SAFETY: A successful prepare writes the complete fixed target.
        let prepared = unsafe { prepared.assume_init() };
        let designs_before = coefficient_design_count_for_tests();

        for _ in 0..100 {
            assert_eq!(
                unsafe { db_processor_apply_prepared_v1(processor, &prepared) },
                DbStatus::Ok
            );
            assert_eq!(
                unsafe { db_processor_apply_stepped_plan_v1(processor, &plan) },
                DbStatus::Ok
            );
        }

        assert_eq!(coefficient_design_count_for_tests(), designs_before);
        assert_eq!(unsafe { db_processor_destroy(processor) }, DbStatus::Ok);
    }
}
