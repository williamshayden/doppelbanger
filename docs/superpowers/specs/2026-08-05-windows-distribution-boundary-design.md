# Windows Build, Integration, And Distribution Boundary Design

**Date:** 2026-08-05

**Status:** Approved in conversation on 2026-08-05; independent written-spec review complete

## Goal

Make the Windows development and release boundaries explicit before the first VST3 is built. A musician must never need WSL, Docker, compilers, build tools, or a globally installed database to load and use Doppelbanger. Docker's WSL2 backend remains an optional developer integration environment only.

The first headless handoff is intentionally smaller than the full product: it loads in a VST3 host, processes an embedded or default runtime plan, exposes generic host parameters, and restores saved state without any companion service. New reference analysis arrives later with a separately packaged native per-user companion runtime.

## Decision

Separate three dependency planes:

1. **Native VST3 build plane:** Rust, MSVC, the Windows SDK, CMake, Ninja, and validators build and validate native Windows AMD64 artifacts. WSL ancestry and GNU/MinGW artifacts are forbidden. WSL and Docker may be absent.
2. **State-plane integration environment:** Docker Desktop, Compose, and the `desktop-linux` engine run Postgres and PostgREST for developer integration tests. Its strict profile is orthogonal to the compiler profile; the API harness composes both when it needs a freshly built native test binary. It never defines the plugin's runtime contract.
3. **End-user distribution plane:** the VST3 and, later, a native per-user companion runtime are installed without WSL, Docker, developer tools, or a pre-existing database.

The existing developer workstation installer remains developer tooling. Its ordinary path keeps Docker disabled. It is not the product installer.

## Dependency Matrix

| Dependency | `HeadlessVst3` profile | `StatePlaneIntegration` profile | Shipped UI-NONE VST3 | Full product installation |
| --- | --- | --- | --- | --- |
| Rust, MSVC, Windows SDK | required | not required | absent | absent |
| CMake, Ninja | required | not required | absent | absent |
| Steinberg Validator, pluginval | requested validation only | not required | absent | absent |
| Node, npm | not required | not required | absent | absent |
| WSL | absent or ignored; WSL process ancestry forbidden | required for the locked WSL2 developer backend | absent | absent |
| Docker Desktop, Compose | absent or ignored | required | absent | absent |
| Postgres, PostgREST | absent | containerized developer services | absent | bundled native companion components later |
| Native worker and supervisor | test binaries only | not required by profile; API harness starts the developer worker | absent | bundled per-user companion later |
| WebView2 | absent | absent | absent | explicit supported baseline or installer prerequisite later |
| Ableton or another VST3 host | manual host validation only | not required | required to host the plugin | required to host the plugin |

## Toolchain Profiles

### `HeadlessVst3`

`HeadlessVst3` is the strict native plugin build and validation profile. It requires exact locked native Windows x86_64 provenance for Rust, MSVC, the Windows SDK, CMake, and Ninja. It also validates a requested validator when a validation command uses one.

It does not require, resolve, launch, version-check, or health-check WSL, Docker Desktop, Docker Engine, Docker Compose, Node, npm, Postgres, or PostgREST. The presence of those tools cannot make an otherwise valid native build fail.

The current process still fails when it has WSL environment markers or descends from `wsl.exe`, `wslhost.exe`, or `bash.exe`. This rule protects native artifact provenance; it does not require WSL to be installed. An installed WSL whose version is old, unknown, or unavailable does not fail this profile when the native process has no WSL markers or ancestry.

### `StatePlaneIntegration`

`StatePlaneIntegration` is an orthogonal strict profile for the developer state plane. It shares the native Windows process, repository ownership, checked-in lock, and no-WSL-ancestry safety baseline, but it does not require the compiler toolchain. It requires the exact locked Docker Desktop, native Docker CLI, Docker Compose plugin provenance, `desktop-linux` context, Linux/amd64 server, and Compose configuration.

