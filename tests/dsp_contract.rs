use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::atomic::{AtomicUsize, Ordering};

use doppelbanger::{EqFilterKindV1, EqFilterV1, MasteringPlanV1, MasteringProcessor};

struct CountingAllocator;

thread_local! {
    static COUNT_ALLOCATIONS: Cell<bool> = const { Cell::new(false) };
}

static ALLOCATION_COUNT: AtomicUsize = AtomicUsize::new(0);

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        record_allocation();
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        record_allocation();
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe { System.dealloc(pointer, layout) }
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        record_allocation();
        unsafe { System.realloc(pointer, layout, size) }
    }
}

#[test]
fn processing_is_block_partition_invariant() {
    let input = signal(4_096);
    let mut whole = input.clone();
    let mut partitioned = input;
    let mut whole_processor = MasteringProcessor::new(&plan(false), 48_000).unwrap();
    let mut partitioned_processor = MasteringProcessor::new(&plan(false), 48_000).unwrap();

    whole_processor.process_interleaved(&mut whole).unwrap();
    for block in partitioned.chunks_exact_mut(2 * 64) {
        partitioned_processor.process_interleaved(block).unwrap();
    }

    assert_eq!(whole, partitioned);
}

#[test]
fn processing_allocates_nothing_after_construction() {
    let mut processor = MasteringProcessor::new(&plan(false), 48_000).unwrap();
    let mut block = signal(256);
    COUNT_ALLOCATIONS.with(|enabled| enabled.set(false));
    ALLOCATION_COUNT.store(0, Ordering::SeqCst);

    COUNT_ALLOCATIONS.with(|enabled| enabled.set(true));
    for _ in 0..100 {
        processor.process_interleaved(&mut block).unwrap();
    }
    COUNT_ALLOCATIONS.with(|enabled| enabled.set(false));

    assert_eq!(ALLOCATION_COUNT.load(Ordering::SeqCst), 0);
}

#[test]
fn bypass_is_an_exact_no_op() {
    let mut samples = signal(128);
    let expected = samples.clone();
    let mut processor = MasteringProcessor::new(&plan(true), 48_000).unwrap();

    processor.process_interleaved(&mut samples).unwrap();

    assert_eq!(samples, expected);
}

#[test]
fn malformed_interleaved_blocks_fail_without_panicking() {
    let mut samples = [0.0_f32; 3];
    let mut processor = MasteringProcessor::new(&plan(false), 48_000).unwrap();

    let error = processor.process_interleaved(&mut samples).unwrap_err();

    assert_eq!(
        error.to_string(),
        "stereo interleaved buffers require an even sample count"
    );
}

#[test]
fn non_finite_processing_silences_the_entire_affected_block() {
    let mut samples = signal(128);
    samples[17] = f32::NAN;
    let mut processor = MasteringProcessor::new(&plan(false), 48_000).unwrap();

    let error = processor.process_interleaved(&mut samples).unwrap_err();

    assert_eq!(error.to_string(), "processor produced a non-finite sample");
    assert!(samples.iter().all(|sample| *sample == 0.0));
}

#[test]
fn processor_rejects_incompatible_schema_and_topology() {
    let mut incompatible_schema = plan(false);
    incompatible_schema.schema_version = 2;
    let schema_error = MasteringProcessor::new(&incompatible_schema, 48_000)
        .err()
        .unwrap()
        .to_string();

    let mut incompatible_topology = plan(false);
    incompatible_topology.eq[0].frequency_hz = 121.0;
    let topology_error = MasteringProcessor::new(&incompatible_topology, 48_000)
        .err()
        .unwrap()
        .to_string();

    assert!(schema_error.contains("schema_version must be 1"));
    assert!(topology_error.contains("eq[0] topology"));
}

#[test]
fn linear_processor_reports_zero_latency_and_accepts_empty_blocks() {
    let mut processor = MasteringProcessor::new(&plan(false), 48_000).unwrap();

    processor.process_interleaved(&mut []).unwrap();

    assert_eq!(processor.latency_samples(), 0);
}

fn record_allocation() {
    if COUNT_ALLOCATIONS
        .try_with(|enabled| enabled.get())
        .unwrap_or(false)
    {
        ALLOCATION_COUNT.fetch_add(1, Ordering::SeqCst);
    }
}

fn signal(frames: usize) -> Vec<f32> {
    let mut samples = Vec::with_capacity(frames * 2);
    for frame in 0..frames {
        let left = (std::f32::consts::TAU * 440.0 * frame as f32 / 48_000.0).sin() * 0.25;
        samples.push(left);
        samples.push(-left * 0.75);
    }
    samples
}

fn plan(bypass: bool) -> MasteringPlanV1 {
    MasteringPlanV1 {
        schema_version: 1,
        analyzer_version: "analysis-v1".to_string(),
        processor_version: "linear-eq-gain-v1".to_string(),
        reference_sha256: "reference".to_string(),
        target_sha256: "target".to_string(),
        bypass,
        desired_gain_db: if bypass { 0.0 } else { 1.0 },
        applied_gain_db: if bypass { 0.0 } else { 1.0 },
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
            gain_db: if bypass { 0.0 } else { gain_db },
        })
        .collect(),
    }
}
