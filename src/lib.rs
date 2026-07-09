mod analysis;
mod audio;

use std::fmt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub use analysis::{
    AnalysisAnomaliesV1, AudioMetadataV1, LoudnessMetricsV1, PairDiffV1, SpectralBandV1,
    StereoMetricsV1, TrackAnalysisV1, TransientMetricsV1, analyze_track,
};
pub use audio::{AudioBlock, AudioReader, AudioStreamInfo};

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
    TuningOutOfRange {
        field: &'static str,
        value: f32,
        min: f32,
        max: f32,
    },
    InvalidNumber {
        field: String,
        value: String,
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
            Self::TuningOutOfRange {
                field,
                value,
                min,
                max,
            } => write!(f, "{field}={value} is outside safe range {min}..={max}"),
            Self::InvalidNumber { field, value } => {
                write!(f, "{field} must be a number, got {value}")
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

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct Tuning {
    pub loudness_db: f32,
    pub punch: f32,
    pub low_eq_db: f32,
    pub mid_eq_db: f32,
    pub high_eq_db: f32,
    pub width: f32,
}

impl Tuning {
    pub fn new(
        loudness_db: f32,
        punch: f32,
        low_eq_db: f32,
        mid_eq_db: f32,
        high_eq_db: f32,
        width: f32,
    ) -> Result<Self> {
        check_range("loudness_db", loudness_db, -12.0, 12.0)?;
        check_range("punch", punch, -1.0, 1.0)?;
        check_range("low_eq_db", low_eq_db, -12.0, 12.0)?;
        check_range("mid_eq_db", mid_eq_db, -12.0, 12.0)?;
        check_range("high_eq_db", high_eq_db, -12.0, 12.0)?;
        check_range("width", width, -1.0, 1.0)?;

        Ok(Self {
            loudness_db,
            punch,
            low_eq_db,
            mid_eq_db,
            high_eq_db,
            width,
        })
    }
}

impl Default for Tuning {
    fn default() -> Self {
        Self {
            loudness_db: 0.0,
            punch: 0.0,
            low_eq_db: 0.0,
            mid_eq_db: 0.0,
            high_eq_db: 0.0,
            width: 0.0,
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct RequestAudioFile {
    pub path: String,
    pub format: AudioFormat,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct MasteringRequest {
    pub reference: RequestAudioFile,
    pub target: RequestAudioFile,
    pub tuning: Tuning,
}

impl MasteringRequest {
    pub fn from_paths(
        reference_path: impl AsRef<Path>,
        target_path: impl AsRef<Path>,
        tuning: Tuning,
    ) -> Result<Self> {
        Ok(Self {
            reference: request_file("reference", reference_path.as_ref())?,
            target: request_file("target", target_path.as_ref())?,
            tuning,
        })
    }
}

fn request_file(field: &'static str, path: &Path) -> Result<RequestAudioFile> {
    if !path.is_file() {
        return Err(DoppelbangerError::MissingFile {
            field,
            path: path.to_path_buf(),
        });
    }

    let format = AudioFormat::from_path(path)?;
    let canonical = path.canonicalize().map_err(|err| {
        DoppelbangerError::Io(format!("failed to resolve {}: {err}", path.display()))
    })?;

    Ok(RequestAudioFile {
        path: canonical.to_string_lossy().into_owned(),
        format,
    })
}

fn check_range(field: &'static str, value: f32, min: f32, max: f32) -> Result<()> {
    if (min..=max).contains(&value) {
        return Ok(());
    }

    Err(DoppelbangerError::TuningOutOfRange {
        field,
        value,
        min,
        max,
    })
}