The approved developer backend is WSL2, so this profile alone requires the locked minimum WSL version when that backend is selected. Missing WSL fails with `DBDOC_WSL_REQUIRED`, unknown version evidence with `DBDOC_WSL_VERSION_UNKNOWN`, and an older version with `DBDOC_TOOL_VERSION_DRIFT`, all before a Docker command is launched. This WSL version rule never applies to `HeadlessVst3`.

Docker failures retain their stable diagnostic codes in this profile. Those same facts may be reported as optional information by compatibility diagnostics but are not build failures in `HeadlessVst3`.

### Future `ReactEditorBuild`

The later editor milestone may add a separate `ReactEditorBuild` contract for exact Node/npm and frontend assets. Node and npm remain build-time tools and never become plugin runtime dependencies. This profile is not implemented during the UI-NONE milestone.

### `Compatibility`

`Compatibility` remains read-only diagnostic output. It may report native, Docker, WSL, Node, WebView2, and Ableton facts without turning optional-plane absence or drift into an error. Optional-plane findings are warnings and do not make `success=false`. Universal safety failures such as a non-Windows process, WSL ancestry for a native command, an invalid repository path, unreadable ownership/configuration evidence, or a malformed checked-in lock remain errors. `Compatibility` is never build or release evidence.

## Native Tool Wrapper Routing

The native wrapper selects the narrowest applicable contract:

- `cargo`, `rustc`, `rustfmt`, `clippy-driver`, `cl`, `link`, `lib`, `dumpbin`, `cmake`, `ctest`, `ninja`, Steinberg Validator, and pluginval use `HeadlessVst3`;
- `docker` uses `StatePlaneIntegration` without requiring the compiler profile;
- `node`, `npm`, and `npx` are rejected with stable code `DBDOC_TOOL_PROFILE_REQUIRED` until `ReactEditorBuild` exists;
- future editor asset commands use `ReactEditorBuild` when that profile exists.

The isolated `scripts/test_api_integration.ps1` orchestration script composes the two orthogonal profiles explicitly: it first requires `HeadlessVst3`, then requires `StatePlaneIntegration`, invokes Docker only through the state-plane wrapper route, and invokes Cargo only through the native-build wrapper route. The wrapper never guesses a profile from Cargo arguments or test names.

A non-Docker command must not fail because Docker is missing, stopped, outdated, shadowed, or configured without WSL2. It must not invoke Docker merely to prove native compiler provenance. Docker commands continue to reject a shadowing Compose plugin and every nonlocked server or context. After universal native-safety and WSL2-backend preconditions, Docker error precedence is: malformed or unsafe plugin configuration, shadowing Compose provenance, missing locked binaries/Desktop, version drift, stopped engine, wrong context, then wrong server OS/architecture. Contract fixtures pin this order.

When the locked Docker and Compose binaries are present and version-exact, an invalid checked-in `docker-compose.yml` emits `DBDOC_COMPOSE_CONFIG_INVALID` after version drift and before the stopped-engine check. Missing or untrusted binaries do not run Compose configuration validation.

## Shipped VST3 Contract

The UI-NONE VST3 links the Rust processor as a static library and uses the static MSVC and Rust CRT settings already required by the native roadmap. Its module and bundle contain no React, Node, WebView, Docker, WSL, Postgres, PostgREST, or development-server resource.

The built module receives an explicit PE dependency-closure gate. A committed reviewed allowlist names the supported Windows system DLLs; it is designed from documented platform requirements and reviewed code usage, not populated automatically from whatever the first artifact imports. The gate parses both normal and delay-load import tables, rejects toolchain runtime DLLs that should have been statically linked, and rejects WSL, Docker, database, service, Node, and package-manager dependencies.

Every native executable and DLL shipped in the bundle is inspected recursively. A non-system dependency must be present in the bundle, must itself pass AMD64 PE provenance and both import-table checks, and must not escape the bundle through DLL search. The UI-NONE bundle is expected to contain only its plugin module, but the gate is defined for additional bundled native files so later packaging cannot bypass it.

