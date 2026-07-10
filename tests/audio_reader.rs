use std::fs;
use std::path::{Path, PathBuf};

use doppelbanger::{AudioFormat, AudioReader};

#[test]
fn streams_real_stereo_wav_in_bounded_blocks() {
    let path = fixture_path("stereo.wav");
    write_sine(&path, 2, 48_000, 1.0, 440.0, 0.5);

    let mut reader = AudioReader::open(&path).unwrap();
    assert_eq!(reader.info().format, AudioFormat::Wav);
    assert_eq!(reader.info().sample_rate_hz, 48_000);
    assert_eq!(reader.info().channels, 2);
    assert_eq!(reader.info().source_sha256.len(), 64);

    let mut frames = 0_u64;
    while let Some(block) = reader.next_block().unwrap() {
        assert!(!block.samples.is_empty());
        assert_eq!(block.samples.len() % 2, 0);
        assert!(block.samples.iter().all(|sample| sample.is_finite()));
        frames += block.frames as u64;
    }

    assert_eq!(frames, 48_000);
}

#[test]
fn identifies_audio_from_decoded_content_instead_of_extension() {
    let path = fixture_path("wav-disguised-as-mp3.mp3");
    write_sine(&path, 2, 44_100, 0.25, 1_000.0, 0.25);

    let reader = AudioReader::open(&path).unwrap();
    assert_eq!(reader.info().format, AudioFormat::Wav);
}

#[test]
fn streams_generated_stereo_mp3_fixture() {
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/generated-stereo-sine.mp3");

    let mut reader = AudioReader::open(&path).unwrap();
    assert_eq!(reader.info().format, AudioFormat::Mp3);
    assert_eq!(reader.info().sample_rate_hz, 44_100);
    assert_eq!(reader.info().channels, 2);

    let mut frames = 0_usize;
    while let Some(block) = reader.next_block().unwrap() {
        assert!(block.samples.iter().all(|sample| sample.is_finite()));
        frames += block.frames;
    }

    assert!(frames >= 44_100);
}

#[test]
fn rejects_mono_audio_at_the_decode_boundary() {
    let path = fixture_path("mono.wav");
    write_sine(&path, 1, 44_100, 0.25, 220.0, 0.25);

    let err = AudioReader::open(&path).unwrap_err();
    assert!(err.to_string().contains("stereo"));
    assert!(err.to_string().contains(&canonical_display(&path)));
}

#[test]
fn rejects_corrupt_files_with_supported_extensions() {
    let path = fixture_path("corrupt.wav");
    fs::write(&path, b"not audio").unwrap();

    let err = AudioReader::open(&path).unwrap_err();
    assert!(err.to_string().contains("audio"));
    assert!(err.to_string().contains(&canonical_display(&path)));
}

fn canonical_display(path: &Path) -> String {
    path.canonicalize().unwrap().to_string_lossy().into_owned()
}

fn fixture_path(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("doppelbanger-audio-reader-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn write_sine(
    path: &Path,
    channels: u16,
    sample_rate: u32,
    duration_seconds: f32,
    frequency_hz: f32,
    amplitude: f32,
) {
    let spec = hound::WavSpec {
        channels,
        sample_rate,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut writer = hound::WavWriter::create(path, spec).unwrap();
    let frames = (sample_rate as f32 * duration_seconds) as usize;
    for frame in 0..frames {
        let sample = amplitude
            * (std::f32::consts::TAU * frequency_hz * frame as f32 / sample_rate as f32).sin();
        for _ in 0..channels {
            writer.write_sample(sample).unwrap();
        }
    }
    writer.finalize().unwrap();
}
