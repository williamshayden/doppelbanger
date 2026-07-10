use std::fs;
use std::path::{Path, PathBuf};

use doppelbanger::{PairDiffV1, SubmitRequest, analyze_track, generate_plan};
use uuid::Uuid;

#[test]
fn builds_canonical_api_submission_for_existing_audio() {
    let reference = fixture_path("request-reference.wav");
    let target = fixture_path("request-target.wav");
    let output = fixture_path("request-output.wav");
    write_sine(&reference, 440.0, 0.5);
    write_sine(&target, 440.0, 0.25);

    let request = SubmitRequest::from_paths(&reference, &target, &output, None, None).unwrap();

    assert!(request.reference_path.is_absolute());
    assert!(request.target_path.is_absolute());
    assert!(request.output_path.is_absolute());
    assert!(request.reference_path.ends_with("request-reference.wav"));
}

#[test]
fn edited_plan_requires_a_parent_request_and_wav_output() {
    let reference = fixture_path("edited-reference.wav");
    let target = fixture_path("edited-target.wav");
    write_sine(&reference, 440.0, 0.5);
    write_sine(&target, 440.0, 0.25);
    let reference_analysis = analyze_track(&reference).unwrap();
    let target_analysis = analyze_track(&target).unwrap();
    let diff = PairDiffV1::between(&reference_analysis, &target_analysis).unwrap();
    let plan = generate_plan(&reference_analysis, &target_analysis, &diff).unwrap();

    let missing_parent = SubmitRequest::from_paths(
        &reference,
        &target,
        fixture_path("edited-output.wav"),
        Some(plan.clone()),
        None,
    )
    .unwrap_err();
    assert!(missing_parent.to_string().contains("provided together"));

    let bad_output = SubmitRequest::from_paths(
        &reference,
        &target,
        fixture_path("edited-output.mp3"),
        Some(plan),
        Some(Uuid::nil()),
    )
    .unwrap_err();
    assert!(bad_output.to_string().contains("output must be a WAV"));
}

#[test]
fn submission_records_the_decoded_format_instead_of_the_extension() {
    let reference = fixture_path("content-is-wav.mp3");
    let target = fixture_path("content-is-also-wav.mp3");
    write_sine(&reference, 440.0, 0.5);
    write_sine(&target, 440.0, 0.25);

    let request = SubmitRequest::from_paths(
        &reference,
        &target,
        fixture_path("content-output.wav"),
        None,
        None,
    )
    .unwrap();

    assert_eq!(request.reference_format, doppelbanger::AudioFormat::Wav);
    assert_eq!(request.target_format, doppelbanger::AudioFormat::Wav);
}

fn fixture_path(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "doppelbanger-request-contract-{}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn write_sine(path: &Path, frequency_hz: f32, amplitude: f32) {
    let sample_rate = 48_000;
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut writer = hound::WavWriter::create(path, spec).unwrap();
    for frame in 0..sample_rate * 4 {
        let sample = amplitude
            * (std::f32::consts::TAU * frequency_hz * frame as f32 / sample_rate as f32).sin();
        writer.write_sample(sample).unwrap();
        writer.write_sample(sample).unwrap();
    }
    writer.finalize().unwrap();
}
