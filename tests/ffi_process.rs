use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::mem::size_of;
use std::ptr;
use std::sync::atomic::{AtomicUsize, Ordering};

use doppelbanger::{
    DB_ABI_VERSION, DB_PLAN_SCHEMA_VERSION, DB_PROCESSOR_VERSION, DbProcessor, DbRuntimePlanV1,
    DbStatus, EqFilterKindV1, EqFilterV1, MasteringPlanV1, MasteringProcessor, db_processor_create,
    db_processor_destroy, db_processor_process_f32, db_processor_reset,
};

struct CountingAllocator;

thread_local! {
    static COUNT_MEMORY: Cell<bool> = const { Cell::new(false) };
}

static ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);
static DEALLOCATIONS: AtomicUsize = AtomicUsize::new(0);

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        count(&ALLOCATIONS);
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        count(&DEALLOCATIONS);
        unsafe { System.dealloc(pointer, layout) }
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        count(&ALLOCATIONS);
        count(&DEALLOCATIONS);
        unsafe { System.realloc(pointer, layout, size) }
    }
}

#[test]
fn ffi_process_matches_the_direct_planar_adapter_and_reset() {
    let plan = runtime_plan();
    let handle = create(&plan, 512);
    let original_left = signal(256, 440.0);
    let original_right = signal(256, 880.0);
    let mut left = original_left.clone();
    let mut right = original_right.clone();
    let mut expected_left = original_left.clone();
    let mut expected_right = original_right.clone();
    MasteringProcessor::new(&direct_plan(), 48_000)
        .unwrap()
        .process_planar(&mut expected_left, &mut expected_right)
        .unwrap();

    assert_eq!(
        unsafe { db_processor_process_f32(handle, left.as_mut_ptr(), right.as_mut_ptr(), 256) },
        DbStatus::Ok
    );
    assert_eq!((&left, &right), (&expected_left, &expected_right));

    assert_eq!(unsafe { db_processor_reset(handle) }, DbStatus::Ok);
    left = original_left;
    right = original_right;
    assert_eq!(
        unsafe { db_processor_process_f32(handle, left.as_mut_ptr(), right.as_mut_ptr(), 256) },
        DbStatus::Ok
    );
    assert_eq!((&left, &right), (&expected_left, &expected_right));
    assert_eq!(unsafe { db_processor_destroy(handle) }, DbStatus::Ok);
}

#[test]
fn ffi_process_rejects_invalid_buffers_and_latches_non_finite_faults() {
    let handle = create(&runtime_plan(), 128);
    let mut channel = vec![0.0_f32; 256];
    assert_eq!(
        unsafe { db_processor_process_f32(handle, ptr::null_mut(), ptr::null_mut(), 0) },
        DbStatus::Ok
    );
    assert_eq!(
        unsafe { db_processor_process_f32(handle, channel.as_mut_ptr(), channel.as_mut_ptr(), 64) },
        DbStatus::AliasedChannels
    );
    assert_eq!(
        unsafe {
            db_processor_process_f32(
                handle,
                channel.as_mut_ptr(),
                channel.as_mut_ptr().add(32),
                64,
            )
        },
        DbStatus::AliasedChannels
    );
    let mut raw = vec![0_u8; size_of::<f32>() * 64 + 1];
    let misaligned = unsafe { raw.as_mut_ptr().add(1).cast::<f32>() };
    assert_eq!(
        unsafe { db_processor_process_f32(handle, misaligned, channel.as_mut_ptr(), 64) },
        DbStatus::InvalidBuffer
    );
    assert_eq!(
        unsafe { db_processor_process_f32(handle, channel.as_mut_ptr(), ptr::null_mut(), 64) },
        DbStatus::NullPointer
    );
    assert_eq!(
        unsafe {
            db_processor_process_f32(
                handle,
                channel.as_mut_ptr(),
                channel[128..].as_mut_ptr(),
                129,
            )
        },
        DbStatus::BlockTooLarge
    );

    let mut left = signal(64, 440.0);
    let mut right = signal(64, 880.0);
    left[8] = f32::NAN;
    assert_eq!(
        unsafe { db_processor_process_f32(handle, left.as_mut_ptr(), right.as_mut_ptr(), 64) },
        DbStatus::ProcessFault
    );
    assert!(left.iter().chain(&right).all(|sample| *sample == 0.0));
    assert_eq!(
        unsafe { db_processor_process_f32(handle, ptr::null_mut(), ptr::null_mut(), 0) },
        DbStatus::ProcessFault
    );
    assert_eq!(unsafe { db_processor_reset(handle) }, DbStatus::Ok);
    assert_eq!(unsafe { db_processor_destroy(handle) }, DbStatus::Ok);
}

