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
    assert!(output.with_extension("report.json").is_file());
    assert_eq!(stored_plan, report.plan);
    assert!(report.after_diff.integrated_lufs.abs() < report.before_diff.integrated_lufs.abs());
    assert!(report.render.output_analysis.loudness.true_peak_dbtp <= -0.9);

    let edited_output = fixture_path("api-output-edited.wav");
    let mut edited_plan = stored_plan;
    edited_plan.applied_gain_db -= 1.0;
    let edited_id = client
        .submit(
            &SubmitRequest::from_paths(
                &reference,
                &target,
                &edited_output,
                Some(edited_plan),
                Some(job.id),
            )
            .unwrap(),
        )
        .unwrap();
    let edited_job = client
        .claim()
        .unwrap()
        .expect("edited request is claimable");
    assert_eq!(edited_job.id, edited_id);
    assert_eq!(edited_job.parent_request_id, Some(job.id));

    let edited_report = process_job(&client, &edited_job).unwrap();
    assert_eq!(
        edited_report.plan.applied_gain_db,
        report.plan.applied_gain_db - 1.0
    );
    assert!(edited_output.is_file());
    assert_eq!(
        client.request(&edited_id).unwrap().status,
        RequestStatus::Complete
    );

    let missing_target = fixture_path("api-target-removed-after-submit.wav");
    let failed_output = fixture_path("api-output-failed.wav");
    write_sine(&missing_target, 48_000, 4.0, 440.0, 0.25);
    let failed_id = client
        .submit(
            &SubmitRequest::from_paths(&reference, &missing_target, &failed_output, None, None)
                .unwrap(),
        )
        .unwrap();
    fs::remove_file(&missing_target).unwrap();
    let failed_job = client
        .claim()
        .unwrap()
        .expect("failure request is claimable");

    let error = process_job(&client, &failed_job).unwrap_err().to_string();
    let failed_state = client.request(&failed_id).unwrap();

    assert!(error.contains("api-target-removed-after-submit.wav"));
    assert_eq!(failed_state.status, RequestStatus::Failed);
    assert!(
        failed_state
            .error
            .unwrap()
            .contains("api-target-removed-after-submit.wav")
    );
    assert!(!failed_output.exists());
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
