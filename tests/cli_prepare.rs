use std::fs;
use std::process::Command;

use serde_json::Value;

#[test]
fn prepare_writes_a_valid_mastering_request_json_file() {
    let dir = std::env::temp_dir().join(format!("doppelbanger-cli-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();

    let reference = dir.join("reference.mp3");
    let target = dir.join("target.wav");
    let output = dir.join("request.json");
    fs::write(&reference, b"fixture").unwrap();
    fs::write(&target, b"fixture").unwrap();

    let status = Command::new(env!("CARGO_BIN_EXE_doppelbanger"))
        .args([
            "prepare",
            "--reference",
            reference.to_str().unwrap(),
            "--target",
            target.to_str().unwrap(),
            "--output",
            output.to_str().unwrap(),
            "--loudness-db",
            "1.5",
            "--punch",
            "0.25",
            "--low-eq-db",
            "-2.0",
            "--mid-eq-db",
            "0.0",
            "--high-eq-db",
            "1.0",
            "--width",
            "-0.2",
        ])
        .status()
        .unwrap();

    assert!(status.success());

    let json: Value = serde_json::from_slice(&fs::read(output).unwrap()).unwrap();
    assert_eq!(json["reference"]["format"], "mp3");
    assert_eq!(json["target"]["format"], "wav");
    assert_eq!(json["tuning"]["loudness_db"], 1.5);
    assert_eq!(json["tuning"]["low_eq_db"], -2.0);
}
