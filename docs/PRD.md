# doppelbanger PRD v0.2

## Summary

doppelbanger is a local reference-mastering plugin for techno and electronic producers. The user supplies a reference master and captures the dry premaster stream from the DAW, doppelbanger measures both, creates an editable mastering plan, and applies that plan inside the DAW.

The sole user-facing MVP surface is a VST3 plugin for macOS and Windows, backed by a local Postgres/PostgREST runtime for analysis, job state, and plan persistence. The plugin must continue processing an already-loaded plan when that runtime is stopped. Command-line entry points are internal test and benchmark tooling, not an installed or supported product.

## MVP User

The initial user produces and mixes stereo electronic music in Ableton Live and has difficulty translating a premaster toward a chosen commercial reference without losing low-end control, punch, or stereo stability.

## MVP Workflow

1. Insert doppelbanger on the premaster or master channel.
2. Select one stereo reference master, arm target capture, and play the full premaster through the plugin once.
3. A preallocated callback-to-writer queue records the dry input; the local service analyzes the reference and completed capture and creates a versioned plan.
4. The plugin embeds that plan in DAW project state and applies it to host audio.
5. Adjust the exposed plan controls and compare processed, bypassed, and loudness-matched playback.
6. Export through the DAW and retain a machine-readable before/after report.

The first implementation supports MP3 and WAV reference input and processes stereo `f32` host audio. The CLI may use a premaster file as a validation adapter. It does not upload music or require a cloud account.

## MVP Capabilities

- Measure integrated LUFS, loudness range, short-term loudness, sample and true peak, peak-to-loudness ratio, spectral balance, stereo correlation and mid-side energy, transients, clipping, DC, and non-finite samples.
- Represent signed reference-minus-target differences directly instead of hiding them behind one score.
- Generate one versioned plan containing broad tonal controls, gain, safety limits, and processing provenance.
- Apply the same processor implementation in the VST3 callback and offline validation renderer.
- Capture target input without blocking the callback; any dropped frame invalidates the capture.
- Apply a transparent true-peak safety limiter with fixed, accurately reported latency before claiming a release-ready master.
- Save the active plan in plugin state so existing projects remain playable without the local service.
- Persist tracks, analyses, jobs, plans, and reports through Postgres/PostgREST outside the audio callback.
- Produce reproducible quality, performance, validator, and DAW-host evidence.

## System Shape

There is one mastering pipeline and one DSP implementation.

```text
plugin UI/controller -> PostgREST -> Postgres job -> native worker
                     <- analysis + MasteringPlanV1 snapshot

DAW audio callback -> shared MasteringProcessor -> DAW output
offline benchmark  -> shared MasteringProcessor -> measured WAV
```

Postgres/PostgREST is the state plane. The filesystem is the audio artifact plane. Neither is permitted in the real-time audio path. The plugin wrapper owns host integration and presentation but contains no independent mastering math.

## Product Requirements

- **Local-first:** source audio and processing stay on the user's machine.
- **One path:** plugin playback, offline render, and benchmark use the same processor contract.
- **Auditable:** every generated change maps to measured input and a bounded parameter.
- **Recoverable:** service failure may block new analysis but may not interrupt an embedded plan.
- **Editable:** users can inspect and adjust the generated plan without switching to a generic effect rack.
- **Safe:** identity is an exact no-op; invalid plans fail explicitly; processed output never silently clips.
- **Portable:** VST3 supports the initial Ableton workflow on macOS and Windows; AU follows only as another thin wrapper over the same core.

## Quality And Performance

- Quality gates combine deterministic tests, public paired audio, user-owned techno pairs, objective before/after metrics, and structured listening.
- The audio callback performs no heap allocation, locking, filesystem or network access, logging, database access, or unbounded work.
- The initial linear processor reports zero samples of latency.
- On the Apple M5 baseline at 48 kHz and a 64-sample block, p99 processing time must remain below 20% of the callback deadline and the maximum observed block below 50% during the defined stress run.
- Target capture must drop zero frames during the defined 30-minute 96 kHz/32-frame stress run.
- Safety-limiter latency must not exceed `5 ms`, and reported latency must equal measured impulse latency.
- Offline analysis and rendering must each run at least `1x realtime` with peak RSS below `512 MiB` on the baseline machine.
- The VST3 bundle must pass the official Steinberg validator and the documented Ableton host matrix before release.
- Performance checks never replace audio quality checks, and generic hosted CI does not define machine-specific performance truth.

## MVP Non-Goals

- Cloud processing, accounts, stems, batch mastering, generative AI, and opaque learned mastering models.
- A public CLI, separate browser product, duplicate standalone processor, or alternate direct-to-DSP mode.
- AU, AAX, VST2, mobile formats, or one-command public installation before the VST3 path is validated.
- Musical compression, stereo modification, or transient shaping before the linear plugin baseline and safety limiter produce trustworthy evidence.

## Assumptions

- Target capture records the dry plugin input before doppelbanger processing and is invalid if any frame is dropped.
- The local service is required for new analysis and plan generation, but not for callback processing of a saved plan.
- The project remains MIT-licensed while product licensing is evaluated; dependencies must not silently force a conflicting distribution model.
- Reference-derived preset reuse follows stable single-pair plans and is not required for the first VST3 release.
