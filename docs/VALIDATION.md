# Validation And Evidence

Validation is part of the product architecture. A change is not complete because audio was produced; it is complete when the relevant contract, quality, performance, and host evidence can be reproduced from a named commit and input manifest.

## Principles

- Generated fixtures prove deterministic mechanics, not mastering quality.
- Public paired audio proves repeatable algorithm behavior, not techno-specific taste.
- User-owned pairs prove product relevance but remain outside git.
- Objective metrics are directional evidence, not a replacement for loudness-matched listening.
- Performance evidence is valid only with machine, build, and workload provenance.
- The offline renderer and plugin callback share one processor; separate quality baselines are prohibited.

## Validation Tiers

### Tier 0: Static Contracts

Runs on every change:

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --test decision_docs --test docs_current
docker compose config
```

This tier checks formatting, lint, documentation invariants, schemas, and build configuration. It does not claim audio correctness.

### Tier 1: Deterministic DSP Units

Runs on every DSP or plan change:

```bash
cargo test --test dsp_contract
cargo test --test analysis_contract
cargo test --test mastering_pipeline
bash scripts/test_native_ffi.sh
```

Coverage includes exact bypass, filter direction, bounds, block partition invariance, anti-phase energy, malformed input, finite output, zero callback allocation/deallocation, fixed ABI layout, and native C/C++ compile-link-run behavior. Tests use generated signals with known frequencies and levels so each assertion has a specific physical meaning.

### Tier 2: API And Pipeline Integration

Runs before merging changes to state, jobs, worker behavior, or the product path:

```bash
docker compose up -d --wait
cargo test --test api_integration -- --ignored --test-threads=1
docker compose down
```

It proves PostgREST request creation, atomic worker claim, state transitions, plan/report persistence, filesystem artifacts, and explicit failure behavior. Audio bytes never travel through PostgREST.

### Tier 3: Fast Real-Audio Quality

Runs for DSP, analyzer, plan, benchmark, or release-candidate changes. It uses prepared AlbumDB pairs `01`, `04`, and `10`:

```bash
cargo run --release --bin doppelbanger -- benchmark \
  --corpus var/albumdb/pairs \
  --output var/validation/albumdb-fast.json
```

The manifest and SHA-256 values are verified before processing. A three-pair run is a development gate, not a release claim.

### Tier 4: Full Real-Audio And User Corpus

Runs for release candidates and algorithm decisions:

```bash
cargo run --release --bin doppelbanger -- benchmark \
  --corpus var/albumdb/pairs \
  --output var/validation/albumdb-full.json \
  --full
