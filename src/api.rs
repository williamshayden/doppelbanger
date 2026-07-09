use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    AudioFormat, AudioReader, DoppelbangerError, MasteringPlanV1, Result, TrackAnalysisV1,
};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RequestStatus {
    Queued,
    Analyzing,
    Ready,
    Rendering,
    Complete,
    Failed,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TrackRole {
    Reference,
    Target,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SubmitRequest {
    pub reference_path: PathBuf,
    pub reference_format: AudioFormat,
    pub target_path: PathBuf,
    pub target_format: AudioFormat,
    pub output_path: PathBuf,
    pub submitted_plan: Option<MasteringPlanV1>,
    pub parent_request_id: Option<Uuid>,
}

impl SubmitRequest {
    pub fn from_paths(
        reference_path: impl AsRef<Path>,
        target_path: impl AsRef<Path>,
        output_path: impl AsRef<Path>,
        submitted_plan: Option<MasteringPlanV1>,
        parent_request_id: Option<Uuid>,
    ) -> Result<Self> {
        if submitted_plan.is_some() != parent_request_id.is_some() {
            return Err(DoppelbangerError::InvalidRequest(
                "--plan and parent_request_id must be provided together".to_string(),
            ));
        }
        let reference_path = canonical_input("reference", reference_path.as_ref())?;
        let target_path = canonical_input("target", target_path.as_ref())?;
        let reference_format = AudioReader::open(&reference_path)?.info().format;
        let target_format = AudioReader::open(&target_path)?.info().format;
        let output_path = absolute_output(output_path.as_ref())?;
        if !matches!(AudioFormat::from_path(&output_path), Ok(AudioFormat::Wav)) {
            return Err(DoppelbangerError::InvalidRequest(format!(
                "output must be a WAV path: {}",
                output_path.display()
            )));
        }
        let parent = output_path.parent().ok_or_else(|| {
            DoppelbangerError::InvalidRequest(format!(
                "output has no parent directory: {}",
                output_path.display()
            ))
        })?;
        if !parent.is_dir() {
            return Err(DoppelbangerError::InvalidRequest(format!(
                "output directory does not exist: {}",
                parent.display()
            )));
        }

        Ok(Self {
            reference_path,
            reference_format,
            target_path,
            target_format,
            output_path,
            submitted_plan,
            parent_request_id,
        })
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct MasteringJob {
    pub id: Uuid,
    pub parent_request_id: Option<Uuid>,
    pub reference_track_id: Uuid,
    pub target_track_id: Uuid,
    pub reference_path: PathBuf,
    pub target_path: PathBuf,
    pub output_path: PathBuf,
    pub submitted_plan: Option<MasteringPlanV1>,
    pub status: RequestStatus,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct MasteringRequestState {
    pub id: Uuid,
    pub output_path: PathBuf,
    pub status: RequestStatus,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct EditablePlanFileV1 {
    pub schema_version: u32,
    pub parent_request_id: Uuid,
    pub plan: MasteringPlanV1,
}

#[derive(Clone, Debug)]
pub struct ApiClient {
    base_url: String,
    agent: ureq::Agent,
}

impl ApiClient {
    pub fn new(base_url: impl Into<String>) -> Result<Self> {
        let base_url = base_url.into().trim_end_matches('/').to_string();
        if !base_url.starts_with("http://") {
            return Err(DoppelbangerError::InvalidRequest(format!(
                "local API URL must start with http://: {base_url}"
            )));
        }
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .build()
            .into();
        Ok(Self { base_url, agent })
    }

    pub fn submit(&self, request: &SubmitRequest) -> Result<Uuid> {
        let body = json!({
            "reference_path": request.reference_path,
            "reference_format": request.reference_format,
            "target_path": request.target_path,
            "target_format": request.target_format,
            "output_path": request.output_path,
            "submitted_plan": request.submitted_plan,
            "parent_request_id": request.parent_request_id,
        });
        self.post_json("rpc/submit_mastering_request", &body)
    }

    pub fn claim(&self) -> Result<Option<MasteringJob>> {
        self.post_json("rpc/claim_mastering_request", &json!({}))
    }

    pub fn insert_analysis(
        &self,
        request_id: &Uuid,
        track_id: &Uuid,
        role: TrackRole,
        analysis: &TrackAnalysisV1,
    ) -> Result<()> {
        self.post_empty(
            "analysis_results",
            &json!({
                "mastering_request_id": request_id,
                "track_id": track_id,
                "role": role,
                "metrics": analysis,
            }),
        )
    }

    pub fn insert_plan(&self, request_id: &Uuid, plan: &MasteringPlanV1) -> Result<()> {
        self.post_empty(
            "mastering_plans",
            &json!({"mastering_request_id": request_id, "plan": plan}),
        )
    }

    pub fn insert_artifact<T: Serialize>(
        &self,
        request_id: &Uuid,
        output_path: &Path,
        report: &T,
    ) -> Result<()> {
        self.post_empty(
            "render_artifacts",
            &json!({
                "mastering_request_id": request_id,
                "output_path": output_path,
                "report": report,
            }),
        )
    }

    pub fn update_request(
        &self,
        request_id: &Uuid,
        status: RequestStatus,
        error: Option<&str>,
    ) -> Result<()> {
        let path = format!("mastering_requests?id=eq.{request_id}");
        let url = self.url(&path);
        let response = self
            .agent
            .patch(&url)
            .header("Prefer", "return=minimal")
            .send_json(json!({"status": status, "error": error}))
            .map_err(|err| api_error("update request", &url, err))?;
        ensure_success("update request", &url, response)
    }

    pub fn request(&self, request_id: &Uuid) -> Result<MasteringRequestState> {
        let path =
            format!("mastering_requests?id=eq.{request_id}&select=id,output_path,status,error");
        let url = self.url(&path);
        let response = self
            .agent
            .get(&url)
            .call()
            .map_err(|err| api_error("read request", &url, err))?;
        let states: Vec<MasteringRequestState> = decode_json("read request", &url, response)?;
        match states.as_slice() {
            [state] => Ok(state.clone()),
            [] => Err(DoppelbangerError::Api {
                operation: "read request",
                url,
                message: format!("request {request_id} was not found"),
            }),
            _ => Err(DoppelbangerError::Api {
                operation: "read request",
                url,
                message: format!("request {request_id} returned multiple rows"),
            }),
        }
    }

    pub fn plan(&self, request_id: &Uuid) -> Result<MasteringPlanV1> {
        #[derive(Deserialize)]
        struct PlanRow {
            plan: MasteringPlanV1,
        }

        let path = format!("mastering_plans?mastering_request_id=eq.{request_id}&select=plan");
        let url = self.url(&path);
        let response = self
            .agent
            .get(&url)
            .call()
            .map_err(|err| api_error("read plan", &url, err))?;
        let rows: Vec<PlanRow> = decode_json("read plan", &url, response)?;
        match rows.as_slice() {
            [row] => Ok(row.plan.clone()),
            [] => Err(DoppelbangerError::Api {
                operation: "read plan",
                url,
                message: format!("plan for request {request_id} was not found"),
            }),
            _ => Err(DoppelbangerError::Api {
                operation: "read plan",
                url,
                message: format!("request {request_id} returned multiple plans"),
            }),
        }
    }

    fn post_json<T: DeserializeOwned>(&self, path: &str, body: &Value) -> Result<T> {
        let url = self.url(path);
        let response = self
            .agent
            .post(&url)
            .send_json(body)
            .map_err(|err| api_error("POST", &url, err))?;
        decode_json("POST", &url, response)
    }

    fn post_empty(&self, path: &str, body: &Value) -> Result<()> {
        let url = self.url(path);
        let response = self
            .agent
            .post(&url)
            .header("Prefer", "return=minimal")
            .send_json(body)
            .map_err(|err| api_error("POST", &url, err))?;
        ensure_success("POST", &url, response)
    }

    fn url(&self, path: &str) -> String {
        format!("{}/{}", self.base_url, path.trim_start_matches('/'))
    }
}

fn canonical_input(field: &'static str, path: &Path) -> Result<PathBuf> {
    if !path.is_file() {
        return Err(DoppelbangerError::MissingFile {
            field,
            path: path.to_path_buf(),
        });
    }
    path.canonicalize().map_err(|err| {
        DoppelbangerError::Io(format!("failed to resolve {}: {err}", path.display()))
    })
}

fn absolute_output(path: &Path) -> Result<PathBuf> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        std::env::current_dir()
            .map(|current| current.join(path))
            .map_err(|err| {
                DoppelbangerError::Io(format!(
                    "failed to resolve output {}: {err}",
                    path.display()
                ))
            })
    }
}

fn decode_json<T: DeserializeOwned>(
    operation: &'static str,
    url: &str,
    mut response: ureq::http::Response<ureq::Body>,
) -> Result<T> {
    let body = response
        .body_mut()
        .read_to_string()
        .map_err(|err| api_error(operation, url, err))?;
    ensure_status(operation, url, response.status().as_u16(), &body)?;
    serde_json::from_str(&body).map_err(|err| DoppelbangerError::Api {
        operation,
        url: url.to_string(),
        message: format!("invalid JSON response: {err}; body={body}"),
    })
}

fn ensure_success(
    operation: &'static str,
    url: &str,
    mut response: ureq::http::Response<ureq::Body>,
) -> Result<()> {
    let status = response.status().as_u16();
    let body = response
        .body_mut()
        .read_to_string()
        .map_err(|err| api_error(operation, url, err))?;
    ensure_status(operation, url, status, &body)
}

fn ensure_status(operation: &'static str, url: &str, status: u16, body: &str) -> Result<()> {
    if (200..300).contains(&status) {
        Ok(())
    } else {
        Err(DoppelbangerError::Api {
            operation,
            url: url.to_string(),
            message: format!("HTTP {status}: {body}"),
        })
    }
}

fn api_error(
    operation: &'static str,
    url: &str,
    error: impl std::fmt::Display,
) -> DoppelbangerError {
    DoppelbangerError::Api {
        operation,
        url: url.to_string(),
        message: error.to_string(),
    }
}
