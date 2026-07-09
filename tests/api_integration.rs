use std::fs;
use std::path::{Path, PathBuf};

use doppelbanger::{ApiClient, RequestStatus, SubmitRequest, process_job};

#[test]
#[ignore = "requires a fresh local Docker Compose Postgres/PostgREST runtime"]
fn postgrest_request_lifecycle_round_trips_real_contracts() {
    let reference = fixture_path("api-reference.wav");
    let target = fixture_path("api-target.wav");
    let output = fixture_path("api-output.wav");
    write_sine(&reference, 48_000, 4.0, 440.0, 0.5);
    write_sine(&target, 48_000, 4.0, 440.0, 0.25);

    let client = ApiClient::new("http://localhost:3000").unwrap();
    let request_id = client
        .submit(&SubmitRequest::from_paths(&reference, &target, &output, None, None).unwrap())
        .unwrap();
    let job = client
        .claim()
        .unwrap()
        .expect("submitted request is claimable");

    assert_eq!(job.id, request_id);
    assert_eq!(job.status, RequestStatus::Analyzing);
    assert_eq!(job.reference_path, reference.canonicalize().unwrap());
    assert_eq!(job.target_path, target.canonicalize().unwrap());

    let report = process_job(&client, &job).unwrap();

    let state = client.request(&job.id).unwrap();
    let stored_plan = client.plan(&job.id).unwrap();
    assert_eq!(state.status, RequestStatus::Complete);
    assert_eq!(state.output_path, output);
    assert_eq!(state.error, None);
    assert!(output.is_file());
    assert_eq!(stored_plan, report.plan);
    assert!(report.after_diff.integrated_lufs.abs() < report.before_diff.integrated_lufs.abs());
    assert!(report.render.output_analysis.loudness.true_peak_dbtp <= -0.9);
}

fn fixture_path(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "doppelbanger-api-integration-{}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn write_sine(
    path: &Path,
    sample_rate: u32,
    duration_seconds: f32,
    frequency_hz: f32,
    amplitude: f32,
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
        let sample = amplitude
            * (std::f32::consts::TAU * frequency_hz * frame as f32 / sample_rate as f32).sin();
        writer.write_sample(sample).unwrap();
        writer.write_sample(sample).unwrap();
    }
    writer.finalize().unwrap();
}
