# doppelbanger

Local-first reference mastering for Ableton Live and other DAWs.

doppelbanger is building toward a VST3 plugin for macOS and Windows. The plugin will capture dry target audio from the DAW, compare it with a selected reference master through a local analysis service, embed an editable plan in the DAW project, and process host audio through one shared real-time-safe Rust DSP core.

## Status

Early development. The repository currently contains deterministic analysis, plan generation, an API-backed worker, an offline validation renderer, corpus benchmarks, and the first allocation-free block processor. The iPlug2 VST3 wrapper, host UI, target-capture queue, safety limiter, Windows validation, and release packaging are not implemented yet.

There is no public CLI in the MVP. The current source binary is a temporary developer and evidence harness and has no compatibility promise.

## Product Path

```text
plugin editor -> local PostgREST API -> Postgres job -> native worker
              <- analysis + versioned plan

DAW callback -> shared Rust MasteringProcessor -> host output
benchmark    -> shared Rust MasteringProcessor -> measured WAV
```

Postgres/PostgREST owns durable analysis and plan state. The filesystem owns audio artifacts. The plugin stores the executable plan in DAW project state, so an existing project keeps processing when the local service is stopped. No API, database, file, allocation, or lock is permitted in the audio callback.

See [the PRD](docs/PRD.md), [engineering spec](docs/ENGINEERING_SPEC.md), [plugin architecture](docs/PLUGIN_ARCHITECTURE.md), and [validation contract](docs/VALIDATION.md).

## Requirements

Current development requires:

- Rust toolchain
- Docker with Compose
- stereo MP3 or WAV test inputs

AlbumDB setup additionally needs `curl`, `unzip`, roughly 5.3 GB of download space, and space for extracted audio and renders. Future plugin work also requires CMake, platform build tools, and the pinned iPlug2 dependency.

## Current Developer Proof

The current source tree temporarily exposes `doppelbanger master`, `doppelbanger worker`, and `doppelbanger benchmark` for automation and validation. These are not installed product interfaces and will move behind repository tooling as the plugin path takes over.

Start Postgres and PostgREST:

```bash
docker compose up -d --wait
```

Run the native worker:

```bash
cargo run --bin doppelbanger -- worker
```

Submit a reference and premaster file from another terminal:

```bash
cargo run --bin doppelbanger -- master \
  --reference /absolute/path/reference.wav \
  --target /absolute/path/premaster.wav \
  --output /absolute/path/mastered.wav
```

A successful developer run creates:

- `mastered.wav`: stereo 32-bit float output;
- `mastered.report.json`: analyses, before/after differences, applied plan, and output measurements;
- `mastered.plan.json`: the versioned editable plan.

The future VST3 controller will request the same plan through the same API. Offline rendering already uses the shared `MasteringProcessor` that will sit behind the plugin ABI.

## Current Processing Baseline

- Measures LUFS, loudness range, short-term loudness, true/sample peak, PLR, nine spectral bands, stereo correlation and M/S energy, transients, clipping, DC, and non-finite samples.
- Applies a low shelf at 120 Hz, broad bell at 1 kHz, high shelf at 6 kHz, and true-peak-constrained gain.
- Constrains EQ to `-3..=3 dB` and gain to `-12..=12 dB`.
- Preserves identity as an exact decoded no-op.
- Processes arbitrary interleaved blocks without allocating and produces block-partition-invariant output.

This linear stage is the measurable baseline. A transparent, fixed-latency true-peak safety limiter is required before the first release-ready plugin. Musical compression follows only if limiter-only evidence leaves a repeatable gap.

## AlbumDB Benchmark

The source manifest is [corpus/albumdb/manifest.json](corpus/albumdb/manifest.json). Download, verify, extract, and reconstruct all ten premaster targets:

```bash
./scripts/fetch_albumdb.sh
```

Run the fast suite on songs 01, 04, and 10:

```bash
cargo run --release --bin doppelbanger -- benchmark \
  --corpus var/albumdb/pairs \
  --output var/validation/albumdb-fast.json
```

Add `--full` for all ten pairs. Generated tones are unit fixtures only; they are not mastering-quality evidence. AlbumDB and private techno pairs provide the real-audio tiers described in [docs/VALIDATION.md](docs/VALIDATION.md).

## Development

```bash
cargo fmt --all -- --check
cargo test
cargo clippy --all-targets -- -D warnings
docker compose config
```

The ignored API integration test requires Compose. Contribution, PR sizing, testing, evidence, and real-time rules are in [CONTRIBUTING.md](CONTRIBUTING.md). Product decisions are append-only in [docs/DECISIONS.md](docs/DECISIONS.md).

## License

MIT. AlbumDB is separately licensed CC BY 4.0 and is never redistributed from this repository. Plugin framework and SDK dependencies must retain their own required notices.
