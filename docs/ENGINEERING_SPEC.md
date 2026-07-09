# doppelbanger Engineering Spec v0.1

## First Milestone

Get the repo ready for real reference/target development without pretending the DSP exists.

Done means:

- CLI can validate a reference + target pair and write a typed request JSON.
- Local Postgres/PostgREST can start from Docker Compose with initial state tables.
- Tests cover the public request contract.
- Docs explain what exists and what intentionally does not.

## Repository Shape

```text
.
├── AGENTS.md
├── README.md
├── Cargo.toml
├── docker-compose.yml
├── db/init/001_schema.sql
├── docs/PRD.md
├── docs/ENGINEERING_SPEC.md
├── src/lib.rs
├── src/main.rs
└── tests/
```

## Current Public Interfaces

CLI:

```bash
doppelbanger prepare \
  --reference <mp3|wav> \
  --target <mp3|wav> \
  --output <request.json> \
  [--loudness-db <db>] \
  [--punch <-1..1>] \
  [--low-eq-db <db>] \
  [--mid-eq-db <db>] \
  [--high-eq-db <db>] \
  [--width <-1..1>]
```

Rust library:

- `AudioFormat::from_path`
- `Tuning::new`
- `MasteringRequest::from_paths`

API state:

- `api.tracks`
- `api.mastering_requests`
- `api.analysis_results`
- `api.render_artifacts`

## Next Work

1. Add a worker command that claims queued `mastering_requests`.
2. Add real audio decoding and duration/sample-rate/channel inspection.
3. Write the first benchmark fixture and enforce the `1x realtime` floor locally.
4. Add generated mastering-plan schema once analysis produces real measurements.
