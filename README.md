# doppelbanger

Local-first reference mastering for stereo music. doppelbanger analyzes a reference and target, generates a conservative broad-EQ and gain plan, renders a 32-bit float WAV, and saves measurable before/after evidence.

Status: development prototype. The first audible API-backed path works on macOS; AlbumDB quality tuning, Windows validation, packaging, UI, and plugin formats are not complete.

The public commands are `doppelbanger master`, `doppelbanger worker`, and `doppelbanger benchmark`.

## Requirements

- Rust toolchain
- Docker with Compose
- Stereo MP3 or WAV inputs

AlbumDB setup additionally needs `curl`, `unzip`, roughly 5.3 GB of download space, and space for extracted audio and renders.

## Quick Start

Start Postgres and PostgREST:

```bash
docker compose up -d --wait
```

Run the native worker in one terminal:

```bash
cargo run --bin doppelbanger -- worker
```

Submit and wait for a master in another terminal:

```bash
cargo run --bin doppelbanger -- master \
  --reference /absolute/path/reference.wav \
  --target /absolute/path/target.wav \
  --output /absolute/path/mastered.wav
```

A successful run creates:

- `mastered.wav`: stereo 32-bit float output at the target sample rate and duration;
- `mastered.report.json`: analyses, before/after differences, applied plan, and output measurements;
- `mastered.plan.json`: editable plan envelope linked to the completed request.

Edit only plan gains within their documented bounds, then submit a linked rerun:

```bash
cargo run --bin doppelbanger -- master \
  --reference /absolute/path/reference.wav \
  --target /absolute/path/target.wav \
  --output /absolute/path/mastered-v2.wav \
  --plan /absolute/path/mastered.plan.json
```

Stop the local services with `docker compose down`. Use `docker compose down -v` only when local doppelbanger state should be deleted.

## Processing Contract

- Decodes stereo MP3 and WAV by content into bounded interleaved `f32` blocks.
- Measures loudness, true/sample peak, dynamics, nine spectral bands, stereo correlation and M/S energy, transients, clipping, DC, and non-finite samples.
- Applies only low shelf at 120 Hz, broad bell at 1 kHz, high shelf at 6 kHz, and true-peak-constrained gain.
- Constrains EQ to `-3..=3 dB`, gain to `-12..=12 dB`, and processed output true peak to `-1 dBTP` with `0.1 dB` measurement tolerance. Identity bypass remains sample-exact and reports pre-existing overs.
- Bypasses identical reference/target WAV audio and preserves decoded samples exactly.
- Does not apply limiting, compression, stereo modification, transient shaping, resampling, or dithering in this phase.

## AlbumDB Benchmark

The source manifest is [corpus/albumdb/manifest.json](corpus/albumdb/manifest.json). Download, verify, extract, and reconstruct all ten premaster targets:

```bash
./scripts/fetch_albumdb.sh
```

Run the fast suite (songs 01, 04, and 10):

```bash
cargo run --release --bin doppelbanger -- benchmark \
  --corpus var/albumdb/pairs \
  --output var/albumdb/fast-benchmark.json
```

Add `--full` for all prepared pairs. The command records per-pair quality and performance evidence and exits nonzero when a hard gate fails. See [docs/AUDITION.md](docs/AUDITION.md) for the Ableton review gate.

## Development

```bash
cargo fmt --all -- --check
cargo test
cargo test --test api_integration -- --ignored
cargo clippy --all-targets -- -D warnings
docker compose config
```

The ignored integration test requires the Compose runtime. Product decisions live in [docs/DECISIONS.md](docs/DECISIONS.md); the current engineering contract is [docs/ENGINEERING_SPEC.md](docs/ENGINEERING_SPEC.md). Audio and generated artifacts under `var/` are intentionally excluded from git.

## Architecture

```text
CLI -> PostgREST -> Postgres request -> native worker
    -> analysis -> pair diff -> mastering plan -> WAV render -> report
```

Postgres/PostgREST owns durable application state. The filesystem owns source audio, rendered WAVs, plans, reports, corpus files, and benchmark artifacts. DSP code is independent from CLI, database, and UI state so future desktop and plugin wrappers can reuse the same contracts.

## License

MIT. AlbumDB is separately licensed CC BY 4.0 and is never redistributed from this repository.
