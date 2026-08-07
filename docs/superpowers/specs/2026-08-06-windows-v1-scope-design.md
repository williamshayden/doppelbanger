# Doppelbanger Windows V1 Design

**Date:** 2026-08-06
**Status:** Approved for implementation planning

## Product Goal

Doppelbanger v1 is a Windows x64 VST3 mastering effect that analyzes a user's mix against a locally selected reference track, produces an editable and reproducible processing plan, and applies that plan safely in Ableton Live. It must install from a conventional `.exe`, require no development environment or background service, restore correctly with an Ableton project, and be demonstrable in a short screen recording with audible before/after playback.

V1 is a real release boundary, not a disposable prototype. Scope is intentionally narrow so the supported workflow can be reliable and understandable.

## Supported Boundary

- Windows 10 and Windows 11, x64 only.
- VST3 audio effect only.
- Ableton Live 12 is the primary supported and demonstrated host.
- The customer receives `Doppelbanger-Setup.exe` and installs a finished VST3 bundle into the standard system VST3 location.
- The installed plugin has no dependency on WSL, Docker, PowerShell, CMake, Rust, Node.js, Postgres, PostgREST, or any separately running Doppelbanger process.
- macOS, AU, AAX, CLAP, Linux, accounts, cloud synchronization, telemetry, licensing, and automatic updating are outside v1.
- Developer setup may exist inside the repository but is not a published product artifact.

## User Workflow

1. The user installs Doppelbanger with `Doppelbanger-Setup.exe`.
2. Ableton discovers Doppelbanger as a VST3 effect.
3. The user inserts it near the end of the master chain.
4. The user selects a local reference audio file in the plugin.
5. The plugin analyzes the reference off the realtime audio thread.
6. The user plays a representative section of the mix and starts capture.
7. The plugin analyzes the captured mix off the realtime audio thread.
8. Doppelbanger generates a conservative, editable matching plan.
9. The user reviews the proposed changes, adjusts their strength or individual settings, and enables processing.
10. The user can level-matched A/B the original and processed signal.
11. Saving and reopening the Ableton project restores the effective processing plan and settings without requiring the reference file to remain available.

## V1 Feature Scope

### Required

- Local reference-file selection for WAV, AIFF, FLAC, and MP3.
- Reference waveform or progress feedback sufficient to identify the loaded file and analysis state.
- Explicit mix capture controlled by the user; no unbounded recording.
- Spectral and loudness analysis of the reference and captured mix.
- Generation of a bounded tonal-matching EQ plan.
- An editable EQ plan with global amount control, per-band enable/disable, frequency, gain, and Q.
- Safe realtime application of the plan with parameter smoothing and no allocation, file I/O, locks, WebView work, or analysis on the audio thread.
- Input, output, and gain-reduction/adjustment metering sufficient to operate the effect.
- Level-matched bypass/A-B comparison.
- Output gain and a protective true-peak limiter at the end of the chain.
- Versioned plugin-state serialization and migration from every publicly released v1 state version.
- Helpful errors for unsupported or unreadable references, insufficient capture, failed analysis, unavailable WebView2, and incompatible state.
- A deterministic Windows release build, VST3 validation, installer build, clean-machine installation test, and Ableton smoke test.

### Deferred

- Automatic compression, saturation, stereo widening, source separation, or full mastering-chain generation.
- Database-backed reports, remote workers, collaboration, cloud storage, and cross-device state.
- Automatic song-section detection and automatic transport control.
- Hosting or controlling third-party plugins.
- A standalone application.
- Copy protection, payment, accounts, analytics, and update services.

## Architecture

### iPlug2/C++ Host Layer

The C++ layer owns the VST3 lifecycle, buses, parameters, automation, editor lifetime, WebView2 hosting, host callbacks, and the strict realtime boundary. It exposes a small C ABI to the Rust core rather than sharing C++ or Rust implementation types across the boundary.

The host layer sends immutable parameter snapshots to the processor and publishes bounded meter/analyzer snapshots to the editor. UI messages are asynchronous and never call realtime DSP through the WebView message handler.

### Rust Core

Rust owns audio analysis, matching-plan generation, DSP coefficients and processing primitives, metering calculations, limiter behavior, and versioned product-state encoding. The core builds as a native Windows static library linked into the VST3; Rust is not installed on the customer's machine.

Analysis runs on a bounded background worker owned by the plugin instance. Jobs are cancelable during editor closure, plugin destruction, project reload, and replacement by a newer job. Analysis results are immutable objects promoted to active state through a bounded handoff.

### React/TypeScript Editor

React is the product editor, not the audio engine. It renders imported-reference status, capture controls, analysis progress, the proposed EQ curve, editable controls, metering, A/B controls, and actionable errors. Production HTML, JavaScript, CSS, fonts, and images are bundled with the plugin and do not require a network connection.

Development supports a normal frontend dev server and hot reload. Release builds use only bundled, content-hashed assets. The C++/JavaScript bridge is typed and versioned, with explicit commands and snapshots rather than arbitrary native function exposure.

### WebView2

