# Windows V1 Native Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a reproducible native Windows x64 build of a headless Doppelbanger VST3 that processes through the existing Rust core, restores its complete effective plan from Ableton project state, and passes Rust, ABI, CMake, and VST3 validation gates.

**Architecture:** Stock pinned iPlug2 supplies the VST3 host wrapper, a narrow C++ class translates host buffers and state to the versioned Rust C ABI, and Rust remains the only wet-processing implementation. CMake orchestrates the native MSVC build without downloading dependencies during configure; all customer runtime code is linked into the VST3 bundle.

**Tech Stack:** Rust 1.97.1, C++17/MSVC, CMake/Ninja, iPlug2, Steinberg VST3 SDK and validator, Windows x64.

## Global Constraints

- Windows 10 and Windows 11, x64 only; VST3 only; Ableton Live 12 is the primary host.
- No WSL, Docker, Postgres, PostgREST, PowerShell, CMake, Rust, Node.js, or separately running Doppelbanger process may be required on an end-user machine.
- Native Windows build, link, validation, and host testing use `x86_64-pc-windows-msvc`; WSL may edit files but is never a product build environment.
- The audio callback performs no allocation, blocking synchronization, file I/O, logging, WebView work, JSON parsing, coefficient design, or analysis.
- Rust owns all wet DSP. C++ owns only VST3 lifecycle, host translation, state bytes, and fail-safe dry/silence behavior.
- Existing public C ABI layouts remain source and binary compatible. Add versioned symbols and structures instead of mutating V1 layouts.
- CMake configure performs no network operation. Dependencies are pinned before configure.
- Use test-driven development and commit each task independently after its complete regression gate passes.
- Do not scan, modify, delete, or launch Ableton while implementing automated tasks. The final manual smoke test is the only host interaction in this plan.
- Do not push commits without William's explicit authorization.

## Program Sequence

This plan is the first of four independently reviewable v1 plans:

1. **Native foundation:** loadable headless VST3, Rust processing, automation, state restoration, validator.
2. **Local analysis and capture:** reference decoding, bounded mix capture, background jobs, editable generated plan.
3. **React editor and product safety:** WebView2 editor, meters/A-B, true-peak limiter, lifecycle and randomized DSP tests.
4. **Distribution and release:** Inno Setup, clean-machine install, Ableton acceptance pass, README, demo checklist, repository deletion audit.

Each later plan begins only after the preceding milestone is green and independently reviewed.

## File Structure

- `CMakeLists.txt`: top-level native build and tests only.
- `CMakePresets.json`: deterministic Windows configure/build/test entry points.
- `cmake/BuildRust.cmake`: builds and imports the Rust static library.
- `cmake/PrepareIPlug2.cmake`: creates a build-tree composite of pinned, unmodified iPlug2 and VST3 SDK sources.
- `third_party/iPlug2`, `third_party/vst3sdk`: pinned git submodules.
- `plugin/Doppelbanger.h`, `plugin/Doppelbanger.cpp`: VST3 lifecycle, parameters, buffers, state, and Rust-handle ownership.
- `plugin/config.h`: iPlug2 product identity and format configuration.
- `plugin/StateCodec.h`, `plugin/StateCodec.cpp`: bounded binary state codec independent of iPlug2 UI code.
- `include/doppelbanger_dsp.h`: additive versioned C ABI.
- `src/ffi/update.rs`: realtime-safe Rust plan-update ABI.
- `tests/plugin/`: C++ unit and hosted lifecycle tests.
- `tests/cmake/`: dependency and configure-time network contracts.
- `scripts/dev.ps1`: small native developer command dispatcher; not shipped to customers.

---

### Task 1: Replace the legacy workstation surface with conventional native entry points

**Files:**

- Create: `scripts/dev.ps1`
- Create: `tests/tooling/dev_entrypoint_contract.ps1`
- Modify: `README.md`
- Modify: `docs/WINDOWS_WORKSTATION.md`
- Modify: `.gitignore`
- Delete after the replacement contract passes: `scripts/doctor_windows.ps1`
- Delete after the replacement contract passes: `scripts/install_windows_toolchain.ps1`
- Delete after the replacement contract passes: `scripts/run_native_tool.ps1`
- Delete after the replacement contract passes: `tests/tooling/windows_installer_contract.ps1`
- Delete after the replacement contract passes: `tests/tooling/windows_toolchain_contract.ps1`
- Delete after the replacement contract passes: `tests/tooling/fixtures/*.json`
- Delete after the replacement contract passes: `tools/windows-toolchain.lock.json`

