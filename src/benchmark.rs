use std::fs;
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{
    ANALYZER_VERSION, DoppelbangerError, PROCESSOR_VERSION, PairDiffV1, Result, analyze_track,
    generate_plan, render_master,
};

const FAST_PAIR_IDS: [&str; 3] = ["01", "04", "10"];
const FULL_PAIR_IDS: [&str; 10] = ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10"];
const ALBUMDB_DOI: &str = "10.5281/zenodo.19683001";

#[derive(Deserialize)]
struct PreparedCorpusManifest {
    schema_version: u32,
    source_doi: String,
    pairs: Vec<PreparedPair>,
}

#[derive(Deserialize)]
struct PreparedPair {
    id: String,
    reference_sha256: String,
    target_sha256: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct BenchmarkItemV1 {
    pub pair_id: String,
    pub duration_seconds: f64,
    pub reference_analysis_seconds: f64,
    pub target_analysis_seconds: f64,
    pub analysis_seconds: f64,
    pub analysis_realtime_factor: f64,
    pub render_seconds: f64,
    pub render_realtime_factor: f64,
    pub tonal_error_before_db: f64,
    pub tonal_error_after_db: f64,
    pub tonal_improvement_percent: f64,
    pub spectral_delta_before_db: Vec<f64>,
    pub spectral_delta_after_db: Vec<f64>,
    pub eq_gains_db: Vec<f64>,
    pub loudness_error_before_db: f64,
    pub loudness_error_after_db: f64,
    pub lra_error_before_lu: f64,
    pub lra_error_after_lu: f64,
    pub plr_error_before_db: f64,
    pub plr_error_after_db: f64,
    pub transient_p95_error_before: f64,
    pub transient_p95_error_after: f64,
    pub correlation_error_before: f64,
    pub correlation_error_after: f64,
    pub output_true_peak_dbtp: f64,
    pub loudness_shortfall_db: f64,
    pub output_path: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BenchmarkProvenanceV1 {
    pub package_version: String,
    pub analyzer_version: String,
    pub processor_version: String,
    pub git_commit: Option<String>,
    pub git_dirty: Option<bool>,
    pub workspace_git_commit: Option<String>,
    pub workspace_git_dirty: Option<bool>,
    pub build_profile: String,
    pub rustc_version: Option<String>,
    pub target_os: String,
    pub os_version: Option<String>,
    pub target_arch: String,
    pub logical_cpu_count: usize,
    pub machine_label: Option<String>,
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
    pub provenance: BenchmarkProvenanceV1,
    pub mode: String,
    pub corpus_path: String,
    pub corpus_manifest_sha256: String,
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
    let corpus_manifest_sha256 = sha256_file(&corpus.join("manifest.json"))?;
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

        let reference_analysis_started = Instant::now();
        let reference = analyze_track(&reference_path)?;
        let reference_analysis_seconds = reference_analysis_started
            .elapsed()
            .as_secs_f64()
            .max(f64::MIN_POSITIVE);
        let target_analysis_started = Instant::now();
        let target = analyze_track(&target_path)?;
        let target_analysis_seconds = target_analysis_started
            .elapsed()
            .as_secs_f64()
            .max(f64::MIN_POSITIVE);
        let analysis_seconds = reference_analysis_seconds + target_analysis_seconds;
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
        let tonal_before = three_band_tonal_error(&before.spectral_relative_db);
        let tonal_after = three_band_tonal_error(&after.spectral_relative_db);
        let tonal_improvement_percent = if tonal_before <= 1e-9 {
            0.0
        } else {
            (1.0 - tonal_after / tonal_before) * 100.0
        };
        let duration_seconds = target.metadata.duration_seconds;
        let output_path = format!("benchmark-renders/{pair_id}.wav");

        items.push(BenchmarkItemV1 {
            pair_id,
            duration_seconds,
            reference_analysis_seconds,
            target_analysis_seconds,
            analysis_seconds,
            analysis_realtime_factor: (reference.metadata.duration_seconds + duration_seconds)
                / analysis_seconds,
            render_seconds,
            render_realtime_factor: duration_seconds / render_seconds,
            tonal_error_before_db: tonal_before,
            tonal_error_after_db: tonal_after,
            tonal_improvement_percent,
            spectral_delta_before_db: before.spectral_relative_db.clone(),
            spectral_delta_after_db: after.spectral_relative_db.clone(),
            eq_gains_db: plan.eq.iter().map(|filter| filter.gain_db).collect(),
            loudness_error_before_db: before.integrated_lufs.abs(),
            loudness_error_after_db: after.integrated_lufs.abs(),
            lra_error_before_lu: before.loudness_range_lu.abs(),
            lra_error_after_lu: after.loudness_range_lu.abs(),
            plr_error_before_db: before.peak_to_loudness_ratio_db.abs(),
            plr_error_after_db: after.peak_to_loudness_ratio_db.abs(),
            transient_p95_error_before: before.transient_p95_flux.abs(),
            transient_p95_error_after: after.transient_p95_flux.abs(),
            correlation_error_before: before.correlation.abs(),
            correlation_error_after: after.correlation.abs(),
            output_true_peak_dbtp: render.output_analysis.loudness.true_peak_dbtp,
            loudness_shortfall_db: plan.loudness_shortfall_db,
            output_path,
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
            loudness_within_bound(
                item.loudness_error_before_db,
                item.loudness_error_after_db,
                item.loudness_shortfall_db,
            )
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
        provenance: benchmark_provenance(),
        mode: if full { "full" } else { "fast" }.to_string(),
        corpus_path: corpus.to_string_lossy().into_owned(),
        corpus_manifest_sha256,
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
    let manifest_path = corpus.join("manifest.json");
    let manifest_bytes = fs::read(&manifest_path).map_err(|error| {
        DoppelbangerError::InvalidRequest(format!(
            "benchmark corpus requires prepared manifest {}: {error}",
            manifest_path.display()
        ))
    })?;
    let manifest: PreparedCorpusManifest =
        serde_json::from_slice(&manifest_bytes).map_err(|error| {
            DoppelbangerError::InvalidRequest(format!(
                "failed to decode prepared corpus manifest {}: {error}",
                manifest_path.display()
            ))
        })?;
    if manifest.schema_version != 1 || manifest.source_doi != ALBUMDB_DOI {
        return Err(DoppelbangerError::InvalidRequest(format!(
            "prepared corpus manifest must be schema 1 from {ALBUMDB_DOI}"
        )));
    }

    let mut manifest_ids: Vec<&str> = manifest.pairs.iter().map(|pair| pair.id.as_str()).collect();
    manifest_ids.sort_unstable();
    if manifest_ids.windows(2).any(|ids| ids[0] == ids[1]) {
        return Err(DoppelbangerError::InvalidRequest(
            "prepared corpus manifest contains duplicate pair IDs".to_string(),
        ));
    }
    manifest_ids.dedup();
    if full && manifest_ids != FULL_PAIR_IDS {
        return Err(DoppelbangerError::InvalidRequest(
            "full benchmark requires exactly AlbumDB pairs 01 through 10".to_string(),
        ));
    }

    let selected: &[&str] = if full { &FULL_PAIR_IDS } else { &FAST_PAIR_IDS };
    selected
        .iter()
        .map(|id| {
            let pair = manifest
                .pairs
                .iter()
                .find(|pair| pair.id == *id)
                .ok_or_else(|| {
                    DoppelbangerError::InvalidRequest(format!(
                        "benchmark manifest is missing AlbumDB pair {id}"
                    ))
                })?;
            let path = corpus.join(id);
            let reference = path.join("reference.wav");
            let target = path.join("target.wav");
            require_file("reference", &reference)?;
            require_file("target", &target)?;
            verify_sha256(&reference, &pair.reference_sha256)?;
            verify_sha256(&target, &pair.target_sha256)?;
            Ok(((*id).to_string(), path))
        })
        .collect()
}

fn verify_sha256(path: &Path, expected: &str) -> Result<()> {
    let actual = sha256_file(path)?;
    if actual == expected {
        Ok(())
    } else {
        Err(DoppelbangerError::InvalidRequest(format!(
            "corpus hash mismatch for {}: expected {expected}, got {actual}",
            path.display()
        )))
    }
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut file = File::open(path).map_err(|error| {
        DoppelbangerError::Io(format!("failed to hash {}: {error}", path.display()))
    })?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).map_err(|error| {
            DoppelbangerError::Io(format!("failed to hash {}: {error}", path.display()))
        })?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

fn benchmark_provenance() -> BenchmarkProvenanceV1 {
    let workspace_git_commit = git_output(&["rev-parse", "HEAD"]).filter(|value| !value.is_empty());
    let workspace_git_dirty = git_output(&["status", "--porcelain"]).map(|value| !value.is_empty());
    BenchmarkProvenanceV1 {
        package_version: env!("CARGO_PKG_VERSION").to_string(),
        analyzer_version: ANALYZER_VERSION.to_string(),
        processor_version: PROCESSOR_VERSION.to_string(),
        git_commit: option_env!("DOPPELBANGER_BUILD_GIT_COMMIT").map(str::to_string),
        git_dirty: option_env!("DOPPELBANGER_BUILD_GIT_DIRTY").and_then(|value| value.parse().ok()),
        workspace_git_commit,
        workspace_git_dirty,
        build_profile: if cfg!(debug_assertions) {
            "debug".to_string()
        } else {
            "release".to_string()
        },
        rustc_version: option_env!("DOPPELBANGER_BUILD_RUSTC_VERSION").map(str::to_string),
        target_os: std::env::consts::OS.to_string(),
        os_version: os_version(),
        target_arch: std::env::consts::ARCH.to_string(),
        logical_cpu_count: std::thread::available_parallelism()
            .map(usize::from)
            .unwrap_or(1),
        machine_label: std::env::var("DOPPELBANGER_BENCHMARK_MACHINE").ok(),
    }
}

fn git_output(args: &[&str]) -> Option<String> {
    let mut command = Command::new("git");
    command.arg("-C").arg(env!("CARGO_MANIFEST_DIR"));
    command.args(args);
    command_output_from(&mut command)
}

fn command_output(program: &str, args: &[&str]) -> Option<String> {
    command_output_from(Command::new(program).args(args))
}

fn command_output_from(command: &mut Command) -> Option<String> {
    let output = command.output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn os_version() -> Option<String> {
    if let Ok(version) = std::env::var("DOPPELBANGER_OS_VERSION") {
        return Some(version);
    }
    if cfg!(target_os = "macos") {
        command_output("sw_vers", &["-productVersion"])
    } else if cfg!(target_os = "windows") {
        command_output("cmd", &["/C", "ver"])
    } else {
        command_output("uname", &["-sr"])
    }
}

fn three_band_tonal_error(values: &[f64]) -> f64 {
    debug_assert_eq!(values.len(), 9);
    let region_error =
        |region: &[f64]| region.iter().map(|value| value.abs()).sum::<f64>() / region.len() as f64;
    median(
        [
            region_error(&values[0..3]),
            region_error(&values[3..7]),
            region_error(&values[7..9]),
        ]
        .into_iter(),
    )
}

fn loudness_within_bound(before: f64, after: f64, shortfall: f64) -> bool {
    let allowed_regression = if shortfall > 0.0 { 0.25 } else { 0.05 };
    after <= before + allowed_regression + f64::EPSILON
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

#[cfg(not(unix))]
fn peak_rss_mib() -> Option<f64> {
    None
}

#[cfg(test)]
mod tests {
    use super::{loudness_within_bound, three_band_tonal_error};

    #[test]
    fn tonal_error_matches_the_three_processor_regions() {
        let deltas = [3.0, -3.0, 3.0, 1.0, -1.0, 1.0, -1.0, 2.0, -2.0];

        assert_eq!(three_band_tonal_error(&deltas), 2.0);
    }

    #[test]
    fn loudness_cap_exemption_is_small_and_bounded() {
        assert!(loudness_within_bound(1.0, 1.05, 0.0));
        assert!(!loudness_within_bound(1.0, 1.06, 0.0));
        assert!(loudness_within_bound(1.0, 1.25, 6.0));
        assert!(!loudness_within_bound(1.0, 1.26, 6.0));
    }
}
