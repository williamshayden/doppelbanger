mod analysis;
mod api;
mod audio;
mod benchmark;
mod dsp;
mod ffi;
mod plan;
mod render;
mod worker;

use std::fmt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub use analysis::{
    ANALYZER_VERSION, AnalysisAnomaliesV1, AudioMetadataV1, LoudnessMetricsV1, PairDiffV1,
    SpectralBandV1, StereoMetricsV1, TrackAnalysisV1, TransientMetricsV1, analyze_track,
};
pub use api::{
    ApiClient, EditablePlanFileV1, MasteringJob, MasteringRequestState, RequestStatus,
    SubmitRequest, TrackRole,
};
pub use audio::{AudioBlock, AudioReader, AudioStreamInfo};
pub use benchmark::{
    BenchmarkGatesV1, BenchmarkItemV1, BenchmarkProvenanceV1, BenchmarkReportV1,
    BenchmarkSummaryV1, run_benchmark,
};
pub use dsp::{MasteringProcessor, ProcessError};
pub use ffi::{
    DB_ABI_VERSION, DB_MAX_BLOCK_FRAMES, DB_PLAN_SCHEMA_VERSION, DB_PROCESSOR_VERSION, DbProcessor,
    DbRuntimePlanV1, DbStatus, db_processor_create, db_processor_destroy,
    db_processor_latency_samples, db_processor_process_f32, db_processor_reset,
};
pub use plan::{
    EqFilterKindV1, EqFilterV1, MasteringPlanV1, PROCESSOR_VERSION, TRUE_PEAK_CEILING_DBTP,
    generate_plan, validate_plan,
};
pub use render::{RenderReportV1, render_master};
pub use worker::{PipelineReportV1, process_job};

pub type Result<T> = std::result::Result<T, DoppelbangerError>;

#[derive(Debug, PartialEq)]
pub enum DoppelbangerError {
    MissingExtension {
        path: PathBuf,
    },
    UnsupportedAudioFormat {
        path: PathBuf,
    },
    MissingFile {
        field: &'static str,
        path: PathBuf,
    },
    MissingArgument(&'static str),
    UnexpectedArgument(String),
    AudioProcessing {
        operation: &'static str,
        path: PathBuf,
        message: String,
    },
    MissingAudioProperty {
        property: &'static str,
        path: PathBuf,
    },
    UnsupportedChannelCount {
        path: PathBuf,
        channels: usize,
    },
    InvalidPlan(String),
    InvalidRequest(String),
    Api {
        operation: &'static str,
        url: String,
        message: String,
    },
    Io(String),
}

impl fmt::Display for DoppelbangerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingExtension { path } => {
                write!(f, "missing audio format extension: {}", path.display())
            }
            Self::UnsupportedAudioFormat { path } => {
                write!(f, "unsupported audio format for {}", path.display())
            }
            Self::MissingFile { field, path } => {
                write!(f, "{field} file does not exist: {}", path.display())
            }
            Self::MissingArgument(name) => write!(f, "missing required argument {name}"),
            Self::UnexpectedArgument(arg) => write!(f, "unexpected argument {arg}"),
            Self::AudioProcessing {
                operation,
                path,
                message,
            } => write!(
                f,
                "failed to {operation} audio {}: {message}",
                path.display()
            ),
            Self::MissingAudioProperty { property, path } => {
                write!(f, "audio {} is missing {property}", path.display())
            }
            Self::UnsupportedChannelCount { path, channels } => write!(
                f,
                "audio {} must be stereo, found {channels} channels",
                path.display()
            ),
            Self::InvalidPlan(message) => write!(f, "invalid mastering plan: {message}"),
            Self::InvalidRequest(message) => write!(f, "invalid request: {message}"),
            Self::Api {
                operation,
                url,
                message,
            } => write!(f, "API {operation} failed for {url}: {message}"),
            Self::Io(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for DoppelbangerError {}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum AudioFormat {
    Mp3,
    Wav,
}

impl AudioFormat {
    pub fn from_path(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let extension = path
            .extension()
            .and_then(|value| value.to_str())
            .ok_or_else(|| DoppelbangerError::MissingExtension {
                path: path.to_path_buf(),
            })?
            .to_ascii_lowercase();

        match extension.as_str() {
            "mp3" => Ok(Self::Mp3),
            "wav" => Ok(Self::Wav),
            _ => Err(DoppelbangerError::UnsupportedAudioFormat {
                path: path.to_path_buf(),
            }),
        }
    }
}
