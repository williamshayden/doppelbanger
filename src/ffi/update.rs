use std::mem::size_of;
use std::ptr;

use super::{
    DB_ABI_VERSION, DB_PROCESSOR_VERSION, DbProcessor, DbRuntimePlanV1, DbStatus, ffi_guard,
    runtime_plan_version_is_compatible,
};

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
/// Replaces the processor's numeric targets after validating the complete V1 plan.
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
        if processor.is_null() || plan.is_null() {
            return DbStatus::NullPointer;
        }
        // SAFETY: The caller guarantees the first u32 is readable. A shorter layout fails before
        // the complete current structure is accessed.
        let struct_size = unsafe { ptr::read_unaligned(plan.cast::<u32>()) };
        if struct_size as usize != size_of::<DbRuntimePlanV1>() {
            return DbStatus::IncompatibleVersion;
        }
        // SAFETY: A matching struct_size requires the full current structure to be readable.
        let plan = unsafe { ptr::read_unaligned(plan) };
        if !runtime_plan_version_is_compatible(&plan) {
            return DbStatus::IncompatibleVersion;
        }
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
}
