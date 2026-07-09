use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;
use std::thread;
use std::time::{Duration, Instant};

use doppelbanger::{
    ApiClient, DoppelbangerError, EditablePlanFileV1, RequestStatus, SubmitRequest, process_job,
    run_benchmark,
};

const DEFAULT_API_URL: &str = "http://localhost:3000";
const POLL_INTERVAL: Duration = Duration::from_millis(250);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60 * 60);

fn main() {
    if let Err(err) = run(env::args().skip(1).collect()) {
        eprintln!("error: {err}");
        process::exit(1);
    }
}

fn run(args: Vec<String>) -> doppelbanger::Result<()> {
    match args.first().map(String::as_str) {
        Some("master") => master(&args[1..]),
        Some("worker") => worker(&args[1..]),
        Some("benchmark") => benchmark(&args[1..]),
        Some("-h" | "--help") | None => {
            print_usage();
            Ok(())
        }
        Some(command) => Err(DoppelbangerError::UnexpectedArgument(command.to_string())),
    }
}

fn master(args: &[String]) -> doppelbanger::Result<()> {
    let mut reference = None;
    let mut target = None;
    let mut output = None;
    let mut plan_path = None;
    let mut api_url = default_api_url();

    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        let missing = match flag {
            "--reference" => "--reference",
            "--target" => "--target",
            "--output" => "--output",
            "--plan" => "--plan",
            "--api-url" => "--api-url",
            _ => return Err(DoppelbangerError::UnexpectedArgument(flag.to_string())),
        };
        let value = argument_value(args, index, missing)?;
        match flag {
            "--reference" => reference = Some(PathBuf::from(value)),
            "--target" => target = Some(PathBuf::from(value)),
            "--output" => output = Some(PathBuf::from(value)),
            "--plan" => plan_path = Some(PathBuf::from(value)),
            "--api-url" => api_url = value.to_string(),
            _ => unreachable!("known master flag was validated above"),
        }
        index += 2;
    }

    let reference = reference.ok_or(DoppelbangerError::MissingArgument("--reference"))?;
    let target = target.ok_or(DoppelbangerError::MissingArgument("--target"))?;
    let output = output.ok_or(DoppelbangerError::MissingArgument("--output"))?;
    let edited = plan_path.map(read_editable_plan).transpose()?;
    let request = SubmitRequest::from_paths(
        reference,
        target,
        &output,
        edited.as_ref().map(|file| file.plan.clone()),
        edited.as_ref().map(|file| file.parent_request_id),
    )?;
    let client = ApiClient::new(api_url)?;
    let request_id = client.submit(&request)?;
    println!("submitted request {request_id}");

    let started = Instant::now();
    loop {
        let state = client.request(&request_id)?;
        match state.status {
            RequestStatus::Complete => {
                let plan = client.plan(&request_id)?;
                let plan_file = EditablePlanFileV1 {
                    schema_version: 1,
                    parent_request_id: request_id,
                    plan,
                };
                let plan_output = editable_plan_path(&output);
                let json = serde_json::to_string_pretty(&plan_file).map_err(|err| {
                    DoppelbangerError::Io(format!("failed to encode editable plan JSON: {err}"))
                })?;
                fs::write(&plan_output, format!("{json}\n")).map_err(|err| {
                    DoppelbangerError::Io(format!(
                        "failed to write editable plan {}: {err}",
                        plan_output.display()
                    ))
                })?;
                println!("mastered {}", state.output_path.display());
                println!("editable plan {}", plan_output.display());
                return Ok(());
            }
            RequestStatus::Failed => {
                return Err(DoppelbangerError::Io(format!(
                    "mastering request {request_id} failed: {}",
                    state
                        .error
                        .as_deref()
                        .unwrap_or("worker did not provide an error")
                )));
            }
            _ if started.elapsed() >= REQUEST_TIMEOUT => {
                return Err(DoppelbangerError::Io(format!(
                    "mastering request {request_id} did not finish within {} seconds",
                    REQUEST_TIMEOUT.as_secs()
                )));
            }
            _ => thread::sleep(POLL_INTERVAL),
        }
    }
}