```

All ten AlbumDB pairs must pass. At least three private techno pairs then run through the same command and report schema. Private paths, hashes that identify unreleased material, and audio are not committed; sanitized aggregate metrics and completed audition records may be retained.

### Tier 5: Plugin Contract

Required once the wrapper exists:

- build optimized VST3 bundles for macOS arm64/x86_64 and Windows x86_64;
- run the official Steinberg VST3 Validator with zero failures;
- run pluginval at strictness level 10 with zero failures;
- run the repository headless host harness across the sample-rate and block-size matrix;
- prove offline and plugin adapter sample parity;
- prove state save/restore, stable parameter IDs, automation, bypass, reset, and reported latency;
- run the callback stress benchmark with zero allocations, locks, I/O, and non-finite output.
- capture for 30 minutes at 96 kHz/32-frame blocks with zero dropped frames.

### Tier 6: DAW And Listening

The release matrix includes Ableton Live on macOS and Windows. For each target build:

1. Scan and load the plugin.
2. Analyze a reference and premaster through the local service.
3. Play, bypass, automate every exposed parameter, and change sample rate/buffer size.
4. Save, close, stop the service, reopen, and confirm the embedded plan still processes.
5. Freeze and perform an offline export.
6. Null or compare the export against the headless shared-processor render within the declared tolerance.
7. Complete `docs/AUDITION.md` at matched loudness.

Screenshots are supporting evidence. Validator logs, report JSON, exported measurements, and exact host versions are the primary evidence.

## Premaster-To-Master Measurement

Every pair produces signed `reference - target` metrics before processing and `reference - output` metrics after processing.

| Area | Primary metric | Role |
| --- | --- | --- |
| loudness | absolute integrated-LUFS error | active gain target and gate |
| peak safety | output true peak and shortfall | active safety gate |
| tonal balance | nine signed spectral deltas grouped into low/mid/high processor regions | active EQ target and gate |
| dynamics | LRA error, PLR error, max short-term LUFS error | observation and later dynamics trigger |
| transients | density and p95 spectral-flux error | observation and later transient trigger |
| stereo | correlation error and low/mid/high M/S ratio error | observation and later stereo trigger |
| integrity | format, duration, finite values, clipping, DC | hard regression gate |

The EQ quality score is the median of three regional mean-absolute errors, matching the three controlled EQ filters. Reports also retain all nine signed deltas and applied gains so a passing aggregate cannot hide the wrong filter direction.

Current hard tonal gates:

- median three-region error improves by at least `25%`;
- no pair regresses more than `0.25 dB`;
- generated multitone tests assert the expected low/mid/high gain direction;
- anti-phase signals retain their spectral energy.

Current hard loudness gates:

- absolute LUFS error may regress at most `0.05 dB` without a safety shortfall;
- when true-peak headroom limits gain, regression remains capped at `0.25 dB` and shortfall must be reported;
- output true peak remains at or below `-1 dBTP` within the analyzer's `0.1 dB` tolerance.

## Dynamics And Limiter Decision Rule

Dynamics processing is added from evidence, not because a mastering chain is expected to contain it.

1. Establish the validated plugin baseline with EQ and safe gain.
2. Quantify remaining LUFS shortfall, PLR/LRA error, transient error, and listening failures by pair and section.
3. Implement the plugin-MVP true-peak safety limiter as an isolated processor stage with at most `5 ms` of fixed, exactly reported latency, oversampling/conformance tests, gain-reduction telemetry, and limiter-only ablation.
4. Accept the limiter only if it closes repeatable loudness gaps without exceeding artifact, transient, peak, callback, and listening thresholds.
5. Add compression only when limiter-only results leave a repeatable dynamics-shape gap across multiple real pairs. Compare baseline, limiter-only, and limiter-plus-compressor with identical loudness and plans.

No stage is accepted solely because the final LUFS is closer. Severe pumping, transient loss, distortion, stereo shift, or hidden latency is a failure.

## Performance Evidence

Machine-specific reports must include:

- git commit and dirty status;
- package, analyzer, processor, ABI, and plugin versions;
- build profile and compiler version;
- operating system, architecture, CPU model, logical core count, and memory;
- sample rate, block-size sequence, channel layout, warm-up, and run duration;
- corpus DOI, manifest hash, pair IDs, and input hashes;
- per-file analysis/render timing and per-block callback distribution;
- p50, p95, p99, maximum, realtime factor, peak RSS, and gate results;
- exact command and UTC timestamp.

Debug-build timing is diagnostic only. Shared CI catches gross regressions; the named baseline machine owns hard realtime thresholds.

## Evidence Storage

Raw audio, private paths, and routine local output live under ignored `var/`. Reproducible release evidence is organized as:

```text
var/validation/<run-id>/             local raw logs, renders, reports
validation/baselines/<version>/      reviewed aggregate JSON, no audio
validation/manifests/                public corpus and workload manifests
```

Only small, sanitized, machine-readable aggregate evidence is committed. Every committed baseline names its git commit, workload manifest, platform, and command. Replacing a baseline requires a PR that explains the measured change; tests never auto-update expected quality.

## Regression Triage

When a gate fails:

1. Reproduce from a clean optimized build and unchanged manifest.
2. Classify analyzer change, processor change, fixture/corpus change, environment change, or test defect.
3. Inspect per-pair and per-region values before aggregate scores.
4. Keep the failed evidence; do not widen tolerances to make a branch pass.
5. Add the smallest regression test that measures the root cause.
6. Update a threshold only with an explicit decision record and before/after evidence.
