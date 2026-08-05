# Native Windows Headless VST3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish a reproducible native Windows x86_64 workstation and ship a UI-less Doppelbanger VST3 that processes through the existing Rust DSP, exposes five stable host parameters, preserves a complete validated plan in DAW state, and passes automated host/validator checks plus an Ableton save-and-reopen smoke test.

**Architecture:** Windows-native PowerShell, Rust/MSVC, CMake/Ninja, the Steinberg SDK, Validator, pluginval, and Ableton own the plugin path. Docker Desktop may use its private WSL2 Linux backend only for Postgres/PostgREST. A stock pinned iPlug2 `IPlugVST3::process()` is called once per positive host block with parameter changes removed; the derived plugin validates all raw queues first, and its single `ProcessBlock()` call divides only the Rust DSP into sample-offset slices. Rust owns normalization, safety limiting of requested output gain, coefficient/amplitude targets, smoothing, state validation, and `active_plan_hash_v1`.

**Tech Stack:** Rust 1.97.1, MSVC 19.44 / VS Build Tools 2022 17.14.37, Windows SDK 10.0.26100.0, CMake 4.4.2, Ninja 1.13.2, iPlug2 at `5c2df9dce3f5258acfeff3846a6a9563f382212c`, VST3 SDK at `58f8da7936800732561402d7936584ca4505de07`, pluginval 1.0.4, Node.js 24.19.0 LTS, Docker Desktop 4.85.0, and PowerShell 5.1-compatible scripts.

## Global Constraints

- Scope is Milestones 0 and 1 only. Do not add React, WebView2 SDK integration, capture, PostgREST calls from the plugin, a limiter, MIDI, sidechain buses, presets, or a second DSP path.
- Build, link, test, validate, stage, and host the plugin in native 64-bit Windows. Reject WSL paths, WSL environment variables, GNU Windows targets, MinGW, ELF objects, and `wsl.exe cargo/cmake/ninja` invocations.
- Every native `cargo`, `rustc`, `cl`, `link`, `lib`, `dumpbin`, `cmake`, `ctest`, `ninja`, `docker`, `docker compose`, Validator, and pluginval invocation goes through `scripts/run_native_tool.ps1`. The wrapper imports the locked MSVC/SDK environment and resolves the locked tools by absolute path; command spellings later in this plan are payloads for that wrapper, never permission to use ambient `PATH`.
- Docker's native Windows CLI may address Docker Desktop's `desktop-linux` engine. Only the two state-plane containers and their named volumes run in that private WSL2 backend.
- Use test-driven development: add the named failing test, run it and retain the failure in PR evidence, implement the smallest passing behavior, rerun the focused test, then run the task's regression gate.
- The audio callback performs no heap allocation/deallocation, locks, waits, I/O, logging, JSON, hashing, coefficient design, transcendental gain calculation, JavaScript, or unbounded traversal.
- iPlug2 is host glue, not a DSP implementation. Rust owns all wet processing and click-free bypass. C++ may copy dry input to output only for the explicit fail-closed path.
- Keep `db_runtime_plan_v1` and `db_processor_process_f32` source/binary compatible. Add new V1 symbols and structs rather than changing existing layouts.
- Use stock iPlug2. Do not patch it during configure and do not create a fork. The process-override compile/host proof is a hard gate; if the pinned SHA cannot satisfy it, stop and return for an architecture decision.
- Every dependency used at configure/build time is already present in a pinned checkout or a checksum-verified tool cache. CMake configure performs no clone, download, or `FetchContent` operation.
- All release/plugin targets use `/MT` and Rust `-C target-feature=+crt-static`. The CMake contract rejects a CRT mismatch.
- Keep commits reviewable and normally below 400 changed lines. If a task exceeds that, split it at the test/contract boundary without combining unrelated work.
- Do not change global Git `safe.directory`. Development begins in a new William-owned NTFS clone; all final clean-clone evidence must run without a safe-directory override.
- Store machine evidence under ignored `var/validation/`. Never commit Ableton projects, private audio, absolute private paths, Docker credentials, or raw workstation logs.
- The roadmap in `docs/superpowers/specs/2026-08-05-vst3-react-editor-design.md` remains authoritative. This plan makes four previously implicit Milestone 1 choices explicit: a 10 ms transition, a separate-input/output ABI, safety-clamped effective output gain, and iPlug2's built-in VST3 bypass parameter.

## Execution Workspace Gate

The current Codex checkout is on native NTFS but is owned by `CodexSandboxOnline`, so native Git provenance is intentionally rejected. This plan and the approved roadmap status must first be committed in the source checkout, and its status must be clean. Before Task 1, create a separate owner-correct clone containing that exact commit:

```powershell
$source = 'C:\Users\William\Documents\Codex\2026-08-05\i-w\doppelbanger'
$destination = 'C:\Users\William\Documents\Codex\doppelbanger-native'
$safeSource = $source.Replace('\', '/')
if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite $destination" }
$sourceStatus = git -c "safe.directory=$safeSource" -C $source status --porcelain=v1
if ($LASTEXITCODE -ne 0 -or $sourceStatus) { throw 'Source must be clean; untracked or modified authoritative documents would be omitted' }
$sourceHead = git -c "safe.directory=$safeSource" -C $source rev-parse HEAD
git -c "safe.directory=$safeSource" clone --no-hardlinks $source $destination
git -C $destination remote set-url origin https://github.com/williamshayden/doppelbanger.git
Set-Location $destination
if ((Get-Acl -LiteralPath .).Owner -notmatch '\\william$') { throw 'Native clone is not owned by William' }
if ((git rev-parse HEAD) -ne $sourceHead) { throw 'Source and native clone HEAD differ' }
git submodule update --init --recursive
if ((git submodule status --recursive) -match '^[+\-U]') { throw 'Recursive submodule provenance mismatch' }
if (git status --porcelain=v1) { throw 'Native clone is not clean' }
git status --short --branch
```

Expected: `main` includes the roadmap and this plan, `origin` is GitHub, the owner is William, and plain `git status` succeeds. All remaining commands run from `C:\Users\William\Documents\Codex\doppelbanger-native`.

---

## Task 1: Lock and diagnose the native Windows workstation

**Files:**

- Create: `rust-toolchain.toml`
- Create: `.node-version`
- Create: `tools/windows-toolchain.lock.json`
- Create: `scripts/doctor_windows.ps1`
- Create: `scripts/run_native_tool.ps1`
- Create: `tests/tooling/windows_toolchain_contract.ps1`
- Create: `tests/tooling/fixtures/windows-native-valid.json`
- Create: `tests/tooling/fixtures/windows-wsl-invalid.json`
- Create: `tests/tooling/fixtures/windows-wsl-parent-invalid.json`
- Create: `tests/tooling/fixtures/windows-compose-shadow-invalid.json`
- Create: `tests/tooling/fixtures/windows-version-drift-invalid.json`
- Create: `docs/WINDOWS_WORKSTATION.md`
- Modify: `.gitignore`

**Pinned lock content:**

| Item | Exact contract |
|---|---|
| Rust toolchain | `1.97.1`, `x86_64-pc-windows-msvc`, `rustfmt`, `clippy` |
| rustup installer | 1.29.0, SHA-256 `86478e53f769379d7f0ebfa7c9aa97cb76ca92233f79aa2cc0dbee2efaac73c7` |
| VS Build Tools | 17.14.37 / installation 17.14.37516.0 |
| MSVC component | `Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64` |
| Windows SDK | component `Microsoft.VisualStudio.Component.Windows11SDK.26100`, target `10.0.26100.0` |
| CMake ZIP | 4.4.2, SHA-256 `e8139d85b3813bc38833142ae1940472e9a587e9b5d2718ac1804c60f4e57a64` |
| Ninja ZIP | 1.13.2, SHA-256 `07fc8261b42b20e71d1720b39068c2e14ffcee6396b76fb7a795fb460b78dc65` |
| Node ZIP | 24.19.0 LTS, SHA-256 `57f71ab3652e797d84acddc79c81cc9ff1c6ddb2a1974cdb83f00fee9bff4c73` |
| npm | bundled 11.17.0 |
| Docker Desktop | 4.85.0 build 235549; Engine/CLI 29.6.2; Compose 5.3.1; installer SHA-256 `5417cedc1aeb16b488b8084025246b64a5e9da4d71388f324b107140dfe00699` |
| WSL | record resolved version; require at least 2.1.5; never invoke the Ubuntu toolchain |

The lock stores these literal artifact URLs rather than release aliases:

```text
https://static.rust-lang.org/rustup/archive/1.29.0/x86_64-pc-windows-msvc/rustup-init.exe
https://download.visualstudio.microsoft.com/download/pr/f7f5ecbc-83ca-4cf0-bdb2-aaf70efb6d97/e0b8ea16494b4a79c68da26773131562aefecc8d87f1923c24d579c7a72e0575/vs_BuildTools.exe
https://github.com/Kitware/CMake/releases/download/v4.4.2/cmake-4.4.2-windows-x86_64.zip
https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-win.zip
https://nodejs.org/dist/v24.19.0/node-v24.19.0-win-x64.zip
https://desktop.docker.com/win/main/amd64/235549/Docker%20Desktop%20Installer.exe
```

`rust-toolchain.toml` is cross-platform and therefore omits a Windows target:

```toml
[toolchain]
channel = "1.97.1"
profile = "minimal"
components = ["rustfmt", "clippy"]
```

