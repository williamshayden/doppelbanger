use std::fs;
use std::path::{Path, PathBuf};

use doppelbanger::{PairDiffV1, analyze_track};

#[test]
fn analyzes_loudness_spectrum_stereo_and_anomalies_deterministically() {
    let path = fixture_path("analysis.wav");
    write_signal(&path, 48_000, 4.0, |frame, sample_rate| {
        0.5 * (std::f32::consts::TAU * 1_500.0 * frame as f32 / sample_rate as f32).sin()
    });

    let first = analyze_track(&path).unwrap();
    let second = analyze_track(&path).unwrap();

    assert_eq!(first, second);
    assert_eq!(first.schema_version, 1);
    assert_eq!(first.metadata.sample_rate_hz, 48_000);
    assert_eq!(first.metadata.channels, 2);
    assert_eq!(first.metadata.frame_count, 192_000);
    assert_eq!(first.spectrum.len(), 9);
    assert!((-8.0..-4.0).contains(&first.loudness.integrated_lufs));
    assert!((-8.0..-4.0).contains(&first.loudness.true_peak_dbtp));
    assert!(first.stereo.correlation > 0.999);
    assert!(
        first
            .stereo
            .mid_side_ratio_db
            .iter()
            .all(|value| *value > 100.0)
    );
    assert_eq!(first.anomalies.clipped_samples, 0);
    assert_eq!(first.anomalies.non_finite_samples, 0);

    let dominant_band = first
        .spectrum
        .iter()
        .enumerate()
        .max_by(|(_, left), (_, right)| left.relative_db.total_cmp(&right.relative_db))
        .unwrap()
        .0;
    assert_eq!(dominant_band, 5, "1.5 kHz belongs in the 1-2 kHz band");
}

#[test]
fn measures_known_gain_difference_and_zero_identity_diff() {
    let louder = fixture_path("louder.wav");
    let quieter = fixture_path("quieter.wav");
    write_signal(&louder, 44_100, 4.0, sine(440.0, 0.5));
    write_signal(&quieter, 44_100, 4.0, sine(440.0, 0.25));

    let reference = analyze_track(&louder).unwrap();
    let target = analyze_track(&quieter).unwrap();
    let gain_diff = PairDiffV1::between(&reference, &target).unwrap();
    let identity = PairDiffV1::between(&reference, &reference).unwrap();

    assert!((gain_diff.integrated_lufs - 6.0206).abs() < 0.15);
    assert!((gain_diff.true_peak_dbtp - 6.0206).abs() < 0.15);
    assert!(identity.is_zero(0.0));
}

#[test]
fn transient_metric_distinguishes_impulses_from_a_steady_tone() {
    let steady = fixture_path("steady.wav");
    let impulses = fixture_path("impulses.wav");
    write_signal(&steady, 48_000, 4.0, sine(440.0, 0.25));
    write_signal(&impulses, 48_000, 4.0, |frame, sample_rate| {
        if frame % (sample_rate as usize / 2) == 0 {
            1.0
        } else {
            0.001
        }
    });

    let steady = analyze_track(&steady).unwrap();
    let impulses = analyze_track(&impulses).unwrap();

    assert!(impulses.transients.density_hz > steady.transients.density_hz);
    assert!(impulses.transients.p95_flux > steady.transients.p95_flux);
}

#[test]
fn counts_samples_over_full_scale() {
    let path = fixture_path("clipped.wav");
    write_signal(&path, 48_000, 4.0, sine(100.0, 1.1));

    let analysis = analyze_track(&path).unwrap();
    assert!(analysis.anomalies.clipped_samples > 0);
}

#[test]
fn rejects_silence_when_loudness_is_not_measurable() {
    let path = fixture_path("silence.wav");
    write_signal(&path, 48_000, 1.0, |_, _| 0.0);

    let error = analyze_track(&path).unwrap_err().to_string();

    assert!(error.contains("integrated loudness"));
    assert!(error.contains(path.to_str().unwrap()));
    assert!(error.contains("not finite"));
}

#[test]
fn rejects_non_finite_decoded_samples() {
    let path = fixture_path("non-finite.wav");
    write_signal(&path, 48_000, 1.0, |frame, _| {
        if frame == 128 { f32::NAN } else { 0.25 }
    });

    let error = analyze_track(&path).unwrap_err().to_string();

    assert!(error.contains("non-finite sample at frame 128"));
    assert!(error.contains(path.to_str().unwrap()));
}

#[test]
fn spectrum_preserves_antiphase_stereo_energy() {
    let path = fixture_path("antiphase.wav");
    write_stereo_signal(&path, 48_000, 4.0, |frame, sample_rate| {
        let sample = sine_sample(frame, sample_rate, 1_500.0, 0.5);
        (sample, -sample)
    });

    let analysis = analyze_track(&path).unwrap();
    let dominant_band = analysis
        .spectrum
        .iter()
        .enumerate()
        .max_by(|(_, left), (_, right)| left.relative_db.total_cmp(&right.relative_db))
        .unwrap()
        .0;

    assert_eq!(dominant_band, 5);
    assert!(analysis.spectrum[5].relative_db > -0.1);
    assert!(analysis.stereo.correlation < -0.999);
}

fn fixture_path(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("doppelbanger-analysis-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn sine(frequency_hz: f32, amplitude: f32) -> impl Fn(usize, u32) -> f32 {
    move |frame, sample_rate| {
        amplitude * (std::f32::consts::TAU * frequency_hz * frame as f32 / sample_rate as f32).sin()
    }
}

fn sine_sample(frame: usize, sample_rate: u32, frequency_hz: f32, amplitude: f32) -> f32 {
    amplitude * (std::f32::consts::TAU * frequency_hz * frame as f32 / sample_rate as f32).sin()
}

fn write_signal(
    path: &Path,
    sample_rate: u32,
    duration_seconds: f32,
    signal: impl Fn(usize, u32) -> f32,
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
        let sample = signal(frame, sample_rate);
        writer.write_sample(sample).unwrap();
        writer.write_sample(sample).unwrap();
    }
    writer.finalize().unwrap();
}

fn write_stereo_signal(
    path: &Path,
    sample_rate: u32,
    duration_seconds: f32,
    signal: impl Fn(usize, u32) -> (f32, f32),
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
        let (left, right) = signal(frame, sample_rate);
        writer.write_sample(left).unwrap();
        writer.write_sample(right).unwrap();
    }
    writer.finalize().unwrap();
}