Windows uses the Evergreen WebView2 runtime. The installer detects its availability and, when missing, asks for consent and runs Microsoft's supported Evergreen bootstrapper. This prerequisite step may require internet access; normal plugin use remains fully offline. A WebView initialization failure must not crash the host; the editor presents a small native fallback explaining how to repair WebView2 while audio processing and saved state remain safe.

### Persistence and Local Data

The complete effective plan, user edits, automatable values, relevant analysis summaries, reference fingerprint, reference display name, and optional source path are stored in versioned VST3 state so Ableton can restore the sound.

Reference audio is not embedded in the project state. If the referenced file is missing after reload, the saved processing continues unchanged. Reanalysis requires the user to locate the file again. Disposable decoded audio and analysis intermediates may use a versioned cache beneath the user's local application-data directory. Cache loss must never change a saved project's effective sound.

No database is part of v1.

## Realtime and Safety Rules

- The audio callback performs no heap allocation, blocking synchronization, file access, logging, WebView interaction, process launch, or analysis.
- Parameter and plan changes are applied at block boundaries through preallocated or atomically published state.
- All audible parameter transitions are smoothed.
- DSP produces finite output for finite input and recovers safely from invalid state.
- Processing has deterministic latency. Any reported latency is updated through the host-supported mechanism and covered by tests.
- Bypass and A/B behavior avoid discontinuities and misleading loudness differences.
- The limiter is a safety stage, not a mechanism for silently maximizing loudness. Its activity is visible and its ceiling is explicit.

## Failure Handling

- A failed import or analysis leaves the previous valid plan untouched.
- Starting a new analysis cancels or supersedes the previous job deterministically.
- Closing the editor does not interrupt audio processing.
- Destroying the plugin cancels workers and joins them without accessing freed host or UI objects.
- Missing reference files degrade to saved-plan operation.
- Corrupt or unsupported state is rejected safely, with defaults used only when restoration cannot continue. State decoding is bounded against unreasonable lengths and counts.
- Missing WebView2 affects the editor only and never prevents the host from loading the processor safely.

## Installer and Distribution

Inno Setup produces `Doppelbanger-Setup.exe`. Public release artifacts are Authenticode-signed; signing credentials remain external to the repository and CI logs. The installer:

- supports a normal elevated per-machine install;
- installs the VST3 bundle under `C:\Program Files\Common Files\VST3`;
- installs only Doppelbanger product files and required redistributable/runtime prerequisites;
- detects WebView2 and handles the supported Evergreen prerequisite path;
- provides uninstall metadata and cleanly removes only files it owns;
- never scans, modifies, launches, or removes Ableton, WSL, Docker, gaming software, user projects, plugin databases, or unrelated software.

The release package contains no source tree, developer scripts, machine-specific paths, credentials, caches, captured audio, test fixtures, or debug symbols unless symbols are intentionally published as a separate maintainer artifact.

## Repository Simplification

Implementation may delete obsolete bootstrap and state-plane machinery once replacement build and validation paths prove equivalent required coverage. In particular, Postgres/PostgREST/Docker runtime paths and oversized machine-provisioning PowerShell are not retained merely for historical compatibility.

The supported repository entry points should converge on:

- a concise README with prerequisites and native Windows build commands;
- CMake presets or similarly conventional build entry points;
- a small, explicit developer bootstrap only where package managers cannot express the requirement;
- automated tests and release packaging commands that run in native Windows CI.

Repository deletion occurs milestone-by-milestone after dependency checks and independent review. Ableton-related files outside this repository are never deletion targets.

## Validation and Release Gates

### Automated

- Rust unit tests for analysis, plan bounds, serialization, DSP, smoothing, metering, and limiter behavior.
- C++ tests for C ABI ownership, lifecycle, parameter mapping, worker cancellation, and state handoff.
- Golden analysis fixtures with tolerance-based expected plans.
- Realtime-safety checks and long-running randomized DSP tests covering silence, impulses, denormals, extreme levels, malformed state, and rapid automation.
- Build the Release VST3 from a clean native Windows checkout.
- Run Steinberg's VST3 validator successfully.
- Build the installer reproducibly from release artifacts.
- Verify installer contents contain no machine-specific or developer-only files.

### Host and Product

- Install on a Windows environment without development tools.
- Confirm Ableton Live 12 discovers and loads the plugin.
- Confirm reference selection, capture, analysis, editing, processing, A/B, save, close, reopen, and missing-reference recovery.
- Confirm project restoration is audibly and numerically equivalent within declared tolerances.
- Exercise common sample rates and buffer sizes, including rapid editor open/close and transport changes.
- Confirm uninstall removes only Doppelbanger-owned files.

### Demo

The release README links to a user-recorded screen capture with synchronized audio. The demo shows installation or installed-plugin discovery, insertion on Ableton's master channel, reference selection, mix capture, generated plan, an edit, level-matched before/after playback, and project save/reopen. The demo uses no development shell or background service.

## Definition of Done

Windows v1 is done when a user can download one installer, install Doppelbanger, use the complete supported workflow in Ableton Live 12 without developer tooling or a service process, save and restore the result reliably, uninstall safely, and reproduce the documented demo. All automated and manual release gates pass, known limitations are stated plainly, and the repository README describes only commands and promises that are actually supported.