The doctor's public entry point is:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\doctor_windows.ps1 -Profile HeadlessVst3 -Json
```

`-ExecutionPolicy Bypass` is process-scoped. The doctor reads registry, executable metadata, command output, disk state, pending-reboot keys, Docker info, Compose config and plugin provenance, Git provenance, WebView2/Ableton presence, process ancestry, and PE architecture. It does not install, start services, change PATH/configuration, or write unless `-ReportPath` names an ignored path.

`scripts/run_native_tool.ps1` accepts a tool name followed by its arguments. It prepends the absolute CMake/Ninja/Node/Rust paths from the lock, locates the exact VS 17.14 installation with `vswhere.exe`, imports `VsDevCmd.bat -arch=x64 -host_arch=x64 -vcvars_ver=14.44 -winsdk=10.0.26100.0`, and resolves the requested executable again. Toolchain and downloaded validator executables must reside under locked roots; the separately built Steinberg Validator is allowed only beneath its canonical repo build directory after its producing target and pinned submodule provenance are verified. For `docker`, the wrapper resolves the Docker Desktop installation's absolute `docker.exe`, verifies CLI 29.6.2 and PE provenance, rechecks the winning Compose plugin path/version on every invocation, and permits only the expected Linux/amd64 `desktop-linux` server. Every executable is checked as PE32/PE32+ before launch. The wrapper never accepts a WSL/GNU executable. `-Describe` emits resolved paths and environment without executing a tool.

- [ ] Add the five probe fixtures and `tests/tooling/windows_toolchain_contract.ps1`. The valid fixture must report `os=Windows`, `arch=x86_64`, `wsl=false`, `compiler=MSVC`, `rust_target=x86_64-pc-windows-msvc`, exact versions, `docker_server_os=linux`, and `docker_server_arch=amd64`. The invalid fixtures must cover an explicit WSL environment, a cleared-variable Windows process descended from a WSL launcher, a shadowing user Compose plugin, and version drift, with stable codes `DBDOC_WSL_FORBIDDEN`, `DBDOC_DOCKER_PLUGIN_SHADOW`, and `DBDOC_TOOL_VERSION_DRIFT`.
- [ ] Run `powershell.exe -NoProfile -File .\tests\tooling\windows_toolchain_contract.ps1`. Expected red: the doctor and lock file do not exist.
- [ ] Add the toolchain files and implement pure probe-validation functions `Read-ToolchainLock`, `Get-NativeWindowsProbe`, `Test-NativeWindowsProbe`, and `Write-DoctorReport`. Require both `$env:WSL_DISTRO_NAME` and `$env:WSL_INTEROP` to be empty, reject any `wsl.exe`, `wslhost.exe`, or `bash.exe` ancestor, require the repo path to be a drive-letter NTFS path rather than UNC/`\\wsl$`, require `rustc -vV` to report the MSVC host, `cl /Bv` to report 19.44, Node to report `win32/x64`, and every resolved build/plugin binary to be PE32/PE32+ AMD64. This must still allow native `docker.exe` to address Docker Desktop's Linux WSL2 engine.
- [ ] Detect Docker CLI plugin provenance, including `%USERPROFILE%\.docker\cli-plugins\docker-compose.exe`. A user/plugin-path executable that wins resolution over Docker Desktop is a hard `DBDOC_DOCKER_PLUGIN_SHADOW` failure even when its version looks compatible; diagnostics never move or delete it.
- [ ] Implement and contract-test `scripts/run_native_tool.ps1 -Describe`, including rejection of ambient CMake/Ninja/Docker shadowing, user Compose-plugin shadowing on each Docker launch, WSL ancestry, non-PE tools, the wrong VS instance, and missing `INCLUDE`/`LIB`/`WindowsSdkDir` after the exact `VsDevCmd.bat` import.
- [ ] Make low disk, pending reboot, Docker licensing, and missing Ableton warnings in diagnostic mode. Make them hard preconditions only for the installer in Task 2. Lock the exact Compose version and provenance resolved from Docker Desktop rather than accepting an arbitrary version 2+ plugin.
- [ ] Rerun `powershell.exe -NoProfile -File .\tests\tooling\windows_toolchain_contract.ps1`. Expected green: all fixture assertions pass on any OS because they inject probe JSON.
- [ ] Run the real doctor. Expected current result: nonzero with missing Rust/MSVC/SDK/CMake/Ninja/Node, Docker Desktop 4.46 stopped, a shadowing user Compose 2.39.4 plugin, and no WSL compilation attempt.
- [ ] Document the ownership-correct clone, native/container boundary, strict and compatibility profiles, user VST3 location, and evidence directory in `docs/WINDOWS_WORKSTATION.md`.
- [ ] Commit with `git add rust-toolchain.toml .node-version tools/windows-toolchain.lock.json scripts/doctor_windows.ps1 scripts/run_native_tool.ps1 tests/tooling docs/WINDOWS_WORKSTATION.md .gitignore && git commit -m "build: lock native Windows workstation contract"`.

## Task 2: Add the checksum-verified installer and provision the workstation

**Files:**

- Create: `scripts/install_windows_toolchain.ps1`
- Create: `tests/tooling/windows_installer_contract.ps1`
- Modify: `docs/WINDOWS_WORKSTATION.md`

The installer is PowerShell 5.1-compatible, idempotent, and driven exclusively by `tools/windows-toolchain.lock.json`. Its default cache is `%LOCALAPPDATA%\doppelbanger\downloads`; extracted CMake, Ninja, and Node live in version-named directories beneath `%LOCALAPPDATA%\Programs\doppelbanger-devtools`. It never invokes `winget`, never runs `wsl --update`, never reboots, and never prunes, resets, uninstalls, or silently upgrades Docker Desktop.

- [ ] Add `windows_installer_contract.ps1` with `-PlanOnly` assertions: exact URLs/hashes are emitted, Visual Studio uses `--add Microsoft.VisualStudio.Workload.VCTools`, `--add Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64`, and `--add Microsoft.VisualStudio.Component.Windows11SDK.26100`, and the command contains neither `--includeRecommended` nor a floating version. For this workstation's detected all-users Docker installation at `C:\Program Files\Docker\Docker`, require the exact verified-installer payload `install --quiet --backend=wsl-2`; forbid `--user`, installation/data-root migration switches, and mode changes unless William separately approves a migration. Simulate an installer exit 3010 and prove no later installer/move runs after that checkpoint.
- [ ] Run `powershell.exe -NoProfile -File .\tests\tooling\windows_installer_contract.ps1`. Expected red: installer script missing.
- [ ] Implement `Assert-InstallPreconditions`, `Get-VerifiedArtifact`, `Install-VsBuildTools`, `Install-RustToolchain`, `Expand-VersionedTool`, `Upgrade-DockerDesktop`, and `Set-DoppelbangerUserPath`. Every downloaded byte sequence is checked with `Get-FileHash -Algorithm SHA256` before execution/extraction. Exit 3010 writes a resumable checkpoint and halts immediately; after reboot the script reruns pending-reboot and free-space checks before any remaining mutation.
- [ ] Require 40 GiB free on every volume that will receive tools/data and no pending reboot before mutation. On this workstation the first real preflight is expected to stop because about 20 GiB is free and a Gaming Services rename is pending. Pause execution, report both facts, let William reboot and free space, then rerun; do not weaken the thresholds.
- [ ] Keep Docker Desktop upgrade behind explicit `-UpgradeDockerDesktop`. Preserve the detected all-users installation mode/path and WSL2 backend. Require Desktop fully stopped and `-DockerBackupManifest` naming schema V1 JSON from Docker's [official backup/restore procedure](https://docs.docker.com/desktop/settings-and-maintenance/backup-and-restore/). Validate: source Desktop version; `all-users` mode and install path; source data path; backup path outside Docker data/install/plugin roots; existing nonempty backup size; matching SHA-256; UTC creation timestamp; and `desktop_stopped=true`, confirmed again from live processes before install. A filename or unchecked boolean is not evidence. Forbid prune/reset/uninstall. A shadowing user Compose plugin may only be moved to a timestamped backup with separate `-BackupShadowingComposePlugin` opt-in; never delete it or rewrite the lock to match it.
- [ ] Rerun the contract test and `powershell.exe -NoProfile -File .\scripts\install_windows_toolchain.ps1 -PlanOnly`. Expected green: deterministic install plan, no mutation.
- [ ] Commit before machine mutation: `git add scripts/install_windows_toolchain.ps1 tests/tooling/windows_installer_contract.ps1 docs/WINDOWS_WORKSTATION.md && git commit -m "build: add pinned Windows toolchain installer"`.
- [ ] After the preconditions pass, run the installer from an ordinary PowerShell. Approve only its VS Build Tools prompt; opt into the Docker upgrade separately only after its preservation gate passes. If an installer reports exit 3010, reboot at the immediate checkpoint and explicitly resume. Open a fresh native PowerShell after completion.
- [ ] Run the real `doctor_windows.ps1 -Profile HeadlessVst3 -Json -ReportPath var/validation/m0-windows/doctor.json`. Expected: all compile tools pass; Docker may still report `DBDOC_DOCKER_STOPPED` until Docker Desktop is started.
- [ ] Start Docker Desktop normally, wait for the `desktop-linux` context, and rerun the doctor. Require the locked Engine/CLI 29.6.2 and Compose 5.3.1 inherited by Docker Desktop 4.85.0; stop on any mismatch instead of rewriting the lock to match the machine.

## Task 3: Pin the state-plane containers and prove the existing ABI with MSVC

**Files:**

- Create: `.cargo/config.toml`
- Create: `scripts/test_native_ffi.ps1`
- Modify: `scripts/test_native_ffi.sh`
- Modify: `tests/native/native_abi_smoke.h`
- Modify: `tests/native/c11_smoke.c`
- Modify: `tests/native/cpp17_smoke.cpp`
- Modify: `docker-compose.yml`
- Modify: `.github/workflows/ci.yml`
- Modify: `build.rs`
- Modify: `docs/VALIDATION.md`

Pin the containers exactly and bind them only to loopback:

```yaml
db:
  image: postgres:17.10-alpine3.24@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
  platform: linux/amd64
  ports: ["127.0.0.1:54329:5432"]
api:
  image: postgrest/postgrest:v14.14@sha256:d2009b5c9deffc210c8a5592698472fede14fd9f6ca89823c8474ca54d58c012
  platform: linux/amd64
  ports: ["127.0.0.1:3000:3000"]