Static imports are not the complete runtime dependency surface. The clean-target host records its canonical loaded-module paths before loading the plugin and again after plugin initialization, processing, state restore, and unload. Every newly loaded module must be the validated plugin, a dependency-closed bundled module, or an allowlisted System32 module. The evidence records canonical paths and hashes, rejects modules loaded from the host directory, PATH, user-writable search locations, or network paths, and fails any undeclared `LoadLibrary`/`GetProcAddress` dependency.

The first handoff can:

- load in a supported Windows VST3 host;
- create its default processor state;
- process and bypass stereo audio;
- expose the five generic host parameters;
- save and restore its complete embedded plan and parameter state; and
- continue processing after all Doppelbanger development containers and services are stopped.

It cannot create a new reference analysis yet. That limitation is explicit engineering-milestone scope, not an implicit requirement that a user install Docker.

## Native Companion Runtime

The full product later packages pinned native Postgres, PostgREST, the worker, migrations, and a small supervisor beneath a per-user installation root. The companion binds only to loopback, uses a per-install credential, stores data under platform-standard user application-data directories, and advertises a versioned local endpoint descriptor.

The public installer must not depend on a globally installed database, Docker Desktop, WSL, Rust, Visual Studio, CMake, Ninja, Node, or npm. Missing or stopped companion services may block new analysis, but they cannot interrupt an already loaded plan. The DAW project remains sufficient to restore audio processing.

The later companion release gate inspects every shipped executable and DLL as native AMD64 PE, proves normal and delay-load dependency closure against its own reviewed allowlist, and runs installation, startup, analysis, shutdown, and uninstall checks on a network-disconnected base where WSL, Docker, container or nested-virtualization runtimes, databases, and developer tools are absent. Process and image-load monitoring records every companion process and runtime-loaded module with canonical paths and hashes; undeclared modules and any launch of `wsl.exe`, Docker, a container runtime, or a nested-virtualization process fail the gate. Outbound connections are denied and audited, while only the documented loopback listeners and user-data paths are permitted. The installer and runtime cannot fetch a prerequisite.

The companion packaging is a later milestone. This boundary design does not choose its installer technology or implement it now.

## React And WebView2 Boundary

React and Vite remain build-time concerns. Compiled static assets eventually ship inside the plugin and load no remote page, CDN, development server, or cloud resource.

The Windows editor will require an explicit WebView2 runtime contract. Before the React milestone is considered distributable, its design must either establish a supported Windows baseline that includes an approved Evergreen WebView2 runtime or have the product installer detect and install the approved runtime. Missing WebView2 must leave audio processing, saved state, and Ableton's generic parameter surface functional while reporting an editor-specific error outside the callback.

## Error Handling

- A WSL-launched native build fails immediately with the existing WSL-forbidden diagnostic.
- Missing or unhealthy Docker fails `StatePlaneIntegration` and Docker/API integration commands, not native compilation or VST3 validation.
- Until `ReactEditorBuild` exists, live Node/npm/npx wrapper requests fail with `DBDOC_TOOL_PROFILE_REQUIRED`; afterward, missing Node/npm fails only that profile.
- Missing companion services reject new analysis with a bounded controller-thread error while the last valid embedded plan continues unchanged.
- Missing WebView2 prevents the custom editor from opening but does not change audio, state, or generic host parameters.
- A forbidden PE import or dynamic runtime dependency fails release validation before staging the bundle.

## Verification

### Profile and wrapper contracts

- A native fixture with no WSL installation and no Docker installation passes `HeadlessVst3` when its native tools are exact.
- Installed WSL with missing, unknown, or older-than-lock version evidence also passes `HeadlessVst3` when the process has no WSL markers or ancestry.
- A native fixture with Docker absent, stopped, drifted, or shadowed still passes `HeadlessVst3`.
- WSL environment markers or WSL launcher ancestry always fail native compilation.
- Missing, unknown, or older-than-lock WSL fails `StatePlaneIntegration` before Docker launch when the selected backend is WSL2.
- The same Docker-absent fixture fails `StatePlaneIntegration` with the expected stable Docker code.
- Exact Docker Desktop, Compose provenance, context, engine, OS, and architecture pass `StatePlaneIntegration`.
- Exact Docker/WSL evidence with Rust, Visual Studio, the Windows SDK, CMake, and Ninja absent passes `StatePlaneIntegration`; Docker routing does not import VsDevCmd or resolve compiler tools.
- Non-Docker wrapper commands neither launch Docker nor depend on Docker probe results.
- Docker wrapper commands select and enforce `StatePlaneIntegration`.
- Task 1's existing native provenance, PE, ownership, and lock-override tests remain green.

