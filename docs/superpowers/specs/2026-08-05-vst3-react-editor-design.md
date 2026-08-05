# VST3 Host Path And React Editor Design

**Date:** 2026-08-05

**Status:** Architecture accepted; milestone roadmap draft for user review

## Goal

Deliver the first playable doppelbanger VST3 in Ableton Live on Windows, then add React and TypeScript as its first real editor without building a disposable native UI. The plugin must process through the existing Rust `MasteringProcessor`, preserve a plan in DAW state, remain usable when its editor or local service is unavailable, and create reproducible evidence for each milestone.

## Current Starting Point

The repository already contains deterministic stereo analysis, plan generation, an offline renderer, a Postgres/PostgREST worker path, an allocation-free planar Rust processor, a versioned C ABI, native C/C++ ABI smoke tests, and cross-platform Rust CI. It does not contain a CMake plugin build, pinned iPlug2 source, production C++ wrapper, VST3 bundle, editor, capture queue, limiter, validator integration, retained real-audio evidence, or installer.

The roadmap advances the accepted plugin-first architecture. It does not replace the Rust DSP, create a second processing path, turn the temporary CLI into a product, or change the local-first state model.

## Product Boundary

The first supported interface remains one stereo VST3 effect for Ableton Live and other compatible hosts. The initial development target is Windows x86_64 because the current workstation has Ableton Live 12 and the first local host proof can run there. macOS arm64/x86_64 remains a Phase 1 release gate and receives an early WebView smoke test after the React shell works on Windows.

The product editor is React and TypeScript hosted inside the VST3. It is not a separate browser application. Its compiled assets ship inside the plugin and require no development server, internet access, account, or cloud content.

## Architecture

```text
React + TypeScript editor
        |
        | versioned controller-thread messages
        v
iPlug2 C++ VST3 controller ----- background capture/API workers
        |
        | stable host parameters + validated runtime snapshots
        v
versioned C ABI
        |
        v
Rust MasteringProcessor -------- offline renderer/benchmark
```

The C++ wrapper is unavoidable host glue and remains intentionally thin. It owns VST3 lifecycle, parameter registration and gestures, project-state serialization, WebView lifecycle, native file dialogs, fixed-capacity handoffs, and calls into the existing C ABI. It contains no mastering rules.

React owns only presentation and interaction state. It renders parameter controls, capture and analysis progress, reports, and recoverable errors from native snapshots. It never reads audio buffers, calls PostgREST directly, opens arbitrary filesystem paths, stores authoritative parameter values, or executes work on the audio thread.

Rust remains the source of truth for analysis, plan validation, DSP, and offline parity. The first plugin uses the existing single Rust crate. A crate split is considered only if measured static-link, dependency, or build-graph problems require it.

## Editor Bridge

Every editor message uses this logical envelope:

```text
version: positive integer
type: closed message identifier
request_id: optional editor-generated correlation identifier
payload: message-specific object
```

Native-to-editor message families are:

- `state.snapshot`: complete editor state after initialization or resynchronization;
- `parameter.changed`: authoritative host parameter value and change source;
- `capture.status`: idle, armed, capturing, finalizing, complete, or failed, with frame and dropped-frame counts;
- `analysis.status`: `idle`, `queued`, `analyzing`, `plan_ready`, or `failed`, with bounded progress and stable error code;
- `plan.ready`: sanitized analysis differences and active-plan summary suitable for presentation;
- `report.status`: idle, queued, analyzing, `plan_ready`, rendering, complete, or failed, with bounded progress and the pinned plan hash;
- `report.ready`: sanitized before/after report summary and plan hash when a validation render exists;
- `audition.changed`: authoritative processed, bypass, or loudness-matched-bypass audition mode.

Editor-to-native message families are:

- `ui.ready`: requests the first complete snapshot;
- `parameter.begin_edit`, `parameter.set`, and `parameter.end_edit`: preserve normal host automation gestures;
- `audition.set_mode`: requests processed, bypass, or loudness-matched-bypass auditioning;
- `reference.select`: requests a native file dialog rather than accepting an arbitrary web path;
- `capture.arm` and `capture.cancel`: request capture lifecycle transitions;
- `analysis.retry`: retries the last eligible failed request without replacing the active plan first;
- `report.generate`: requests a managed validation render of the current validated plan against the completed target capture;
- `report.export`: opens a native save dialog and copies an existing machine-readable report without exposing arbitrary paths to React.