```

Use static CRT for the future iPlug2 link:

```toml
[target.x86_64-pc-windows-msvc]
rustflags = ["-C", "target-feature=+crt-static"]
```

- [ ] Extend the native fixture to assert current V1 layout from both C11 and C++17, create/process/reset/destroy a handle, verify finite audio, and verify the zero-frame/null-buffer contract.
- [ ] Add a test invocation to `tests/tooling/windows_toolchain_contract.ps1` for `scripts/test_native_ffi.ps1 -Describe`. Run it. Expected red: the MSVC harness is absent.
- [ ] Implement the harness entirely through `scripts/run_native_tool.ps1`: run `cargo rustc --locked --release --lib --target x86_64-pc-windows-msvc -- --print native-static-libs`, parse the emitted libraries rather than hard-coding them, compile with `/W4 /WX /permissive- /MT /std:c11` and `/W4 /WX /permissive- /MT /EHsc /std:c++17`, link, inspect with `dumpbin /headers`, run both executables, and clean a validated temp directory in `finally`.
- [ ] Keep `scripts/test_native_ffi.sh` exclusively in the Linux CI job, change it and all Cargo CI commands to `--locked`, and replace floating Rust installation with explicit `rustup toolchain install 1.97.1 --profile minimal` plus the required components. No native-Windows task invokes `bash.exe` because it resolves to the WSL launcher on this machine.
- [ ] Update `build.rs` so its Git subprocesses pass a command-scoped `safe.directory` equal to canonical `CARGO_MANIFEST_DIR`; do not write global Git configuration. Add/extend a build provenance test that rejects an absent commit on the owner-correct clone.
- [ ] Pin the Compose images/digests and loopback bindings. Through the native wrapper run `docker compose config --quiet` and assert the resolved config contains no `0.0.0.0` published address and no un-digested image.
- [ ] Through `scripts/run_native_tool.ps1`, run `cargo fmt --all -- --check`, `cargo clippy --locked --all-targets -- -D warnings`, and `cargo test --locked --all-targets`; then run native `scripts/test_native_ffi.ps1`. Expected green.
- [ ] Run API integration in an isolated Compose project, always tearing down only that project:

```powershell
$project = "doppelbanger-m0-$([guid]::NewGuid().ToString('N'))"
$evidence = 'var/validation/m0-windows'
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
try {
  & .\scripts\run_native_tool.ps1 docker compose -p $project up -d --wait
  & .\scripts\run_native_tool.ps1 cargo test --locked --test api_integration -- --ignored --test-threads=1
} finally {
  & .\scripts\run_native_tool.ps1 docker compose -p $project logs --no-color *> "$evidence/$project.log"
  & .\scripts\run_native_tool.ps1 docker compose -p $project down -v
}
```

- [ ] Commit with `git add .cargo/config.toml scripts tests/native docker-compose.yml .github/workflows/ci.yml build.rs docs/VALIDATION.md && git commit -m "ci: prove the Rust ABI with native MSVC"`.

Milestone 0 is complete only when Tasks 1–3 are green on the owner-correct native clone.

## Task 4: Pin iPlug2/VST3 SDK and build Rust through offline CMake

**Files:**

- Create: `.gitmodules`
- Create: `third_party/iPlug2` gitlink
- Create: `third_party/vst3sdk` gitlink with recursive SDK gitlinks
- Create: `third_party/README.md`
- Create: `tools/plugin-dependencies.lock.json`
- Create: `CMakeLists.txt`
- Create: `CMakePresets.json`
- Create: `cmake/PrepareIPlug2.cmake`
- Create: `cmake/BuildRust.cmake`
- Create: `tests/cmake/dependency_contract.cmake`
- Create: `tests/plugin/probe/config.h`
- Create: `tests/plugin/probe/IPlug2ProcessOverrideProbe.cpp`
- Create: `tests/plugin/probe/IPlug2ProcessOverrideHostProbe.cpp`
- Create: `tests/plugin/probe/CMakeLists.txt`
- Modify: `.gitignore`

Dependency lock:

- iPlug2: `https://github.com/iPlug2/iPlug2.git` at `5c2df9dce3f5258acfeff3846a6a9563f382212c`.
- VST3 SDK meta-repository: `https://github.com/steinbergmedia/vst3sdk.git` at `58f8da7936800732561402d7936584ca4505de07`.
- Required recursive VST3 gitlinks: `base=3d2e82f8e6bff59c1d8b7a27491a29c2286b5206`, `cmake=de6e54eeaaab35b7145f5c32c279b5e892146e04`, `pluginterfaces=31d6eeba6daaa3e2a8bfbe3e7a90ca0b7fbfbc1c`, and `public.sdk=a3911a4615dabbfdfd9d181ee26b05c70c289a95`.

Stock iPlug2 hard-codes `Dependencies/IPlug/VST3_SDK`. `PrepareIPlug2.cmake` therefore creates a hash-stamped composite copy only inside `build/windows-msvc-x64-release/_deps/iPlug2`: copy the pinned iPlug2 checkout, replace the copied README-only VST3 directory, then copy the four pinned SDK directories above. Never write inside either source submodule.

- [ ] Add the submodules with `git submodule add`, check out the exact SHAs, and run `git submodule update --init --recursive`. Record the expected recursive status in the dependency lock.
- [ ] Add `dependency_contract.cmake` to reject a missing/dirty/mismatched submodule, absent recursive SDK directories, any `FetchContent`/download/clone command in project CMake, a composite path outside the selected binary directory, and a composite stamp that does not contain both top-level SHAs.
- [ ] Through the native wrapper, run `cmake -P tests/cmake/dependency_contract.cmake`. Expected red: lock, scripts, and project do not exist.
- [ ] Implement `PrepareIPlug2.cmake` with canonical-path checks before every removal/copy. Recreate only `build/windows-msvc-x64-release/_deps/iPlug2` when its stamp differs. Point `IPLUG2_DIR` at the composite copy before including `iPlug2.cmake`.
- [ ] Implement `doppelbanger_add_rust_static_library()` in `BuildRust.cmake`. It runs locked Cargo for `x86_64-pc-windows-msvc`, parses `native-static-libs`, exposes imported target `doppelbanger_rust`, and adds build target `doppelbanger_rust_build`. Reject a non-MSVC Rust host/target or non-static CRT.
- [ ] Add configure/build/test/workflow presets named `windows-msvc-x64-release`, using generator `Ninja`, `CMAKE_BUILD_TYPE=Release`, `CMAKE_SYSTEM_VERSION=10.0.26100.0`, `IPLUG_DEPLOY_PLUGINS=OFF`, and binary directory `build/windows-msvc-x64-release`.
- [ ] Add the compile probe. It derives from `Plugin` under `VST3_API`, overrides public `setActive(Steinberg::TBool)`, `setupProcessing(Steinberg::Vst::ProcessSetup&)`, `process(Steinberg::Vst::ProcessData&)`, and `canProcessSampleSize(Steinberg::int32)`; validates component-inactive state/sample rate/max block/sample size before a qualified base setup call; makes a qualified `IPlugVST3::process(sanitized)` call; statically asserts `kBypassParam == 65536`; and accepts only `kSample32`. It is a test target, not a shipping plugin.
- [ ] Add the Task 4 hosted hard gate: instantiate the probe through its VST3 component interface, call setup while inactive, send multiple raw points in one queue plus a simultaneous second queue, and prove the derived override observes every raw point, the sanitized qualified base call invokes `ProcessBlock` exactly once, and stock iPlug2 parameter ingestion sees no queue. Stop the plan here if stock pinned iPlug2 cannot pass.
- [ ] Through the native wrapper, run `cmake --preset windows-msvc-x64-release`, `cmake --build --preset windows-msvc-x64-release --target doppelbanger_rust_build iplug2_process_override_probe`, and `ctest --preset windows-msvc-x64-release -R IPlug2ProcessOverrideProbe --output-on-failure`. Expected green with MSVC, 64-bit pointers, stock iPlug2, one hosted base call, and no configure-time network.
- [ ] Through the native wrapper, rerun `cmake -P tests/cmake/dependency_contract.cmake`; then run native Git `git submodule status --recursive`. Expected exact SHAs and clean gitlinks.
- [ ] Commit with `git add .gitmodules third_party tools/plugin-dependencies.lock.json CMakeLists.txt CMakePresets.json cmake tests/cmake tests/plugin/probe .gitignore && git commit -m "build: pin offline iPlug2 VST3 toolchain"`.

## Task 5: Freeze the Milestone 1 runtime contracts in canonical docs

**Files:**

- Modify: `docs/DECISIONS.md`
- Modify: `docs/ENGINEERING_SPEC.md`
- Modify: `docs/PLUGIN_ARCHITECTURE.md`
- Modify: `docs/VALIDATION.md`
- Modify: `tests/decision_docs.rs`
- Modify: `tests/docs_current.rs`

Record decision `PD-032` with these exact choices:

1. Numerical parameter transitions last exactly 10 ms: 441, 480, 882, 960, or 1920 frames at the five supported rates. Initial/restored state begins settled. A retarget starts from the current interpolated position; the event-offset sample performs tick 1 and tick N reaches the target. Reset clears history, snaps to the latest target, and cancels ramps.
2. EQ/output endpoints are precomputed at processor construction. Runtime ramps in centidecibel space and selects table entries; bypass uses a linear 10 ms wet/dry crossfade while the wet filters continue advancing. Settled bypass copies the original dry sample exactly.
3. Requested host EQ is applied exactly. Rust caps effective output to the centidecibel floor of `-1.00 dBTP - target_true_peak_dbtp - sum(max(eq_gain, 0))`; requested output and safety-limited effective output are both state fields. A safe maximum below -12.00 dB rejects the entire snapshot atomically.
4. Normal positive-block faults silence the entire host output block even if a later Rust slice fails; subsequent blocks dry-bypass until an explicit non-realtime reset. Malformed automation is rejected before DSP, dry-bypasses only that block, retains the previous target, and records a bounded non-realtime error.
5. The additive out-of-place ABI supports distinct input/output buffers and exact corresponding in-place aliases. It rejects every partial or cross-channel overlap.
6. The four ordinary IDs are low=0, mid=1, high=2, output=3. iPlug2's built-in VST3 bypass is the fifth parameter at ID 65536 and carries `kIsBypass`. All four gains are integer centidecibel plain values with VST3 step counts 600/600/600/2400.
7. The plugin accepts one stereo input and one stereo output, no MIDI/sidechain, and only 32-bit host samples for Milestone 1.
8. Desired gain is rounded to nearest centidecibel with half away from zero. Target true peak is rounded toward positive infinity to a conservative centidecibel before recomputing safe output and integer shortfall; the fixed ceiling is exactly -100 centidecibels TP.

- [ ] Add failing doc assertions for `PD-032`, 10 ms, output safety behavior, out-of-place alias rules, IDs, `kSample32`, and full-block fault semantics.
- [ ] Through the native wrapper, run `cargo test --locked --test decision_docs --test docs_current`. Expected red.
- [ ] Update the four canonical documents with the exact contract above and the stock-iPlug2 single-base-call sequence.
- [ ] Through the native wrapper, rerun the two tests and `cargo test --locked --all-targets`. Expected green.
- [ ] Commit with `git add docs tests/decision_docs.rs tests/docs_current.rs && git commit -m "docs: freeze headless VST3 runtime contracts"`.

## Task 6: Normalize generated and submitted plans to safe centidecibels

**Files:**

- Create: `src/parameters.rs`
- Create: `tests/plan_normalization.rs`
- Modify: `src/lib.rs`
- Modify: `src/plan.rs`
- Modify: `src/worker.rs`
- Modify: `src/render.rs`
- Modify: `tests/api_integration.rs`

Public Rust surface:

