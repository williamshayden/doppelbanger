use std::path::Path;
use std::sync::Arc;

use ebur128::{EbuR128, Mode};
use rustfft::num_complex::Complex;
use rustfft::{Fft, FftPlanner};
use serde::{Deserialize, Serialize};

use crate::{AudioFormat, AudioReader, DoppelbangerError, Result};

const ANALYZER_VERSION: &str = "analysis-v1";
const ACTIVE_AMPLITUDE: f64 = 0.000_316_227_766;
const SPECTRUM_WINDOW: usize = 4096;
const SPECTRUM_HOP: usize = 1024;
const TRANSIENT_WINDOW: usize = 2048;
const TRANSIENT_HOP: usize = 512;
const SPECTRAL_BANDS: [(f64, f64); 9] = [
    (20.0, 60.0),
    (60.0, 120.0),
    (120.0, 250.0),
    (250.0, 500.0),
    (500.0, 1_000.0),
    (1_000.0, 2_000.0),
    (2_000.0, 4_000.0),
    (4_000.0, 8_000.0),
    (8_000.0, 16_000.0),
];

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct AudioMetadataV1 {
    pub path: String,
    pub source_sha256: String,
    pub format: AudioFormat,
    pub sample_rate_hz: u32,
    pub channels: usize,
    pub frame_count: u64,
    pub duration_seconds: f64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct LoudnessMetricsV1 {
    pub integrated_lufs: f64,
    pub loudness_range_lu: f64,
    pub max_short_term_lufs: f64,
    pub sample_peak_dbfs: f64,
    pub true_peak_dbtp: f64,
    pub peak_to_loudness_ratio_db: f64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct SpectralBandV1 {
    pub low_hz: f64,
    pub high_hz: f64,
    pub relative_db: f64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct StereoMetricsV1 {
    pub correlation: f64,
    pub mid_side_ratio_db: [f64; 3],
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct TransientMetricsV1 {
    pub density_hz: f64,
    pub p95_flux: f64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct AnalysisAnomaliesV1 {
    pub clipped_samples: u64,
    pub non_finite_samples: u64,
    pub dc_offset: [f64; 2],
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct TrackAnalysisV1 {
    pub schema_version: u32,
    pub analyzer_version: String,
    pub metadata: AudioMetadataV1,
    pub loudness: LoudnessMetricsV1,
    pub spectrum: Vec<SpectralBandV1>,
    pub stereo: StereoMetricsV1,
    pub transients: TransientMetricsV1,
    pub anomalies: AnalysisAnomaliesV1,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct PairDiffV1 {
    pub schema_version: u32,
    pub integrated_lufs: f64,
    pub loudness_range_lu: f64,
    pub max_short_term_lufs: f64,
    pub sample_peak_dbfs: f64,
    pub true_peak_dbtp: f64,
    pub peak_to_loudness_ratio_db: f64,
    pub spectral_relative_db: Vec<f64>,
    pub correlation: f64,
    pub mid_side_ratio_db: [f64; 3],
    pub transient_density_hz: f64,
    pub transient_p95_flux: f64,
}

impl PairDiffV1 {
    pub fn between(reference: &TrackAnalysisV1, target: &TrackAnalysisV1) -> Result<Self> {
        if reference.spectrum.len() != target.spectrum.len() {
            return Err(DoppelbangerError::Io(format!(
                "analysis spectrum length mismatch: reference={}, target={}",
                reference.spectrum.len(),
                target.spectrum.len()
            )));
        }

        Ok(Self {
            schema_version: 1,
            integrated_lufs: reference.loudness.integrated_lufs - target.loudness.integrated_lufs,
            loudness_range_lu: reference.loudness.loudness_range_lu
                - target.loudness.loudness_range_lu,
            max_short_term_lufs: reference.loudness.max_short_term_lufs
                - target.loudness.max_short_term_lufs,
            sample_peak_dbfs: reference.loudness.sample_peak_dbfs
                - target.loudness.sample_peak_dbfs,
            true_peak_dbtp: reference.loudness.true_peak_dbtp - target.loudness.true_peak_dbtp,
            peak_to_loudness_ratio_db: reference.loudness.peak_to_loudness_ratio_db
                - target.loudness.peak_to_loudness_ratio_db,
            spectral_relative_db: reference
                .spectrum
                .iter()
                .zip(&target.spectrum)
                .map(|(reference, target)| reference.relative_db - target.relative_db)
                .collect(),
            correlation: reference.stereo.correlation - target.stereo.correlation,
            mid_side_ratio_db: subtract_arrays(
                reference.stereo.mid_side_ratio_db,
                target.stereo.mid_side_ratio_db,
            ),
            transient_density_hz: reference.transients.density_hz - target.transients.density_hz,
            transient_p95_flux: reference.transients.p95_flux - target.transients.p95_flux,
        })
    }

    pub fn is_zero(&self, tolerance: f64) -> bool {
        let scalars = [
            self.integrated_lufs,
            self.loudness_range_lu,
            self.max_short_term_lufs,
            self.sample_peak_dbfs,
            self.true_peak_dbtp,
            self.peak_to_loudness_ratio_db,
            self.correlation,
            self.transient_density_hz,
            self.transient_p95_flux,
        ];

        scalars
            .into_iter()
            .chain(self.spectral_relative_db.iter().copied())
            .chain(self.mid_side_ratio_db)
            .all(|value| value.abs() <= tolerance)
    }
}

pub fn analyze_track(path: impl AsRef<Path>) -> Result<TrackAnalysisV1> {
    let path = path.as_ref();
    let mut reader = AudioReader::open(path)?;
    let info = reader.info().clone();
    let mode = Mode::I | Mode::LRA | Mode::SAMPLE_PEAK | Mode::TRUE_PEAK;
    let mut loudness = EbuR128::new(2, info.sample_rate_hz, mode)
        .map_err(|err| analysis_error(path, "initialize loudness meter", err))?;
    let mut distribution = DistributionAccumulator::new(info.sample_rate_hz);
    let mut max_short_term_lufs = f64::NEG_INFINITY;
    let mut frame_count = 0_u64;

    while let Some(block) = reader.next_block()? {
        for (index, sample) in block.samples.iter().enumerate() {
            if !sample.is_finite() {
                return Err(analysis_error(
                    path,
                    "analyze",
                    format!(
                        "non-finite sample at frame {}, channel {}",
                        frame_count + (index / 2) as u64,
                        index % 2
                    ),
                ));
            }
        }

        loudness
            .add_frames_f32(&block.samples)
            .map_err(|err| analysis_error(path, "measure loudness", err))?;
        if let Ok(value) = loudness.loudness_shortterm()
            && value.is_finite()
        {
            max_short_term_lufs = max_short_term_lufs.max(value);
        }
        distribution.push(&block.samples);
        frame_count += block.frames as u64;
    }

    if frame_count == 0 {
        return Err(analysis_error(path, "analyze", "decoded stream is empty"));
    }

    let integrated_lufs = finite_metric(path, "integrated loudness", loudness.loudness_global())?;
    let loudness_range_lu = finite_metric(path, "loudness range", loudness.loudness_range())?;
    let sample_peak = peak_across_channels(&loudness, false, path)?;
    let true_peak = peak_across_channels(&loudness, true, path)?;
    let sample_peak_dbfs = amplitude_to_db(sample_peak);
    let true_peak_dbtp = amplitude_to_db(true_peak);
    let max_short_term_lufs = if max_short_term_lufs.is_finite() {
        max_short_term_lufs
    } else {
        integrated_lufs
    };
    let duration_seconds = frame_count as f64 / info.sample_rate_hz as f64;
    let finalized = distribution.finalize(duration_seconds);

    Ok(TrackAnalysisV1 {
        schema_version: 1,
        analyzer_version: ANALYZER_VERSION.to_string(),
        metadata: AudioMetadataV1 {
            path: info.path.to_string_lossy().into_owned(),
            source_sha256: info.source_sha256,
            format: info.format,
            sample_rate_hz: info.sample_rate_hz,
            channels: info.channels,
            frame_count,
            duration_seconds,
        },
        loudness: LoudnessMetricsV1 {
            integrated_lufs,
            loudness_range_lu,
            max_short_term_lufs,
            sample_peak_dbfs,
            true_peak_dbtp,
            peak_to_loudness_ratio_db: true_peak_dbtp - integrated_lufs,
        },
        spectrum: finalized.spectrum,
        stereo: finalized.stereo,
        transients: finalized.transients,
        anomalies: finalized.anomalies,
    })
}

struct DistributionAccumulator {
    spectrum: SpectrumAccumulator,
    transients: TransientAccumulator,
    correlation: CorrelationAccumulator,
    clipped_samples: u64,
    sample_count: u64,
    dc_sum: [f64; 2],
}

impl DistributionAccumulator {
    fn new(sample_rate_hz: u32) -> Self {
        Self {
            spectrum: SpectrumAccumulator::new(sample_rate_hz),
            transients: TransientAccumulator::new(sample_rate_hz),
            correlation: CorrelationAccumulator::default(),
            clipped_samples: 0,
            sample_count: 0,
            dc_sum: [0.0; 2],
        }
    }

    fn push(&mut self, interleaved: &[f32]) {
        let mut left = Vec::with_capacity(interleaved.len() / 2);
        let mut right = Vec::with_capacity(interleaved.len() / 2);
        let mut mono = Vec::with_capacity(interleaved.len() / 2);

        for frame in interleaved.chunks_exact(2) {
            let l = frame[0] as f64;
            let r = frame[1] as f64;
            self.clipped_samples += u64::from(l.abs() > 1.0) + u64::from(r.abs() > 1.0);
            self.sample_count += 1;
            self.dc_sum[0] += l;
            self.dc_sum[1] += r;
            self.correlation.push(l, r);
            left.push(frame[0]);
            right.push(frame[1]);
            mono.push((frame[0] + frame[1]) * 0.5);
        }

        self.spectrum.push(&left, &right);
        self.transients.push(&mono);
    }

    fn finalize(self, duration_seconds: f64) -> DistributionMetrics {
        let dc_divisor = self.sample_count.max(1) as f64;
        DistributionMetrics {
            spectrum: self.spectrum.finalize_spectrum(),
            stereo: StereoMetricsV1 {
                correlation: self.correlation.finish(),
                mid_side_ratio_db: self.spectrum.finalize_mid_side(),
            },
            transients: self.transients.finalize(duration_seconds),
            anomalies: AnalysisAnomaliesV1 {
                clipped_samples: self.clipped_samples,
                non_finite_samples: 0,
                dc_offset: [self.dc_sum[0] / dc_divisor, self.dc_sum[1] / dc_divisor],
            },
        }
    }
}

struct DistributionMetrics {
    spectrum: Vec<SpectralBandV1>,
    stereo: StereoMetricsV1,
    transients: TransientMetricsV1,
    anomalies: AnalysisAnomaliesV1,
}

struct SpectrumAccumulator {
    sample_rate_hz: u32,
    fft: Arc<dyn Fft<f32>>,
    window: Vec<f32>,
    left: Vec<f32>,
    right: Vec<f32>,
    offset: usize,
    band_ratio_sum: [f64; 9],
    active_windows: u64,
    mid_power: [f64; 3],
    side_power: [f64; 3],
}

impl SpectrumAccumulator {
    fn new(sample_rate_hz: u32) -> Self {
        let mut planner = FftPlanner::new();
        Self {
            sample_rate_hz,
            fft: planner.plan_fft_forward(SPECTRUM_WINDOW),
            window: hann_window(SPECTRUM_WINDOW),
            left: Vec::with_capacity(SPECTRUM_WINDOW * 2),
            right: Vec::with_capacity(SPECTRUM_WINDOW * 2),
            offset: 0,
            band_ratio_sum: [0.0; 9],
            active_windows: 0,
            mid_power: [0.0; 3],
            side_power: [0.0; 3],
        }
    }

    fn push(&mut self, left: &[f32], right: &[f32]) {
        self.left.extend_from_slice(left);
        self.right.extend_from_slice(right);

        while self.left.len() - self.offset >= SPECTRUM_WINDOW {
            self.process_window();
            self.offset += SPECTRUM_HOP;
        }
        self.compact();
    }

    fn process_window(&mut self) {
        let left = &self.left[self.offset..self.offset + SPECTRUM_WINDOW];
        let right = &self.right[self.offset..self.offset + SPECTRUM_WINDOW];
        let rms = left
            .iter()
            .zip(right)
            .map(|(left, right)| {
                let left = *left as f64;
                let right = *right as f64;
                (left * left + right * right) * 0.5
            })
            .sum::<f64>()
            / SPECTRUM_WINDOW as f64;
        if rms.sqrt() < ACTIVE_AMPLITUDE {
            return;
        }

        let mut left_fft: Vec<Complex<f32>> = left
            .iter()
            .zip(&self.window)
            .map(|(sample, window)| Complex::new(sample * window, 0.0))
            .collect();
        let mut right_fft: Vec<Complex<f32>> = right
            .iter()
            .zip(&self.window)
            .map(|(sample, window)| Complex::new(sample * window, 0.0))
            .collect();
        self.fft.process(&mut left_fft);
        self.fft.process(&mut right_fft);

        let mut band_power = [0.0_f64; 9];
        for bin in 1..=SPECTRUM_WINDOW / 2 {
            let frequency = bin as f64 * self.sample_rate_hz as f64 / SPECTRUM_WINDOW as f64;
            if !(20.0..16_000.0).contains(&frequency) {
                continue;
            }
            let mono = (left_fft[bin] + right_fft[bin]) * 0.5;
            let power = mono.norm_sqr() as f64;
            if let Some(index) = spectral_band_index(frequency) {
                band_power[index] += power;
            }

            let stereo_band = if frequency < 120.0 {
                0
            } else if frequency < 4_000.0 {
                1
            } else {
                2
            };
            let mid = (left_fft[bin] + right_fft[bin]) * std::f32::consts::FRAC_1_SQRT_2;
            let side = (left_fft[bin] - right_fft[bin]) * std::f32::consts::FRAC_1_SQRT_2;
            self.mid_power[stereo_band] += mid.norm_sqr() as f64;
            self.side_power[stereo_band] += side.norm_sqr() as f64;
        }

        let total_power: f64 = band_power.iter().sum();
        if total_power > f64::EPSILON {
            for (sum, power) in self.band_ratio_sum.iter_mut().zip(band_power) {
                *sum += power / total_power;
            }
            self.active_windows += 1;
        }
    }

    fn compact(&mut self) {
        if self.offset >= SPECTRUM_WINDOW {
            self.left.drain(..self.offset);
            self.right.drain(..self.offset);
            self.offset = 0;
        }
    }

    fn finalize_spectrum(&self) -> Vec<SpectralBandV1> {
        let windows = self.active_windows.max(1) as f64;
        SPECTRAL_BANDS
            .iter()
            .zip(self.band_ratio_sum)
            .map(|(&(low_hz, high_hz), sum)| SpectralBandV1 {
                low_hz,
                high_hz: high_hz.min(self.sample_rate_hz as f64 * 0.5),
                relative_db: power_to_db(sum / windows),
            })
            .collect()
    }

    fn finalize_mid_side(&self) -> [f64; 3] {
        std::array::from_fn(|index| {
            let mid = self.mid_power[index];
            let side_floor = (mid * 1e-12).max(f64::MIN_POSITIVE);
            power_to_db(mid / self.side_power[index].max(side_floor)).min(120.0)
        })
    }
}

struct TransientAccumulator {
    sample_rate_hz: u32,
    fft: Arc<dyn Fft<f32>>,
    window: Vec<f32>,
    samples: Vec<f32>,
    offset: usize,
    previous: Option<Vec<f32>>,
    flux: Vec<f64>,
}

impl TransientAccumulator {
    fn new(sample_rate_hz: u32) -> Self {
        let mut planner = FftPlanner::new();
        Self {
            sample_rate_hz,
            fft: planner.plan_fft_forward(TRANSIENT_WINDOW),
            window: hann_window(TRANSIENT_WINDOW),
            samples: Vec::with_capacity(TRANSIENT_WINDOW * 2),
            offset: 0,
            previous: None,
            flux: Vec::new(),
        }
    }

    fn push(&mut self, mono: &[f32]) {
        self.samples.extend_from_slice(mono);
        while self.samples.len() - self.offset >= TRANSIENT_WINDOW {
            self.process_window();
            self.offset += TRANSIENT_HOP;
        }
        if self.offset >= TRANSIENT_WINDOW {
            self.samples.drain(..self.offset);
            self.offset = 0;
        }
    }

    fn process_window(&mut self) {
        let samples = &self.samples[self.offset..self.offset + TRANSIENT_WINDOW];
        let rms = (samples
            .iter()
            .map(|sample| (*sample as f64).powi(2))
            .sum::<f64>()
            / TRANSIENT_WINDOW as f64)
            .sqrt();
        if rms < ACTIVE_AMPLITUDE {
            return;
        }

        let mut bins: Vec<Complex<f32>> = samples
            .iter()
            .zip(&self.window)
            .map(|(sample, window)| Complex::new(sample * window, 0.0))
            .collect();
        self.fft.process(&mut bins);
        let magnitudes: Vec<f32> = (1..=TRANSIENT_WINDOW / 2)
            .filter_map(|bin| {
                let frequency = bin as f64 * self.sample_rate_hz as f64 / TRANSIENT_WINDOW as f64;
                (20.0..16_000.0)
                    .contains(&frequency)
                    .then(|| bins[bin].norm())
            })
            .collect();

        if let Some(previous) = &self.previous {
            let positive_change: f64 = magnitudes
                .iter()
                .zip(previous)
                .map(|(current, previous)| (*current - *previous).max(0.0) as f64)
                .sum();
            let current_energy = magnitudes.iter().map(|value| *value as f64).sum::<f64>();
            self.flux
                .push(positive_change / current_energy.max(f64::MIN_POSITIVE));
        }
        self.previous = Some(magnitudes);
    }

    fn finalize(self, duration_seconds: f64) -> TransientMetricsV1 {
        if self.flux.is_empty() {
            return TransientMetricsV1 {
                density_hz: 0.0,
                p95_flux: 0.0,
            };
        }

        let mut sorted = self.flux.clone();
        sorted.sort_by(f64::total_cmp);
        let median = percentile(&sorted, 0.5);
        let mut deviations: Vec<f64> = sorted.iter().map(|value| (value - median).abs()).collect();
        deviations.sort_by(f64::total_cmp);
        let threshold = median + 3.0 * percentile(&deviations, 0.5) + 1e-6;
        let transient_count = sorted.iter().filter(|value| **value > threshold).count();

        TransientMetricsV1 {
            density_hz: transient_count as f64 / duration_seconds.max(f64::MIN_POSITIVE),
            p95_flux: percentile(&sorted, 0.95),
        }
    }
}

#[derive(Default)]
struct CorrelationAccumulator {
    sum_left_squared: f64,
    sum_right_squared: f64,
    sum_product: f64,
}

impl CorrelationAccumulator {
    fn push(&mut self, left: f64, right: f64) {
        if left.abs().max(right.abs()) < ACTIVE_AMPLITUDE {
            return;
        }
        self.sum_left_squared += left * left;
        self.sum_right_squared += right * right;
        self.sum_product += left * right;
    }

    fn finish(&self) -> f64 {
        let denominator = (self.sum_left_squared * self.sum_right_squared).sqrt();
        if denominator <= f64::EPSILON {
            0.0
        } else {
            (self.sum_product / denominator).clamp(-1.0, 1.0)
        }
    }
}

fn peak_across_channels(meter: &EbuR128, true_peak: bool, path: &Path) -> Result<f64> {
    (0..2)
        .map(|channel| {
            if true_peak {
                meter.true_peak(channel)
            } else {
                meter.sample_peak(channel)
            }
            .map_err(|err| analysis_error(path, "measure peak", err))
        })
        .try_fold(0.0_f64, |max, value| value.map(|value| max.max(value)))
}

fn finite_metric(
    path: &Path,
    name: &'static str,
    value: std::result::Result<f64, ebur128::Error>,
) -> Result<f64> {
    let value = value.map_err(|err| analysis_error(path, name, err))?;
    if value.is_finite() {
        Ok(value)
    } else {
        Err(analysis_error(path, name, "metric is not finite"))
    }
}

fn hann_window(size: usize) -> Vec<f32> {
    (0..size)
        .map(|index| {
            0.5 - 0.5
                * (std::f32::consts::TAU * index as f32 / (size.saturating_sub(1)) as f32).cos()
        })
        .collect()
}

fn spectral_band_index(frequency: f64) -> Option<usize> {
    SPECTRAL_BANDS
        .iter()
        .position(|(low, high)| frequency >= *low && frequency < *high)
}

fn percentile(sorted: &[f64], percentile: f64) -> f64 {
    let index = ((sorted.len() - 1) as f64 * percentile).round() as usize;
    sorted[index]
}

fn amplitude_to_db(value: f64) -> f64 {
    20.0 * value.max(f64::MIN_POSITIVE).log10()
}

fn power_to_db(value: f64) -> f64 {
    10.0 * value.max(1e-12).log10()
}

fn subtract_arrays(reference: [f64; 3], target: [f64; 3]) -> [f64; 3] {
    std::array::from_fn(|index| reference[index] - target[index])
}

fn analysis_error(
    path: &Path,
    operation: &'static str,
    error: impl std::fmt::Display,
) -> DoppelbangerError {
    DoppelbangerError::AudioProcessing {
        operation,
        path: path.to_path_buf(),
        message: error.to_string(),
    }
}
