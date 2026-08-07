# Validation And Evidence

Validation is part of the product architecture. A change is not complete because audio was produced; it is complete when the relevant contract, build, and host evidence can be reproduced from a named commit. This document separates the implemented Windows native foundation from later release gates.

## Current Windows native foundation

Task 4 provides a headless Windows x64 VST3 bundle and its Rust/C/C++ lifecycle and state contracts. Task 5A adds the automated native validation gate. The implemented scope is Windows x64 only; macOS is not a V1 claim.

From an x64 Visual Studio developer PowerShell, the local automated gate is:

```powershell
.\scripts\dev.ps1 -Task doctor
.\scripts\dev.ps1 -Task format
.\scripts\dev.ps1 -Task test
.\scripts\dev.ps1 -Task configure
.\scripts\dev.ps1 -Task build
.\scripts\dev.ps1 -Task validate
```

`scripts/dev.ps1` rejects WSL ancestry. It configures the checked-in Release product preset and the pinned Steinberg SDK validator without plug-in deployment, builds the product/tests and only the validator target, runs CTest, then invokes the wrapper with these exact paths:

```text
build\windows-vst3-validator\bin\validator.exe
build\windows-msvc-x64-release\artefacts\Release\VST3\Doppelbanger.vst3
```

The wrapper launches Steinberg's validator directly, requires exact absolute native drive paths, rejects relative/WSL/UNC/quoted/wildcard targets before launch, drains stdout and stderr separately, enforces a bounded timeout, and fails the calling PowerShell process for any launch error, timeout, nonzero exit, crash, or incomplete evidence write.

### Tier 0: static and native-foundation contracts

Tier 0 runs formatting, warnings-denied lint, locked Rust tests, dependency and dispatcher contracts, native CTest, and the official Steinberg VST3 Validator. CI associates uploaded reports with the validating git commit through workflow-run metadata; the local validator result records exact paths and UTC start/end timestamps.

## Automated evidence

Ignored native-foundation evidence lives at:

```text
var\validation\native-foundation\
```

Each validator run retains:

- `validator.stdout.txt` and `validator.stderr.txt` as separate streams;
- `validator.result.json` with exact paths, UTC start/end, timeout, timed-out flag, real validator exit code, and outcome;
- native CTest and Rust test reports when produced by CI.

The Windows workflow performs a recursive checkout, uses Rust `1.97.1` and an x64 MSVC environment, runs format, warnings-denied clippy, locked Rust tests, the dependency and PowerShell contracts, Release configure/build/CTest, and the official validator. Its narrow artifact contains only the unsigned `Doppelbanger.vst3` bundle and sanitized validator/test reports. It does not upload validator binaries, build intermediates, caches, source, private audio, or machine-specific paths. It does not start Docker, databases, services, or copy a plug-in to a system directory.

## Deliberately unperformed manual host gate

This automated task does not deploy, launch, scan, configure, or inspect Ableton. The separately authorized Task 5 manual gate still requires a narrow Ableton Live 12 smoke: copy only the built bundle to the standard VST3 location, scan and insert it in a disposable Set, automate controls, save/reopen, and record version, sample rate, buffer size, bundle hash, and pass/fail evidence outside Git. No private Set or audio belongs in the repository.

## Later release gates, not current claims

The following are subsequent milestones and are not satisfied by the native foundation:

- pluginval at strictness level 10;
- custom editor and UI interaction coverage;
- a fixed-latency true-peak limiter and its ablation/conformance evidence;
- long callback stress at 96 kHz/32-frame blocks, with allocation, lock, I/O, finite-output, and dropped-frame checks;
- installer, clean-machine packaging, signing, and customer deployment;
- the complete local analysis/capture workflow and its end-to-end host proof;
- release listening and real-audio corpus gates.

## Separate analysis-development validation

The repository also contains analysis, plan generation, offline rendering, and benchmark work. Postgres/PostgREST and Docker belong only to that separate analysis-development context; they are never VST3 runtime dependencies and are not part of the native foundation gate. When analysis work changes, its own contracts, deterministic DSP checks, API pipeline tests, and sanitized corpus evidence remain required before making analysis or quality claims.

That separate lifecycle keeps `plan_only` at `queued -> analyzing -> plan_ready`. An explicit idempotent claim with the same plan hash is required before a render can advance, and reports use the canonical active-plan hash. AlbumDB is one public paired-audio corpus for those later analysis and quality gates.

Generated fixtures prove deterministic mechanics, not mastering quality. Public paired audio proves repeatable algorithm behavior, and user-owned pairs remain outside Git. Objective metrics support loudness-matched listening; they do not replace it. The offline renderer and plug-in callback continue to share one processor, so separate processing baselines are prohibited.

## Evidence handling and triage

Raw audio, private paths, and routine local output remain under ignored `var/`. Committed evidence, when a later milestone authorizes it, must be small, sanitized, machine-readable, and name its commit, workload, platform, command, and UTC timestamp.

When a gate fails, retain the failed evidence, reproduce from an unchanged optimized build, classify the failure, inspect the specific report before an aggregate, and add the smallest regression contract that measures the root cause. Do not widen tolerances or substitute a manual claim for a failed gate.