```rust
pub const EQ_GAIN_MIN_CENTIDB: i32 = -300;
pub const EQ_GAIN_MAX_CENTIDB: i32 = 300;
pub const OUTPUT_GAIN_MIN_CENTIDB: i32 = -1200;
pub const OUTPUT_GAIN_MAX_CENTIDB: i32 = 1200;
pub const PARAMETER_SMOOTHING_MILLISECONDS: u32 = 10;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ParameterSnapshotV1 {
    bypass: bool,
    low_eq_gain_centidb: i32,
    mid_eq_gain_centidb: i32,
    high_eq_gain_centidb: i32,
    output_gain_centidb: i32,
}

impl ParameterSnapshotV1 {
    pub fn try_new(
        bypass: bool,
        low_eq_gain_centidb: i32,
        mid_eq_gain_centidb: i32,
        high_eq_gain_centidb: i32,
        output_gain_centidb: i32,
    ) -> Option<Self>;
    pub const fn bypass(&self) -> bool;
    pub const fn eq_gains_centidb(&self) -> [i32; 3];
    pub const fn output_gain_centidb(&self) -> i32;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RuntimeSafetyV1 {
    true_peak_ceiling_centidbtp: i32,
    target_true_peak_centidbtp: i32,
}

impl RuntimeSafetyV1 {
    pub fn try_new(
        true_peak_ceiling_centidbtp: i32,
        target_true_peak_centidbtp: i32,
    ) -> Option<Self>;
    pub const fn true_peak_ceiling_centidbtp(&self) -> i32;
    pub const fn target_true_peak_centidbtp(&self) -> i32;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ParameterUpdateError {
    OutOfRange,
    SafetyImpossible,
}

pub fn normalize_runtime_plan_v1(
    plan: &MasteringPlanV1,
    target: &TrackAnalysisV1,
) -> Result<MasteringPlanV1>;
```

Normalization is shared by `generate_plan` and `worker::prepare_submitted_plan`: EQ and desired gain use nearest centidecibel with half away from zero; target true peak rounds toward positive infinity to a conservative centidecibel; safe headroom is recomputed from those quantized values; output is floored toward negative infinity without the `0.29 * 100` floating trap; shortfall is recomputed as an integer centidecibel difference. Runtime safety requires ceiling exactly `-100` centidecibels TP. Every sum/subtraction uses `i64`, validates the final range before conversion, and cannot overflow on malformed `i32::MIN/MAX` ABI/state input. Runtime plans accepted by DSP must be exactly on-grid. There is no released plugin state, so the stricter invariant retains schema V1 and is recorded in PD-032.

- [ ] Add failing cases `nearest_eq_centidb_uses_half_away_from_zero`, `output_gain_floors_toward_negative_infinity`, `quantized_eq_recomputes_safe_headroom`, `normalization_recomputes_shortfall`, `runtime_safety_requires_fixed_ceiling_and_cannot_overflow`, `normalized_plan_round_trips_json_on_the_exact_grid`, and `generated_and_submitted_plans_share_the_normalizer`. Include `±0.0049`, `±0.005`, `±2.995`, exact `-0.29`, values immediately around a safe boundary, and every `i32::MIN/MAX` safety position.
- [ ] Through the native wrapper, run `cargo test --locked --test plan_normalization`. Expected red: missing module/function and non-grid output.
- [ ] Implement one private checked centidecibel conversion. For the floor, first round to the nearest integer step, compare the reconstructed dB to the original, and subtract one only when the candidate is above the original.
- [ ] Route generated and submitted plan publication through the normalizer before JSON/database serialization. Make the renderer reject non-grid input rather than silently normalize a second time.
- [ ] Through the native wrapper, run `cargo test --locked --test plan_normalization`, `cargo test --locked --test mastering_pipeline`, and `cargo test --locked --all-targets`. Expected green.
- [ ] Run the isolated API integration tier from Task 3 and, through the native wrapper, `cargo run --locked --release --bin doppelbanger -- benchmark --corpus var/albumdb/pairs --output var/validation/albumdb-fast.json` because plan publication changed.
- [ ] Commit with `git add src tests && git commit -m "feat: normalize runtime plans to safe centidecibels"`.

## Task 7: Add precomputed 10 ms smoothing and separate-input/output Rust processing

**Files:**

- Create: `src/dsp/automation.rs`
- Create: `tests/dsp_automation.rs`
- Create: `tests/dsp_out_of_place.rs`
- Modify: `src/dsp.rs`
- Modify: `src/parameters.rs`
- Modify: `src/lib.rs`
- Modify: `tests/dsp_contract.rs`

Rust methods:

```rust
impl MasteringProcessor {
    pub fn new_with_runtime_safety(
        plan: &MasteringPlanV1,
        safety: RuntimeSafetyV1,
        sample_rate_hz: u32,
    ) -> Result<Self>;

    pub fn preview_parameters_v1(
        &self,
        parameters: ParameterSnapshotV1,
    ) -> Result<ParameterSnapshotV1, ParameterUpdateError>;

    pub fn set_parameters_v1(
        &mut self,
        parameters: ParameterSnapshotV1,
    ) -> Result<ParameterSnapshotV1, ParameterUpdateError>;

    pub fn restore_runtime_v1(
        &mut self,
        safety: RuntimeSafetyV1,
        parameters: ParameterSnapshotV1,
    ) -> Result<ParameterSnapshotV1, ParameterUpdateError>;

    pub fn process_planar_distinct(
        &mut self,
        input_left: &[f32],
        input_right: &[f32],
        output_left: &mut [f32],
        output_right: &mut [f32],
    ) -> Result<(), ProcessError>;
}
```

Construction allocates and fills three 601-entry coefficient tables and one 2401-entry amplitude table. `new_with_runtime_safety` receives the exact target-peak/ceiling metadata used by the plugin; ordinary host automation cannot change it, while `restore_runtime_v1` may replace it only as part of a prevalidated DAW-state restore and snaps/reset state without allocation. The existing `new` derives a conservative budget from its initial safe plan for offline/backward-compatible callers. A whole-snapshot retarget uses one exact-duration ramp. Each numeric frame selects precomputed endpoints; it performs no `powf`, trig, coefficient construction, allocation, or lock. The safe `process_planar_distinct` method requires four distinct buffers; existing `process_planar` remains the safe full-in-place API. A private unsafe raw-pointer frame kernel exists only for the validated FFI alias modes and reads both channel inputs before writing either output, never constructing overlapping Rust references.

- [ ] Add failing tests for construction settled state; every table endpoint; exact 10 ms completion at all five rates; first tick at event offset; zero frames not advancing; arbitrary partition invariance; mid-ramp retarget; rapid opposing changes; exact settled bypass; reset snap; state-restore snap; finite output over every legal endpoint; and zero allocations after construction.
- [ ] Add out-of-place tests for safe distinct buffers, existing full in-place processing, FFI full alias, both FFI mixed corresponding-alias cases, all illegal partial/cross overlaps, equivalence across legal modes, and error silencing of the complete output slice. Prove no legal alias branch ever creates simultaneous shared/mutable Rust references to overlapping storage.
- [ ] Through the native wrapper, run `cargo test --locked --test dsp_automation --test dsp_out_of_place`. Expected red: missing APIs and fixed processor state.
- [ ] Extract coefficient/amplitude table construction into `src/dsp/automation.rs`, using `biquad::Biquad::update_coefficients` for state-preserving table changes. Keep one frame kernel shared by interleaved, planar in-place, and planar I/O methods.
- [ ] Implement one non-mutating `preview_parameters_v1` and reuse it from the setter. Validate the complete snapshot before mutating target state; return the effective snapshot. Use `ParameterUpdateError`, not `ProcessError`, for range/safety rejection.
- [ ] At every smoothing tick, select the current three EQ table steps first, compute the safe output maximum from those current steps, and use `min(ramped_requested_output, safe_max_current_eq)` as the current effective output. Exhaustively test the invariant across all endpoints, opposing ramps, centidecibel rounding boundaries, and mid-ramp retargets; endpoint-only safety is insufficient.
- [ ] Extend the counting allocator test to bracket repeated setter/process/reset calls after warmup. Require zero allocation and deallocation.
- [ ] Through the native wrapper, run the focused tests, `cargo test --locked --test dsp_contract`, and `cargo test --locked --all-targets`. Expected green.
- [ ] Commit with `git add src/dsp.rs src/dsp src/parameters.rs src/lib.rs tests && git commit -m "dsp: add bounded parameter smoothing and planar I/O"`.

## Task 8: Expose parameter updates and planar I/O through the additive C ABI

**Files:**

- Create: `src/ffi/parameters.rs`
- Create: `tests/ffi_parameters.rs`
- Modify: `include/doppelbanger_dsp.h`
- Modify: `src/ffi.rs`
- Modify: `src/ffi/process.rs`
- Modify: `src/lib.rs`
- Modify: `tests/ffi_contract.rs`
- Modify: `tests/ffi_process.rs`
- Modify: `tests/native/native_abi_smoke.h`

C ABI additions:

```c
#define DB_STATUS_INVALID_PARAMETER ((db_status)8)

typedef struct db_runtime_safety_v1 {
  uint32_t struct_size;
  uint32_t abi_version;
  int32_t true_peak_ceiling_centidbtp;
  int32_t target_true_peak_centidbtp;
  uint32_t reserved[2];
} db_runtime_safety_v1;

typedef struct db_parameter_snapshot_v1 {
  uint32_t struct_size;
  uint32_t abi_version;
  uint32_t bypass;
  uint32_t reserved;
  int32_t low_eq_gain_centidb;
  int32_t mid_eq_gain_centidb;
  int32_t high_eq_gain_centidb;
  int32_t output_gain_centidb;
} db_parameter_snapshot_v1;

db_status db_processor_create_with_safety_v1(
  const db_runtime_plan_v1 *plan,
  const db_runtime_safety_v1 *safety,
  double sample_rate_hz,
  uint32_t max_block_frames,
  db_processor **output);

db_status db_processor_preview_parameters_v1(
  const db_processor *processor,
  const db_parameter_snapshot_v1 *requested,
  db_parameter_snapshot_v1 *effective);

db_status db_processor_set_parameters_v1(
  db_processor *processor,
  const db_parameter_snapshot_v1 *requested,
  db_parameter_snapshot_v1 *effective);

db_status db_processor_restore_runtime_v1(
  db_processor *processor,
  const db_runtime_safety_v1 *safety,
  const db_parameter_snapshot_v1 *requested,
  db_parameter_snapshot_v1 *effective);

db_status db_processor_process_planar_f32_v1(
  db_processor *processor,
  const float *input_left,
  const float *input_right,
  float *output_left,
  float *output_right,
  uint32_t frames);
```

The safety view is size 24/alignment 4 with fields at 0/4/8/12 and reserved words at 16/20; the snapshot is size 32/alignment 4 with fields at offsets 0,4,8,12,16,20,24,28. Nulls return `NULL_POINTER`; wrong size/ABI or nonzero reserved returns `INCOMPATIBLE_VERSION`; boolean/range/safety impossibility returns `INVALID_PARAMETER`. Preview, setter, and runtime restore all return `PROCESS_FAULT` without mutation on a faulted handle; only explicit `db_processor_reset` clears that fault. On a healthy handle, restore validates every input into locals, then atomically replaces runtime safety/requested state, clears history/ramps, and snaps current/target values without allocation. Preview is non-mutating and realtime-safe. Preview, setter, and restore write `effective` only on success. A contained preview/setter/restore panic latches the handle.