### Artifact and target contracts

- Normal and delay-load PE import parsing enforce the committed Windows-system allowlist and static-runtime policy transitively for every bundled native binary.
- The hosted VST3 state round trip remains bit-identical with the Doppelbanger Compose project stopped.
- A clean-target smoke test runs in a disposable, network-disconnected Windows 11 x64 VM snapshot. A statically linked pinned Steinberg-based headless host with its own reviewed dependency closure enables safe DLL search, permits only System32 and the explicit plugin bundle directory, and runs from a separate directory so it cannot supply plugin DLLs accidentally. A Windows job limits the host tree to one process, preventing the UI-NONE plugin from launching helpers.
- Before loading, a committed evidence script records the exact OS image, disabled WSL and Virtual Machine Platform optional features, absence of WSL distributions, Docker/container/nested-virtualization files, services, and processes, absence of Postgres/PostgREST services, developer-tool absence from PATH and installed-program inventory, network-disconnected state, host hash, and bundle hash. The script and host perform no downloads or prerequisite installation.
- The test records loaded modules before plugin load and after initialization, processing, state restore, and unload, including canonical paths and hashes. It loads, processes, bypasses, and restores the validated bundle, then records the process tree and filesystem changes. Any undeclared static or dynamic dependency, process, listener, installation, or download fails the gate.
- The later React milestone adds WebView2-present and WebView2-absent host tests.
- The later companion milestone proves installation on a target with no pre-existing WSL, Docker, database, or developer toolchain.

## Implementation Sequence

1. Change the Task 1 doctor and native wrapper contracts so `HeadlessVst3` is build-only and add orthogonal `StatePlaneIntegration`.
2. Update Task 1 fixtures, `docs/WINDOWS_WORKSTATION.md`, the canonical `docs/PLUGIN_ARCHITECTURE.md`, and the native implementation roadmap with the approved distribution invariant. Append a new accepted entry to `docs/DECISIONS.md`; never rewrite historical decisions.
3. Independently review and commit that focused boundary correction.
4. Rebase the already review-clean Task 2 developer installer documentation onto the new profile wording, rerun its full contract and Task 1 regression, and commit it before machine mutation.
5. Provision the non-Docker native toolchain through the Task 2 installer. Docker Desktop remains a separate explicit opt-in.
6. Add the module dependency-closure gate in Task 11, enforce it alongside validator evidence in Task 14, run the network-disconnected clean-target smoke in Task 15, and rerun both gates during Task 16 final review.

## Non-Goals

- Do not package the native companion during the UI-NONE milestone.
- Do not add React, WebView2 integration, capture, service calls, or a second DSP path now.
- Do not move analysis into the audio callback or duplicate the Rust processor.
- Do not install, update, or remove WSL as part of native plugin development.
- Do not install, reset, prune, or silently upgrade Docker Desktop.
- Do not modify Ableton installations, projects, packs, samples, preferences, or installers while implementing the profile split.
- Do not turn the developer workstation installer into the public product installer.

## Acceptance Criteria

This boundary correction is complete when:

- native build and validation commands pass with Docker and WSL absent;
- state-plane integration still requires the exact locked Docker environment;
- documentation cannot reasonably be read as making WSL or Docker an end-user prerequisite;
- the implementation roadmap contains explicit PE dependency and clean-target release gates;
- Task 1 and Task 2 contracts pass after the split; and
- no machine provisioning or Ableton mutation occurs before the focused code changes are independently reviewed and committed.
