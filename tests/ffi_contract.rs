use std::fs;
use std::mem::{align_of, offset_of, size_of};
use std::ptr;

use doppelbanger::{
    DB_ABI_VERSION, DB_PLAN_SCHEMA_VERSION, DB_PROCESSOR_VERSION, DbProcessor, DbRuntimePlanV1,
    DbStatus, db_processor_create, db_processor_destroy, db_processor_latency_samples,
    db_processor_reset,
};

#[test]
fn c_abi_owns_one_resettable_zero_latency_handle() {
    let plan = runtime_plan();
    let mut handle: *mut DbProcessor = ptr::null_mut();

    assert_eq!(
        unsafe { db_processor_create(&plan, 48_000.0, 512, &mut handle) },
        DbStatus::Ok
    );
    assert!(!handle.is_null());
    assert_eq!(unsafe { db_processor_latency_samples(handle) }, 0);
    assert_eq!(unsafe { db_processor_reset(handle) }, DbStatus::Ok);
    assert_eq!(unsafe { db_processor_destroy(handle) }, DbStatus::Ok);
}

#[test]
fn c_abi_rejects_null_incompatible_and_short_inputs() {
    let mut plan = runtime_plan();
    let mut handle: *mut DbProcessor = ptr::null_mut();

    assert_eq!(
        unsafe { db_processor_create(ptr::null(), 48_000.0, 512, &mut handle) },
        DbStatus::NullPointer
    );
    assert_eq!(
        unsafe { db_processor_create(&plan, 48_000.0, 512, ptr::null_mut()) },
        DbStatus::NullPointer
    );
    assert_eq!(
        unsafe { db_processor_reset(ptr::null_mut()) },
        DbStatus::NullPointer
    );
    assert_eq!(
        unsafe { db_processor_destroy(ptr::null_mut()) },
        DbStatus::NullPointer
    );
    assert_eq!(
        unsafe { db_processor_latency_samples(ptr::null()) },
        u32::MAX
    );

    plan.abi_version += 1;
    assert_eq!(
        unsafe { db_processor_create(&plan, 48_000.0, 512, &mut handle) },
        DbStatus::IncompatibleVersion
    );
    assert!(handle.is_null());

    #[repr(C)]
    struct ShortPlan {
        struct_size: u32,
    }
    let short_plan = ShortPlan {
        struct_size: size_of::<ShortPlan>() as u32,
    };
    assert_eq!(
        unsafe {
            db_processor_create(
                (&raw const short_plan).cast::<DbRuntimePlanV1>(),
                48_000.0,
                512,
                &mut handle,
            )
        },
        DbStatus::IncompatibleVersion
    );
    assert!(handle.is_null());
}

#[test]
fn c_abi_accepts_only_the_supported_sample_rate_and_block_size_matrix() {
    let plan = runtime_plan();
    for sample_rate_hz in [44_100.0, 48_000.0, 88_200.0, 96_000.0, 192_000.0] {
        for max_block_frames in [1, 32, 512, 8_192] {
            let mut handle: *mut DbProcessor = ptr::null_mut();
            assert_eq!(
                unsafe {
                    db_processor_create(&plan, sample_rate_hz, max_block_frames, &mut handle)
                },
                DbStatus::Ok
            );
            assert_eq!(unsafe { db_processor_destroy(handle) }, DbStatus::Ok);
        }
    }

    for (sample_rate_hz, max_block_frames) in [(44_101.0, 512), (48_000.0, 0), (48_000.0, 8_193)] {
        let mut handle: *mut DbProcessor = ptr::null_mut();
        assert_eq!(
            unsafe { db_processor_create(&plan, sample_rate_hz, max_block_frames, &mut handle) },
            DbStatus::InvalidConfiguration
        );
        assert!(handle.is_null());
    }
}

#[test]
fn runtime_plan_and_header_are_versioned_fixed_layout_contracts() {
    let plan = runtime_plan();
    let header = fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/include/doppelbanger_dsp.h"
    ))
    .unwrap();

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
    assert_eq!(plan.struct_size as usize, size_of::<DbRuntimePlanV1>());
    for symbol in [
        "DB_ABI_VERSION",
        "db_runtime_plan_v1",
        "db_processor_create",
        "db_processor_reset",
        "db_processor_latency_samples",
        "db_processor_destroy",
    ] {
        assert!(header.contains(symbol), "header is missing {symbol}");
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