For preview/setter/restore, `effective` may be distinct from `requested` or exactly equal to it; every partial overlap and every overlap with `safety` is `INVALID_BUFFER`. The implementation uses unaligned raw reads to copy every input into locals before any output write, computes a local result, and uses one unaligned success write, so the exact-alias case never constructs overlapping Rust references and failure remains output-atomic.

`db_processor_create_with_safety_v1` is the normal plugin constructor. The legacy `db_processor_create` remains setter-capable but derives a conservative combined-gain budget from the initial on-grid plan: `budget_centidb = applied_output_centidb + sum(max(initial_eq_centidb, 0))`; it represents that as ceiling `-100` and target peak `-100 - budget_centidb`. Later automation can never exceed that initial combined budget. Both constructors leave `*output` null on failure.

The new processing call accepts either four distinct non-overlapping arrays or `input_left == output_left` and/or `input_right == output_right`. It computes byte ranges with checked integer arithmetic and rejects cross-channel, partial, and every other overlap before writing. After validation it builds raw per-channel modes (`InPlace` or `Separate`) and invokes the private raw frame kernel; it never constructs a Rust slice pair that aliases. Zero frames accepts all four audio pointers as null. The existing `db_processor_process_f32` delegates with two corresponding aliases.

- [ ] Add fixed-layout Rust/C/C++ assertions and failing tests `safety_constructor_is_additive_and_legacy_budget_is_conservative`, `preview_is_nonmutating_and_matches_setter`, `setter_rejects_null_version_reserved_and_ranges`, `parameter_views_allow_exact_but_not_partial_alias`, `invalid_snapshot_is_atomic`, `setter_returns_safety_limited_effective_values`, `restore_snaps_without_allocating`, `faulted_processor_rejects_parameter_updates_and_restore`, `only_reset_clears_process_fault`, `invalid_restore_does_not_clear_fault`, `contained_preview_and_restore_panics_latch_handle`, `zero_frame_flush_persists_targets_without_advancing`, `planar_io_accepts_distinct_full_and_mixed_aliases`, and `planar_io_rejects_partial_and_cross_overlap`.
- [ ] Through the native wrapper, run `cargo test --locked --test ffi_contract --test ffi_parameters --test ffi_process`. Expected red: missing struct, status, and symbols.
- [ ] Implement guarded preview/setter/restore entry points and one shared raw process implementation. On a new panic/process fault, silence the complete valid output slice; validation failures leave outputs unchanged.
- [ ] Extend the FFI allocation test to repeated setter and both processing symbols. Expected zero allocations/deallocations after construction.
- [ ] Run focused tests and all Cargo tests through the native wrapper, then `scripts/test_native_ffi.ps1`. Require the Linux CI job's Bash ABI smoke to be green; never invoke Bash locally. Expected green in Rust, C11, and C++17.
- [ ] Commit with `git add include src tests scripts/test_native_ffi.ps1 && git commit -m "ffi: add realtime parameter and planar I/O ABI"`.

## Task 9: Implement Rust-owned plugin state and active-plan identity

**Files:**

- Create: `src/plugin_state.rs`
- Create: `examples/generate_plugin_state_fixture.rs`
- Create: `tests/plugin_state_contract.rs`
- Create: `tests/plugin/fixtures/runtime-state-v1-nonbypass.bin`
- Modify: `include/doppelbanger_dsp.h`
- Modify: `src/ffi.rs`
- Modify: `src/lib.rs`
- Modify: `tests/ffi_contract.rs`

Public C state view (size 240/alignment 4):

```c
#define DB_PLUGIN_STATE_SCHEMA_VERSION 1u
#define DB_PLUGIN_STATE_V1_ENCODED_SIZE 248u
#define DB_STATUS_INVALID_STATE ((db_status)9)
#define DB_STATUS_STATE_BUFFER_SIZE ((db_status)10)

typedef struct db_plugin_state_v1 {
  uint32_t struct_size;
  uint32_t abi_version;
  uint32_t state_schema_version;
  uint32_t plan_schema_version;
  uint32_t analyzer_version;
  uint32_t processor_version;
  uint32_t topology_version;
  uint32_t flags;
  db_parameter_snapshot_v1 requested;
  db_parameter_snapshot_v1 effective;
  int32_t desired_gain_centidb;
  int32_t loudness_shortfall_centidb;
  int32_t true_peak_ceiling_centidbtp;
  int32_t target_true_peak_centidbtp;
  uint8_t reference_sha256[32];
  uint8_t target_sha256[32];
  uint8_t last_request_id[16];
  uint8_t last_report_id[16];
  uint8_t active_plan_hash[32];
} db_plugin_state_v1;

#define DB_PLUGIN_STATE_FLAG_HAS_REQUEST_ID 1u
#define DB_PLUGIN_STATE_FLAG_HAS_REPORT_ID 2u
#define DB_PLUGIN_STATE_FLAG_DEFAULT_IDENTITY 4u

db_status db_plugin_state_normalize_v1(db_plugin_state_v1 *state);
db_status db_plugin_state_encode_v1(
  const db_plugin_state_v1 *state,
  uint8_t *output,
  size_t output_size);
db_status db_plugin_state_decode_v1(
  const uint8_t *input,
  size_t input_size,
  db_plugin_state_v1 *state);
db_status db_processor_create_from_state_v1(
  const db_plugin_state_v1 *state,
  double sample_rate_hz,
  uint32_t max_block_frames,
  db_processor **output);
```

The 248-byte wire format is fixed little-endian. All versions, flags, and bypass are `u32`; gains/safety values are two's-complement `i32`; hashes and IDs are raw bytes. Magic `DBSTATE1` occupies 0-7; encoded size `u32` is 8; state/ABI/plan/analyzer/processor/topology `u32` versions are 12/16/20/24/28/32; flags are 36; bypass is 40; requested low/mid/high/output `i32` gains begin at 44; effective gains begin at 60; desired/shortfall/ceiling/target peak `i32` values begin at 76; reference hash is 92-123; target hash 124-155; request ID 156-171; report ID 172-187; active hash 188-219; and 28 reserved zero bytes are 220-247. `DB_ABI_VERSION`, `DB_PLUGIN_STATE_SCHEMA_VERSION`, `DB_PLAN_SCHEMA_VERSION`, analyzer version, `DB_PROCESSOR_VERSION`, and topology version are all exactly 1. Unknown flags, nonzero reserved bytes, trailing bytes, inconsistent requested/effective bypass, hash mismatch, unsafe effective gain, and non-current versions are rejected.

Request/report IDs are opaque UUID bytes in RFC 4122 wire order and are copied verbatim with no integer endian transform. If a corresponding presence bit is clear, all 16 bytes must be zero; if set, at least one byte must be nonzero. Only bits 0 (`HAS_REQUEST_ID`), 1 (`HAS_REPORT_ID`), and 2 (`DEFAULT_IDENTITY`) are legal.

Unless `DEFAULT_IDENTITY` is set, both the reference and target SHA-256 arrays must each contain at least one nonzero byte. Zeroing either source identity is invalid even when the stored active hash is recomputed.

`active_plan_hash_v1` is SHA-256 over exactly 184 bytes. The ASCII domain `doppelbanger.active-plan.v1\0` is bytes 0-27. Little-endian `u32` ABI/plan/analyzer/processor/topology versions are 28/32/36/40/44. Each topology tuple is three little-endian `u32` values `(kind, frequency_millihz, q_millionths)`: low shelf at 48/52/56, bell at 60/64/68, and high shelf at 72/76/80. Effective bypass is `u32` at 84. Effective low/mid/high/output, desired, shortfall, ceiling, and target peak are little-endian `i32` at 88/92/96/100/104/108/112/116. Reference hash is 120-151 and target hash 152-183. Requested values, state schema, flags, and request/report IDs are excluded.

The numeric mapping is exact: all five version fields are 1; topology kinds are `LowShelf=1`, `Bell=2`, `HighShelf=3`; topology V1 is `(1, 120000, 707000)`, `(2, 1000000, 500000)`, `(3, 6000000, 707000)` in that order; analyzer `analysis-v1=1`; processor `linear-eq-gain-v1=1`. There is no implicit padding in the canonical hash input.

`DEFAULT_IDENTITY` is also exact: only flag bit 2 is set; both nested snapshots have `struct_size=32`, `abi_version=1`, bypass off, `reserved=0`, and all gains zero; desired and shortfall are zero; ceiling and target peak are both `-100`; both source hashes and both IDs are all zero; every current version is 1; and the active hash is `17a9bcc804af7ee6f086a4881f585c18b5c2784d4733811d4a367f131dcd1086`. Any state carrying the flag but not this identity is invalid.

`db_processor_create_from_state_v1` does not trust a caller merely because the struct did not come from the decoder. It directly validates outer and nested layouts/versions/reserved fields, legal flags and source identities, requested/effective bypass and safety consistency, ranges, fixed ceiling, and the recomputed active hash. A directly corrupted public C view returns `INVALID_STATE`, leaves `*output` null, and allocates no surviving handle.

Fixture contract:

- Bypass off; low `+150`, mid `-75`, high `+50`, output requested/effective `-100` centidecibels.
- Desired `+200`, shortfall `+300`, ceiling `-100`, target true peak `-200` centidecibels.
- Reference SHA-256 `a0194f5ae9d22f95a2889994bbc90831f9770b70926781e3a560ef73ba372a27`.
- Target SHA-256 `1c7b35c60c8f2202c49783d9cd17114f32efa056f3216ea565f7ac319fef8831`.
- No request/report IDs.
- Canonical active hash `fd848d2dfd4555ea7e50bb9374a26aef8fdff9e18201168c2811421a13495a76`.
- Encoded file SHA-256 `6d7b1e532346d92b631c7835c2936c90c523fde6f0a33baa5334ceb16194cf33`.

- [ ] Add failing tests for the C/Rust view layout; every listed 248-byte wire offset; every listed 184-byte canonical offset/type/value; exact active and default-identity hashes; exact 248-byte fixture/hash; production decode of the fixture; round trip; every truncation; magic/size/version/flag/reserved/range/hash/trailing-byte corruption; optional ID byte/presence rules; either non-default source hash zeroed; default identity state; creation from decoded state; and direct `db_processor_create_from_state_v1` rejection of every corrupted public-view field with null output.
- [ ] Through the native wrapper, run `cargo test --locked --test plugin_state_contract --test ffi_contract`. Expected red.
- [ ] Implement a fixed-buffer encoder/decoder with checked offsets and no serde. Use the existing `sha2` dependency and ordinary byte equality for the non-secret integrity hash. `normalize` works on a local copy and writes `state` only on success; encode validates and fills a local `[u8; 248]` before one success copy; decode writes its output state only after full validation. Nulls keep their existing status, semantic corruption returns `INVALID_STATE`, and any input/output size other than exactly 248 returns `STATE_BUFFER_SIZE`. Every caller-supplied state/output byte remains unchanged on failure.
- [ ] Implement normalization so Rust preserves the validated desired gain, recomputes effective output from requested state and safety metadata, recomputes shortfall as `max(desired - effective, 0)`, then writes the active hash. C++ never reproduces this logic.
- [ ] Implement `examples/generate_plugin_state_fixture.rs` as a thin production-encoder caller. Through the native wrapper, generate the committed fixture with `cargo run --locked --example generate_plugin_state_fixture -- tests/plugin/fixtures/runtime-state-v1-nonbypass.bin`; do not hand-author it. Assert both its encoded-file SHA-256 and production decode.
- [ ] Run focused tests and all Cargo tests through the native wrapper, then the native PowerShell ABI smoke; require the Linux CI Bash ABI smoke result. Expected green.
- [ ] Commit with `git add src include examples/generate_plugin_state_fixture.rs tests/plugin_state_contract.rs tests/plugin/fixtures tests/ffi_contract.rs && git commit -m "feat: add canonical plugin state and plan hash"`.

