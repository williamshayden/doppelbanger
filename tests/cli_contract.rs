use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[test]
fn help_exposes_master_worker_and_benchmark_commands() {
    let output = Command::new(env!("CARGO_BIN_EXE_doppelbanger"))
        .arg("--help")
        .output()
        .unwrap();

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("doppelbanger master"));
    assert!(stdout.contains("doppelbanger worker"));
    assert!(stdout.contains("doppelbanger benchmark"));
    assert!(!stdout.contains("prepare"));
}

#[test]
fn master_reports_an_unreachable_api_without_creating_output() {
    let reference = fixture_path("cli-reference.wav");
    let target = fixture_path("cli-target.wav");
    let output = fixture_path("cli-output.wav");
    write_sine(&reference, 440.0, 0.5);
    write_sine(&target, 440.0, 0.25);

    let result = Command::new(env!("CARGO_BIN_EXE_doppelbanger"))
        .args([
            "master",
            "--reference",
            reference.to_str().unwrap(),
            "--target",
            target.to_str().unwrap(),
            "--output",
            output.to_str().unwrap(),
            "--api-url",
            "http://127.0.0.1:1",
        ])
        .output()
        .unwrap();

    assert!(!result.status.success());
    assert!(!output.exists());
    let stderr = String::from_utf8(result.stderr).unwrap();
    assert!(stderr.contains("http://127.0.0.1:1"));
    assert!(stderr.contains("API"));
}

#[test]
fn worker_once_reports_an_unreachable_api() {
    let result = Command::new(env!("CARGO_BIN_EXE_doppelbanger"))
        .args(["worker", "--once", "--api-url", "http://127.0.0.1:1"])
        .output()
        .unwrap();

    assert!(!result.status.success());
    let stderr = String::from_utf8(result.stderr).unwrap();
    assert!(stderr.contains("http://127.0.0.1:1"));
}

fn fixture_path(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("doppelbanger-cli-contract-{}", std::process::id()));
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
    for frame in 0..sample_rate {
        let sample = amplitude
            * (std::f32::consts::TAU * frequency_hz * frame as f32 / sample_rate as f32).sin();
        writer.write_sample(sample).unwrap();
        writer.write_sample(sample).unwrap();
    }
    writer.finalize().unwrap();
}
