use std::mem::{align_of, size_of};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;

use super::{DbProcessor, DbStatus};

#[unsafe(no_mangle)]
/// Processes one planar stereo block in place.
///
/// # Safety
///
/// `processor` must be a live handle returned by `db_processor_create`. For nonzero `frames`,
/// `left` and `right` must be aligned, non-overlapping, writable arrays of at least `frames`
/// samples. The handle and buffers must not be accessed concurrently during the call.
pub unsafe extern "C" fn db_processor_process_f32(
    processor: *mut DbProcessor,
    left: *mut f32,
    right: *mut f32,
    frames: u32,
) -> DbStatus {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if processor.is_null() {
            return DbStatus::NullPointer;
        }
        // SAFETY: The caller owns a live handle returned by db_processor_create.
        let processor = unsafe { &mut *processor };
        if frames > processor.max_block_frames {
            return DbStatus::BlockTooLarge;
        }
        if processor.faulted {
            return DbStatus::ProcessFault;
        }
        if frames == 0 {
            return DbStatus::Ok;
        }
        if left.is_null() || right.is_null() {
            return DbStatus::NullPointer;
        }
        if !buffers_are_aligned(left, right) {
            return DbStatus::InvalidBuffer;
        }
        if buffers_overlap(left, right, frames) {
            return DbStatus::AliasedChannels;
        }
        let frames = frames as usize;
        // SAFETY: Null, alignment, maximum length, and overlap were checked above.
        let (left, right) = unsafe {
            (
                slice::from_raw_parts_mut(left, frames),
                slice::from_raw_parts_mut(right, frames),
            )
        };
        #[cfg(test)]
        if std::mem::take(&mut processor.panic_next_process) {
            std::panic::resume_unwind(Box::new("test-induced processor panic"));
        }
        match processor.processor.process_planar(left, right) {
            Ok(()) => DbStatus::Ok,
            Err(_) => {
                processor.faulted = true;
                DbStatus::ProcessFault
            }
        }
    }));

    match result {
        Ok(status) => status,
        Err(_) => {
            // SAFETY: The helper repeats all runtime buffer checks before writing after unwind.
            unsafe { silence_and_latch_after_panic(processor, left, right, frames) };
            DbStatus::Panic
        }
    }
}

fn buffers_are_aligned(left: *mut f32, right: *mut f32) -> bool {
    (left as usize).is_multiple_of(align_of::<f32>())
        && (right as usize).is_multiple_of(align_of::<f32>())
}

fn buffers_overlap(left: *mut f32, right: *mut f32, frames: u32) -> bool {
    let bytes = frames as usize * size_of::<f32>();
    let left_start = left as usize;
    let right_start = right as usize;
    let Some(left_end) = left_start.checked_add(bytes) else {
        return true;
    };
    let Some(right_end) = right_start.checked_add(bytes) else {
        return true;
    };
    left_start < right_end && right_start < left_end
}

unsafe fn silence_and_latch_after_panic(
    processor: *mut DbProcessor,
    left: *mut f32,
    right: *mut f32,
    frames: u32,
) {
    if processor.is_null() {
        return;
    }
    // SAFETY: The FFI contract requires a live handle for every non-null processor pointer.
    let processor = unsafe { &mut *processor };
    processor.faulted = true;
    if frames == 0
        || frames > processor.max_block_frames
        || left.is_null()
        || right.is_null()
        || !buffers_are_aligned(left, right)
        || buffers_overlap(left, right, frames)
    {
        return;
    }
    let frames = frames as usize;
    // SAFETY: The same pointer and length checks as the normal path passed above.
    let (left, right) = unsafe {
        (
            slice::from_raw_parts_mut(left, frames),
            slice::from_raw_parts_mut(right, frames),
        )
    };
    left.fill(0.0);
    right.fill(0.0);
}

#[cfg(test)]
mod tests {
    use std::mem::size_of;
    use std::ptr;

    use super::*;
    use crate::ffi::{
        DB_ABI_VERSION, DB_PLAN_SCHEMA_VERSION, DB_PROCESSOR_VERSION, DbRuntimePlanV1,
        db_processor_create, db_processor_destroy, db_processor_reset,
    };

    #[test]
    fn panic_silences_and_latches_fault_until_reset() {
        let plan = DbRuntimePlanV1 {
            struct_size: size_of::<DbRuntimePlanV1>() as u32,
            abi_version: DB_ABI_VERSION,
            plan_schema_version: DB_PLAN_SCHEMA_VERSION,
            processor_version: DB_PROCESSOR_VERSION,
            bypass: 0,
            reserved: 0,
            applied_gain_db: 0.0,
            eq_gains_db: [0.0; 3],
        };
        let mut handle = ptr::null_mut();
        assert_eq!(
            unsafe { db_processor_create(&plan, 48_000.0, 8, &mut handle) },
            DbStatus::Ok
        );
        let mut left = [0.25_f32; 8];
        let mut right = [-0.25_f32; 8];

        unsafe { (*handle).panic_next_process = true };
        assert_eq!(
            unsafe { db_processor_process_f32(handle, left.as_mut_ptr(), right.as_mut_ptr(), 8) },
            DbStatus::Panic
        );
        assert!(left.iter().chain(&right).all(|sample| *sample == 0.0));
        assert_eq!(
            unsafe { db_processor_process_f32(handle, ptr::null_mut(), ptr::null_mut(), 0) },
            DbStatus::ProcessFault
        );
        assert_eq!(unsafe { db_processor_reset(handle) }, DbStatus::Ok);
        assert_eq!(unsafe { db_processor_destroy(handle) }, DbStatus::Ok);
    }
}