## Task 10: Validate and collapse bounded VST3 automation queues

**Files:**

- Create: `plugin/src/ParameterContract.h`
- Create: `plugin/src/AutomationQueueReader.h`
- Create: `plugin/src/AutomationQueueReader.cpp`
- Create: `tests/plugin/TestMain.cpp`
- Create: `tests/plugin/FakeParameterChanges.h`
- Create: `tests/plugin/AutomationQueueReaderTests.cpp`
- Create: `tests/plugin/CMakeLists.txt`
- Modify: root `CMakeLists.txt`

Parameter mapping:

```cpp
enum EParams : int {
  kLowEqGain = 0,
  kMidEqGain = 1,
  kHighEqGain = 2,
  kOutputGain = 3,
  kNumPluginParams = 4,
};

inline constexpr Steinberg::Vst::ParamID kHostBypassParam = 65536;
static_assert(kHostBypassParam == iplug::kBypassParam);
```

Reader surface:

```cpp
class AutomationQueueReader final {
public:
  explicit AutomationQueueReader(uint32_t maxFrames);
  AutomationReadResult Read(
    Steinberg::Vst::IParameterChanges* changes,
    int32_t frameCount,
    const db_parameter_snapshot_v1& initial) noexcept;
};
```

Allocate `5 * (maxFrames + 1)` raw points and `maxFrames` merged events during setup, never in `Read`. Validate queue count 0–5 before iteration; reject duplicate/unknown IDs and null queues. Positive blocks accept 0–`frames+1` readable points per queue with finite normalized values in `[0,1]`, nondecreasing offsets, and `0 <= offset < frames`. Zero-frame flush accepts at most one readable offset-zero point per queue. Collapse duplicates within a queue with last raw value winning, then perform a five-way linear merge; all parameters at an offset form one whole requested snapshot. Distinct merged event offsets are strictly increasing. The reader performs only syntactic/range validation; Task 11 previews every merged snapshot through Rust before any DSP and stores the resulting effective snapshot alongside it in the same fixed event storage.

- [ ] Add failing tests for both bounds; unknown/duplicate IDs; null queue; a failing `getPoint`; decreasing/negative/past-end offsets; NaN/infinity/out-of-range values; same-offset last-wins; simultaneous whole snapshots; maximum raw count; zero-frame rules; null changes; and no allocation during `Read`.
- [ ] Through the native wrapper, run `cmake --build --preset windows-msvc-x64-release --target automation_queue_reader_tests` followed by `ctest --preset windows-msvc-x64-release -R AutomationQueueReader --output-on-failure`. Expected red: target/classes absent.
- [ ] Implement fixed storage and the linear five-way merge. Map normalized ordinary parameter values to nearest integer plain centidecibels; bypass uses `value > 0.5`. Do not call Rust or mutate plugin state in the reader.
- [ ] Run the focused CTest 1,000 times with a deterministic randomized valid/malformed corpus. Expected green and stable allocation count zero.
- [ ] Commit with `git add plugin/src/ParameterContract.h plugin/src/AutomationQueueReader.* tests/plugin CMakeLists.txt && git commit -m "plugin: bound VST3 automation ingestion"`.

## Task 11: Build the production UI-NONE VST3 over the Rust processor

**Files:**

- Create: `plugin/config.h`
- Create: `plugin/CMakeLists.txt`
- Create: `plugin/resources/resource.h`
- Create: `plugin/src/RustProcessor.h`
- Create: `plugin/src/RustProcessor.cpp`
- Create: `plugin/src/AtomicPluginState.h`
- Create: `plugin/src/DoppelbangerPlugin.h`
- Create: `plugin/src/DoppelbangerPlugin.cpp`
- Create: `tests/plugin/RustProcessorTests.cpp`
- Create: `tests/plugin/PluginLifecycleTests.cpp`
- Modify: `tests/plugin/CMakeLists.txt`
- Modify: root `CMakeLists.txt`

Plugin configuration is fixed:

```cpp
#define PLUG_NAME "Doppelbanger"
#define PLUG_MFR "William Hayden"
#define PLUG_VERSION_HEX 0x00000100
#define PLUG_VERSION_STR "0.1.0"
#define PLUG_UNIQUE_ID 'Dbgr'
#define PLUG_MFR_ID 'Wshy'
#define PLUG_CLASS_NAME DoppelbangerPlugin
#define PLUG_CHANNEL_IO "2-2"
#define PLUG_LATENCY 0
#define PLUG_TYPE 0
#define PLUG_DOES_MIDI_IN 0
#define PLUG_DOES_MIDI_OUT 0
#define PLUG_DOES_MPE 0
#define PLUG_DOES_STATE_CHUNKS 1
#define PLUG_HAS_UI 0
#define VST3_SUBCATEGORY "Fx|Mastering"
```

CMake target:

```cmake
iplug_add_plugin(Doppelbanger
  SOURCES ${DOPPELBANGER_PLUGIN_SOURCES}
  FORMATS VST3
  LINK doppelbanger_rust
  DEFINES SAMPLE_TYPE_FLOAT
  UI NONE)
```

Class surface:

```cpp
class DoppelbangerPlugin final : public iplug::Plugin {
public:
  explicit DoppelbangerPlugin(const iplug::InstanceInfo& info);
  void ProcessBlock(iplug::sample** inputs,
                    iplug::sample** outputs,
                    int nFrames) override;
  void OnReset() override;
  void OnRestoreState() override;
  bool SerializeState(iplug::IByteChunk& chunk) const override;
  int UnserializeState(const iplug::IByteChunk& chunk, int startPos) override;
#if defined(VST3_API)
  Steinberg::tresult PLUGIN_API setupProcessing(
    Steinberg::Vst::ProcessSetup& setup) override;
  Steinberg::tresult PLUGIN_API setActive(
    Steinberg::TBool state) override;
  Steinberg::tresult PLUGIN_API setProcessing(
    Steinberg::TBool state) override;
  Steinberg::tresult PLUGIN_API process(
    Steinberg::Vst::ProcessData& data) override;
  Steinberg::tresult PLUGIN_API canProcessSampleSize(
    Steinberg::int32 symbolicSampleSize) override;
#endif
};
```

Processing sequence:

1. At the block boundary, inspect at most one stable pending DAW-state generation from Task 12. If the Rust processor is healthy, call the no-allocation runtime restore; success acknowledges the generation but clears the malformed-restore latch only when the applied component epoch is strictly newer than its malformed-call watermark. `PANIC` or `PROCESS_FAULT` sets the wrapper DSP-fault latch, leaves the generation unacknowledged, zeros the complete current positive output block, and returns.
2. If the malformed-restore or DSP-fault latch was already set on entry, dry-copy the complete positive block and perform no automation/base/Rust DSP call. Only explicit non-realtime reset clears the Rust and wrapper DSP-fault latches; the next block may then apply any retained pending state.
3. Otherwise, derived `process` syntactically validates/collapses every raw automation queue, then calls non-mutating `db_processor_preview_parameters_v1` for every merged snapshot and stores requested/effective pairs. `INVALID_PARAMETER` dry-copies this block with no DSP and no latch. `PANIC` or `PROCESS_FAULT` sets the wrapper DSP-fault latch, zeros the complete current positive block, and returns.
4. Zero frames apply at most one fully previewed merged snapshot, call no base `process` and no Rust process, and advance no ramp/filter state.
5. A malformed or safety-invalid positive block dry-copies input to output, keeps the prior target, records one bounded error, and returns without base/Rust processing.
6. A valid positive block copies `ProcessData`, sets only `inputParameterChanges=nullptr`, and calls qualified `IPlugVST3::process(sanitized)` exactly once. iPlug2's internal DSP-bypass field remains false for the plugin's entire lifetime and is never authoritative host/state data.
7. iPlug2 calls `DoppelbangerPlugin::ProcessBlock` once. It walks the fully previewed events, calls the Rust whole-snapshot setter at each offset, and calls the separate-input/output Rust process for each nonempty interval.
8. Any unexpected `PANIC`/`PROCESS_FAULT` from runtime restore, preview, setter, or process zeros both complete host output channels for the first affected positive block and latches subsequent dry bypass until explicit non-realtime reset. Requested/effective parameter state is published only through lock-free atomics.

Processor/table/scratch allocation occurs in VST3 `setupProcessing` only while both component-active and processing-active flags are false; stopped processing while the component remains Activated is still rejected. `OnReset` only resets existing DSP history/process-fault state and is a no-op when preparation has not completed; it never clears the separate malformed-component-state latch. Reject unsupported rates, symbolic sizes other than `kSample32`, zero/max blocks above 8192, and invalid lifecycle state before mutation. Build a complete candidate processor/queue/scratch set first, call qualified base `setupProcessing` with defined ordering, and commit the candidate only on base success; failure preserves the prior valid preparation. `setActive` and `setProcessing` each call their qualified base and change their separate lock-free flag only on success. `canProcessSampleSize` returns true only for `kSample32`.

Register four `InitInt` ordinary parameters in centidecibels, then attach a display function that formats signed dB with two decimals. iPlug2 supplies the fifth/bypass parameter. `AtomicPluginState` is the only authoritative persistence publication domain: from Task 11 onward it contains the complete 240-byte state view (initially the exact default identity), and audio automation republishes a whole view with updated requested/effective fields. It uses only lock-free atomic words/generations. There is no independent parameter snapshot that `getState` later combines with plan metadata.