**Interfaces:**

- Produces: `scripts/dev.ps1 -Task <doctor|format|test|configure|build|validate> [-Configuration Release]`.
- Produces: stable failures `DBDEV_WINDOWS_REQUIRED`, `DBDEV_WSL_FORBIDDEN`, `DBDEV_TOOL_MISSING`, and `DBDEV_WRONG_RUST_HOST`.

- [ ] **Step 1: Write the failing entry-point contract.** Assert that `-Task doctor` rejects injected WSL ancestry, accepts a native Windows fixture with `rustc`, `cmake`, `ninja`, `cl`, and `git`, and that every non-doctor task delegates only to checked native executables. Assert the script contains no installer download, registry mutation, service mutation, reboot, Docker, Postgres, Steam, Gaming Services, or Ableton operation.
- [ ] **Step 2: Run the contract red.** Run `powershell.exe -NoProfile -File .\tests\tooling\dev_entrypoint_contract.ps1`. Expected: FAIL because `scripts/dev.ps1` does not exist.
- [ ] **Step 3: Implement the smallest dispatcher.** Use `Get-CimInstance Win32_Process` for ancestry, `Get-Command` for tools, `rustc -vV` for the `x86_64-pc-windows-msvc` host, and a fixed `switch ($Task)` that invokes the commands introduced by later tasks. `doctor` is read-only; no task installs anything.
- [ ] **Step 4: Run the focused contract green.** Run the command from Step 2. Expected: PASS.
- [ ] **Step 5: Update user/developer documentation.** README states that customers use an installer and developers install Visual Studio Build Tools, Rust, CMake, and Ninja normally. `docs/WINDOWS_WORKSTATION.md` documents native PowerShell and the six dispatcher tasks without machine-specific paths.
- [ ] **Step 6: Delete legacy provisioning only after parity.** Remove the listed legacy scripts, fixtures, and lock. Run `rg -n "doctor_windows|install_windows_toolchain|run_native_tool|windows_installer_contract|windows_toolchain_contract" --glob '!docs/superpowers/**'`. Expected: no matches.
- [ ] **Step 7: Run regression gates.** Run the focused contract and `cargo test --locked --all-targets`. Expected: PASS.
- [ ] **Step 8: Commit.** Stage only the files listed in this task and commit `build: simplify native Windows developer entry points`.

### Task 2: Pin the offline plugin dependencies and CMake graph

**Files:**

- Create: `.gitmodules`
- Create: `third_party/iPlug2` gitlink
- Create: `third_party/vst3sdk` gitlink and recursive SDK gitlinks
- Create: `third_party/README.md`
- Create: `tools/plugin-dependencies.lock.json`
- Create: `CMakeLists.txt`
- Create: `CMakePresets.json`
- Create: `cmake/BuildRust.cmake`
- Create: `cmake/PrepareIPlug2.cmake`
- Create: `tests/cmake/dependency_contract.cmake`
- Modify: `.gitignore`

**Interfaces:**

- Consumes: native tools verified by `scripts/dev.ps1 -Task doctor`.
- Produces: CMake target `doppelbanger_rust`, preset `windows-msvc-x64-release`, and prepared source directory `${binaryDir}/_deps/iPlug2`.

- [ ] **Step 1: Add exact dependency locks.** Pin iPlug2 URL `https://github.com/iPlug2/iPlug2.git` at `5c2df9dce3f5258acfeff3846a6a9563f382212c` and VST3 SDK URL `https://github.com/steinbergmedia/vst3sdk.git` at `58f8da7936800732561402d7936584ca4505de07`, including the recursive SDK gitlinks recorded in `tools/plugin-dependencies.lock.json`.
- [ ] **Step 2: Write the failing dependency contract.** The CMake script must reject missing, dirty, or mismatched gitlinks; any `FetchContent`, `file(DOWNLOAD)`, clone, or source-tree copy destination; and a non-MSVC Rust target.
- [ ] **Step 3: Run the contract red.** Run `cmake -P tests/cmake/dependency_contract.cmake`. Expected: FAIL before CMake support files exist.
- [ ] **Step 4: Implement the prepared dependency tree.** `PrepareIPlug2.cmake` canonicalizes every source/destination, copies pinned sources only into `${CMAKE_BINARY_DIR}/_deps/iPlug2`, and stamps the two top-level SHAs. It never writes into either submodule.
- [ ] **Step 5: Implement the Rust imported target.** `BuildRust.cmake` runs `cargo rustc --locked --release --lib --target x86_64-pc-windows-msvc -- --print native-static-libs`, imports `target/x86_64-pc-windows-msvc/release/doppelbanger.lib`, and exposes the parsed native libraries to consumers.
- [ ] **Step 6: Add deterministic presets.** Configure with Ninja, `Release`, x64 MSVC environment, static MSVC runtime, no plugin deployment, and binary directory `build/windows-msvc-x64-release`.
- [ ] **Step 7: Run green gates.** Run `scripts/dev.ps1 -Task configure`, build target `doppelbanger_rust`, rerun the dependency contract, and verify `git submodule status --recursive` exactly matches the lock.
- [ ] **Step 8: Commit.** Commit `build: pin native VST3 dependencies`.

