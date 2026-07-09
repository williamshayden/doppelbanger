use std::env;
use std::fs;
use std::process;

use doppelbanger::{DoppelbangerError, MasteringRequest, Tuning};

fn main() {
    if let Err(err) = run(env::args().skip(1).collect()) {
        eprintln!("error: {err}");
        process::exit(1);
    }
}

fn run(args: Vec<String>) -> doppelbanger::Result<()> {
    match args.first().map(String::as_str) {
        Some("prepare") => prepare(&args[1..]),
        Some("-h" | "--help") | None => {
            print_usage();
            Ok(())
        }
        Some(command) => Err(DoppelbangerError::UnexpectedArgument(command.to_string())),
    }
}

fn prepare(args: &[String]) -> doppelbanger::Result<()> {
    let mut reference = None;
    let mut target = None;
    let mut output = None;
    let mut loudness_db = 0.0;
    let mut punch = 0.0;
    let mut low_eq_db = 0.0;
    let mut mid_eq_db = 0.0;
    let mut high_eq_db = 0.0;
    let mut width = 0.0;

    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        let value = args
            .get(index + 1)
            .ok_or(DoppelbangerError::MissingArgument(match flag {
                "--reference" => "--reference",
                "--target" => "--target",
                "--output" => "--output",
                "--loudness-db" => "--loudness-db",
                "--punch" => "--punch",
                "--low-eq-db" => "--low-eq-db",
                "--mid-eq-db" => "--mid-eq-db",
                "--high-eq-db" => "--high-eq-db",
                "--width" => "--width",
                _ => "value",
            }))?;

        match flag {
            "--reference" => reference = Some(value.clone()),
            "--target" => target = Some(value.clone()),
            "--output" => output = Some(value.clone()),
            "--loudness-db" => loudness_db = parse_f32(flag, value)?,
            "--punch" => punch = parse_f32(flag, value)?,
            "--low-eq-db" => low_eq_db = parse_f32(flag, value)?,
            "--mid-eq-db" => mid_eq_db = parse_f32(flag, value)?,
            "--high-eq-db" => high_eq_db = parse_f32(flag, value)?,
            "--width" => width = parse_f32(flag, value)?,
            _ => return Err(DoppelbangerError::UnexpectedArgument(flag.to_string())),
        }

        index += 2;
    }

    let tuning = Tuning::new(loudness_db, punch, low_eq_db, mid_eq_db, high_eq_db, width)?;
    let request = MasteringRequest::from_paths(
        reference.ok_or(DoppelbangerError::MissingArgument("--reference"))?,
        target.ok_or(DoppelbangerError::MissingArgument("--target"))?,
        tuning,
    )?;
    let json = serde_json::to_string_pretty(&request)
        .map_err(|err| DoppelbangerError::Io(format!("failed to encode request JSON: {err}")))?;

    fs::write(
        output.ok_or(DoppelbangerError::MissingArgument("--output"))?,
        format!("{json}\n"),
    )
    .map_err(|err| DoppelbangerError::Io(format!("failed to write request JSON: {err}")))?;

    Ok(())
}

fn parse_f32(field: &str, value: &str) -> doppelbanger::Result<f32> {
    value.parse().map_err(|_| DoppelbangerError::InvalidNumber {
        field: field.to_string(),
        value: value.to_string(),
    })
}

fn print_usage() {
    println!(
        "Usage: doppelbanger prepare --reference <file.mp3|file.wav> --target <file.mp3|file.wav> --output <request.json> [--loudness-db <db>] [--punch <-1..1>] [--low-eq-db <db>] [--mid-eq-db <db>] [--high-eq-db <db>] [--width <-1..1>]"
    );
}
