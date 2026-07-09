# doppelbanger

Local-first reference mastering assistant for techno/electronic producers.

Status: first development scaffold. It does **not** master audio yet. It validates a reference + target pair, captures tuning intent as JSON, and provides the local Postgres/PostgREST state shell we will build against.

## Quick Start

```bash
cargo test
docker compose config
```

Prepare a mastering request:

```bash
cargo run -- prepare \
  --reference /path/to/reference.mp3 \
  --target /path/to/target.wav \
  --output /tmp/doppelbanger-request.json \
  --loudness-db 0 \
  --punch 0 \
  --low-eq-db 0 \
  --mid-eq-db 0 \
  --high-eq-db 0 \
  --width 0
```

Start the local API shell:

```bash
docker compose up -d
curl http://localhost:3000/
```

Stop and delete local DB state:

```bash
docker compose down -v
```

## Architecture

```text
CLI / future UI
  -> local PostgREST API
    -> Postgres state and jobs
      -> worker + DSP engine
        -> filesystem audio artifacts
```

The DSP engine will read audio from disk directly. Postgres stores state, jobs, analyses, generated mastering plans, and render metadata. Audio bytes do not move through PostgREST.

## Current Contract

- Inputs: MP3 or WAV reference, MP3 or WAV target.
- Export target: WAV once rendering exists.
- Tuning request fields:
  - `loudness_db`: `-12..=12`
  - `punch`: `-1..=1`
  - `low_eq_db`: `-12..=12`
  - `mid_eq_db`: `-12..=12`
  - `high_eq_db`: `-12..=12`
  - `width`: `-1..=1`

## Development Rule

Public contracts get tests before implementation. No fake DSP: analysis and rendering commands should fail clearly until real processing exists.
