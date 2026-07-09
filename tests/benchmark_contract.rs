use std::fs;
use std::path::{Path, PathBuf};

use doppelbanger::run_benchmark;

#[test]
fn benchmark_writes_measured_quality_and_performance_evidence() {
    let root = fixture_root();
    let pair = root.join("pairs/01");
    fs::create_dir_all(&pair).unwrap();
    write_sine(&pair.join("reference.wav"), 0.5);
    write_sine(&pair.join("target.wav"), 0.25);
    let output = root.join("benchmark.json");

    let report = run_benchmark(&root.join("pairs"), &output, true).unwrap();

    assert!(output.is_file());
    assert_eq!(report.schema_version, 1);
    assert_eq!(report.items.len(), 1);
    assert_eq!(report.items[0].pair_id, "01");
    assert!(report.items[0].analysis_realtime_factor > 0.0);
    assert!(report.items[0].render_realtime_factor > 0.0);
    assert!(report.items[0].loudness_error_after_db < report.items[0].loudness_error_before_db);
    assert!(report.items[0].output_true_peak_dbtp <= -0.9);
    assert!(report.summary.peak_rss_mib.unwrap() > 0.0);

    let decoded: serde_json::Value = serde_json::from_slice(&fs::read(output).unwrap()).unwrap();
    assert_eq!(decoded["items"][0]["pair_id"], "01");
    assert!(decoded["gates"]["true_peak"].is_boolean());
}

fn fixture_root() -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "doppelbanger-benchmark-contract-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).unwrap();
    root
}

fn write_sine(path: &Path, amplitude: f32) {
    let sample_rate = 48_000;
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut writer = hound::WavWriter::create(path, spec).unwrap();
    for frame in 0..sample_rate * 4 {
        let sample =
            amplitude * (std::f32::consts::TAU * 440.0 * frame as f32 / sample_rate as f32).sin();
        writer.write_sample(sample).unwrap();
        writer.write_sample(sample).unwrap();
    }
    writer.finalize().unwrap();
}