The first bridge version is `1`. Unknown versions, types, fields that violate bounds, and non-finite numeric values are rejected on the controller thread. The editor receives a stable compatibility error. Bridge messages never contain audio samples, service credentials, private absolute paths, or unbounded logs.

The shared contract lives in `plugin/contracts/editor_bridge_v1.schema.json`. TypeScript types are generated from that schema, while native parsing uses a closed C++ enum and bounded validators exercised by the same committed valid and invalid message fixtures. Schema version changes require compatibility fixtures and an explicit migration or rejection rule.

## Host Parameters And State

The first VST3 exposes five stable automatable parameters:

- bypass;
- low EQ gain;
- mid EQ gain;
- high EQ gain;
- output gain.

Their numeric VST3 identifiers are constants and never derive from UI labels or array positions. React mirrors the controller's current values and emits host parameter gestures; it does not keep an independent saved copy.

DAW state contains the active validated plan, the five parameter values, analyzer/processor/ABI versions, reference and target hashes, and the last request/report identifier when available. Closing the editor, stopping the service, or reopening the project must preserve processing. Invalid restored state fails closed to bypass and retains a non-realtime error for the editor.

Rust owns `active_plan_hash_v1`, a versioned hash over canonical fixed-endian bytes containing source identities; schema, analyzer, processor, and ABI versions; fixed topology; quantized effective parameters; and safety metadata. Paths, request IDs, and presentation fields are excluded. The same Rust function supplies DAW-state identity, validation-render input, report persistence, and freshness comparison; C++ and React receive the hash and a controller-owned stale flag but never reimplement it.

The headless proof uses the same parameters and state schema as the React editor. Enabling the WebView therefore adds a view, not a second product model or a state migration.

Audition mode is controller state rather than an automatable host parameter. It remains unchanged when the editor closes, is not serialized into DAW state, and restores to `processed` when a project loads. A bounded callback snapshot selects the Rust-owned audition path with a click-free transition; audition controls never overwrite the saved bypass parameter or active plan.

## Audio And Threading Rules

The audio callback may invoke only the fixed C ABI and bounded fixed-memory handoffs. It performs no allocation, deallocation, lock acquisition, wait, filesystem or network access, logging, JSON parsing, JavaScript call, WebView interaction, plan construction, or unbounded work.

Milestone 1 adds a realtime-safe parameter-update ABI for bypass, low EQ, mid EQ, high EQ, and output gain. EQ and output values use one-centidecibel host steps. One Rust normalization routine rounds generated EQ gains to the nearest step with half steps away from zero, recomputes true-peak headroom, floors applied output gain toward negative infinity to a safe step, and recomputes shortfall before serialization. At construction Rust prepares immutable coefficient/amplitude tables and the wrapper allocates automation scratch for `5 * (max_block_frames + 1)` raw points. Before iteration, the wrapper requires the queue count in `0..=5` and rejects duplicate or unknown IDs. Positive blocks allow `0..=frames + 1` points per queue with successful reads, nondecreasing offsets satisfying `0 <= offset < frames`, and finite legal values. A zero-frame flush instead allows at most one offset-zero point per queue and null audio buffers; it updates the Rust target snapshot without processing or advancing DSP state, and the next positive block begins smoothing. Invalid input fails before DSP. In scratch, same-offset points collapse, simultaneous parameters form one `db_parameter_snapshot_v1`, and positive blocks split at each effective offset. Raw work stays bounded by `5 * (frames + 1)` with no callback allocation or coefficient math. Boundary-rounding, raw-limit, malformed-queue, zero-frame-flush/persistence, next-block-transition, sample-offset, and partition tests enforce the contract. Full plan replacement waits for Milestone 3's bounded handoff.

React events run on the editor thread. File selection, capture finalization, PostgREST calls, plan decoding, and report loading run on controller or background threads with cancellation and bounded queues. Destroying the editor cancels editor-only work without destroying the active processor.

## Control-Plane Request Lifecycle

