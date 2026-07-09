# doppelbanger Engineering Spec v0.2

## Phase 1 Exit

Phase 1 turns the request scaffold into one audible, API-backed reference-mastering path:

```text
CLI -> PostgREST -> Postgres request -> native worker
    -> analysis -> pair diff -> mastering plan -> WAV render -> report
```

The phase is complete when all ten AlbumDB pairs run through that path, the fast three-song suite supports repeatable Ableton review, and the automated correctness, quality, and performance gates pass.

## Public Interfaces

```bash
doppelbanger master \
  --reference <reference.mp3|reference.wav> \
  --target <target.mp3|target.wav> \
  --output <mastered.wav> \
  [--plan <edited-plan.json>] \
  [--api-url <http://localhost:3000>]

doppelbanger worker [--once] [--api-url <http://localhost:3000>]

doppelbanger benchmark \
  --corpus <albumdb-root> \
  --output <benchmark.json> \
  [--full]
```

`master` submits and waits through PostgREST. It does not invoke DSP directly. `worker` is the only product process that executes the mastering pipeline. Library tests may call pure analysis and processing contracts directly.

The scaffold-only `prepare` command and incoming generic `Tuning` fields are removed. User adjustment happens by editing a generated `MasteringPlanV1` and submitting a linked rerun with `--plan`.

## Audio Contract

- Input: decoded stereo MP3 or WAV content. Extensions do not establish validity.
- Internal samples: interleaved `f32`, streamed in bounded blocks at the input sample rate.
- Output: stereo IEEE 32-bit float WAV at the target sample rate and duration.
- No Phase 1 resampling, dithering, limiting, compression, transient shaping, or stereo modification.
- The `-1 dBTP` ceiling applies to processed output. Identity bypass remains sample-exact and reports a pre-existing hot source rather than changing it.
- Corrupt, unsupported, mono, non-finite, or inconsistent streams fail with a field- and path-specific error.

## Analysis V1

`TrackAnalysisV1` is deterministic and versioned. It includes:

- source SHA-256, codec, sample rate, channel count, frame count, and duration;
- integrated LUFS, LRA, maximum short-term LUFS, sample peak, true peak, and PLR;
- loudness-normalized power in fixed bands `20-60`, `60-120`, `120-250`, `250-500`, `500-1000`, `1000-2000`, `2000-4000`, `4000-8000`, and `8000-16000 Hz`, clipped to Nyquist;
- global correlation and low/mid/high mid-side energy ratios;
- transient density and p95 half-wave spectral flux;
- clipping, DC, and non-finite sample counts.

Spectrum uses a 4096-sample Hann window and 1024-sample hop. Transients use a 2048-sample Hann window and 512-sample hop. Frames below `-70 dBFS` are excluded from spectral, stereo, and transient distributions.

`PairDiffV1` stores signed `reference - target` values. Reports expose the metric vector directly; they do not publish a single opaque quality score.

## Mastering Plan V1

The generated plan contains analyzer/processor versions, source hashes, bypass state, desired/applied gain, loudness shortfall, a `-1 dBTP` ceiling, and three editable EQ filters:

- low shelf at `120 Hz`;
- broad bell at `1 kHz`;
- high shelf at `6 kHz`.

Generated and edited EQ gains are constrained to `-3..=3 dB`. Overall gain is constrained to `-12..=12 dB` and may not exceed measured true-peak headroom. If the safe gain cannot reach reference loudness, the plan records the shortfall rather than clipping.

Matching source hashes and zero deltas produce an explicit bypass plan. WAV identity is evaluated by exact decoded `f32` samples; MP3 identity is evaluated against deterministic decoded PCM, never encoded bytes.

## API Lifecycle

The state plane stores tracks, requests, analyses, plans, render artifacts, and failures. Track roles belong to requests, not tracks.

```text
queued -> analyzing -> ready -> rendering -> complete
                   \-> failed
```

The worker claims one queued request atomically through a Postgres RPC using `FOR UPDATE SKIP LOCKED`. Edited-plan reruns create a new request linked to their parent. Audio bytes remain on the filesystem and never travel through PostgREST.

## Evaluation Corpus

AlbumDB v1 is the public paired corpus. The untracked local data directory contains the published mixed-stem and stereo-master archives. Premasters are reconstructed by summing each song's aligned mixed stems into unclipped 32-bit float WAV without normalization or additional processing.

- Fast suite: songs `01`, `04`, and `10`.
- Full suite: all ten songs.
- Git stores only manifests, checksums, attribution, aggregate metrics, and benchmark reports.

## Quality Gates

- Official EBU loudness fixtures pass their published tolerances.
- Identity produces deterministic analysis, zero diff, bypass, and an exact decoded WAV null.
- Every AlbumDB output preserves sample rate, channels, duration, finite samples, and true peak at or below `-1 dBTP` within `0.1 dB` measurement tolerance.
- Median three-band tonal error improves by at least `25%`; no item regresses more than `0.25 dB`.
- Absolute loudness error does not increase unless true-peak capping is active and reported.
- Analysis and render each run at least `1x realtime` with peak RSS below `512 MiB` on the baseline Apple M5 / 10 CPU / 16 GB / macOS 26.2 machine.
- Ableton review of the fast suite finds no severe artifact and rates at least two of three outputs closer to the corresponding master.

## Phase 1 Deferrals

Browser workshop UI, compression/limiting, transient shaping, stereo modification, reusable presets, VST3/AU, Windows packaging, and one-command installation are outside Phase 1. Their revisit triggers live in `docs/DECISIONS.md` and linked GitHub issues.
