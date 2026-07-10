use std::mem::size_of;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;

use crate::{
    EqFilterKindV1, EqFilterV1, MasteringPlanV1, MasteringProcessor, PROCESSOR_VERSION,
    TRUE_PEAK_CEILING_DBTP,
};

mod process;
pub use process::db_processor_process_f32;

pub const DB_ABI_VERSION: u32 = 1;
pub const DB_PLAN_SCHEMA_VERSION: u32 = 1;
pub const DB_PROCESSOR_VERSION: u32 = 1;
pub const DB_MAX_BLOCK_FRAMES: u32 = 8_192;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(i32)]
pub enum DbStatus {
    Ok = 0,
    NullPointer = 1,
    IncompatibleVersion = 2,
    InvalidConfiguration = 3,
    BlockTooLarge = 4,
    AliasedChannels = 5,
    InvalidBuffer = 6,
    ProcessFault = 7,
    Panic = 255,
}

#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct DbRuntimePlanV1 {
    pub struct_size: u32,
    pub abi_version: u32,
    pub plan_schema_version: u32,
    pub processor_version: u32,
    pub bypass: u32,
    pub reserved: u32,
    pub applied_gain_db: f64,
    pub eq_gains_db: [f64; 3],
}

pub struct DbProcessor {
    processor: MasteringProcessor,
    max_block_frames: u32,
    faulted: bool,
    #[cfg(test)]
    panic_next_process: bool,
}

#[unsafe(no_mangle)]
/// Creates an opaque realtime processor handle.
///
/// # Safety
///
/// `plan` must point to a readable `struct_size`. When that value matches
/// `DbRuntimePlanV1`, the full structure must be readable. `output` must point to aligned,
/// writable pointer storage. A successful handle must be destroyed exactly once with
/// `db_processor_destroy`.
pub unsafe extern "C" fn db_processor_create(
    plan: *const DbRuntimePlanV1,
    sample_rate_hz: f64,
    max_block_frames: u32,
    output: *mut *mut DbProcessor,
) -> DbStatus {
    ffi_guard(|| {
        if output.is_null() {
            return DbStatus::NullPointer;
        }
        // SAFETY: The caller guarantees output points to writable pointer storage.
        unsafe { *output = ptr::null_mut() };
        if plan.is_null() {
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
        let Some(sample_rate_hz) = supported_sample_rate(sample_rate_hz) else {
            return DbStatus::InvalidConfiguration;
        };
        if !(1..=DB_MAX_BLOCK_FRAMES).contains(&max_block_frames) {
            return DbStatus::InvalidConfiguration;
        }
        let Some(plan) = mastering_plan(&plan) else {
            return DbStatus::InvalidConfiguration;
        };
        let Ok(processor) = MasteringProcessor::new(&plan, sample_rate_hz) else {
            return DbStatus::InvalidConfiguration;
        };
        // SAFETY: output was checked above and receives ownership of the Box allocation.
        unsafe {
            *output = Box::into_raw(Box::new(DbProcessor {
                processor,
                max_block_frames,
                faulted: false,
                #[cfg(test)]
                panic_next_process: false,
            }))
        };
        DbStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Clears filter history.
///
/// # Safety
///
/// `processor` must be a live handle returned by `db_processor_create` and must not be
/// accessed concurrently for the duration of the call.
pub unsafe extern "C" fn db_processor_reset(processor: *mut DbProcessor) -> DbStatus {
    ffi_guard(|| {
        if processor.is_null() {
            return DbStatus::NullPointer;
        }
        // SAFETY: The caller owns a live handle returned by db_processor_create.
        unsafe {
            (*processor).processor.reset();
            (*processor).faulted = false;
        }
        DbStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the processor latency in samples.
///
/// # Safety
///
/// `processor` must be a live handle returned by `db_processor_create` and remain readable
/// without concurrent access for the duration of the call.
pub unsafe extern "C" fn db_processor_latency_samples(processor: *const DbProcessor) -> u32 {
    catch_unwind(AssertUnwindSafe(|| {
        if processor.is_null() {
            return u32::MAX;
        }
        // SAFETY: The caller owns a live handle returned by db_processor_create.
        unsafe { (*processor).processor.latency_samples() }
    }))
    .unwrap_or(u32::MAX)
}

#[unsafe(no_mangle)]
/// Destroys an opaque processor handle.
///
/// # Safety
///
/// `processor` must be a live handle returned by `db_processor_create`, must not be accessed
/// concurrently, and must not be used again after this call.
pub unsafe extern "C" fn db_processor_destroy(processor: *mut DbProcessor) -> DbStatus {
    ffi_guard(|| {
        if processor.is_null() {
            return DbStatus::NullPointer;
        }
        // SAFETY: The caller transfers the live allocation returned by db_processor_create.
        drop(unsafe { Box::from_raw(processor) });
        DbStatus::Ok
    })
}

fn ffi_guard(operation: impl FnOnce() -> DbStatus) -> DbStatus {
    catch_unwind(AssertUnwindSafe(operation)).unwrap_or(DbStatus::Panic)
}

fn runtime_plan_version_is_compatible(plan: &DbRuntimePlanV1) -> bool {
    plan.abi_version == DB_ABI_VERSION
        && plan.plan_schema_version == DB_PLAN_SCHEMA_VERSION
        && plan.processor_version == DB_PROCESSOR_VERSION
        && plan.reserved == 0
}

fn supported_sample_rate(sample_rate_hz: f64) -> Option<u32> {
    [44_100_u32, 48_000, 88_200, 96_000, 192_000]
        .into_iter()
        .find(|&supported| sample_rate_hz == supported as f64)
}

fn mastering_plan(runtime: &DbRuntimePlanV1) -> Option<MasteringPlanV1> {
    if runtime.bypass > 1
        || !runtime.applied_gain_db.is_finite()
        || runtime.eq_gains_db.iter().any(|gain| !gain.is_finite())
    {
        return None;
    }
    Some(MasteringPlanV1 {
        schema_version: DB_PLAN_SCHEMA_VERSION,
        analyzer_version: "plugin-runtime-v1".to_string(),
        processor_version: PROCESSOR_VERSION.to_string(),
        reference_sha256: "embedded-runtime-plan".to_string(),
        target_sha256: "embedded-runtime-plan".to_string(),
        bypass: runtime.bypass == 1,
        desired_gain_db: runtime.applied_gain_db,
        applied_gain_db: runtime.applied_gain_db,
        loudness_shortfall_db: 0.0,
        true_peak_ceiling_dbtp: TRUE_PEAK_CEILING_DBTP,
        eq: [
            (EqFilterKindV1::LowShelf, 120.0, 0.707),
            (EqFilterKindV1::Bell, 1_000.0, 0.5),
            (EqFilterKindV1::HighShelf, 6_000.0, 0.707),
        ]
        .into_iter()
        .zip(runtime.eq_gains_db)
        .map(|((kind, frequency_hz, q), gain_db)| EqFilterV1 {
            kind,
            frequency_hz,
            q,
            gain_db,
        })
        .collect(),
    })
}