- [ ] Add failing wrapper/lifecycle tests for distinct versus full/mixed aliased buffers; all-event preview before any DSP; zero DSP calls for a late safety-invalid event; injected restore/preview/setter/process panic statuses all causing first-block silence then dry bypass; pending restore retained across restore panic and applied only after reset; one base `ProcessBlock` call; stock ingestion skipped; Rust call count per effective segment; exact offset behavior; iPlug DSP bypass permanently false while Rust owns bypass; 32-bit-only advertisement; one stereo bus pair; setup accepted only after `setActive(false)` and rejected when Processing or merely Activated; separate base-failure rollback for `setActive`, `setProcessing`, and setup; every supported/unsupported sample rate; zero/8192/8193 max block; `OnReset` before prepare; zero allocation in reset/process; and parameter metadata/count/IDs/steps/defaults.
- [ ] Through the native wrapper, run `cmake --build --preset windows-msvc-x64-release --target Doppelbanger-vst3 plugin_lifecycle_tests`. Expected red.
- [ ] Implement `RustProcessor` as the sole owner of one `db_processor*`, with move disabled and destructor calling destroy off the callback. `Prepare` uses `db_processor_create_from_state_v1`; preview/setter/runtime-restore/process/reset forward status exactly.
- [ ] Implement the plugin sequence above. Do not call the stock iPlug2 parameter ingestion because `inputParameterChanges` is null in the qualified base call.
- [ ] Assert the bundle path is `build/windows-msvc-x64-release/out/Doppelbanger.vst3/Contents/x86_64-win/Doppelbanger.vst3`, inspect the module through the native wrapper with `dumpbin /headers`, and reject any WebView/Node/React resource.
- [ ] Through the native wrapper run `ctest --preset windows-msvc-x64-release -L plugin-core --output-on-failure` and all Cargo tests, then run the native PowerShell ABI smoke and require the Linux CI Bash result. Expected green.
- [ ] Commit with `git add plugin tests/plugin CMakeLists.txt && git commit -m "plugin: build native UI-NONE VST3 over Rust"`.

## Task 12: Integrate production state with VST3 lifecycle and fixture restore

**Files:**

- Create: `plugin/src/PluginState.h`
- Create: `plugin/src/PluginState.cpp`
- Create: `tests/plugin/PluginStateTests.cpp`
- Modify: `plugin/src/AtomicPluginState.h`
- Modify: `plugin/src/DoppelbangerPlugin.h`
- Modify: `plugin/src/DoppelbangerPlugin.cpp`
- Modify: `tests/plugin/CMakeLists.txt`

`PluginState` never decodes mastering fields itself. It copies exactly 248 bytes between `IByteChunk` and the Rust decoder/encoder, takes one complete view from the sole `AtomicPluginState` generation domain, and asks Rust to normalize/recompute effective values, shortfall, and hash before save. It never combines independently sampled parameters and plan metadata.

The final class overrides VST3 `getState(IBStream*)`, component `setState(IBStream*)`, and controller `setComponentState(IBStream*)` rather than delegating bypass serialization to iPlug2. `getState` writes the 248-byte Rust encoding followed by one 32-bit VST3 bypass trailer read from the same stable atomic requested-state snapshot. iPlug2's internal DSP-bypass field remains false. Component `setState` reads both pieces, requires trailer/state bypass agreement, decodes/normalizes through Rust off the callback, and publishes the complete current state plus exactly one pending-runtime generation. Controller `setComponentState` independently validates the component stream and synchronizes only the controller's generic parameter view; it never publishes/acknowledges a runtime generation, changes either audio latch, or snaps/resets DSP. Thus the host's normal `setState` then `setComponentState` sequence produces one processor restore even if automation runs between the calls.

```cpp
Steinberg::tresult PLUGIN_API getState(Steinberg::IBStream* stream) override;
Steinberg::tresult PLUGIN_API setState(Steinberg::IBStream* stream) override;
Steinberg::tresult PLUGIN_API setComponentState(
  Steinberg::IBStream* stream) override;
```