#[test]
fn ffi_process_and_reset_allocate_and_deallocate_nothing() {
    let mut plan = runtime_plan();
    plan.applied_gain_db = 0.0;
    plan.eq_gains_db = [0.0; 3];
    let handle = create(&plan, 256);
    let mut left = signal(256, 440.0);
    let mut right = signal(256, 880.0);
    ALLOCATIONS.store(0, Ordering::SeqCst);
    DEALLOCATIONS.store(0, Ordering::SeqCst);

    COUNT_MEMORY.with(|enabled| enabled.set(true));
    for _ in 0..100 {
        assert_eq!(unsafe { db_processor_reset(handle) }, DbStatus::Ok);
        assert_eq!(
            unsafe { db_processor_process_f32(handle, left.as_mut_ptr(), right.as_mut_ptr(), 256) },
            DbStatus::Ok
        );
    }
    COUNT_MEMORY.with(|enabled| enabled.set(false));

    assert_eq!(ALLOCATIONS.load(Ordering::SeqCst), 0);
    assert_eq!(DEALLOCATIONS.load(Ordering::SeqCst), 0);
    assert_eq!(unsafe { db_processor_destroy(handle) }, DbStatus::Ok);
}

fn create(plan: &DbRuntimePlanV1, max_block_frames: u32) -> *mut DbProcessor {
    let mut handle = ptr::null_mut();
    assert_eq!(
        unsafe { db_processor_create(plan, 48_000.0, max_block_frames, &mut handle) },
        DbStatus::Ok
    );
    handle
}

fn count(counter: &AtomicUsize) {
    if COUNT_MEMORY
        .try_with(|enabled| enabled.get())
        .unwrap_or(false)
    {
        counter.fetch_add(1, Ordering::SeqCst);
    }
}

fn runtime_plan() -> DbRuntimePlanV1 {
    DbRuntimePlanV1 {
        struct_size: size_of::<DbRuntimePlanV1>() as u32,
        abi_version: DB_ABI_VERSION,
        plan_schema_version: DB_PLAN_SCHEMA_VERSION,
        processor_version: DB_PROCESSOR_VERSION,
        bypass: 0,
        reserved: 0,
        applied_gain_db: 1.0,
        eq_gains_db: [1.0, -1.0, 0.5],
    }
}

fn direct_plan() -> MasteringPlanV1 {
    MasteringPlanV1 {
        schema_version: 1,
        analyzer_version: "plugin-runtime-v1".to_string(),
        processor_version: "linear-eq-gain-v1".to_string(),
        reference_sha256: "embedded-runtime-plan".to_string(),
        target_sha256: "embedded-runtime-plan".to_string(),
        bypass: false,
        desired_gain_db: 1.0,
        applied_gain_db: 1.0,
        loudness_shortfall_db: 0.0,
        true_peak_ceiling_dbtp: -1.0,
        eq: [
            (EqFilterKindV1::LowShelf, 120.0, 0.707, 1.0),
            (EqFilterKindV1::Bell, 1_000.0, 0.5, -1.0),
            (EqFilterKindV1::HighShelf, 6_000.0, 0.707, 0.5),
        ]
        .into_iter()
        .map(|(kind, frequency_hz, q, gain_db)| EqFilterV1 {
            kind,
            frequency_hz,
            q,
            gain_db,
        })
        .collect(),
    }
}

fn signal(frames: usize, frequency_hz: f32) -> Vec<f32> {
    (0..frames)
        .map(|frame| 0.25 * (std::f32::consts::TAU * frequency_hz * frame as f32 / 48_000.0).sin())
        .collect()
}
