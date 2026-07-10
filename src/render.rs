use std::fs;
use std::path::{Path, PathBuf};

use biquad::{Biquad, Coefficients, DirectForm2Transposed, ToHertz, Type};
use serde::{Deserialize, Serialize};

use crate::{
    AudioReader, DoppelbangerError, EqFilterKindV1, EqFilterV1, MasteringPlanV1, PROCESSOR_VERSION,
    Result, TrackAnalysisV1, analyze_track, validate_plan,
};

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct RenderReportV1 {
    pub schema_version: u32,
    pub processor_version: String,
    pub output_path: String,
    pub output_analysis: TrackAnalysisV1,
}

pub fn render_master(
    target_path: impl AsRef<Path>,
    output_path: impl AsRef<Path>,
    plan: &MasteringPlanV1,
) -> Result<RenderReportV1> {
    let target_path = target_path.as_ref();
    let output_path = absolute_output_path(output_path.as_ref())?;
    let target_analysis = analyze_track(target_path)?;
    validate_plan(plan, &target_analysis)?;
    reject_input_overwrite(&target_analysis, &output_path)?;

    let mut reader = AudioReader::open(target_path)?;
    let sample_rate_hz = reader.info().sample_rate_hz;
    let mut filters = if plan.bypass {
        Vec::new()
    } else {
        create_filters(&plan.eq, sample_rate_hz)?
    };
    let gain = 10.0_f32.powf(plan.applied_gain_db as f32 / 20.0);
    let temp_path = temporary_output_path(&output_path);
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate: sample_rate_hz,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut writer = hound::WavWriter::create(&temp_path, spec)
        .map_err(|err| render_error("create", &temp_path, err))?;

    let render_result = (|| {
        while let Some(mut block) = reader.next_block()? {
            for frame in block.samples.chunks_exact_mut(2) {
                if !plan.bypass {
                    for filter in &mut filters {
                        frame[0] = filter.left.run(frame[0]);
                        frame[1] = filter.right.run(frame[1]);
                    }
                    frame[0] *= gain;
                    frame[1] *= gain;
                }
                if !frame[0].is_finite() || !frame[1].is_finite() {
                    return Err(render_error(
                        "render",
                        &output_path,
                        "processor produced a non-finite sample",
                    ));
                }
                writer
                    .write_sample(frame[0])
                    .and_then(|_| writer.write_sample(frame[1]))
                    .map_err(|err| render_error("write", &temp_path, err))?;
            }
        }
        writer
            .finalize()
            .map_err(|err| render_error("finalize", &temp_path, err))?;
        Ok(())
    })();

    if let Err(err) = render_result {
        let _ = fs::remove_file(&temp_path);
        return Err(err);
    }
    if output_path.exists() {
        fs::remove_file(&output_path).map_err(|err| render_error("replace", &output_path, err))?;
    }
    fs::rename(&temp_path, &output_path)
        .map_err(|err| render_error("publish", &output_path, err))?;

    let output_analysis = analyze_track(&output_path)?;
    if output_analysis.metadata.sample_rate_hz != target_analysis.metadata.sample_rate_hz
        || output_analysis.metadata.channels != target_analysis.metadata.channels
        || output_analysis.metadata.frame_count != target_analysis.metadata.frame_count
    {
        return Err(remove_failed_output(
            "verify",
            &output_path,
            "render changed sample rate, channel count, or duration",
        ));
    }
    if !plan.bypass && output_analysis.loudness.true_peak_dbtp > plan.true_peak_ceiling_dbtp + 0.1 {
        return Err(remove_failed_output(
            "verify",
            &output_path,
            format!(
                "true peak {:.3} dBTP exceeds {:.3} dBTP ceiling with 0.1 dB tolerance",
                output_analysis.loudness.true_peak_dbtp, plan.true_peak_ceiling_dbtp
            ),
        ));
    }

    Ok(RenderReportV1 {
        schema_version: 1,
        processor_version: PROCESSOR_VERSION.to_string(),
        output_path: output_analysis.metadata.path.clone(),
        output_analysis,
    })
}

fn remove_failed_output(
    operation: &'static str,
    path: &Path,
    error: impl std::fmt::Display,
) -> DoppelbangerError {
    let message = error.to_string();
    match fs::remove_file(path) {
        Ok(()) => render_error(operation, path, message),
        Err(cleanup_error) => render_error(
            operation,
            path,
            format!("{message}; additionally failed to remove unsafe output: {cleanup_error}"),
        ),
    }
}

struct StereoBiquad {
    left: DirectForm2Transposed<f32>,
    right: DirectForm2Transposed<f32>,
}

fn create_filters(filters: &[EqFilterV1], sample_rate_hz: u32) -> Result<Vec<StereoBiquad>> {
    filters
        .iter()
        .filter(|filter| filter.gain_db != 0.0)
        .map(|filter| {
            let filter_type = match filter.kind {
                EqFilterKindV1::LowShelf => Type::LowShelf(filter.gain_db as f32),
                EqFilterKindV1::Bell => Type::PeakingEQ(filter.gain_db as f32),
                EqFilterKindV1::HighShelf => Type::HighShelf(filter.gain_db as f32),
            };
            let coefficients = Coefficients::<f32>::from_params(
                filter_type,
                (sample_rate_hz as f32).hz(),
                (filter.frequency_hz as f32).hz(),
                filter.q as f32,
            )
            .map_err(|err| {
                DoppelbangerError::InvalidPlan(format!(
                    "cannot create {:?} filter at {} Hz: {err:?}",
                    filter.kind, filter.frequency_hz
                ))
            })?;
            Ok(StereoBiquad {
                left: DirectForm2Transposed::new(coefficients),
                right: DirectForm2Transposed::new(coefficients),
            })
        })
        .collect()
}

fn absolute_output_path(path: &Path) -> Result<PathBuf> {
    if path.is_absolute() {
        return Ok(path.to_path_buf());
    }
    std::env::current_dir()
        .map(|current| current.join(path))
        .map_err(|err| render_error("resolve", path, err))
}

fn reject_input_overwrite(target: &TrackAnalysisV1, output_path: &Path) -> Result<()> {
    if output_path.exists() {
        let canonical = output_path
            .canonicalize()
            .map_err(|err| render_error("resolve", output_path, err))?;
        if canonical.to_string_lossy() == target.metadata.path {
            return Err(render_error(
                "render",
                output_path,
                "output path must not overwrite the target input",
            ));
        }
    }
    Ok(())
}

fn temporary_output_path(output_path: &Path) -> PathBuf {
    let file_name = output_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("mastered.wav");
    output_path.with_file_name(format!(".{file_name}.part-{}", std::process::id()))
}

fn render_error(
    operation: &'static str,
    path: &Path,
    error: impl std::fmt::Display,
) -> DoppelbangerError {
    DoppelbangerError::AudioProcessing {
        operation,
        path: path.to_path_buf(),
        message: error.to_string(),
    }
}
