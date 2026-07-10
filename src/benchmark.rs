use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::{DoppelbangerError, PairDiffV1, Result, analyze_track, generate_plan, render_master};

const FAST_PAIR_IDS: [&str; 3] = ["01", "04", "10"];

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct BenchmarkItemV1 {
    pub pair_id: String,
    pub duration_seconds: f64,
    pub analysis_seconds: f64,
    pub analysis_realtime_factor: f64,
    pub render_seconds: f64,
    pub render_realtime_factor: f64,
    pub tonal_error_before_db: f64,
    pub tonal_error_after_db: f64,
    pub tonal_improvement_percent: f64,
    pub loudness_error_before_db: f64,
    pub loudness_error_after_db: f64,
    pub output_true_peak_dbtp: f64,
    pub loudness_shortfall_db: f64,
    pub output_path: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct BenchmarkSummaryV1 {
    pub pair_count: usize,
    pub median_tonal_error_before_db: f64,
    pub median_tonal_error_after_db: f64,
    pub median_tonal_improvement_percent: f64,
    pub maximum_tonal_regression_db: f64,
    pub minimum_analysis_realtime_factor: f64,
    pub minimum_render_realtime_factor: f64,
    pub peak_rss_mib: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BenchmarkGatesV1 {
    pub tonal_improvement: bool,
    pub tonal_regression: bool,
    pub loudness: bool,
    pub true_peak: bool,
    pub analysis_performance: bool,
    pub render_performance: bool,
    pub memory: bool,
}

impl BenchmarkGatesV1 {
    pub fn all_pass(&self) -> bool {
        self.tonal_improvement
            && self.tonal_regression
            && self.loudness
            && self.true_peak
            && self.analysis_performance
            && self.render_performance
            && self.memory
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct BenchmarkReportV1 {
    pub schema_version: u32,
    pub generated_at_unix_seconds: u64,
    pub mode: String,
    pub corpus_path: String,
    pub items: Vec<BenchmarkItemV1>,
    pub summary: BenchmarkSummaryV1,
    pub gates: BenchmarkGatesV1,
    pub gates_passed: bool,
}

pub fn run_benchmark(corpus: &Path, output: &Path, full: bool) -> Result<BenchmarkReportV1> {
    if !corpus.is_dir() {
        return Err(DoppelbangerError::InvalidRequest(format!(
            "benchmark corpus directory does not exist: {}",
            corpus.display()
        )));
    }
    let pair_dirs = pair_directories(corpus, full)?;
    let output = absolute_path(output)?;
    let output_parent = output.parent().ok_or_else(|| {
        DoppelbangerError::InvalidRequest(format!(
            "benchmark output has no parent directory: {}",
            output.display()
        ))
    })?;
    fs::create_dir_all(output_parent).map_err(|error| {
        DoppelbangerError::Io(format!(
            "failed to create benchmark output directory {}: {error}",
            output_parent.display()
        ))
    })?;
    let render_dir = output_parent.join("benchmark-renders");
    fs::create_dir_all(&render_dir).map_err(|error| {
        DoppelbangerError::Io(format!(
            "failed to create benchmark render directory {}: {error}",
            render_dir.display()
        ))
    })?;

    let mut items = Vec::with_capacity(pair_dirs.len());
    for (pair_id, pair_dir) in pair_dirs {
        let reference_path = pair_dir.join("reference.wav");
        let target_path = pair_dir.join("target.wav");
        require_file("reference", &reference_path)?;
        require_file("target", &target_path)?;

        let analysis_started = Instant::now();
        let reference = analyze_track(&reference_path)?;
        let target = analyze_track(&target_path)?;
        let analysis_seconds = analysis_started
            .elapsed()
            .as_secs_f64()
            .max(f64::MIN_POSITIVE);
        let before = PairDiffV1::between(&reference, &target)?;
        let plan = generate_plan(&reference, &target, &before)?;

        let render_path = render_dir.join(format!("{pair_id}.wav"));
        let render_started = Instant::now();
        let render = render_master(&target_path, &render_path, &plan)?;
        let render_seconds = render_started
            .elapsed()
            .as_secs_f64()
            .max(f64::MIN_POSITIVE);
        let after = PairDiffV1::between(&reference, &render.output_analysis)?;
        let tonal_before = median_absolute(&before.spectral_relative_db);
        let tonal_after = median_absolute(&after.spectral_relative_db);
        let tonal_improvement_percent = if tonal_before <= 1e-9 {
            0.0
        } else {
            (1.0 - tonal_after / tonal_before) * 100.0
        };
        let duration_seconds = target.metadata.duration_seconds;

        items.push(BenchmarkItemV1 {
            pair_id,
            duration_seconds,
            analysis_seconds,
            analysis_realtime_factor: (reference.metadata.duration_seconds + duration_seconds)
                / analysis_seconds,
            render_seconds,
            render_realtime_factor: duration_seconds / render_seconds,
            tonal_error_before_db: tonal_before,
            tonal_error_after_db: tonal_after,
            tonal_improvement_percent,
            loudness_error_before_db: before.integrated_lufs.abs(),
            loudness_error_after_db: after.integrated_lufs.abs(),
            output_true_peak_dbtp: render.output_analysis.loudness.true_peak_dbtp,
            loudness_shortfall_db: plan.loudness_shortfall_db,
            output_path: render.output_path,
        });
    }

    let median_tonal_before = median(items.iter().map(|item| item.tonal_error_before_db));
    let median_tonal_after = median(items.iter().map(|item| item.tonal_error_after_db));
    let median_tonal_improvement = if median_tonal_before <= 1e-9 {
        0.0
    } else {
        (1.0 - median_tonal_after / median_tonal_before) * 100.0
    };
    let maximum_tonal_regression = items
        .iter()
        .map(|item| item.tonal_error_after_db - item.tonal_error_before_db)
        .fold(f64::NEG_INFINITY, f64::max);
    let minimum_analysis_realtime = items
        .iter()
        .map(|item| item.analysis_realtime_factor)
        .fold(f64::INFINITY, f64::min);
    let minimum_render_realtime = items
        .iter()
        .map(|item| item.render_realtime_factor)
        .fold(f64::INFINITY, f64::min);
    let peak_rss_mib = peak_rss_mib();
    let gates = BenchmarkGatesV1 {
        tonal_improvement: median_tonal_improvement >= 25.0
            || (median_tonal_before <= 0.01 && median_tonal_after <= 0.01),
        tonal_regression: maximum_tonal_regression <= 0.25,
        loudness: items.iter().all(|item| {
            item.loudness_error_after_db <= item.loudness_error_before_db + 0.01
                || item.loudness_shortfall_db > 0.0
        }),
        true_peak: items.iter().all(|item| item.output_true_peak_dbtp <= -0.9),
        analysis_performance: minimum_analysis_realtime >= 1.0,
        render_performance: minimum_render_realtime >= 1.0,
        memory: peak_rss_mib.is_some_and(|memory| memory < 512.0),
    };
    let gates_passed = gates.all_pass();
    let report = BenchmarkReportV1 {
        schema_version: 1,
        generated_at_unix_seconds: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| DoppelbangerError::Io(format!("system clock error: {error}")))?
            .as_secs(),
        mode: if full { "full" } else { "fast" }.to_string(),
        corpus_path: corpus.to_string_lossy().into_owned(),
        summary: BenchmarkSummaryV1 {
            pair_count: items.len(),
            median_tonal_error_before_db: median_tonal_before,
            median_tonal_error_after_db: median_tonal_after,
            median_tonal_improvement_percent: median_tonal_improvement,
            maximum_tonal_regression_db: maximum_tonal_regression,
            minimum_analysis_realtime_factor: minimum_analysis_realtime,
            minimum_render_realtime_factor: minimum_render_realtime,
            peak_rss_mib,
        },
        gates,
        items,
        gates_passed,
    };
    write_report(&output, &report)?;
    Ok(report)
}

fn pair_directories(corpus: &Path, full: bool) -> Result<Vec<(String, PathBuf)>> {
    if !full {
        return FAST_PAIR_IDS
            .into_iter()
            .map(|id| {
                let path = corpus.join(id);
                if path.is_dir() {
                    Ok((id.to_string(), path))
                } else {
                    Err(DoppelbangerError::InvalidRequest(format!(
                        "fast benchmark pair is missing: {}",
                        path.display()
                    )))
                }
            })
            .collect();
    }

    let mut pairs: Vec<(String, PathBuf)> = fs::read_dir(corpus)
        .map_err(|error| {
            DoppelbangerError::Io(format!(
                "failed to read corpus {}: {error}",
                corpus.display()
            ))
        })?
        .filter_map(|entry| match entry {
            Ok(entry) if entry.path().is_dir() => entry
                .file_name()
                .to_str()
                .filter(|name| name.len() == 2 && name.bytes().all(|byte| byte.is_ascii_digit()))
                .map(|name| Ok((name.to_string(), entry.path()))),
            Ok(_) => None,
            Err(error) => Some(Err(DoppelbangerError::Io(format!(
                "failed to read corpus {}: {error}",
                corpus.display()
            )))),
        })
        .collect::<Result<_>>()?;
    pairs.sort_by(|left, right| left.0.cmp(&right.0));
    if pairs.is_empty() {
        return Err(DoppelbangerError::InvalidRequest(format!(
            "no two-digit pair directories found in {}",
            corpus.display()
        )));
    }
    Ok(pairs)
}

fn median_absolute(values: &[f64]) -> f64 {
    median(values.iter().map(|value| value.abs()))
}

fn median(values: impl Iterator<Item = f64>) -> f64 {
    let mut values: Vec<f64> = values.collect();
    values.sort_by(f64::total_cmp);
    let middle = values.len() / 2;
    if values.len().is_multiple_of(2) {
        (values[middle - 1] + values[middle]) * 0.5
    } else {
        values[middle]
    }
}

fn require_file(field: &'static str, path: &Path) -> Result<()> {
    if path.is_file() {
        Ok(())
    } else {
        Err(DoppelbangerError::MissingFile {
            field,
            path: path.to_path_buf(),
        })
    }
}

fn absolute_path(path: &Path) -> Result<PathBuf> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        std::env::current_dir()
            .map(|current| current.join(path))
            .map_err(|error| {
                DoppelbangerError::Io(format!(
                    "failed to resolve benchmark output {}: {error}",
                    path.display()
                ))
            })
    }
}

fn write_report(path: &Path, report: &BenchmarkReportV1) -> Result<()> {
    let json = serde_json::to_string_pretty(report).map_err(|error| {
        DoppelbangerError::Io(format!("failed to encode benchmark report: {error}"))
    })?;
    fs::write(path, format!("{json}\n")).map_err(|error| {
        DoppelbangerError::Io(format!(
            "failed to write benchmark report {}: {error}",
            path.display()
        ))
    })
}

#[cfg(unix)]
fn peak_rss_mib() -> Option<f64> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    // SAFETY: getrusage initializes the supplied rusage struct when it returns success.
    let result = unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) };
    if result != 0 {
        return None;
    }
    // SAFETY: result == 0 means getrusage initialized the struct.
    let maximum = unsafe { usage.assume_init() }.ru_maxrss as f64;
    #[cfg(target_os = "macos")]
    return Some(maximum / 1024.0 / 1024.0);
    #[cfg(not(target_os = "macos"))]
    return Some(maximum / 1024.0);
}

#[cfg(windows)]
fn peak_rss_mib() -> Option<f64> {
    use windows_sys::Win32::System::ProcessStatus::{
        GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS,
    };
    use windows_sys::Win32::System::Threading::GetCurrentProcess;

    let mut counters = PROCESS_MEMORY_COUNTERS {
        cb: std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32,
        ..Default::default()
    };
    // SAFETY: GetCurrentProcess returns a valid pseudo-handle and counters points to a
    // correctly sized writable PROCESS_MEMORY_COUNTERS value for the duration of the call.
    let result =
        unsafe { GetProcessMemoryInfo(GetCurrentProcess(), &raw mut counters, counters.cb) };
    (result != 0).then_some(counters.PeakWorkingSetSize as f64 / 1024.0 / 1024.0)
}

#[cfg(not(any(unix, windows)))]
fn peak_rss_mib() -> Option<f64> {
    None
}