Before the plugin submits private audio, the state plane adds an explicit request kind. `plan_only` accepts a reference and completed target capture without an output render path and follows `queued -> analyzing -> plan_ready`, with `failed` as the only failure terminal. `validation_render` accepts the same source identities plus either a generated plan or an exact pinned validated plan and first follows `queued -> analyzing -> plan_ready`. Its worker commits and stops there; only an explicit idempotent render claim carrying the matching `active_plan_hash_v1` advances it through `rendering -> complete`. Early or mismatched claims fail, and a supplied plan is validated but never regenerated or published back into the plugin.

Milestone 3 VST3 analysis submits only `plan_only`. In Milestone 4, `report.generate` may submit `validation_render` with the exact active plan and completed target capture; the existing CLI and corpus harness may also submit it. After observing committed `plan_ready`, the controller issues the idempotent render claim with the same canonical hash. The worker renders through the shared processor into a managed private artifact, persists report JSON keyed to that hash, and cannot replace the plugin plan. The controller compares the report hash to the full current `active_plan_hash_v1` and marks it stale after any source, version, topology, effective-parameter, or safety change; React only presents that authoritative flag and can export retained JSON through a native save dialog. This validation artifact is not the user's DAW export path. The React `analysis.status` values map exactly to `idle`, `queued`, `analyzing`, `plan_ready`, and `failed`; rendering and complete belong to `report.status`. Integration tests cover both request kinds, the render-claim gate, and hash freshness.

Before either request kind is connected to captured audio, Postgres and PostgREST bind to loopback only, all API requests require a locally provisioned credential, and the worker accepts artifacts only beneath managed reference, capture, and output roots. Integration tests prove unauthenticated requests fail, non-loopback publication is absent, and path traversal or unmanaged paths are rejected. Supervisor, upgrade, and installer work remains in Milestone 6.

## Failure Behavior

- VST3 or Rust processor construction failure: plugin activates in bypass and reports the exact configuration error outside the callback.
- WebView unavailable or editor asset failure: audio and generic host parameters continue; the host can close and reopen the editor without resetting the processor.
- Unsupported bridge version: reject the editor session and keep audio unchanged.
- Service unavailable: active plan continues; reference analysis and new plan generation remain unavailable until retry.
- Capture overflow: invalidate the entire capture, report dropped frames, and retain the prior plan.
- Invalid analysis result or runtime plan: reject it before publication and retain the prior plan.
- Process fault or contained panic: silence the affected valid block, latch safe bypass, and require an explicit non-realtime reset.

## Source Layout

The implementation plan will use these responsibility boundaries:

```text
plugin/
  CMakeLists.txt                 VST3/iPlug2 target and Rust linkage
  contracts/
    editor_bridge_v1.schema.json shared message contract
    fixtures/                    valid and invalid cross-language messages
  src/
    DoppelbangerPlugin.*        lifecycle, parameters, processing, state
    EditorBridge.*              versioned React/native messages
    RuntimePlanAdapter.*        host state to fixed C ABI plan
  resources/
    resource.h                  stable plugin/resource identifiers
    web/                        generated production React assets
  ui/
    package.json                pinned frontend scripts and dependencies
    package-lock.json           reproducible npm dependency graph
    vite.config.ts              local static bundle configuration
    src/                        React view, bridge client, and tests
cmake/
  BuildRust.cmake               Cargo static-library build integration
CMakePresets.json               repeatable Windows and later macOS builds
third_party/
  iPlug2/                       audited pinned dependency revision
tests/
  plugin/                       native bridge, state, host, and parity tests
```

Generated frontend assets are produced by the build and packaged into the VST3. Source assets and the dependency lockfile are committed; transient dependency directories and development output are ignored.

## Milestone Roadmap

### Milestone 0: Reproducible Windows Workstation

Install Rust through rustup with rustfmt and Clippy, Visual Studio 2022 Build Tools with the C++ desktop workload and Windows SDK, CMake, Ninja, a current Node.js LTS release, and Docker Desktop or a compatible Docker Engine with Compose v2. Record the resolved versions in repository toolchain files and add one doctor command that checks every prerequisite without changing the machine.

Exit evidence:

- existing Rust formatting, lint, unit, API, and native ABI suites pass;
- the native ABI smoke is extended to MSVC and passes for C11 and C++17 callers on Windows x86_64;
- Compose configuration and integration tests pass;
- a clean clone can reproduce the checks using documented commands;
- toolchain versions are pinned rather than inherited from floating `stable` or `latest` labels.

