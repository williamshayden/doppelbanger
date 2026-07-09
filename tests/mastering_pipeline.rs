use std::fs;
use std::path::{Path, PathBuf};

use doppelbanger::{
    AudioReader, PairDiffV1, analyze_track, generate_plan, render_master, validate_plan,
};

#[test]
fn identity_plan_bypasses_and_preserves_decoded_samples_exactly() {
    let input = fixture_path("identity-input.wav");
    let output = fixture_path("identity-output.wav");
    write_signal(&input, 48_000, 4.0, sine(880.0, 0.5));

    let analysis = analyze_track(&input).unwrap();
    let diff = PairDiffV1::between(&analysis, &analysis).unwrap();
    let plan = generate_plan(&analysis, &analysis, &diff).unwrap();

    assert!(plan.bypass);
    assert_eq!(plan.applied_gain_db, 0.0);
    assert!(plan.eq.iter().all(|filter| filter.gain_db == 0.0));

    let report = render_master(&input, &output, &plan).unwrap();

    assert_eq!(report.output_analysis.metadata.frame_count, 192_000);
    assert_eq!(decoded_samples(&input), decoded_samples(&output));
}

#[test]
fn safe_gain_moves_the_target_toward_the_reference_without_exceeding_ceiling() {
    let reference = fixture_path("gain-reference.wav");
    let target = fixture_path("gain-target.wav");
    let output = fixture_path("gain-output.wav");
    write_signal(&reference, 44_100, 4.0, sine(440.0, 0.5));
    write_signal(&target, 44_100, 4.0, sine(440.0, 0.25));

    let reference_analysis = analyze_track(&reference).unwrap();
    let target_analysis = analyze_track(&target).unwrap();
    let before = PairDiffV1::between(&reference_analysis, &target_analysis).unwrap();
    let plan = generate_plan(&reference_analysis, &target_analysis, &before).unwrap();
    let report = render_master(&target, &output, &plan).unwrap();
    let after = PairDiffV1::between(&reference_analysis, &report.output_analysis).unwrap();

    assert!(!plan.bypass);
    assert!((plan.desired_gain_db - 6.0206).abs() < 0.15);
    assert!(plan.applied_gain_db > 5.5);
    assert!(plan.eq.iter().all(|filter| filter.gain_db.abs() < 0.05));
    assert!(report.output_analysis.loudness.true_peak_dbtp <= -0.9);
    assert!(after.integrated_lufs.abs() < before.integrated_lufs.abs());
    assert_eq!(report.output_analysis.metadata.sample_rate_hz, 44_100);
    assert_eq!(
        report.output_analysis.metadata.frame_count,
        target_analysis.metadata.frame_count
    );
}

#[test]
fn generated_and_edited_plans_enforce_phase_one_bounds() {
    let reference = fixture_path("plan-reference.wav");
    let target = fixture_path("plan-target.wav");
    write_signal(&reference, 48_000, 4.0, |frame, sample_rate| {
        sine_sample(frame, sample_rate, 120.0, 0.2) + sine_sample(frame, sample_rate, 7_000.0, 0.2)
    });
    write_signal(&target, 48_000, 4.0, sine(1_000.0, 0.25));

    let reference_analysis = analyze_track(&reference).unwrap();
    let target_analysis = analyze_track(&target).unwrap();
    let diff = PairDiffV1::between(&reference_analysis, &target_analysis).unwrap();
    let mut plan = generate_plan(&reference_analysis, &target_analysis, &diff).unwrap();

    assert!(
        plan.eq
            .iter()
            .all(|filter| (-3.0..=3.0).contains(&filter.gain_db))
    );
    assert!((-12.0..=12.0).contains(&plan.applied_gain_db));
    validate_plan(&plan, &target_analysis).unwrap();

    plan.eq[0].gain_db = 3.01;
    let error = validate_plan(&plan, &target_analysis)
        .unwrap_err()
        .to_string();
    assert!(error.contains("eq[0].gain_db"));
    assert!(error.contains("-3..=3"));
}

fn decoded_samples(path: &Path) -> Vec<f32> {
    let mut reader = AudioReader::open(path).unwrap();
    let mut samples = Vec::new();
    while let Some(block) = reader.next_block().unwrap() {
        samples.extend(block.samples);
    }
    samples
}

fn fixture_path(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "doppelbanger-mastering-pipeline-{}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn sine(frequency_hz: f32, amplitude: f32) -> impl Fn(usize, u32) -> f32 {
    move |frame, sample_rate| sine_sample(frame, sample_rate, frequency_hz, amplitude)
}

fn sine_sample(frame: usize, sample_rate: u32, frequency_hz: f32, amplitude: f32) -> f32 {
    amplitude * (std::f32::consts::TAU * frequency_hz * frame as f32 / sample_rate as f32).sin()
}

fn write_signal(
    path: &Path,
    sample_rate: u32,
    duration_seconds: f32,
    signal: impl Fn(usize, u32) -> f32,
) {
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut writer = hound::WavWriter::create(path, spec).unwrap();
    let frames = (sample_rate as f32 * duration_seconds) as usize;
    for frame in 0..frames {
        let sample = signal(frame, sample_rate);
        writer.write_sample(sample).unwrap();
        writer.write_sample(sample).unwrap();
    }
    writer.finalize().unwrap();
}
