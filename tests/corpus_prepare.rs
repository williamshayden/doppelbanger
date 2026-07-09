use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

#[test]
fn prepares_aligned_reference_target_pairs_without_normalizing_the_stem_sum() {
    let root = fixture_root();
    let stems = root.join("stems_mixed/01 Synthetic Song");
    let masters = root.join("masters_stereo");
    fs::create_dir_all(&stems).unwrap();
    fs::create_dir_all(&masters).unwrap();
    write_constant(&stems.join("drums.wav"), 0.2);
    write_constant(&stems.join("bass.wav"), 0.3);
    write_constant(&masters.join("01 - Synthetic Song.wav"), 0.4);

    let output = Command::new(env!("CARGO_BIN_EXE_prepare_albumdb"))
        .args(["--root", root.to_str().unwrap()])
        .output()
        .unwrap();

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let target = root.join("pairs/01/target.wav");
    let reference = root.join("pairs/01/reference.wav");
    assert!(target.is_file());
    assert!(reference.is_file());

    let target_samples: Vec<f32> = hound::WavReader::open(target)
        .unwrap()
        .samples::<f32>()
        .map(Result::unwrap)
        .collect();
    assert!(
        target_samples
            .iter()
            .all(|sample| (*sample - 0.5).abs() < 0.0001)
    );

    let manifest: Value =
        serde_json::from_slice(&fs::read(root.join("pairs/manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["schema_version"], 1);
    assert_eq!(manifest["source_doi"], "10.5281/zenodo.19683001");
    assert_eq!(manifest["pairs"][0]["id"], "01");
    assert_eq!(manifest["pairs"][0]["stem_count"], 2);
}

fn fixture_root() -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "doppelbanger-corpus-prepare-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).unwrap();
    root
}

fn write_constant(path: &Path, value: f32) {
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate: 44_100,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(path, spec).unwrap();
    let sample = (value * i16::MAX as f32) as i16;
    for _ in 0..4_410 {
        writer.write_sample(sample).unwrap();
        writer.write_sample(sample).unwrap();
    }
    writer.finalize().unwrap();
}