### Milestone 1: Headless VST3 Vertical Slice

Pin iPlug2, add the CMake build, link the Rust static library, register the five stable parameters, add the realtime-safe parameter-update ABI, process planar host audio through `db_processor_process_f32`, and serialize/restore the existing runtime plan. Build with `UI NONE`; use Ableton's generic parameters for the first proof.

The automated persistence proof uses `tests/plugin/fixtures/runtime-state-v1-nonbypass.bin`, a committed state blob decoded by the production state deserializer. It contains bypass off, low EQ `+1.5 dB`, mid EQ `-0.75 dB`, high EQ `+0.5 dB`, and output gain `-1.0 dB`, plus explicit test-only source identities and current schema/processor/ABI versions. The same decoder handles host-restored project state; no test-only loading path enters the plugin. The Ableton smoke sets those same nonzero values through generic host parameters before saving and reopening the project.

Exit evidence:

- Windows x86_64 VST3 bundle builds from a clean checkout;
- Steinberg Validator and pluginval pass the supported headless contract;
- Ableton scans, loads, plays, bypasses, automates all five parameters, saves, closes, and reopens the plugin;
- live parameter changes reach Rust at their exact sample offsets through bounded no-allocation updates and use the processor-owned click-free transition;
- the reopened project processes the same non-bypass fixture values with the service stopped and produces the same output as before restart;
- headless host output matches the offline shared processor within the declared tolerance;
- zero callback allocation, fault-latching, raw-queue limit, malformed-automation, zero-frame parameter-flush/persistence, next-block transition, sample-offset, block-partition, sample-rate, and reset tests pass.

### Milestone 2: React Editor Shell

Add a React, TypeScript, and Vite application, package its static build as iPlug2 WebView resources, implement bridge version `1`, and render the five parameters plus build, processor, service, and compatibility status. Release builds load local resources only and disable developer tools.

Exit evidence:

- editor opens, closes, resizes, and reopens repeatedly in Ableton without changing audio;
- React controls perform valid begin/set/end host gestures and reflect host automation;
- a full snapshot restores the view after editor recreation;
- malformed and incompatible messages fail visibly without affecting audio;
- frontend unit/component tests, native bridge tests, packaged-asset checks, and Windows WebView2 host smoke tests pass;
- an early macOS WebView bundle smoke confirms packaged assets and bridge initialization before the editor grows.

### Milestone 3: Capture And Analysis Workflow

First enforce loopback-only service binding, local request authentication, and managed artifact roots. Then implement the `plan_only` lifecycle, preallocated SPSC dry-input capture ring, background float-WAV writer, dropped-frame invalidation, native reference picker, cancellable PostgREST client, worker status flow, plan validation, and atomic active-plan replacement policy.

Exit evidence:

- 30-minute 96 kHz/32-frame capture stress drops zero frames or fails explicitly;
- unauthenticated requests, non-loopback publication, path traversal, and unmanaged artifact paths are rejected before private capture is enabled;
- `plan_only` reaches durable `plan_ready` without requiring or producing an offline render;
- React displays capture integrity, finalization, `queued`, `analyzing`, `plan_ready`, and failure states;
- service loss and worker failure never replace the prior active plan;
- a completed plan is embedded in DAW state and restores offline;
- no file, API, database, JSON, or WebView operation appears in callback instrumentation.

### Milestone 4: Focused Product Workflow

Expand the React editor with reference identity, capture preflight, signed low/mid/high differences, desired versus safety-limited gain, editable plan controls, processed/bypass/loudness-matched auditioning, managed report generation/export, and precise recovery guidance. `report.generate` runs the exact active plan through the offline shared processor against the completed capture, persists before/after JSON keyed to `active_plan_hash_v1`, and never substitutes for DAW export; any hash change visibly marks it stale. Keep the interface focused on one reference and one stereo premaster capture. Audition mode is non-automatable controller state, reaches the Rust processor through a bounded snapshot, remains stable when the editor closes, and resets to processed on project load.

Exit evidence:

- a producer can complete the PRD workflow without using the temporary CLI;
- the producer can generate and export a machine-readable report for the exact canonical active-plan hash, and stale reports are never presented as current;
- every actionable failure identifies the failed operation and preserves recoverable state;
- keyboard navigation, readable focus, scaling, and common Windows/macOS accessibility checks pass;
- save/reopen, automation, freeze, and offline export work with the editor open or closed.

### Milestone 5: Safety Limiter And Quality Evidence

Add the accepted fixed-latency true-peak safety limiter behind the shared Rust processor contract. Expose only evidence-backed controls and gain-reduction telemetry. Run the same algorithm through plugin, headless host, offline renderer, and benchmark paths.

Exit evidence:

- reported and impulse-measured latency match and remain at or below 5 ms;
- true-peak, artifact, allocation, partition, automation, state, parity, and ablation tests pass;
- AlbumDB fast and full suites produce retained aggregate evidence;
- at least three private techno pairs complete sanitized metrics and structured matched-loudness audition records;
- no severe pumping, transient damage, distortion, stereo shift, clipping, or callback regression is accepted.

### Milestone 6: Companion Runtime And Release Candidate

Replace the Milestone 3 development credential/bootstrap with the specified per-user companion supervisor, endpoint discovery, credential rotation, version compatibility, migrations, health, recovery, and clean shutdown. Add Windows and macOS installers, signing/notarization, dependency/license inventory, release provenance, and retained validator/DAW evidence.

Exit evidence:

- clean Windows and macOS machines install, scan, analyze, process, save, reopen offline, upgrade, and uninstall without losing intended user state;
- official validators and the full Ableton matrix pass on supported architectures;
- installers contain no development server, source dependency directory, private audio, credential, or globally exposed service;
- release artifacts are versioned, signed where required, checksummed, and traceable to the tested commit.

## Implementation Decomposition

This document is the program roadmap, not one monolithic implementation plan. Milestones 0 and 1 form the first dependent vertical-slice project: workstation setup is included because it exists to produce and validate the headless VST3. After that slice passes, Milestones 2 through 6 receive separate implementation plans and review gates. A later milestone may refine its internal design from measured evidence, but it may not weaken this roadmap's product, callback, privacy, or single-processor constraints without an explicit decision update.

## Testing Strategy

Each milestone keeps the existing Rust and API suites green and adds the narrowest new layer of evidence:

1. Rust unit and contract tests remain authoritative for analysis, plans, DSP, and ABI behavior.
2. Native C++ tests cover fixed-layout conversion, state migration, bridge validation, controller lifecycle, and callback boundaries.
3. React tests cover rendering from snapshots, parameter gestures, status transitions, accessibility, and recoverable errors.
4. Packaged-resource tests load the production frontend from a built bundle with network access disabled.
5. A headless plugin host covers parameter, state, block-size, sample-rate, latency, and processor parity matrices.
6. Steinberg Validator and pluginval cover plugin-format conformance.
7. Ableton smoke and release matrices cover scan, load, playback, automation, bypass, editor lifecycle, save/reopen, freeze, and export.
8. AlbumDB and private-pair runs cover mastering usefulness and listening quality.

No generated tone, snapshot test, WebView smoke, or validator result is presented as mastering-quality evidence. No real-audio benchmark substitutes for callback safety or host validation.

## Security And Privacy

- React assets are packaged locally and use no remote scripts, fonts, analytics, or navigation.
- The editor never receives service credentials or unsanitized local paths.
- File selection is native and returns only the state needed for presentation.
- WebView message types and payload sizes are allowlisted and bounded.
- Release developer tools are disabled; development builds identify themselves visibly.
- The companion binds to loopback with per-install credentials and never exposes audio through PostgREST.
- Logs and reports redact private paths before entering the editor or retained release artifacts.

## Scope Guardrails

This roadmap does not add musical compression, stereo processing, transient processing, reusable presets, AU, AAX, VST2, a public CLI, a standalone browser workshop, accounts, cloud processing, or public installer polish before their accepted revisit gates. React is the local VST3 editor, not a second product surface.

## Success Definition

The roadmap succeeds when a producer can install doppelbanger, insert it in Ableton, select a reference, capture a full dry premaster pass, receive and edit a plan in the React editor, audition safely, save and reopen the project with the service stopped, and export through the DAW on supported Windows and macOS systems with reproducible validator, callback, real-audio, and listening evidence.