### Task 3: Add realtime-safe plan updates to the Rust C ABI

**Files:**

- Create: `src/ffi/update.rs`
- Create: `tests/ffi_update.rs`
- Modify: `src/ffi.rs`
- Modify: `src/dsp.rs`
- Modify: `src/lib.rs`
- Modify: `include/doppelbanger_dsp.h`
- Modify: `tests/native/c11_smoke.c`
- Modify: `tests/native/cpp17_smoke.cpp`

**Interfaces:**

- Produces: `db_processor_set_plan_v1(db_processor*, const db_runtime_plan_v1*) -> db_status`.
- Produces: `db_processor_get_meter_v1(const db_processor*, db_meter_snapshot_v1*) -> db_status` where `db_meter_snapshot_v1` contains version fields plus finite input/output peak values.
- Preserves: every existing V1 type, constant, function signature, status value, and layout.

- [ ] **Step 1: Write failing Rust and native ABI tests.** Cover nulls, bad versions, non-finite/range-invalid fields, atomic rejection, valid updates, repeated updates during processing, meter finiteness, and unchanged old layout assertions.
- [ ] **Step 2: Run red.** Run `cargo test --locked --test ffi_update` and the native C/C++ smoke harness. Expected: FAIL because both symbols and the meter type are absent.
- [ ] **Step 3: Implement immutable parameter targets.** Convert `db_runtime_plan_v1` into validated numeric targets outside per-sample work. Store fixed-size target/current values in `DbProcessor`; apply a 10 ms bounded ramp during processing. Do not allocate, lock, or redesign coefficients in `db_processor_process_f32`.
- [ ] **Step 4: Implement bounded meters.** Accumulate finite block peaks in the processor and copy one fixed-size snapshot through the ABI. A meter read never mutates DSP state.
- [ ] **Step 5: Prove realtime behavior.** Add an allocation-counting test around 10,000 process/update cycles and randomized finite input tests across supported sample rates and block sizes. Expected: zero process-path allocations and finite output.
- [ ] **Step 6: Run regression gates.** Run format, clippy with warnings denied, all Rust tests, and both native ABI smokes. Expected: PASS.
- [ ] **Step 7: Commit.** Commit `feat: add realtime-safe processor plan updates`.

### Task 4: Build the headless iPlug2 VST3 and persist complete state

**Files:**

- Create: `plugin/config.h`
- Create: `plugin/Doppelbanger.h`
- Create: `plugin/Doppelbanger.cpp`
- Create: `plugin/StateCodec.h`
- Create: `plugin/StateCodec.cpp`
- Create: `tests/plugin/StateCodecTests.cpp`
- Create: `tests/plugin/PluginLifecycleTests.cpp`
- Modify: `CMakeLists.txt`
- Modify: `CMakePresets.json`

**Interfaces:**

- Produces VST3 parameters: `Low EQ`, `Mid EQ`, `High EQ`, `Output`, and host bypass with stable numeric IDs `0`, `1`, `2`, `3`, and iPlug2's VST3 bypass ID.
- Produces state bytes: magic `DBST`, `u32 schema_version=1`, fixed little-endian V1 payload length, plan fields, and CRC-32.
- Consumes: `db_processor_create`, `db_processor_set_plan_v1`, `db_processor_process_f32`, `db_processor_reset`, `db_processor_latency_samples`, and `db_processor_destroy`.

