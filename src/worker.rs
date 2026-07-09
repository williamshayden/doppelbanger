use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    ApiClient, DoppelbangerError, MasteringJob, MasteringPlanV1, PairDiffV1, RenderReportV1,
    RequestStatus, Result, TrackAnalysisV1, TrackRole, analyze_track, generate_plan, render_master,
    validate_plan,
};

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct PipelineReportV1 {
    pub schema_version: u32,
    pub request_id: Uuid,
    pub reference_analysis: TrackAnalysisV1,
    pub target_analysis: TrackAnalysisV1,
    pub before_diff: PairDiffV1,
    pub plan: MasteringPlanV1,
    pub render: RenderReportV1,
    pub after_diff: PairDiffV1,
    pub report_path: String,
}

pub fn process_job(client: &ApiClient, job: &MasteringJob) -> Result<PipelineReportV1> {
    match process_job_inner(client, job) {
        Ok(report) => Ok(report),
        Err(error) => {
            let message = error.to_string();
            match client.update_request(&job.id, RequestStatus::Failed, Some(&message)) {
                Ok(()) => Err(error),
                Err(update_error) => Err(DoppelbangerError::Io(format!(
                    "{message}; additionally failed to persist request failure: {update_error}"
                ))),
            }
        }
    }
}

fn process_job_inner(client: &ApiClient, job: &MasteringJob) -> Result<PipelineReportV1> {
    let reference_analysis = analyze_track(&job.reference_path)?;
    let target_analysis = analyze_track(&job.target_path)?;
    client.insert_analysis(
        &job.id,
        &job.reference_track_id,
        TrackRole::Reference,
        &reference_analysis,
    )?;
    client.insert_analysis(
        &job.id,
        &job.target_track_id,
        TrackRole::Target,
        &target_analysis,
    )?;

    let before_diff = PairDiffV1::between(&reference_analysis, &target_analysis)?;
    let plan = match &job.submitted_plan {
        Some(submitted) => {
            prepare_submitted_plan(submitted, &reference_analysis, &target_analysis)?
        }
        None => generate_plan(&reference_analysis, &target_analysis, &before_diff)?,
    };
    client.insert_plan(&job.id, &plan)?;
    client.update_request(&job.id, RequestStatus::Ready, None)?;
    client.update_request(&job.id, RequestStatus::Rendering, None)?;

    let render = render_master(&job.target_path, &job.output_path, &plan)?;
    let after_diff = PairDiffV1::between(&reference_analysis, &render.output_analysis)?;
    let report_path = job.output_path.with_extension("report.json");
    let report = PipelineReportV1 {
        schema_version: 1,
        request_id: job.id,
        reference_analysis,
        target_analysis,
        before_diff,
        plan,
        render,
        after_diff,
        report_path: report_path.to_string_lossy().into_owned(),
    };
    write_report(&report_path, &report)?;
    client.insert_artifact(&job.id, &job.output_path, &report)?;
    client.update_request(&job.id, RequestStatus::Complete, None)?;
    Ok(report)
}

fn write_report(path: &Path, report: &PipelineReportV1) -> Result<()> {
    let json = serde_json::to_string_pretty(report).map_err(|error| {
        DoppelbangerError::Io(format!("failed to encode pipeline report: {error}"))
    })?;
    let temporary = temporary_path(path);
    fs::write(&temporary, format!("{json}\n")).map_err(|error| {
        DoppelbangerError::Io(format!(
            "failed to write report {}: {error}",
            temporary.display()
        ))
    })?;
    if path.exists() {
        fs::remove_file(path).map_err(|error| {
            DoppelbangerError::Io(format!(
                "failed to replace report {}: {error}",
                path.display()
            ))
        })?;
    }
    fs::rename(&temporary, path).map_err(|error| {
        DoppelbangerError::Io(format!(
            "failed to publish report {}: {error}",
            path.display()
        ))
    })
}

fn temporary_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("mastered.report.json");
    path.with_file_name(format!(".{file_name}.part-{}", std::process::id()))
}

fn prepare_submitted_plan(
    submitted: &MasteringPlanV1,
    reference: &TrackAnalysisV1,
    target: &TrackAnalysisV1,
) -> Result<MasteringPlanV1> {
    if submitted.reference_sha256 != reference.metadata.source_sha256 {
        return Err(DoppelbangerError::InvalidPlan(
            "reference_sha256 does not match the decoded reference file".to_string(),
        ));
    }
    let mut plan = submitted.clone();
    plan.loudness_shortfall_db = (plan.desired_gain_db - plan.applied_gain_db).max(0.0);
    validate_plan(&plan, target)?;
    Ok(plan)
}
use std::fs;
use std::path::{Path, PathBuf};