fn worker(args: &[String]) -> doppelbanger::Result<()> {
    let mut once = false;
    let mut api_url = default_api_url();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--once" => {
                once = true;
                index += 1;
            }
            "--api-url" => {
                api_url = argument_value(args, index, "--api-url")?.to_string();
                index += 2;
            }
            flag => return Err(DoppelbangerError::UnexpectedArgument(flag.to_string())),
        }
    }

    let client = ApiClient::new(api_url)?;
    loop {
        match client.claim()? {
            Some(job) => match process_job(&client, &job) {
                Ok(report) => println!(
                    "completed request {} -> {}",
                    job.id, report.render.output_path
                ),
                Err(error) if !once => eprintln!("request {} failed: {error}", job.id),
                Err(error) => return Err(error),
            },
            None if once => {
                println!("no queued mastering requests");
                return Ok(());
            }
            None => thread::sleep(POLL_INTERVAL),
        }
        if once {
            return Ok(());
        }
    }
}

fn benchmark(args: &[String]) -> doppelbanger::Result<()> {
    let mut corpus = None;
    let mut output = None;
    let mut full = false;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--corpus" => {
                corpus = Some(PathBuf::from(argument_value(args, index, "--corpus")?));
                index += 2;
            }
            "--output" => {
                output = Some(PathBuf::from(argument_value(args, index, "--output")?));
                index += 2;
            }
            "--full" => {
                full = true;
                index += 1;
            }
            flag => return Err(DoppelbangerError::UnexpectedArgument(flag.to_string())),
        }
    }

    let corpus = corpus.ok_or(DoppelbangerError::MissingArgument("--corpus"))?;
    let output = output.ok_or(DoppelbangerError::MissingArgument("--output"))?;
    let report = run_benchmark(&corpus, &output, full)?;
    println!(
        "benchmarked {} pairs: tonal improvement {:.1}%, analysis {:.2}x, render {:.2}x, peak RSS {}",
        report.summary.pair_count,
        report.summary.median_tonal_improvement_percent,
        report.summary.minimum_analysis_realtime_factor,
        report.summary.minimum_render_realtime_factor,
        report
            .summary
            .peak_rss_mib
            .map(|value| format!("{value:.1} MiB"))
            .unwrap_or_else(|| "unavailable".to_string())
    );
    println!("report {}", output.display());
    if report.gates_passed {
        Ok(())
    } else {
        Err(DoppelbangerError::Io(format!(
            "benchmark gates failed: {:?}",
            report.gates
        )))
    }
}

fn read_editable_plan(path: PathBuf) -> doppelbanger::Result<EditablePlanFileV1> {
    let bytes = fs::read(&path).map_err(|err| {
        DoppelbangerError::Io(format!("failed to read plan {}: {err}", path.display()))
    })?;
    let plan: EditablePlanFileV1 = serde_json::from_slice(&bytes).map_err(|err| {
        DoppelbangerError::Io(format!("failed to decode plan {}: {err}", path.display()))
    })?;
    if plan.schema_version != 1 {
        return Err(DoppelbangerError::InvalidRequest(format!(
            "editable plan schema_version must be 1, got {}",
            plan.schema_version
        )));
    }
    Ok(plan)
}

fn editable_plan_path(output: &Path) -> PathBuf {
    output.with_extension("plan.json")
}

fn argument_value<'a>(
    args: &'a [String],
    index: usize,
    flag: &'static str,
) -> doppelbanger::Result<&'a str> {
    args.get(index + 1)
        .map(String::as_str)
        .ok_or(DoppelbangerError::MissingArgument(flag))
}

fn default_api_url() -> String {
    env::var("DOPPELBANGER_API_URL").unwrap_or_else(|_| DEFAULT_API_URL.to_string())
}

fn print_usage() {
    println!(
        "Usage:\n  doppelbanger master --reference <reference.mp3|wav> --target <target.mp3|wav> --output <mastered.wav> [--plan <edited-plan.json>] [--api-url <url>]\n  doppelbanger worker [--once] [--api-url <url>]\n  doppelbanger benchmark --corpus <albumdb-root> --output <benchmark.json> [--full]"
    );
}
