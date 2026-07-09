use std::fmt;
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use symphonia::core::codecs::audio::well_known::CODEC_ID_MP3;
use symphonia::core::codecs::audio::{AudioDecoder, AudioDecoderOptions};
use symphonia::core::formats::{FormatOptions, FormatReader, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;

use crate::{AudioFormat, DoppelbangerError, Result};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AudioStreamInfo {
    pub path: PathBuf,
    pub source_sha256: String,
    pub format: AudioFormat,
    pub sample_rate_hz: u32,
    pub channels: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AudioBlock {
    pub samples: Vec<f32>,
    pub frames: usize,
}

pub struct AudioReader {
    info: AudioStreamInfo,
    track_id: u32,
    format: Box<dyn FormatReader>,
    decoder: Box<dyn AudioDecoder>,
}

impl fmt::Debug for AudioReader {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AudioReader")
            .field("info", &self.info)
            .field("track_id", &self.track_id)
            .finish_non_exhaustive()
    }
}

impl AudioReader {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let canonical = path
            .canonicalize()
            .map_err(|err| audio_error("open", path, err))?;
        let source_sha256 = sha256_file(&canonical)?;
        let file = File::open(&canonical).map_err(|err| audio_error("open", &canonical, err))?;
        let stream = MediaSourceStream::new(Box::new(file), Default::default());
        let format = symphonia::default::get_probe()
            .probe(
                &Default::default(),
                stream,
                FormatOptions::default(),
                MetadataOptions::default(),
            )
            .map_err(|err| audio_error("probe", &canonical, err))?;

        let track = format.default_track(TrackType::Audio).ok_or_else(|| {
            DoppelbangerError::MissingAudioProperty {
                property: "an audio track",
                path: canonical.clone(),
            }
        })?;
        let track_id = track.id;
        let codec_params = track
            .codec_params
            .as_ref()
            .and_then(|params| params.audio())
            .ok_or_else(|| DoppelbangerError::MissingAudioProperty {
                property: "audio codec parameters",
                path: canonical.clone(),
            })?
            .clone();
        let sample_rate_hz =
            codec_params
                .sample_rate
                .ok_or_else(|| DoppelbangerError::MissingAudioProperty {
                    property: "sample rate",
                    path: canonical.clone(),
                })?;
        let channels = codec_params
            .channels
            .as_ref()
            .ok_or_else(|| DoppelbangerError::MissingAudioProperty {
                property: "channel layout",
                path: canonical.clone(),
            })?
            .count();
        if channels != 2 {
            return Err(DoppelbangerError::UnsupportedChannelCount {
                path: canonical,
                channels,
            });
        }

        let audio_format = if codec_params.codec == CODEC_ID_MP3 {
            AudioFormat::Mp3
        } else {
            AudioFormat::Wav
        };
        let decoder = symphonia::default::get_codecs()
            .make_audio_decoder(&codec_params, &AudioDecoderOptions::default())
            .map_err(|err| audio_error("create decoder for", &canonical, err))?;

        Ok(Self {
            info: AudioStreamInfo {
                path: canonical,
                source_sha256,
                format: audio_format,
                sample_rate_hz,
                channels,
            },
            track_id,
            format,
            decoder,
        })
    }

    pub fn info(&self) -> &AudioStreamInfo {
        &self.info
    }

    pub fn next_block(&mut self) -> Result<Option<AudioBlock>> {
        loop {
            let Some(packet) = self
                .format
                .next_packet()
                .map_err(|err| audio_error("read", &self.info.path, err))?
            else {
                return Ok(None);
            };
            if packet.track_id != self.track_id {
                continue;
            }

            let decoded = self
                .decoder
                .decode(&packet)
                .map_err(|err| audio_error("decode", &self.info.path, err))?;
            let mut samples = vec![0.0; decoded.samples_interleaved()];
            decoded.copy_to_slice_interleaved(&mut samples);
            if samples.is_empty() {
                continue;
            }
            let frames = samples.len() / self.info.channels;
            return Ok(Some(AudioBlock { samples, frames }));
        }
    }
}

fn sha256_file(path: &Path) -> Result<String> {
    let file = File::open(path).map_err(|err| audio_error("hash", path, err))?;
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];

    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|err| audio_error("hash", path, err))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }

    Ok(format!("{:x}", hasher.finalize()))
}

fn audio_error(
    operation: &'static str,
    path: &Path,
    error: impl fmt::Display,
) -> DoppelbangerError {
    DoppelbangerError::AudioProcessing {
        operation,
        path: path.to_path_buf(),
        message: error.to_string(),
    }
}
