use std::fs;
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use doppelbanger::run_benchmark;
use sha2::{Digest, Sha256};

#[test]
fn benchmark_writes_measured_quality_and_performance_evidence() {
    let root = fixture_root();
    let pairs = root.join("pairs");
    let mut manifest_pairs = Vec::new();
    for id in ["01", "04", "10"] {
        let pair = pairs.join(id);
        fs::create_dir_all(&pair).unwrap();
        let reference = pair.join("reference.wav");
        let target = pair.join("target.wav");
        write_sine(&reference, 0.5);
        write_sine(&target, 0.25);
        manifest_pairs.push(serde_json::json!({
            "id": id,
            "reference_path": format!("pairs/{id}/reference.wav"),
            "target_path": format!("pairs/{id}/target.wav"),
            "reference_sha256": sha256(&reference),
            "target_sha256": sha256(&target)
        }));
    }
    fs::write(
        pairs.join("manifest.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "schema_version": 1,
            "source_doi": "10.5281/zenodo.19683001",
            "pairs": manifest_pairs
        }))
        .unwrap(),
    )
    .unwrap();
    let output = root.join("benchmark.json");

    let report = run_benchmark(&pairs, &output, false).unwrap();

    assert!(output.is_file());
    assert_eq!(report.schema_version, 1);
    assert_eq!(report.items.len(), 3);
    assert_eq!(report.provenance.package_version, env!("CARGO_PKG_VERSION"));
    assert_eq!(report.provenance.analyzer_version, "analysis-v1");
    assert_eq!(report.provenance.processor_version, "linear-eq-gain-v1");
    assert!(report.provenance.git_commit.is_some());
    assert!(report.provenance.git_dirty.is_some());
    assert!(report.provenance.workspace_git_commit.is_some());
    assert!(report.provenance.workspace_git_dirty.is_some());
    assert!(!report.provenance.build_profile.is_empty());
    assert!(report.provenance.rustc_version.is_some());
    assert!(!report.provenance.target_os.is_empty());
    assert!(!report.provenance.target_arch.is_empty());
    assert!(report.provenance.logical_cpu_count > 0);
    assert!(!report.corpus_manifest_sha256.is_empty());
    assert_eq!(report.items[0].pair_id, "01");
    assert!(report.items[0].reference_analysis_seconds > 0.0);
    assert!(report.items[0].target_analysis_seconds > 0.0);
    assert!(report.items[0].analysis_realtime_factor > 0.0);
    assert!(report.items[0].render_realtime_factor > 0.0);
    assert!(report.items[0].loudness_error_after_db < report.items[0].loudness_error_before_db);
    assert!(report.items[0].output_true_peak_dbtp <= -0.9);
    assert_eq!(report.items[0].spectral_delta_before_db.len(), 9);
    assert_eq!(report.items[0].spectral_delta_after_db.len(), 9);
    assert_eq!(report.items[0].eq_gains_db.len(), 3);
    assert!(report.items[0].lra_error_before_lu >= 0.0);
    assert!(report.items[0].lra_error_after_lu >= 0.0);
    assert!(report.items[0].plr_error_before_db >= 0.0);
    assert!(report.items[0].plr_error_after_db >= 0.0);
    assert!(report.items[0].transient_p95_error_before >= 0.0);
    assert!(report.items[0].transient_p95_error_after >= 0.0);
    assert!(report.items[0].correlation_error_before >= 0.0);
    assert!(report.items[0].correlation_error_after >= 0.0);
    assert_eq!(report.items[0].output_path, "benchmark-renders/01.wav");
    assert!(report.summary.peak_rss_mib.unwrap() > 0.0);

    let decoded: serde_json::Value = serde_json::from_slice(&fs::read(output).unwrap()).unwrap();
    assert_eq!(decoded["items"][0]["pair_id"], "01");
    assert!(decoded["gates"]["true_peak"].is_boolean());
}

#[test]
fn full_benchmark_rejects_a_partial_albumdb_manifest() {
    let root = fixture_root();
    let pairs = root.join("pairs");
    fs::create_dir_all(pairs.join("01")).unwrap();
    fs::write(
        pairs.join("manifest.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "schema_version": 1,
            "source_doi": "10.5281/zenodo.19683001",
            "pairs": [{
                "id": "01",
                "reference_path": "pairs/01/reference.wav",
                "target_path": "pairs/01/target.wav",
                "reference_sha256": "missing",
                "target_sha256": "missing"
            }]
        }))
        .unwrap(),
    )
    .unwrap();

    let error = run_benchmark(&pairs, &root.join("full.json"), true)
        .unwrap_err()
        .to_string();

    assert!(error.contains("exactly AlbumDB pairs 01 through 10"));
}

#[test]
fn benchmark_rejects_duplicate_manifest_pair_ids() {
    let root = fixture_root();
    let pairs = root.join("pairs");
    fs::create_dir_all(&pairs).unwrap();
    fs::write(
        pairs.join("manifest.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "schema_version": 1,
            "source_doi": "10.5281/zenodo.19683001",
            "pairs": [
                {
                    "id": "01",
                    "reference_sha256": "unused",
                    "target_sha256": "unused"
                },
                {
                    "id": "01",
                    "reference_sha256": "unused",
                    "target_sha256": "unused"
                }
            ]
        }))
        .unwrap(),
    )
    .unwrap();

    let error = run_benchmark(&pairs, &root.join("duplicate.json"), false)
        .unwrap_err()
        .to_string();

    assert!(error.contains("duplicate pair IDs"));
}

fn fixture_root() -> PathBuf {
    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);
    let root = std::env::temp_dir().join(format!(
        "doppelbanger-benchmark-contract-{}-{}",
        std::process::id(),
        NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
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

fn sha256(path: &Path) -> String {
    let mut file = File::open(path).unwrap();
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).unwrap();
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    format!("{:x}", digest.finalize())
}
