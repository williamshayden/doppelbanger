# Plugin Architecture

This document defines the host boundary for doppelbanger. It is normative for code that can run in a DAW audio callback.

## Chosen Direction

- Product format: VST3 first on macOS and Windows.
- Host framework: iPlug2, pinned to an audited commit.
- DSP and plan implementation: Rust.
- Wrapper and native editor integration: thin C++/Objective-C++ iPlug2 layer.
- Cross-language boundary: versioned C ABI with panic containment.
- Control plane: local PostgREST API and native worker, used only off the audio thread.
- AU: later wrapper generated from the same iPlug2 project and Rust core.

Ableton Live supports 64-bit VST3 on both target operating systems and Audio Units on macOS. VST3 therefore covers the initial Ableton and cross-DAW requirement with one artifact format. See [Ableton's supported formats](https://help.ableton.com/hc/en-us/articles/5937501570460-Supported-Plug-in-Formats).

iPlug2 supports VST3, AUv2, and AUv3 and uses a permissive zlib-style license. That avoids binding the project to a commercial framework agreement while preserving a route to Audio Units. See the [iPlug2 repository](https://github.com/iPlug2/iPlug2).

The official VST3 SDK is MIT-licensed and supplies the validator used by the release gate. See the [Steinberg licensing documentation](https://steinbergmedia.github.io/vst3_dev_portal/pages/VST%2B3%2BLicensing/Index.html) and [VST3 SDK](https://github.com/steinbergmedia/vst3sdk).

## Alternatives Rejected For Now

- **NIH-plug:** attractive Rust ergonomics, but its current VST3 bindings require GPLv3-compatible distribution, it does not provide AU, and the upstream framework is in maintenance mode. This conflicts with the provisional MIT and format requirements.
- **JUCE:** mature and capable, but current distribution is dual AGPLv3/commercial. That is a product licensing decision, not a dependency to adopt accidentally.
- **Direct VST3 SDK integration:** viable and permissive, but it requires more lifecycle, UI, state, and multi-format glue than iPlug2. Revisit only if the iPlug2 wrapper proves materially obstructive.
- **Separate Rust plugin DSP:** rejected. A second implementation would invalidate benchmark and host parity.

## Runtime Topology

```text
                         non-real-time threads
  plugin editor --------------------------------------+
      | select reference / arm capture                |
      v                                               |
  PostgREST -> Postgres -> worker -> analysis -> plan |
      ^                                               |
      +------------- result/status -------------------+
                                                      |
                                  validated snapshot  |
                                                      v
  Ableton Live audio callback -> C ABI -> Rust MasteringProcessor -> output
```

The API is a product dependency for new analysis, not a live audio dependency. A DAW project stores its active plan. If Postgres, PostgREST, or the worker is stopped, the plugin keeps processing that plan and reports the control-plane failure outside the callback.

## Companion Runtime Packaging

Docker Compose is a development and integration-test tool, not an end-user dependency. Release packaging must install a per-user companion runtime containing pinned Postgres, PostgREST, the native worker, migrations, and a small supervisor.

The supervisor owns startup, health, version compatibility, migration, and clean shutdown. Services bind only to loopback, use a per-install credential, and store database/audio state in platform-standard user application-data directories. The plugin discovers the companion through a versioned local endpoint descriptor; it does not guess a fixed public port.

The eventual one-command developer installer may orchestrate these same pinned components after clone. Public plugin installers, signing, notarization, and updates remain a separate release contract and may not rely on a globally installed database or Docker Desktop.

## Thread Ownership

| Thread | Allowed | Forbidden |
| --- | --- | --- |
| audio callback | read fixed-size parameter snapshot; mutate private DSP state; process host buffers; copy armed dry input to a preallocated SPSC ring | allocation, locks, waits, I/O, API/database calls, logging, parsing, plan generation |
| plugin controller | host state, parameter publication, bounded message exchange | direct mutation of audio-thread DSP state |
| background client | file selection handoff, PostgREST calls, status polling, plan decoding and validation | host buffer access |
| worker | file decode, analysis, diff, plan generation, offline render | plugin instance state |

## Hard Callback Rules

- No heap allocation or deallocation.
- No mutex, condition variable, channel wait, sleep, or blocking atomic loop.
- No filesystem, network, process, environment, database, or clock access.
- No JSON, SQL, path, or dynamic string work.
- No logging or UI callbacks.
- No Rust panic or C++ exception may cross the ABI.
- Work is bounded by frame count and a fixed processor topology.
- Host buffers are modified in place. The only permitted block copy is an armed target capture into fixed ring storage.

Construction, plan validation, coefficient preparation, and state migration happen before publication to the callback. The callback owns filter history and smoothing state.

Production callback code must be panic-free. The C ABI contains an unwind as a last-resort host-survival boundary, silences a valid affected block, and latches the processor until reset. The Rust standard-library panic hook is process-global and runs before unwind containment, so the library does not replace it. Any unexpected panic remains a callback-conformance failure even when the ABI safely returns an error.

## Processor Contract

The Rust processor exposes a block-oriented API and contains all mastering math. The wrapper adapts host buffers and stable host parameter IDs only.

The eventual C ABI is intentionally small:

```c
db_status db_processor_create(
    const db_runtime_plan_v1* plan,
    double sample_rate_hz,
    uint32_t max_block_frames,
    db_processor** out_processor);

db_status db_processor_process_f32(
    db_processor* processor,
    float* left,
    float* right,
    uint32_t frames);

uint32_t db_processor_latency_samples(const db_processor* processor);
void db_processor_reset(db_processor* processor);
void db_processor_destroy(db_processor* processor);
```

Every exported function is `noexcept` from the caller's perspective. Rust catches unwinding at the boundary, returns a small status enum, and writes detailed errors only on non-real-time calls. The process function uses no error strings.

The first wrapper may load a plan only while processing is stopped. Realtime plan replacement is added only with a fixed-capacity handoff and a tested click-free transition. This keeps the first Ableton proof small without creating a second DSP route.

## State Lifecycle

1. The background client receives `MasteringPlanV1` from the local service.
2. The controller validates schema, versions, topology, sample rate, ranges, and finite values.
3. The wrapper converts it to a fixed-layout `RuntimePlanV1`; no JSON enters the callback.
4. The runtime plan and user overrides are serialized into DAW project state.
5. On restore, state is migrated and validated before processor construction.
6. Compatible state constructs the processor. Incompatible state selects bypass and exposes an exact error outside the callback.

Stable host parameter IDs never derive from labels or array positions. State schema migrations are explicit and fixture-tested.

## Failure Semantics

- Service unavailable: active plan continues; new analysis is unavailable.
- Capture ring overflow: invalidate the capture, stop recording, and report the dropped-frame count outside the callback.
- Analysis or plan generation failure: active plan remains unchanged.
- Invalid restored plan: bypass, retain recoverable state, report incompatibility outside callback.
- Unsupported bus layout: plugin declines activation.
- Sample-rate change: prepare a new processor outside active processing, reset state, then activate according to host lifecycle.
- Process fault: silence the entire affected block, return a fixed status, and latch bypass for subsequent blocks; never emit a partially processed/non-finite block, throw, allocate, or call the service.

## Latency

Broad minimum-phase EQ and gain report `0` samples. The measured impulse response must agree. The safety limiter exposes one fixed latency no greater than `5 ms`, notifies the host through the wrapper, and passes automation, state, and offline-render tests. It may not hide lookahead or change latency without the host lifecycle event required by the format.

## Validation Matrix

The wrapper is not considered functional because it compiles. Required evidence includes:

- Rust processor unit and allocation tests;
- offline/plugin adapter sample parity;
- official Steinberg VST3 Validator success;
- state save/restore and parameter automation tests;
- macOS arm64/x86_64 and Windows x86_64 builds;
- Ableton Live load, playback, bypass, automation, freeze, reopen, and offline export;
- sample rates `44.1-192 kHz` and block sizes `1-8192`;
- baseline callback timing and zero-allocation evidence;
- zero dropped capture frames during the 30-minute 96 kHz/32-frame stress run;
- AlbumDB and user-owned techno quality reports produced through the shared processor.

## Incremental Build Order

1. Extract and prove the allocation-free Rust block processor; route offline render through it.
2. Add the fixed C ABI and a headless host harness; prove sample parity and panic containment.
3. Add the minimal iPlug2 VST3 bundle with generic host parameters and persisted state.
4. Pass the official validator and load the bundle in Ableton Live.
5. Add fixed-memory dry-input capture and connect the plugin controller to the local service for reference/capture analysis.
6. Add the focused editor and plan controls.
7. Add and validate the true-peak safety limiter; add musical compression only from measured gaps.
8. Add Windows DAW evidence, signing/packaging, and later AU output.

Each step leaves a usable part of the final product and has its own automated contract. No browser or synthetic presentation layer is on this path.
