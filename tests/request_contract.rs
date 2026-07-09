use std::fs;
use std::path::Path;

use doppelbanger::{AudioFormat, MasteringRequest, Tuning};

fn touch(path: &Path) {
    fs::write(path, b"fixture").unwrap();
}

#[test]
fn detects_supported_audio_formats_case_insensitively() {
    assert_eq!(
        AudioFormat::from_path("reference.WAV").unwrap(),
        AudioFormat::Wav
    );
    assert_eq!(
        AudioFormat::from_path("reference.mp3").unwrap(),
        AudioFormat::Mp3
    );
}

#[test]
fn rejects_unsupported_audio_formats() {
    let err = AudioFormat::from_path("reference.flac").unwrap_err();
    assert!(err.to_string().contains("unsupported audio format"));
}

#[test]
fn rejects_tuning_values_outside_safe_ranges() {
    let err = Tuning::new(0.0, 0.0, 13.0, 0.0, 0.0, 0.0).unwrap_err();
    assert!(err.to_string().contains("low_eq_db"));
}

#[test]
fn builds_request_from_existing_reference_and_target_files() {
    let dir = std::env::temp_dir().join(format!("doppelbanger-request-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();

    let reference = dir.join("reference.mp3");
    let target = dir.join("target.wav");
    touch(&reference);
    touch(&target);

    let tuning = Tuning::new(1.5, 0.25, -2.0, 0.0, 1.0, -0.2).unwrap();
    let request = MasteringRequest::from_paths(&reference, &target, tuning).unwrap();

    assert_eq!(request.reference.format, AudioFormat::Mp3);
    assert_eq!(request.target.format, AudioFormat::Wav);
    assert!(request.reference.path.ends_with("reference.mp3"));
    assert!(request.target.path.ends_with("target.wav"));
    assert_eq!(request.tuning.loudness_db, 1.5);
}