Active state restore is valid because Steinberg permits component [`setState` and `getState` in the Processing state](https://steinbergmedia.github.io/vst3_doc/vstinterfaces/classSteinberg_1_1Vst_1_1IComponent.html). `AtomicPluginState` stores the 240-byte C view as 60 lock-free `std::atomic<uint32_t>` words; signed fields use bit-preserving conversion and byte arrays use fixed word packing. A lock-free sequence word is the writer token. Serialized off-callback state methods first raise an atomic snapshot gate, wait for at most one fixed 60-word audio publication to finish, acquire the token, perform one coherent read/write, release the token, and lower the gate. While the gate is raised, the audio thread skips publication; otherwise it makes one token CAS at block end and skips only state publication if it loses. This makes `getState` one-pass after a bounded in-flight publish rather than a retry loop that dense automation can starve.

The pending-restore mailbox uses two atomic-word banks and a published generation; one bounded audio-thread read either observes a stable new bank or defers it to the next block. Every successful component `setState` increments a monotonic component epoch, publishes the complete authoritative view under that epoch, and attaches the same epoch to its pending bank. A malformed component call records the current epoch as a malformed-call watermark without publishing a generation. The dry latch clears only after a successfully applied pending epoch strictly greater than that watermark; an older/equal queued valid state may apply internally but remains inaudible and cannot forgive the later malformed call. Epoch increment is checked; exhaustion fails closed rather than wrapping.

A block captures the epoch it actually processes. Its block-end whole-state publication is allowed only when that captured epoch still equals the current component epoch and no newer pending generation exists; otherwise it skips publication. A successful runtime restore adopts the pending epoch before any later audio publication. Thus a block begun on state A cannot overwrite or hybridize a mid-block component state B.

On a healthy processor, the next block calls `db_processor_restore_runtime_v1` with only already-decoded safety/requested values, resets/snaps the processor with no allocation/hash/I/O, and acknowledges only a successful application. A DSP-faulted processor rejects the runtime restore, leaves the generation pending, and remains dry until explicit non-realtime reset; active `setState` cannot clear that fault. `is_always_lock_free` assertions cover word, gate, token, epoch, and generation atomics; latest unpublished component restore wins. The audio thread never spins, waits, allocates, destroys a processor, or hashes.

- [ ] Add failing tests for direct production decode of the committed fixture; IByteChunk round trip; exact custom trailer from the same whole-state generation; trailer/state bypass agreement; internal iPlug bypass permanently false; continuous audio writers plus deterministic interleaving proving `getState` returns one non-hybrid generation within a fixed 100 ms test deadline; truncation/corruption; active component restore acceptance and next-block snap; normal component/controller restore order producing exactly one DSP snap; automation between `setState`/`setComponentState` not being erased; `setComponentState` changing controller values only; a gate collision making audio skip publication without spinning; an A block paused after DSP then mid-block `setState(B)` then resumed publication leaving immediate `getState` exactly B; latest component epoch/generation wins; no allocation/hash during audio-thread consume; malformed component state followed by setup/`OnReset`/activation still producing zero wet calls for at least three positive blocks; queue valid B then call malformed C before consumption, apply B internally but remain dry for three blocks, then apply strictly newer valid D and only then clear; epoch exhaustion failing closed; no publication/parameter change on failure; and reset-only DSP-fault recovery.
- [ ] Through the native wrapper, run `ctest --preset windows-msvc-x64-release -R PluginState --output-on-failure`. Expected red.
- [ ] Implement the state adapter, atomic word/generation/epoch mailbox, malformed-call watermark, and derived VST3 state wrappers. A malformed component restore returns `kResultFalse`, publishes no generation or generic-parameter change, retains the previous valid state, records the current epoch, and latches dry bypass across setup, `OnReset`, activation, and processing until a strictly newer valid component epoch successfully applies. Routine lifecycle/DSP reset and older/equal pending states never clear this malformed-state latch. A valid active restore may clear only that latch; it cannot clear a DSP process fault, and its generation remains pending until reset. Never reject a valid restore merely because processing is active.
- [ ] Through the native wrapper, run the focused test and `ctest --preset windows-msvc-x64-release -L plugin-core --output-on-failure`. Expected green.
- [ ] Commit with `git add plugin/src/PluginState.* plugin/src/AtomicPluginState.h plugin/src/DoppelbangerPlugin.* tests/plugin && git commit -m "plugin: persist canonical runtime state"`.

## Task 13: Prove the built VST3 through an actual headless host

**Files:**

- Create: `tests/plugin/host/Vst3HostFixture.h`
- Create: `tests/plugin/host/Vst3HostFixture.cpp`
- Create: `tests/plugin/host/DoppelbangerVst3HostTests.cpp`
- Create: `tests/plugin/host/RealtimeAllocationProbe.cpp`
- Create: `tests/plugin/fixtures/parity-v1.json`
- Modify: `tests/plugin/CMakeLists.txt`
- Modify: `.github/workflows/ci.yml`

Load the built bundle through the pinned Steinberg hosting classes. Do not directly instantiate `DoppelbangerPlugin` for this gate. The host fixture initializes component/controller, activates exactly one stereo bus pair, negotiates 32-bit processing, supplies real `IParameterChanges`, saves/restores `IBStream` state, and terminates every interface.

Named cases:

- `StableParameterMetadata`: exactly five host parameters, IDs 0/1/2/3/65536, step counts 600/600/600/2400/1, and bypass has `kIsBypass`.
- `ProcessParityMatrix`: rates 44.1/48/88.2/96/192 kHz; blocks 1/17/64/511/8192; distinct, full-alias, and both mixed corresponding-alias buffer modes; identity, fixture, every individual parameter, and simultaneous changes.
- `SampleOffsetAutomation`: points at 0, 5, 5, and 9; same-offset last-wins; one plugin `ProcessBlock`; one Rust process call per nonempty segment; direct C ABI reference output.
- `RawAutomationLimits`: all malformed/boundary queue contracts and no DSP call on failure.
- `ZeroFrameFlush`: null audio, target persists, next positive block starts tick 1.
- `StateRoundTripOffline`: fixture output before/after module unload with Compose project down is identical.
- `StateRoundTripWhileProcessing`: call `getState`, then restore a different valid fixture while active; the next stable block boundary snaps to it, the atomic bypass trailer agrees, and audio-thread allocation/hash counts remain zero.
- `PairedComponentControllerRestore`: follow Steinberg's component `setState` then controller `setComponentState` sequence, force one audio/automation block between the calls, and prove exactly one runtime generation/snap; controller synchronization may update its generic view but performs no second DSP publication and does not erase the intervening processor automation/smoothing state.
- `ResetLatencyMatrix`: zero reported/measured latency, reset snap/history semantics, every supported rate.
- `CallbackAllocations`: after lifecycle warmup, setter/process/reset and iPlug2 traversal allocate/deallocate zero times in the instrumented test module.

Float output is bit-exact against direct Rust unless the test demonstrates a specific framework copy/conversion; because 64-bit processing is not advertised, there is no double tolerance.

- [ ] Add the host fixture and failing named tests. Through the native wrapper, run `ctest --preset windows-msvc-x64-release -L plugin-headless --output-on-failure`. Expected red.
- [ ] Implement module loading, host interfaces, fake queues, state stream, and deterministic generated input. Ensure every test verifies unchanged host `ProcessData`, bus objects, channel-pointer arrays, and `ProcessContext` around the call.
- [ ] Add a test-only plugin build definition that traps allocation while the callback flag is set. Warm lifecycle caches before enabling it; fail on the first callback allocation or deallocation.
- [ ] Run the full headless label, then repeat it 100 times. Expected green with no leaked module/interfaces and identical outputs.
- [ ] Add a `windows-vst3` CI job: recursive submodules, pinned Rust/CMake/Ninja, existing runner MSVC 19.44 compatibility check, CMake workflow, Cargo tests, and plugin headless CTest. Do not claim the mutable hosted runner as release-toolchain evidence.
- [ ] Commit with `git add tests/plugin .github/workflows/ci.yml && git commit -m "test: prove hosted VST3 parity and lifecycle"`.

## Task 14: Gate the bundle with Steinberg Validator and pluginval 10

**Files:**

- Create: `scripts/build_validator.ps1`
- Create: `scripts/install_validation_tools.ps1`
- Create: `scripts/validate_vst3.ps1`
- Create: `tests/tooling/validate_vst3_contract.ps1`
- Create: `docs/validation/VST3_VALIDATION.md`
- Modify: `tools/plugin-dependencies.lock.json`
- Modify: `.gitignore`

Validation pins:

- Steinberg Validator is built from the pinned VST3 SDK/meta gitlinks already in `third_party/vst3sdk` and invoked as `validator.exe -e build\windows-msvc-x64-release\out\Doppelbanger.vst3`.
- pluginval Windows 1.0.4 is downloaded only by the install script from `https://github.com/Tracktion/pluginval/releases/download/v1.0.4/pluginval_Windows.zip`, exactly 2,408,590 bytes, SHA-256 `c08e61ce3b96db41636f8ec7e76f4c7e2c13ebdac7fa1b5a1f52b4f32ec715ab`, then invoked as `pluginval.exe --strictness-level 10 build\windows-msvc-x64-release\out\Doppelbanger.vst3`.
- `validate_vst3.ps1` never downloads. It requires explicit existing bundle/validator/pluginval paths and writes tool versions, file hashes, commit/submodule SHAs, stdout/stderr, and exit codes beneath an explicit ignored report directory.

- [ ] Add a contract test that gives both validators an invalid empty bundle and requires nonzero exit/report records; gives the validation script a mismatched pluginval checksum and requires rejection before execution; and scans the validation script for network calls.
- [ ] Run `powershell.exe -NoProfile -File .\tests\tooling\validate_vst3_contract.ps1`. Expected red.
- [ ] Implement the SDK validator build in its own binary directory so its CMake targets never collide with iPlug2's manually compiled SDK sources. Compute canonical absolute `$validatorOut = Join-Path (Resolve-Path .).Path 'build\validator-windows-x64\bin\Release'`; through `scripts/run_native_tool.ps1`, configure with `cmake -S third_party/vst3sdk -B build/validator-windows-x64 -G Ninja -DCMAKE_BUILD_TYPE=Release -DSMTG_ENABLE_VSTGUI_SUPPORT=OFF -DSMTG_ENABLE_VST3_PLUGIN_EXAMPLES=OFF -DSMTG_ENABLE_VST3_HOSTING_EXAMPLES=ON "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY:PATH=$validatorOut"`, then build target `validator`. Assert exactly `$validatorOut\validator.exe` exists and is PE32+ AMD64. The pinned executable must return 0 for `--version`; its intentional `--help` contract is usage text on stdout/stderr with exit 1, which is accepted only for that probe.
- [ ] Implement checksum-verified pluginval installation and the network-free validation runner. The runner launches both validator executables only through `scripts/run_native_tool.ps1`, which verifies their PE/provenance before execution.
- [ ] Run:

```powershell
$bundle = 'build\windows-msvc-x64-release\out\Doppelbanger.vst3'
$validator = 'build\validator-windows-x64\bin\Release\validator.exe'
$pluginval = "$env:LOCALAPPDATA\Programs\doppelbanger-devtools\pluginval-1.0.4\pluginval.exe"
powershell.exe -NoProfile -File .\scripts\validate_vst3.ps1 `
  -Bundle $bundle -Validator $validator -PluginVal $pluginval `
  -ReportDirectory 'var\validation\m1-vst3\validators'
```

Expected: both exit 0; Validator extensive tests and pluginval strictness 10 pass.

- [ ] Rerun the invalid-bundle contract and scan reports for the current Windows username, repo path, and credentials; the retained summary must be sanitized.
- [ ] Commit with `git add scripts tools/plugin-dependencies.lock.json tests/tooling docs/validation .gitignore && git commit -m "test: gate VST3 with official validators"`.

## Task 15: Reproduce from a clean clone and complete Ableton's UI-NONE proof

**Files:**

- Create: `scripts/stage_vst3.ps1`
- Create: `tests/tooling/stage_vst3_contract.ps1`
- Create: `docs/validation/ABLETON_UI_NONE_VST3.md`
- Create: `validation/templates/ableton-ui-none-v1.md`
- Modify: `docs/VALIDATION.md`

The staging script accepts an explicit bundle and explicit destination, defaults to `-WhatIf`, rejects a destination outside `%LOCALAPPDATA%\Programs\Common\VST3`, refuses an existing destination unless `-Replace` is supplied, and copies any replaced bundle to a timestamped ignored backup before writing. It never touches `C:\Program Files\Common Files\VST3`.

- [ ] Add the failing staging contract for source validation, destination containment, `-WhatIf`, refusal to overwrite, backup-before-replace, and PE/bundle layout verification.
- [ ] Run `powershell.exe -NoProfile -File .\tests\tooling\stage_vst3_contract.ps1`. Expected red.
- [ ] Implement the script and rerun the contract. Expected green without copying anything in `-WhatIf` mode.
- [ ] Commit the script/checklist/template with `git add scripts/stage_vst3.ps1 tests/tooling/stage_vst3_contract.ps1 docs/validation validation/templates docs/VALIDATION.md && git commit -m "docs: define Ableton headless VST3 acceptance"`.
- [ ] Require the implementation source status to be empty, record its `HEAD`, and create a new timestamped NTFS clone with `git clone --no-hardlinks --recurse-submodules`. Verify it is William-owned, its `HEAD` exactly matches, every recursive submodule SHA matches the dependency lock, and status is empty. Install no repository-local hidden dependency; run the strict doctor, then run the CMake workflow, all Cargo tests, native PowerShell ABI tests, plugin CTests, and validators through the checked native wrapper. Store sanitized evidence under the original clone's `var/validation/m1-clean-clone/`.
- [ ] Stage the exact validated bundle to `%LOCALAPPDATA%\Programs\Common\VST3\Doppelbanger.vst3`, recording its SHA-256. If Ableton 12.2.5 does not scan that standard per-user location, configure that same directory once as Live's custom VST3 folder.
- [ ] In Ableton Live 12.2.5, record: scan/load; exactly five generic parameters and correct ranges; stereo playback; bit-exact settled bypass; legal automation of every parameter; simultaneous/opposing automation; fixture values low `+1.50`, mid `-0.75`, high `+0.50`, output `-1.00`, bypass off; save; close Live; stop only the Doppelbanger Compose project through the native Docker wrapper; reopen; verify exact parameter/state hash; play; offline render; remove/reinsert; change supported sample rate; and compare the render with the headless fixture.
- [ ] Record the same bundle in Ableton beta 12.4.5b9 as secondary evidence, but keep 12.2.5 Suite as the Milestone 1 acceptance host.
- [ ] Store the checklist, sanitized screenshots, hashes, Ableton versions, and comparison summary under ignored `var/validation/m1-vst3/ableton/`. Do not commit the `.als` project or audio.

## Task 16: Run final gates and independent reviews

**Files:**

- Modify only files required by validated review findings.

- [ ] Run the strict native doctor and save JSON.
- [ ] Run `git diff --check`; through the native wrapper run `cargo fmt --all -- --check`, `cargo clippy --locked --all-targets -- -D warnings`, and `cargo test --locked --all-targets`.
- [ ] Run the native PowerShell ABI smoke, isolated API integration, and through the native wrapper run `cargo run --locked --release --bin doppelbanger -- benchmark --corpus var/albumdb/pairs --output var/validation/albumdb-fast.json`. Require the Linux CI job's Bash ABI smoke; do not invoke Bash on Windows.
- [ ] Run native Git `git submodule status --recursive`; through the native wrapper run the dependency contract, `cmake --workflow --preset windows-msvc-x64-release`, and `ctest --preset windows-msvc-x64-release -L plugin --output-on-failure`; then run the wrapped validation script from Task 14.
- [ ] Compare the implementation line-by-line with the approved design and this plan. Explicitly check: Windows/WSL boundary, one Rust DSP path, five IDs, sample-offset/rate limits, zero-frame semantics, whole-block fault behavior, 10 ms transitions, output safety, state fixture/hash, service-off restore, UI NONE, no callback allocation, and clean-clone reproduction.
- [ ] Ask one independent reviewer for specification/roadmap compliance and a second for code quality, realtime safety, ABI/state compatibility, and test sufficiency. Resolve every Critical/Important finding with a new failing test and focused fix; rerun the affected and full gates.
- [ ] Build a PowerShell pattern list from split literals (`'TB'+'D'`, `'TO'+'DO'`, `'FIX'+'ME'`, `'implement '+'later'`, `'similar '+'to'`, and `'appropriate error '+'handling'`), run `rg -n ($patterns -join '|')` across tracked source/docs, and remove every incomplete marker introduced by this work. Existing unrelated historical text requires an explicit allowlist entry in the final evidence.
- [ ] Verify `git status --short`, `git log --oneline --decorate -20`, and that no evidence/private artifact is tracked. Do not push until William separately authorizes publication.

## Milestone 1 Completion Criteria

Milestone 1 is complete only when all of the following are true:

- The strict doctor proves a native Windows x86_64 MSVC toolchain and the build contains no WSL/GNU artifact.
- A clean owner-correct clone reproduces the Rust static library and `Doppelbanger.vst3/Contents/x86_64-win/Doppelbanger.vst3` without configure-time downloads.
- All Rust, C11, C++17, automation, state, hosted VST3, reset, sample-rate, partition, alias, fault, and allocation tests pass.
- The actual hosted VST3 matches direct shared Rust output for the declared matrix and exact sample offsets.
- Steinberg Validator extensive mode and pluginval strictness 10 both exit 0.
- Ableton Suite 12.2.5 loads the exact bundle, exposes five generic parameters, automates them, saves/reopens the non-bypass fixture with the service stopped, and renders the same output.
- The branch is review-clean, contains no React/WebView implementation yet, and remains local until publication is explicitly requested.
