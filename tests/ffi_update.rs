use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::mem::{MaybeUninit, align_of, offset_of, size_of};
use std::ptr;
use std::sync::atomic::{AtomicUsize, Ordering};

use doppelbanger::{
    DB_ABI_VERSION, DB_MAX_BLOCK_FRAMES, DB_PLAN_SCHEMA_VERSION, DB_PROCESSOR_VERSION,
    DbMeterSnapshotV1, DbProcessor, DbRuntimePlanV1, DbStatus, db_processor_create,
    db_processor_destroy, db_processor_get_meter_v1, db_processor_process_f32,
    db_processor_set_plan_v1,
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

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        count(&ALLOCATIONS);
        unsafe { System.alloc_zeroed(layout) }
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
fn update_and_meter_preserve_the_v1_layout_and_status_contracts() {
    assert_eq!(size_of::<DbStatus>(), 4);
    assert_eq!(size_of::<DbRuntimePlanV1>(), 56);
    assert_eq!(align_of::<DbRuntimePlanV1>(), 8);
    assert_eq!(offset_of!(DbRuntimePlanV1, struct_size), 0);
    assert_eq!(offset_of!(DbRuntimePlanV1, abi_version), 4);
    assert_eq!(offset_of!(DbRuntimePlanV1, plan_schema_version), 8);
    assert_eq!(offset_of!(DbRuntimePlanV1, processor_version), 12);
    assert_eq!(offset_of!(DbRuntimePlanV1, bypass), 16);
    assert_eq!(offset_of!(DbRuntimePlanV1, reserved), 20);
    assert_eq!(offset_of!(DbRuntimePlanV1, applied_gain_db), 24);
    assert_eq!(offset_of!(DbRuntimePlanV1, eq_gains_db), 32);
    assert_eq!(DbStatus::Ok as i32, 0);
    assert_eq!(DbStatus::NullPointer as i32, 1);
    assert_eq!(DbStatus::IncompatibleVersion as i32, 2);
    assert_eq!(DbStatus::InvalidConfiguration as i32, 3);
    assert_eq!(DbStatus::BlockTooLarge as i32, 4);
    assert_eq!(DbStatus::AliasedChannels as i32, 5);
    assert_eq!(DbStatus::InvalidBuffer as i32, 6);
    assert_eq!(DbStatus::ProcessFault as i32, 7);
    assert_eq!(DbStatus::Panic as i32, 255);

    assert_eq!(size_of::<DbMeterSnapshotV1>(), 32);
    assert_eq!(align_of::<DbMeterSnapshotV1>(), 4);
    assert_eq!(offset_of!(DbMeterSnapshotV1, struct_size), 0);
    assert_eq!(offset_of!(DbMeterSnapshotV1, abi_version), 4);
    assert_eq!(offset_of!(DbMeterSnapshotV1, processor_version), 8);
    assert_eq!(offset_of!(DbMeterSnapshotV1, reserved), 12);
    assert_eq!(offset_of!(DbMeterSnapshotV1, input_peak), 16);
    assert_eq!(offset_of!(DbMeterSnapshotV1, output_peak), 24);
}

#[test]
fn set_plan_rejects_null_and_incompatible_inputs() {
    let plan = runtime_plan();
    let handle = create(&plan, 64, 48_000.0);
    assert_eq!(
        unsafe { db_processor_set_plan_v1(ptr::null_mut(), &plan) },
        DbStatus::NullPointer
    );
    assert_eq!(
        unsafe { db_processor_set_plan_v1(handle, ptr::null()) },
        DbStatus::NullPointer
    );

    for mutate in [
        |value: &mut DbRuntimePlanV1| value.struct_size -= 1,
        |value: &mut DbRuntimePlanV1| value.abi_version += 1,
        |value: &mut DbRuntimePlanV1| value.plan_schema_version += 1,
        |value: &mut DbRuntimePlanV1| value.processor_version += 1,
        |value: &mut DbRuntimePlanV1| value.reserved = 1,
    ] {
        let mut incompatible = plan;
        mutate(&mut incompatible);
        assert_eq!(
            unsafe { db_processor_set_plan_v1(handle, &incompatible) },
            DbStatus::IncompatibleVersion
        );
    }

    assert_eq!(unsafe { db_processor_destroy(handle) }, DbStatus::Ok);
}

#[test]
fn rejected_numeric_updates_are_atomic() {
    let initial = runtime_plan();
    let accepted = DbRuntimePlanV1 {
        applied_gain_db: 4.0,
        eq_gains_db: [2.5, -2.0, 1.5],
        ..initial
    };
    let subject = create(&initial, 64, 48_000.0);
    let reference = create(&initial, 64, 48_000.0);
    assert_eq!(
        unsafe { db_processor_set_plan_v1(subject, &accepted) },
        DbStatus::Ok
    );
    assert_eq!(
        unsafe { db_processor_set_plan_v1(reference, &accepted) },
        DbStatus::Ok
    );

    let invalid_plans = [
        DbRuntimePlanV1 {
            bypass: 2,
            ..accepted
        },
        DbRuntimePlanV1 {
            applied_gain_db: f64::NAN,
            ..accepted
        },
        DbRuntimePlanV1 {
            applied_gain_db: f64::INFINITY,
            ..accepted
        },
        DbRuntimePlanV1 {
            applied_gain_db: 12.001,
            ..accepted
        },
        DbRuntimePlanV1 {
            applied_gain_db: -12.001,
            ..accepted
        },
        DbRuntimePlanV1 {
            eq_gains_db: [f64::NAN, 0.0, 0.0],
            ..accepted
        },
        DbRuntimePlanV1 {
            eq_gains_db: [0.0, f64::NEG_INFINITY, 0.0],
            ..accepted
        },
        DbRuntimePlanV1 {
            eq_gains_db: [0.0, 0.0, 3.001],
            ..accepted
        },
        DbRuntimePlanV1 {
            eq_gains_db: [-3.001, 0.0, 0.0],
            ..accepted
        },
        DbRuntimePlanV1 {
            bypass: 1,
            applied_gain_db: 1.0,
            eq_gains_db: [0.0; 3],
            ..accepted
        },
    ];
    for invalid in invalid_plans {
        assert_eq!(
            unsafe { db_processor_set_plan_v1(subject, &invalid) },
            DbStatus::InvalidConfiguration
        );
    }

    let mut subject_left = [0.125_f32; 64];
    let mut subject_right = [-0.25_f32; 64];
    let mut reference_left = subject_left;
    let mut reference_right = subject_right;
    for _ in 0..8 {
        assert_eq!(
            unsafe {
                db_processor_process_f32(
                    subject,
                    subject_left.as_mut_ptr(),
                    subject_right.as_mut_ptr(),
                    64,
                )
            },
            DbStatus::Ok
        );
        assert_eq!(
            unsafe {
                db_processor_process_f32(
                    reference,
                    reference_left.as_mut_ptr(),
                    reference_right.as_mut_ptr(),
                    64,
                )
            },
            DbStatus::Ok
        );
    }
    assert_eq!(subject_left, reference_left);
    assert_eq!(subject_right, reference_right);

    assert_eq!(unsafe { db_processor_destroy(subject) }, DbStatus::Ok);
    assert_eq!(unsafe { db_processor_destroy(reference) }, DbStatus::Ok);
}

#[test]
fn valid_updates_reach_the_target_within_ten_milliseconds() {
    let initial = runtime_plan();
    let handle = create(&initial, 512, 48_000.0);
    let update = DbRuntimePlanV1 {
        applied_gain_db: 6.0,
        ..initial
    };
    assert_eq!(
        unsafe { db_processor_set_plan_v1(handle, &update) },
        DbStatus::Ok
    );

    let mut left = [0.25_f32; 512];
    let mut right = [-0.25_f32; 512];
    assert_eq!(
        unsafe { db_processor_process_f32(handle, left.as_mut_ptr(), right.as_mut_ptr(), 512) },
        DbStatus::Ok
    );
    let target = 0.25 * 10.0_f32.powf(6.0 / 20.0);
    assert!(left[0] > 0.25 && left[0] < target);
    assert!(
        (left[479] - target).abs() < 2.0e-6,
        "ramp endpoint={}, target={}, delta={}",
        left[479],
        target,
        (left[479] - target).abs()
    );
    assert!((left[511] - target).abs() < 2.0e-6);
    assert!((right[511] + target).abs() < 2.0e-6);

    let bypass = DbRuntimePlanV1 {
        bypass: 1,
        applied_gain_db: 0.0,
        eq_gains_db: [0.0; 3],
        ..initial
    };
    assert_eq!(
        unsafe { db_processor_set_plan_v1(handle, &bypass) },
        DbStatus::Ok
    );
    left.fill(0.125);
    right.fill(-0.125);
    assert_eq!(
        unsafe { db_processor_process_f32(handle, left.as_mut_ptr(), right.as_mut_ptr(), 512) },
        DbStatus::Ok
    );
    assert_eq!(left[511], 0.125);
    assert_eq!(right[511], -0.125);

    assert_eq!(unsafe { db_processor_destroy(handle) }, DbStatus::Ok);
}

#[test]
fn meter_reads_are_finite_versioned_and_non_mutating() {
    let plan = runtime_plan();
    let subject = create(&plan, 64, 48_000.0);
    let reference = create(&plan, 64, 48_000.0);
    let mut meter = meter_snapshot();

    assert_eq!(
        unsafe { db_processor_get_meter_v1(ptr::null(), &mut meter) },
        DbStatus::NullPointer
    );
    assert_eq!(
        unsafe { db_processor_get_meter_v1(subject, ptr::null_mut()) },
        DbStatus::NullPointer
    );
    let mut incompatible = meter;
    incompatible.struct_size -= 1;
    assert_eq!(
        unsafe { db_processor_get_meter_v1(subject, &mut incompatible) },
        DbStatus::IncompatibleVersion
    );

    let mut subject_left = [0.0_f32; 64];
    let mut subject_right = [0.0_f32; 64];
    for index in 0..64 {
        subject_left[index] = index as f32 / 128.0;
        subject_right[index] = -(index as f32 / 96.0);
    }
    let mut reference_left = subject_left;
    let mut reference_right = subject_right;
    assert_eq!(
        unsafe {
            db_processor_process_f32(
                subject,
                subject_left.as_mut_ptr(),
                subject_right.as_mut_ptr(),
                64,
            )
        },
        DbStatus::Ok
    );
    assert_eq!(
        unsafe {
            db_processor_process_f32(
                reference,
                reference_left.as_mut_ptr(),
                reference_right.as_mut_ptr(),
                64,
            )
        },
        DbStatus::Ok
    );
    let mut header_only_meter = meter_snapshot_header_only();
    assert_eq!(
        unsafe { db_processor_get_meter_v1(subject, header_only_meter.as_mut_ptr()) },
        DbStatus::Ok
    );
    // SAFETY: A successful call writes the complete snapshot.
    meter = unsafe { header_only_meter.assume_init() };
    assert_eq!(meter.struct_size as usize, size_of::<DbMeterSnapshotV1>());
    assert_eq!(meter.abi_version, DB_ABI_VERSION);
    assert_eq!(meter.processor_version, DB_PROCESSOR_VERSION);
    assert_eq!(meter.reserved, 0);
    assert_eq!(meter.input_peak, [63.0 / 128.0, 63.0 / 96.0]);
    assert!(
        meter
            .input_peak
            .iter()
            .chain(&meter.output_peak)
            .all(|peak| peak.is_finite() && *peak >= 0.0)
    );
    let first_read = meter;
    for _ in 0..100 {
        assert_eq!(
            unsafe { db_processor_get_meter_v1(subject, &mut meter) },
            DbStatus::Ok
        );
        assert_eq!(meter, first_read);
    }

    subject_left.fill(0.25);
    subject_right.fill(-0.25);
    reference_left = subject_left;
    reference_right = subject_right;
    assert_eq!(
        unsafe {
            db_processor_process_f32(
                subject,
                subject_left.as_mut_ptr(),
                subject_right.as_mut_ptr(),
                64,
            )
        },
        DbStatus::Ok
    );
    assert_eq!(
        unsafe {
            db_processor_process_f32(
                reference,
                reference_left.as_mut_ptr(),
                reference_right.as_mut_ptr(),
                64,
            )
        },
        DbStatus::Ok
    );
    assert_eq!(subject_left, reference_left);
    assert_eq!(subject_right, reference_right);

    assert_eq!(unsafe { db_processor_destroy(subject) }, DbStatus::Ok);
    assert_eq!(unsafe { db_processor_destroy(reference) }, DbStatus::Ok);
}

#[test]
fn ten_thousand_update_process_cycles_allocate_nothing() {
    let initial = runtime_plan();
    let handle = create(&initial, 32, 48_000.0);
    let mut left = [0.125_f32; 32];
    let mut right = [-0.125_f32; 32];
    let plans = [
        initial,
        DbRuntimePlanV1 {
            applied_gain_db: 6.0,
            eq_gains_db: [3.0, -3.0, 1.5],
            ..initial
        },
    ];
    ALLOCATIONS.store(0, Ordering::SeqCst);
    DEALLOCATIONS.store(0, Ordering::SeqCst);

    COUNT_MEMORY.with(|enabled| enabled.set(true));
    for cycle in 0..10_000 {
        left.fill(0.125);
        right.fill(-0.125);
        let plan = &plans[cycle & 1];
        let update_status = unsafe { db_processor_set_plan_v1(handle, plan) };
        let process_status =
            unsafe { db_processor_process_f32(handle, left.as_mut_ptr(), right.as_mut_ptr(), 32) };
        if update_status != DbStatus::Ok || process_status != DbStatus::Ok {
            COUNT_MEMORY.with(|enabled| enabled.set(false));
            panic!("cycle {cycle} failed: update={update_status:?}, process={process_status:?}");
        }
    }
    COUNT_MEMORY.with(|enabled| enabled.set(false));

    assert_eq!(ALLOCATIONS.load(Ordering::SeqCst), 0);
    assert_eq!(DEALLOCATIONS.load(Ordering::SeqCst), 0);
    assert_eq!(unsafe { db_processor_destroy(handle) }, DbStatus::Ok);
}

#[test]
fn randomized_supported_sample_rates_and_block_sizes_remain_finite() {
    let sample_rates = [44_100.0, 48_000.0, 88_200.0, 96_000.0, 192_000.0];
    let block_sizes = [1_u32, 2, 7, 31, 64, 127, 512, 2_047, 8_192];
    let mut random = 0x6a09_e667_f3bc_c909_u64;
    let mut left = vec![0.0_f32; DB_MAX_BLOCK_FRAMES as usize];
    let mut right = vec![0.0_f32; DB_MAX_BLOCK_FRAMES as usize];

    for &sample_rate in &sample_rates {
        let initial = runtime_plan();
        let handle = create(&initial, DB_MAX_BLOCK_FRAMES, sample_rate);
        for iteration in 0..256 {
            let frames = block_sizes[next_u32(&mut random) as usize % block_sizes.len()];
            let plan = DbRuntimePlanV1 {
                applied_gain_db: range(&mut random, -12.0, 12.0),
                eq_gains_db: [
                    range(&mut random, -3.0, 3.0),
                    range(&mut random, -3.0, 3.0),
                    range(&mut random, -3.0, 3.0),
                ],
                ..initial
            };
            assert_eq!(
                unsafe { db_processor_set_plan_v1(handle, &plan) },
                DbStatus::Ok,
                "sample_rate={sample_rate}, iteration={iteration}"
            );
            for frame in 0..frames as usize {
                left[frame] = range(&mut random, -1.0, 1.0) as f32;
                right[frame] = range(&mut random, -1.0, 1.0) as f32;
            }
            assert_eq!(
                unsafe {
                    db_processor_process_f32(handle, left.as_mut_ptr(), right.as_mut_ptr(), frames)
                },
                DbStatus::Ok,
                "sample_rate={sample_rate}, frames={frames}, iteration={iteration}"
            );
            assert!(
                left[..frames as usize]
                    .iter()
                    .chain(&right[..frames as usize])
                    .all(|sample| sample.is_finite()),
                "sample_rate={sample_rate}, frames={frames}, iteration={iteration}"
            );
        }
        assert_eq!(unsafe { db_processor_destroy(handle) }, DbStatus::Ok);
    }
}

fn create(plan: &DbRuntimePlanV1, max_block_frames: u32, sample_rate_hz: f64) -> *mut DbProcessor {
    let mut handle = ptr::null_mut();
    assert_eq!(
        unsafe { db_processor_create(plan, sample_rate_hz, max_block_frames, &mut handle) },
        DbStatus::Ok
    );
    assert!(!handle.is_null());
    handle
}

fn runtime_plan() -> DbRuntimePlanV1 {
    DbRuntimePlanV1 {
        struct_size: size_of::<DbRuntimePlanV1>() as u32,
        abi_version: DB_ABI_VERSION,
        plan_schema_version: DB_PLAN_SCHEMA_VERSION,
        processor_version: DB_PROCESSOR_VERSION,
        bypass: 0,
        reserved: 0,
        applied_gain_db: 0.0,
        eq_gains_db: [0.0; 3],
    }
}

fn meter_snapshot() -> DbMeterSnapshotV1 {
    DbMeterSnapshotV1 {
        struct_size: size_of::<DbMeterSnapshotV1>() as u32,
        abi_version: DB_ABI_VERSION,
        processor_version: DB_PROCESSOR_VERSION,
        reserved: 0,
        input_peak: [0.0; 2],
        output_peak: [0.0; 2],
    }
}

fn meter_snapshot_header_only() -> MaybeUninit<DbMeterSnapshotV1> {
    let mut storage = MaybeUninit::<DbMeterSnapshotV1>::uninit();
    let output = storage.as_mut_ptr();
    // SAFETY: These are the only fields callers must initialize before a meter read. The function
    // under test must not read the intentionally uninitialized peak payload.
    unsafe {
        ptr::addr_of_mut!((*output).struct_size).write(size_of::<DbMeterSnapshotV1>() as u32);
        ptr::addr_of_mut!((*output).abi_version).write(DB_ABI_VERSION);
        ptr::addr_of_mut!((*output).processor_version).write(DB_PROCESSOR_VERSION);
        ptr::addr_of_mut!((*output).reserved).write(0);
    }
    storage
}

fn count(counter: &AtomicUsize) {
    if COUNT_MEMORY
        .try_with(|enabled| enabled.get())
        .unwrap_or(false)
    {
        counter.fetch_add(1, Ordering::SeqCst);
    }
}

fn next_u32(state: &mut u64) -> u32 {
    *state = state
        .wrapping_mul(6_364_136_223_846_793_005)
        .wrapping_add(1);
    (*state >> 32) as u32
}

fn range(state: &mut u64, minimum: f64, maximum: f64) -> f64 {
    let unit = next_u32(state) as f64 / u32::MAX as f64;
    minimum + unit * (maximum - minimum)
}