- [ ] **Step 1: Write the failing state-codec test.** Golden bytes must round-trip, reject wrong magic/version/length/CRC, reject trailing or truncated bytes, and preserve all effective plan fields. Decoder limits are fixed before allocation and V1 contains no variable-size field.
- [ ] **Step 2: Run state test red.** Build and run `StateCodecTests`. Expected: FAIL because the codec does not exist.
- [ ] **Step 3: Implement the bounded codec.** Use explicit little-endian reads/writes and fixed-size arrays; never serialize raw C/C++ structure memory or machine pointers.
- [ ] **Step 4: Write the failing lifecycle test.** Instantiate the component, configure stereo 32-bit processing, process silence and an impulse, automate each parameter, save state, create a new instance, restore, and prove equivalent output and parameter values. Cover unsupported sample format, oversized block, corrupt state, reset, and destruction with the editor absent.
- [ ] **Step 5: Run lifecycle test red.** Expected: FAIL because the plugin class does not exist.
- [ ] **Step 6: Implement the minimal plugin.** Own one Rust handle per active processor, expose one stereo input/output bus and no MIDI/sidechain, accept 32-bit samples, translate host automation to validated ABI plans, process one bounded block, report Rust latency, and fail safely without throwing across the host boundary.
- [ ] **Step 7: Add the VST3 bundle target.** Product name `Doppelbanger`, vendor `William Hayden`, category `Fx|Mastering`, bundle output under `build/windows-msvc-x64-release/artefacts/Release/VST3/Doppelbanger.vst3`, and no post-build copy to a system directory.
- [ ] **Step 8: Run all native gates.** Configure, build, run both plugin tests and all Rust/ABI tests. Inspect the produced `.vst3` binaries as PE32+ x64 and verify no Rust/CMake/Node/PowerShell executable is a runtime dependency.
- [ ] **Step 9: Commit.** Commit `feat: add headless Doppelbanger VST3`.

### Task 5: Add validator, clean-checkout CI, and the Ableton milestone gate

**Files:**

- Create: `tests/plugin/validate_vst3.ps1`
- Create: `.github/workflows/windows-vst3.yml`
- Modify: `scripts/dev.ps1`
- Modify: `docs/VALIDATION.md`
- Modify: `README.md`

**Interfaces:**

- Consumes: the Release VST3 bundle from Task 4.
- Produces: ignored evidence under `var/validation/native-foundation/` and a CI artifact containing only the unsigned VST3 bundle plus test reports.

- [ ] **Step 1: Write the failing validation wrapper contract.** Require an explicit validator path or a pinned build-tree validator, an explicit plugin path, nonzero exit propagation, a timeout, and evidence output. Reject WSL/UNC paths and wildcard plugin targets.
- [ ] **Step 2: Run red.** Run the wrapper contract. Expected: FAIL because `validate_vst3.ps1` is absent.
- [ ] **Step 3: Implement validation.** Execute Steinberg's validator against the exact Release bundle, retain stdout/stderr and exit code, and fail on any validator failure or crash.
- [ ] **Step 4: Add clean native Windows CI.** Checkout recursively, install pinned Rust, configure with the preset, build, run Rust/C++ tests, run the validator, and upload the narrow artifact. CI performs no Docker startup and no database setup.
- [ ] **Step 5: Run the complete local automated gate.** `scripts/dev.ps1 -Task format`, `test`, `configure`, `build`, and `validate` all pass from native PowerShell. Native Git status is clean after generated artifacts remain ignored.
- [ ] **Step 6: Perform the authorized Ableton smoke test.** Copy only the built VST3 bundle to the standard VST3 directory, launch Ableton normally, rescan plugins, insert Doppelbanger on a test master channel, automate controls, save a disposable test Set, close/reopen it, and confirm restored sound/settings. Do not inspect or alter unrelated Ableton projects or preferences.
- [ ] **Step 7: Record narrow evidence.** Add no Ableton project or private audio to Git. Record date, Ableton version, sample rate, buffer size, plugin hash, pass/fail checks, and any defect in `var/validation/native-foundation/ableton-smoke.md`.
- [ ] **Step 8: Update docs and commit.** README describes the currently working developer build and clearly marks the installer/editor/analysis as subsequent milestones. Commit `test: validate native VST3 foundation`.

## Milestone Exit

The native foundation is complete only when a clean native Windows checkout builds the x64 VST3 without network access during configure, all Rust/C/C++/hosted tests pass, Steinberg's validator passes, and Ableton Live 12 saves and restores the effective processing state. The milestone does not claim a customer-ready UI, local reference workflow, limiter, or installer.
