# Native Windows Distribution Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make native VST3 compilation independent of WSL, Docker, Node, and the developer state plane, retain an explicit orthogonal Docker/WSL integration profile, and encode the dependency-closure and clean-target gates that later release tasks must execute.

**Architecture:** `doctor_windows.ps1` exposes orthogonal `HeadlessVst3`, `StatePlaneIntegration`, and diagnostic-only `Compatibility` profiles. `run_native_tool.ps1` selects exactly one required profile from the requested tool, rejects Node-family tools until a future React editor profile exists, and never imports MSVC state for Docker. Canonical architecture, decision, workstation, and roadmap documents make the public native/container-free boundary testable through dependency-closure and clean-target gates.

**Tech Stack:** Windows PowerShell 5.1, JSON probe fixtures, Rust documentation contract tests, MSVC Build Tools 2022, Rust MSVC, CMake, Ninja, Docker Desktop/Compose for developer integration only, Git.

## Global Constraints

- Work only in `C:\Users\William\Documents\Codex\doppelbanger-native` on `codex/windows-headless-vst3`.
- Prefix every repository shell command with `rtk`.
- Use native Windows PowerShell and Windows executables for compilation and tests. Do not invoke a compiler, Cargo, CMake, Ninja, or validator through WSL.
- WSL executable metadata may be inspected without launching a distribution only for `StatePlaneIntegration` and diagnostic-only `Compatibility`. `HeadlessVst3` must not resolve WSL. WSL is never a product prerequisite.
- Never remove, overwrite, reconfigure, enumerate, or read the contents of an Ableton installation, library, preference, project, or plugin folder during these tasks. `Compatibility` may perform exact-root `Test-Path` presence checks only; native build and state-plane profiles must not probe Ableton.
- Do not upgrade Docker Desktop. `install_windows_toolchain.ps1` must run without `-UpgradeDockerDesktop` unless William separately authorizes that mutation after a preservation manifest is reviewed.
- Preserve the existing unstaged Task 2 installer work in `scripts/install_windows_toolchain.ps1`, `tests/tooling/windows_installer_contract.ps1`, and the installer section of `docs/WINDOWS_WORKSTATION.md` until Task 4.
- Only the root/operator agent may stage or commit. Implementers and reviewers must leave all changes unstaged.
- Every implementation task uses a fresh implementer, then a specification reviewer, then a code-quality reviewer. Resolve review findings before the root/operator commits that task.
- Never push. Publication requires separate authorization.
- The approved design is `docs/superpowers/specs/2026-08-05-windows-distribution-boundary-design.md`; it is normative when this plan and implementation details appear to conflict.

---

## Task 1: Split native-build and state-plane doctor profiles

**Files:**

- Modify: `scripts/doctor_windows.ps1`
- Modify: `tests/tooling/windows_toolchain_contract.ps1`
- Modify: `tests/tooling/fixtures/windows-native-valid.json`

### Step 1: Add failing pure-validation profile tests

- [ ] Add this helper beside the existing assertion helpers so error ordering is contractual:

```powershell
function Assert-FirstDiagnosticCode {
    param($Result, [string]$Expected, [string]$Message)
    $actual = if (@($Result.Errors).Count -gt 0) { [string]$Result.Errors[0].code } else { '' }
    Assert-Equal $actual $Expected $Message
}

function Assert-FirstDiagnosticMessageLike {
    param($Result, [string]$Pattern, [string]$Message)
    $actual = if (@($Result.Errors).Count -gt 0) { [string]$Result.Errors[0].message } else { '' }
    Assert-True ($actual -match $Pattern) "$Message (first diagnostic: $actual)"
}
```

- [ ] Build fixture variants with the existing `Write-Variant` helper and assert all of the following in `tests/tooling/windows_toolchain_contract.ps1`:

```powershell
$headlessNoState = Write-Variant {
    param($p)
    $p.wsl_present = $false
    $p.wsl_version = ''
    $p.node_version = ''; $p.node_platform = ''; $p.node_arch = ''; $p.npm_version = ''
    $p.docker_desktop_version = ''; $p.docker_desktop_build = ''
    $p.docker_cli_version = ''; $p.docker_engine_version = ''; $p.docker_compose_version = ''
    $p.docker_running = $false; $p.docker_context = ''
    $p.docker_server_os = ''; $p.docker_server_arch = ''
    $p.binaries = @($p.binaries | Where-Object { $_.name -notin @('node', 'docker', 'docker-compose') })
}
$headlessProbe = Get-Content -LiteralPath $headlessNoState -Raw | ConvertFrom-Json
$headless = Test-NativeWindowsProbe -Probe $headlessProbe -Lock $lock -Profile 'HeadlessVst3'
Assert-True $headless.Success 'HeadlessVst3 ignores absent WSL, Docker, Node, and npm'

$headlessOldWsl = Write-Variant {
    param($p)
    $p.wsl_present = $true
    $p.wsl_version = '1.2.3.4'
}
$headlessProbe = Get-Content -LiteralPath $headlessOldWsl -Raw | ConvertFrom-Json
$headless = Test-NativeWindowsProbe -Probe $headlessProbe -Lock $lock -Profile 'HeadlessVst3'
Assert-True $headless.Success 'HeadlessVst3 ignores an installed old WSL executable'

$headlessUnknownWsl = Write-Variant {
    param($p)
    $p.wsl_present = $true
    $p.wsl_version = ''
}
$headlessProbe = Get-Content -LiteralPath $headlessUnknownWsl -Raw | ConvertFrom-Json
$headless = Test-NativeWindowsProbe -Probe $headlessProbe -Lock $lock -Profile 'HeadlessVst3'
Assert-True $headless.Success 'HeadlessVst3 ignores an installed WSL executable with unknown version'
```

- [ ] Retain the existing WSL environment and ancestor fixtures under `HeadlessVst3`; both must still fail first with `DBDOC_WSL_FORBIDDEN`.

- [ ] Add a state-plane-only fixture by blanking all compiler/build fields while retaining the exact WSL/Docker fields from `windows-native-valid.json`:

```powershell
$stateOnly = Write-Variant {
    param($p)
    $p.compiler = ''; $p.compiler_version = ''
    $p.vs_product_version = ''; $p.vs_installation_version = ''; $p.vs_instance_path = ''
    $p.msvc_component = ''; $p.windows_sdk_component = ''; $p.windows_sdk_target = ''
    $p.rust_version = ''; $p.rust_target = ''; $p.rust_toolchain_root = ''
    $p.rust_components = [pscustomobject]@{ cargo=$false; rustfmt=$false; clippy=$false; metadata_valid=$false; installer_version=''; channel_version='' }
    $p.cmake_version = ''; $p.ninja_version = ''
    $p.vsdevcmd = [pscustomobject]@{ path=''; import_args=''; include=''; lib=''; windows_sdk_dir=''; windows_sdk_version=''; vctools_install_dir='' }
    $p.binaries = @($p.binaries | Where-Object { $_.name -in @('docker', 'docker-compose') })
}
$stateProbe = Get-Content -LiteralPath $stateOnly -Raw | ConvertFrom-Json
$state = Test-NativeWindowsProbe -Probe $stateProbe -Lock $lock -Profile 'StatePlaneIntegration'
Assert-True $state.Success 'StatePlaneIntegration does not require a compiler or native build tools'
```

- [ ] Add state-plane WSL precedence tests:

```powershell
$stateNoWsl = Write-Variant { param($p); $p.wsl_present=$false; $p.wsl_version='' }
$probe = Get-Content -LiteralPath $stateNoWsl -Raw | ConvertFrom-Json
$result = Test-NativeWindowsProbe -Probe $probe -Lock $lock -Profile 'StatePlaneIntegration'
Assert-FirstDiagnosticCode $result 'DBDOC_WSL_REQUIRED' 'State-plane missing WSL is diagnosed before Docker'

$stateUnknownWsl = Write-Variant { param($p); $p.wsl_present=$true; $p.wsl_version='' }
$probe = Get-Content -LiteralPath $stateUnknownWsl -Raw | ConvertFrom-Json
$result = Test-NativeWindowsProbe -Probe $probe -Lock $lock -Profile 'StatePlaneIntegration'
Assert-FirstDiagnosticCode $result 'DBDOC_WSL_VERSION_UNKNOWN' 'State-plane unknown WSL version is stable'

$stateOldWsl = Write-Variant { param($p); $p.wsl_present=$true; $p.wsl_version='1.2.3.4' }
$probe = Get-Content -LiteralPath $stateOldWsl -Raw | ConvertFrom-Json
$result = Test-NativeWindowsProbe -Probe $probe -Lock $lock -Profile 'StatePlaneIntegration'
Assert-FirstDiagnosticCode $result 'DBDOC_TOOL_VERSION_DRIFT' 'State-plane old WSL is diagnosed before Docker'
```

- [ ] Place every new test that calls `Write-Variant` inside the existing outer `try` block after `$script:testTemp = $testTemp`. Do not call `Write-Variant` in the pre-temp fixture section.

- [ ] Create explicit variants for Docker absent (`DBDOC_TOOL_MISSING`), engine stopped (`DBDOC_DOCKER_STOPPED`), Docker-only pinned-version drift (`DBDOC_TOOL_VERSION_DRIFT`), a nonempty Compose winner outside the locked path (`DBDOC_DOCKER_PLUGIN_SHADOW`), malformed/unsafe plugin configuration (`DBDOC_DOCKER_PLUGIN_CONFIG_INVALID`), and invalid checked-in Compose configuration (`DBDOC_COMPOSE_CONFIG_INVALID`). Each variant passes `HeadlessVst3` and fails `StatePlaneIntegration` with the named first code. Do not reuse `windows-version-drift-invalid.json` for Docker drift because it represents native CMake drift.

- [ ] Add pairwise/cumulative variants to pin the complete state-plane order: plugin-config fault + shadow; shadow + missing; missing + drift; drift + invalid checked-in Compose configuration; invalid checked-in Compose configuration + stopped engine; stopped engine + wrong context; wrong context + wrong server OS/architecture. The exact order is `DBDOC_DOCKER_PLUGIN_CONFIG_INVALID`, `DBDOC_DOCKER_PLUGIN_SHADOW`, `DBDOC_TOOL_MISSING`, `DBDOC_TOOL_VERSION_DRIFT`, `DBDOC_COMPOSE_CONFIG_INVALID`, `DBDOC_DOCKER_STOPPED`, context drift, then server OS/architecture drift. For each pair, assert the earlier code is first. Where two tiers share `DBDOC_TOOL_VERSION_DRIFT`, also use `Assert-FirstDiagnosticMessageLike` to distinguish Docker component/version, context, server OS, and server architecture messages. Add a reverse-orthogonality variant whose native compiler binaries are missing or shadowed while exact Docker/WSL evidence remains; it must pass `StatePlaneIntegration`.

- [ ] Replace the existing Headless expectations for `windows-wsl-invalid.json`, `windows-wsl-parent-invalid.json`, `windows-compose-shadow-invalid.json`, and `windows-compose-extra-dir-shadow-invalid.json` explicitly: WSL environment/parent fixtures remain Headless failures; Compose-shadow fixtures become Headless successes and State-plane shadow failures. The CMake drift fixture remains a Headless native failure and is not reused as Docker evidence.

- [ ] Add a `Compatibility` variant with absent native, Node, WSL, and Docker fields. Assert success is true, `Errors.Count` is zero, and missing/drift diagnostics appear only in `Warnings`.

- [ ] Run the focused contract and confirm red failures are caused by the absent profile and current unconditional validation:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File tests/tooling/windows_toolchain_contract.ps1
```

Expected: nonzero; failures mention rejected `StatePlaneIntegration`, Headless WSL/Docker/Node coupling, and/or state-only compiler coupling.

### Step 2: Make probe discovery profile-scoped

- [ ] Extend all three public profile declarations to the exact set below:

```powershell
[ValidateSet('HeadlessVst3', 'StatePlaneIntegration', 'Compatibility')]
[string]$Profile = 'HeadlessVst3'
```

This applies to the script-level parameter, `Get-NativeWindowsProbe`, and `Test-NativeWindowsProbe`. Pass `-Profile $Profile` from `Invoke-WindowsDoctorMain` into probe collection and validation.

- [ ] Add an optional validator selector to the script entry point and both probe/validation functions:

```powershell
[ValidateSet('validator', 'pluginval')]
[string]$RequestedValidator
```

`Invoke-WindowsDoctorMain` passes it through. Ordinary `HeadlessVst3` does not require either validator; a wrapper request for `validator` or `pluginval` passes that exact value and requires only that validator's locked provenance. Under `Compatibility`, both validators are optional inventory. Add red/green tests proving unrequested-absence success, requested-absence failure with `DBDOC_TOOL_MISSING`, and requested-present success.

- [ ] At the start of `Get-NativeWindowsProbe`, derive capabilities without inferring them from Cargo arguments or installed software:

```powershell
$includeNative = $Profile -in @('HeadlessVst3', 'Compatibility')
$includeState = $Profile -in @('StatePlaneIntegration', 'Compatibility')
$includeNode = $Profile -eq 'Compatibility'
```

- [ ] Preserve the current probe object schema. For an excluded capability, leave scalar fields empty, booleans false, arrays empty, and do not add its binaries. Do not delete fields based on profile because fixtures and report consumers require a stable schema.

- [ ] Put Rust metadata, Visual Studio/MSVC/SDK discovery, CMake, Ninja, `ctest`, and the requested validator behind `$includeNative`. Put Node/npm metadata behind `$includeNode`. Put WSL executable metadata plus Docker Desktop/CLI/Compose discovery, engine/context queries, and Compose configuration validation behind `$includeState`.

- [ ] The common probe must still collect Windows architecture, current WSL environment variables and ancestor processes, repository path/filesystem/ownership, global `safe.directory`, disk space, and pending reboot. Only `Compatibility` may collect the exact-root Ableton-presence boolean and WebView2 registry fact; other profiles leave those stable-schema fields false and emit no absence warning. State/Compatibility WSL executable metadata must use file version information and must never launch `wsl.exe`.

- [ ] Move Compose `config --quiet` validation inside `$includeState` and route it through the same injectable command layer as every version/context probe. Replace direct `& $composeExpected ...` execution with `Invoke-ProbeCommandResult`, returning both output and exit code:

```powershell
function Invoke-ProbeCommandResult {
    param([string]$Path, [string[]]$Arguments, [scriptblock]$CommandRunner)
    if (-not $Path) { return [pscustomobject]@{ output=''; exit_code=-1 } }
    if ($CommandRunner) {
        $raw = & $CommandRunner $Path $Arguments
        if ($null -ne $raw -and $raw.PSObject.Properties['ExitCode']) {
            return [pscustomobject]@{ output=[string]$raw.Output; exit_code=[int]$raw.ExitCode }
        }
        return [pscustomobject]@{ output=[string]$raw; exit_code=0 }
    }
    try {
        $lines = & $Path @Arguments 2>&1
        return [pscustomobject]@{ output=($lines -join "`n").Trim(); exit_code=[int]$LASTEXITCODE }
    } catch {
        return [pscustomobject]@{ output=''; exit_code=-1 }
    }
}
```

Make `Invoke-ProbeCommand` return only `.output` for existing callers. Run Compose `config --quiet` only after Docker plugin configuration is safe, the Compose winner is the locked path, the locked Docker Desktop/CLI/Compose binaries are present and trusted, and their versions are exact. Set the existing boolean `docker_compose_config_valid` from the result's `exit_code`; when those preconditions fail, do not run configuration validation, leave the boolean false, and make the validator ignore it until the same preconditions are satisfied so it cannot mask the earlier diagnostic. The recording runner must therefore see Compose validation as well as Docker version/context commands only for an exact trusted state-plane candidate; no injected probe test may launch a real Docker or Compose process. Headless collection must not resolve or execute Docker, Compose, Node, npm, or WSL. Probe `ctest.exe` from the locked CMake `bin` directory as a required native build binary.

- [ ] Under `StatePlaneIntegration`, resolve WSL executable metadata before any Docker command. Add `MetadataPaths.WslCandidates` and `MetadataPaths.WslVersion` as test-only overrides. Compute `$stateWslReady` from presence, resolvable file version, and `Test-VersionAtLeast`; when false, return Docker runtime fields as empty/false and do not call the `CommandRunner`, Docker CLI, or Compose plugin. Validation then emits the stable WSL error before any Docker error.

### Step 3: Make validation capability-scoped

- [ ] Keep universal errors before profile-specific checks: native Windows x64, current WSL environment/launcher ancestry forbidden, drive-letter NTFS repository, matching owner SID, and valid global Git-config inspection without a covering `safe.directory` bypass.

- [ ] Replace the current `$strict` boolean with an explicit `switch ($Profile)`. The `HeadlessVst3` arm performs exact MSVC/SDK/Rust/CMake/Ninja/ctest checks and validates only `$RequestedValidator`. The `StatePlaneIntegration` arm performs exact WSL minimum and Docker Desktop/CLI/Compose/runtime checks only. The `Compatibility` arm inspects every capability and converts optional absence/drift into warnings.

- [ ] Implement exact state-plane WSL rules in this order:

```powershell
if (-not $Probe.wsl_present) {
    Add-Error 'DBDOC_WSL_REQUIRED' 'WSL 2 is required for developer state-plane integration'
} elseif ([string]::IsNullOrWhiteSpace([string]$Probe.wsl_version)) {
    Add-Error 'DBDOC_WSL_VERSION_UNKNOWN' 'WSL is present but its executable version could not be resolved without launching it'
} elseif (-not (Test-VersionAtLeast -Actual $Probe.wsl_version -Minimum $Lock.wsl.minimum_version)) {
    Add-Error 'DBDOC_TOOL_VERSION_DRIFT' "WSL expected at least $($Lock.wsl.minimum_version), found $($Probe.wsl_version)"
}
```

- [ ] Preserve Docker error precedence after common/WSL checks: plugin config, shadowing, missing binaries/Desktop, pinned version drift, invalid checked-in Compose configuration, engine stopped, wrong context, then wrong server OS/architecture. Accumulating later errors is allowed; the first code must remain stable.

- [ ] Treat a nonempty Compose winner outside the locked path as `DBDOC_DOCKER_PLUGIN_SHADOW`; treat an empty/missing winner as `DBDOC_TOOL_MISSING`. This prevents an absent Compose plugin from being mislabeled as provenance shadowing while retaining the approved precedence.

- [ ] Refactor exact-value validation so `Compatibility` converts both absence and drift to warnings. `HeadlessVst3` and `StatePlaneIntegration` continue to emit errors for required capabilities.

- [ ] Filter binary provenance and ambient-shadow validation by profile rather than iterating every binary in an injected fixture:

```powershell
$nativeBinaryNames = @('cargo','rustc','rustfmt','clippy-driver','cl','link','lib','dumpbin','cmake','ctest','ninja')
if ($RequestedValidator) { $nativeBinaryNames += $RequestedValidator }
$stateBinaryNames = @('docker','docker-compose')
$relevantBinaryNames = switch ($Profile) {
    'HeadlessVst3' { $nativeBinaryNames }
    'StatePlaneIntegration' { $stateBinaryNames }
    'Compatibility' { $nativeBinaryNames + $stateBinaryNames + @('node','validator','pluginval') }
}
```

Only binaries in `$relevantBinaryNames` may contribute PE, locked-root, or shadow diagnostics. Update `windows-native-valid.json` with locked `ctest.exe` metadata and assert `ctest` is present in live/native probe results.

### Step 4: Prove excluded tools are never resolved or launched

- [ ] Extend the existing fake-layout/`CommandRunner` tests. Record each command path and assert:

```powershell
$headlessCommands | Where-Object { $_ -match '(?i)docker|compose|node|npm|wsl' }
```

returns an empty collection, while the headless set contains Rust/MSVC/CMake/Ninja probes.

- [ ] Record a `StatePlaneIntegration` probe and assert no command path or binary record matches `cargo`, `rustc`, `rustfmt`, `clippy`, `cl.exe`, `link.exe`, `lib.exe`, `dumpbin.exe`, `cmake`, or `ninja`. Assert Docker/Compose are the only executable capabilities launched; WSL is metadata-only.

- [ ] Repeat the state-plane probe with injected missing, unknown-version, and old-version WSL candidates/version overrides. Assert the recorded command list contains no Docker or Compose launch in all three cases.

- [ ] With WSL exact, repeat state-plane probe collection for absent Docker/Compose, a shadowed or otherwise untrusted Compose winner, and Docker/Compose version drift. Assert the recording runner contains no command whose executable is the Compose plugin and whose arguments end in `config --quiet`. The exact trusted/version-locked fixture must record exactly one such validation launch.

- [ ] Assert `Compatibility` can inventory all three capability groups but succeeds with warnings when any optional group is absent or drifted.

- [ ] Run the full contract twice:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File tests/tooling/windows_toolchain_contract.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File tests/tooling/windows_toolchain_contract.ps1
```

Expected: exit 0 both times; the final assertion count is greater than 178 and identical across runs.

### Step 5: Review and commit Task 1

- [ ] Ask a fresh specification reviewer to compare only Task 1's diff with the approved design sections “Doctor profiles,” “Probe scope,” and “Diagnostic precedence.”
- [ ] Ask a fresh code-quality reviewer to inspect PowerShell 5.1 compatibility, stable schema, command-launch scoping, fixture realism, and error ordering.
- [ ] Resolve every finding, rerun the contract twice, then have the root/operator stage only:

```powershell
rtk git add scripts/doctor_windows.ps1 tests/tooling/windows_toolchain_contract.ps1 tests/tooling/fixtures/windows-native-valid.json
rtk git diff --cached --check
rtk git diff --cached -- scripts/doctor_windows.ps1 tests/tooling/windows_toolchain_contract.ps1 tests/tooling/fixtures/windows-native-valid.json
rtk git commit -m "build: split native and state-plane doctor profiles"
```

Expected: the installer files and installer documentation remain unstaged.

---

## Task 2: Route the native wrapper by explicit dependency profile

**Files:**

- Modify: `scripts/run_native_tool.ps1`
- Modify: `tests/tooling/windows_toolchain_contract.ps1`

### Step 1: Add failing wrapper-routing tests

- [ ] Using the existing injected `-Describe -ProbePath` path, assert a native build command succeeds when all Docker, Compose, Node, npm, and installed-WSL fields are missing or drifted:

```powershell
$description = Invoke-Describe -Tool 'cmake' -FixturePath $headlessNoState
Assert-Equal $description.ExitCode 0 'cmake selects HeadlessVst3 only'
$descriptionJson = $description.Text | ConvertFrom-Json
Assert-Equal $descriptionJson.profile 'HeadlessVst3' 'cmake reports its selected profile'
```

- [ ] Assert Docker succeeds with `$stateOnly`, where MSVC, Rust, CMake, Ninja, and `vsdevcmd.path` are absent:

```powershell
$description = Invoke-Describe -Tool 'docker' -FixturePath $stateOnly
Assert-Equal $description.ExitCode 0 'docker selects StatePlaneIntegration without native tools'
$descriptionJson = $description.Text | ConvertFrom-Json
Assert-Equal $descriptionJson.profile 'StatePlaneIntegration' 'docker reports its selected profile'
```

- [ ] Assert `node`, `npm`, and `npx` each fail before tool resolution with `DBDOC_TOOL_PROFILE_REQUIRED`, even when the valid fixture contains Node metadata.

- [ ] Assert `ctest` selects `HeadlessVst3` and resolves to the locked CMake `bin\ctest.exe` record.

- [ ] Assert the Compose-shadow fixture fails for `docker` but succeeds for `cmake`.

- [ ] Add an injected Docker description with an invalid/missing `vsdevcmd` path and environment. Assert success and an empty MSVC import requirement, proving the Docker route never imports `VsDevCmd.bat`.

- [ ] Run the focused contract and confirm red:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File tests/tooling/windows_toolchain_contract.ps1
```

Expected: nonzero because the wrapper currently validates every tool as `HeadlessVst3`, always imports MSVC state, and still accepts Node-family tools.

### Step 2: Select one profile before probing

- [ ] Replace the supported-tool and validation prelude with explicit routing:

```powershell
if ($Tool -in @('node', 'npm', 'npx')) {
    Stop-NativeTool 'DBDOC_TOOL_PROFILE_REQUIRED' "$Tool requires a future ReactEditorBuild profile"
}

$nativeTools = @('cargo', 'rustc', 'rustfmt', 'clippy-driver', 'cl', 'link', 'lib', 'dumpbin', 'cmake', 'ctest', 'ninja', 'validator', 'pluginval')
$stateTools = @('docker')
if ($Tool -in $nativeTools) { $profile = 'HeadlessVst3' }
elseif ($Tool -in $stateTools) { $profile = 'StatePlaneIntegration' }
else { Stop-NativeTool 'DBDOC_TOOL_FORBIDDEN' "unsupported native tool: $Tool" }

$requestedValidator = if ($Tool -in @('validator', 'pluginval')) { $Tool } else { '' }
$probeParameters = @{ Lock=$lock; RepoRoot=$repoRoot; ProbePath=$ProbePath; Profile=$profile }
$validationParameters = @{ Lock=$lock; Profile=$profile }
if ($requestedValidator) {
    $probeParameters.RequestedValidator = $requestedValidator
    $validationParameters.RequestedValidator = $requestedValidator
}
$probe = Get-NativeWindowsProbe @probeParameters
$validationParameters.Probe = $probe
$validation = Test-NativeWindowsProbe @validationParameters
```

- [ ] Do not inspect Cargo arguments, environment variables, or installed tools to change `$profile`.

- [ ] Preserve the current injected, metadata-only description, and two-stage live-execution flows, but pass `$profile` and `$requestedValidator` to every probe and validation call. Native live execution imports `VsDevCmd.bat` only between its metadata preflight and full probe; Docker live execution performs no such import. Invalid state-plane WSL metadata must terminate inside the profile-scoped preflight before the full probe can launch Docker.

- [ ] Include `profile = $profile` in `-Describe` JSON so tests and logs prove the dependency boundary selected for each command.

### Step 3: Scope environment construction to the selected profile

- [ ] Only the `HeadlessVst3` branch may import `VsDevCmd.bat`, add Rust/CMake/Ninja/MSVC/validator roots, or require `INCLUDE`, `LIB`, `WindowsSdkDir`, `WindowsSDKVersion`, and `VCToolsInstallDir`.

- [ ] The `StatePlaneIntegration` branch resolves only the locked Docker CLI and Compose plugin verified by the doctor. It must not add compiler directories, import `VsDevCmd.bat`, or require compiler environment variables.

- [ ] Remove Node/npm/npx from `Add-LockedPath`, live path/root resolution, npm argument rewriting, and normal execution. Their only supported outcome in this milestone is the stable rejection above.

- [ ] Keep tool shadow checks profile-local: ambient Docker/Compose cannot fail a native command; ambient compilers cannot fail a Docker command. Common repository/process safety remains universal.

### Step 4: Run wrapper and regression contracts

- [ ] Run:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File tests/tooling/windows_toolchain_contract.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File tests/tooling/windows_installer_contract.ps1
```

Expected: both exit 0; wrapper routing tests pass, and the existing 282 installer assertions remain green.

- [ ] Parse all changed PowerShell files under Windows PowerShell 5.1:

```powershell
rtk powershell -NoProfile -Command '$tokens=$null; $parseErrors=$null; [void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path "scripts/run_native_tool.ps1"),[ref]$tokens,[ref]$parseErrors); if($parseErrors.Count){$parseErrors | Format-List; exit 1}'
```

Expected: exit 0 with no parser errors.

### Step 5: Review and commit Task 2

- [ ] Ask a fresh specification reviewer to trace every supported tool to exactly one approved profile and verify Node-family rejection.
- [ ] Ask a fresh code-quality reviewer to inspect control flow, error stability, `-Describe` fidelity, and the absence of cross-profile environment mutation.
- [ ] Resolve findings, rerun both contracts, then have the root/operator stage only:

```powershell
rtk git add scripts/run_native_tool.ps1 tests/tooling/windows_toolchain_contract.ps1
rtk git diff --cached --check
rtk git diff --cached -- scripts/run_native_tool.ps1 tests/tooling/windows_toolchain_contract.ps1
rtk git commit -m "build: route native tools by dependency profile"
```

---

## Task 3: Make the native/container-free release boundary canonical and testable

**Files:**

- Modify: `docs/PLUGIN_ARCHITECTURE.md`
- Modify: `docs/DECISIONS.md`
- Modify: `docs/WINDOWS_WORKSTATION.md`
- Modify: `docs/superpowers/plans/2026-08-05-windows-headless-vst3.md`
- Modify: `tests/decision_docs.rs`
- Modify: `tests/docs_current.rs`
- Modify: `tests/tooling/windows_toolchain_contract.ps1`

### Step 1: Add failing documentation contracts

- [ ] In `tests/decision_docs.rs`, change the contiguous decision range from `1..=31` to `1..=32`.

- [ ] Add this test to `tests/docs_current.rs`:

```rust
#[test]
fn windows_distribution_is_native_and_container_free() {
    let architecture = include_str!("../docs/PLUGIN_ARCHITECTURE.md");
    let workstation = include_str!("../docs/WINDOWS_WORKSTATION.md");
    let decisions = include_str!("../docs/DECISIONS.md");

    for required in [
        "does not require WSL",
        "does not require Docker",
        "does not require developer tooling",
        "native per-user companion",
        "network-disconnected clean Windows",
    ] {
        assert!(architecture.contains(required), "missing distribution contract: {required}");
    }
    assert!(workstation.contains("StatePlaneIntegration"));
    assert!(workstation.contains("HeadlessVst3"));
    assert!(decisions.contains("## PD-032: Public Windows distribution is native and container-free"));
}
```

- [ ] Mirror the same source assertions in `tests/tooling/windows_toolchain_contract.ps1`, including required Task 11/14/15/16 phrases. This gives an executable red/green contract before Rust is provisioned:

```powershell
$architectureText = Get-Content -LiteralPath (Join-Path $repoRoot 'docs\PLUGIN_ARCHITECTURE.md') -Raw
$decisionText = Get-Content -LiteralPath (Join-Path $repoRoot 'docs\DECISIONS.md') -Raw
$roadmapText = Get-Content -LiteralPath (Join-Path $repoRoot 'docs\superpowers\plans\2026-08-05-windows-headless-vst3.md') -Raw
Assert-True ($architectureText.Contains('does not require WSL')) 'architecture rejects a WSL product prerequisite'
Assert-True ($architectureText.Contains('does not require Docker')) 'architecture rejects a Docker product prerequisite'
Assert-True ($architectureText.Contains('does not require developer tooling')) 'architecture rejects a developer-tool product prerequisite'
Assert-True ($architectureText.Contains('native per-user companion')) 'architecture requires native companion packaging'
Assert-True ($architectureText.Contains('network-disconnected clean Windows')) 'architecture requires disconnected clean-target proof'
Assert-True ($decisionText.Contains('## PD-032: Public Windows distribution is native and container-free')) 'PD-032 is append-only'
Assert-True ($roadmapText.Contains('normal imports')) 'roadmap checks normal imports'
Assert-True ($roadmapText.Contains('delay-load imports')) 'roadmap checks delay-load imports'
Assert-True ($roadmapText.Contains('runtime-loaded module')) 'roadmap checks runtime-loaded modules'
Assert-True ($roadmapText.Contains('network-disconnected clean Windows 11 x64')) 'roadmap contains a clean-target gate'
```

- [ ] Run the PowerShell contract and confirm red because PD-032 and exact evidence gates do not yet exist:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File tests/tooling/windows_toolchain_contract.ps1
```

Expected: nonzero with documentation-contract failures only.

### Step 2: Update canonical architecture and decision records

- [ ] In `docs/PLUGIN_ARCHITECTURE.md`, make the release boundary explicit:

```markdown
The shipped VST3 does not require WSL and does not require Docker.
It does not require developer tooling or globally installed services, including
Node.js, Rust, Visual Studio, CMake, Ninja, Postgres, and PostgREST. The first UI-NONE
handoff operates from the embedded/default plan and remains usable when no
companion is installed; it cannot create a new analysis yet. A later analysis
feature ships a native per-user companion, never containers. Release proof runs
the installed product on a network-disconnected clean Windows target.
```

- [ ] Keep Docker Compose described only as developer/test infrastructure. State that Docker/WSL developer integration and native compilation are orthogonal capabilities.

- [ ] Append exactly one new decision; do not edit PD-001 through PD-031:

```markdown
## PD-032: Public Windows distribution is native and container-free
- **Status:** `accepted`
- **Date:** 2026-08-05
- **Area:** distribution
- **Decision:** Ship the VST3 and its later per-user companion as native Windows artifacts; WSL, Docker, developer toolchains, Postgres, and PostgREST are never musician-facing prerequisites.
- **Rationale:** The plugin must load and perform its first UI-NONE handoff on a normal Windows host independently of the developer state plane, while later analysis remains installable without containers.
- **Source:** [Windows distribution boundary design](superpowers/specs/2026-08-05-windows-distribution-boundary-design.md)
- **Consequences:** Native build and Docker integration use orthogonal doctor profiles. Release evidence includes normal, delay-load, and runtime-loaded dependency closure plus a network-disconnected clean Windows target with no developer tools.
- **Revisit trigger:** Reconsider packaging only if a native companion cannot satisfy measured product requirements and an alternative still requires no WSL, Docker, or developer tooling on the target.
- **GitHub:** [#5 VST3 plugin path with Ableton validation](https://github.com/williamshayden/doppelbanger/issues/5).
```

### Step 3: Correct workstation and roadmap semantics

- [ ] Rewrite only the top profile contract in `docs/WINDOWS_WORKSTATION.md`:

  - `HeadlessVst3` requires only native compiler/build/validator capabilities.
  - Installed, missing, old, or unknown WSL and all Docker/Node state are irrelevant to this profile.
  - A current WSL environment or WSL launcher ancestor is still forbidden.
  - `StatePlaneIntegration` requires WSL >= 2.1.5 and the pinned Docker Desktop/CLI/Compose `desktop-linux` runtime, but does not require MSVC, Rust, CMake, or Ninja.
  - `Compatibility` is diagnostic-only and never constitutes build or release evidence.
  - `node`, `npm`, and `npx` return `DBDOC_TOOL_PROFILE_REQUIRED` until `ReactEditorBuild` is designed.

- [ ] Preserve the existing unstaged pinned-installer section byte-for-byte. Before editing, verify the LF-normalized UTF-8 text from the exact `## Pinned toolchain installer` marker through EOF hashes to `fe4e8ba303ae402104650d03bd430c3f70fbfa8fc401dead506c53d287a57d22`. Recompute the same section hash after editing and immediately before/after partial staging; stop if it differs.

```powershell
rtk powershell -NoProfile -Command "`$text=Get-Content -LiteralPath 'docs/WINDOWS_WORKSTATION.md' -Raw; `$marker='## Pinned toolchain installer'; `$index=`$text.IndexOf(`$marker,[StringComparison]::Ordinal); if(`$index -lt 0){throw 'installer marker missing'}; `$section=`$text.Substring(`$index).Replace([Environment]::NewLine,[string][char]10); `$sha=[Security.Cryptography.SHA256]::Create(); try{ `$bytes=[Text.Encoding]::UTF8.GetBytes(`$section); `$actual=((`$sha.ComputeHash(`$bytes)|ForEach-Object{`$_.ToString('x2')}) -join ''); if(`$actual -cne 'fe4e8ba303ae402104650d03bd430c3f70fbfa8fc401dead506c53d287a57d22'){throw ('installer section changed: ' + `$actual)}; `$actual } finally { `$sha.Dispose() }"
```

Expected: the recorded hash is printed every time.

- [ ] In the main roadmap, make Task 3's API integration harness explicitly compose `HeadlessVst3` and `StatePlaneIntegration`; it must not infer Docker requirements from Cargo arguments.

- [ ] Add these release gates to the named roadmap tasks:

  - Task 11: create a reusable recursive dependency-closure gate and apply it to every native executable/DLL in the UI-NONE VST3 bundle. Parse normal and delay-load imports, require AMD64 PE provenance, reject static-runtime leakage, permit only a committed reviewed Windows system-DLL allowlist or bundle-contained dependency, and reject bundle escape through DLL search. Derive the allowlist from documented Windows platform requirements and reviewed code usage; explicitly forbid auto-populating it from the first artifact's observed imports. The current bundle is expected to contain only the plugin module; the later native companion must reuse this gate.
  - Task 14: validator evidence must include the same recursive dependency-closure inventory and reject WebView/Node/Docker/WSL/database/service/compiler leakage from UI-NONE artifacts.
  - Task 15: install and run on a disposable, network-disconnected clean Windows 11 x64 VM with no WSL, Docker, Rust, Visual Studio, CMake, Ninja, Node, Postgres, or PostgREST. Use a statically linked pinned Steinberg headless host with its own reviewed dependency closure, safe DLL search, a separate host directory, and a one-process Windows job. Before loading, record the OS image, disabled WSL/Virtual Machine Platform features, absence of WSL distributions and container/database/developer files, services, processes, PATH entries, and installed programs, plus host/bundle hashes and disconnected-network state. Exercise load, stereo processing, settled bypass, state restore, and unload. Record every runtime-loaded module's canonical path/hash before load and after initialization, processing, restore, and unload; record the process tree, listeners, and filesystem changes. Reject undeclared `LoadLibrary`/`GetProcAddress` dependencies, undeclared modules, writable/PATH/network search locations, child processes, downloads, prerequisite installation, listeners, and unexpected filesystem writes.
  - Task 16: rerun the UI-NONE VST3 normal-import, delay-load, runtime-loaded-module, and clean-target gates as final release evidence. Verify that their contract is reusable by the later native-companion milestone, but do not require or execute companion packaging during the UI-NONE milestone.

### Step 4: Run documentation contracts

- [ ] Run:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File tests/tooling/windows_toolchain_contract.ps1
rtk git diff --check
```

Expected: exit 0; the architecture, decision, and roadmap contract assertions pass.

- [ ] Do not claim the Rust documentation tests have run yet if native Cargo is not provisioned. Task 4 runs them through the approved wrapper immediately after provisioning.

### Step 5: Review and commit Task 3 without absorbing installer work

- [ ] Ask a fresh specification reviewer to map every approved boundary requirement to a canonical statement and executable assertion.
- [ ] Ask a fresh quality reviewer to check decision append-only semantics, roadmap gate feasibility, exact terminology, and contradictions across the three canonical documents.
- [ ] Resolve findings and rerun the PowerShell contract.
- [ ] Have the root/operator stage all Task 3 files except `docs/WINDOWS_WORKSTATION.md`, then interactively stage only that file's profile-contract hunk:

```powershell
rtk git add docs/PLUGIN_ARCHITECTURE.md docs/DECISIONS.md docs/superpowers/plans/2026-08-05-windows-headless-vst3.md tests/decision_docs.rs tests/docs_current.rs tests/tooling/windows_toolchain_contract.ps1
rtk git add -p docs/WINDOWS_WORKSTATION.md
rtk git diff --cached --check
rtk git diff --cached -- docs/WINDOWS_WORKSTATION.md
```

- [ ] At the `git add -p` prompt, choose `s` to split hunks. If Git cannot split the profile and installer additions, choose `e`, retain only the profile-contract `+`/`-` lines in the editable patch, and delete only the added (`+`) installer lines from `## Pinned toolchain installer` through EOF while retaining required context lines. If edited-patch application fails, abort staging, reset only the index entry with `rtk git reset docs/WINDOWS_WORKSTATION.md`, and retry; never restore or rewrite the working-tree file.

- [ ] Stop if the cached workstation diff contains the installer heading or any installer implementation detail, or if the normalized installer-section hash differs from the recorded value. Confirm the three original Task 2 paths remain dirty/unstaged, then commit:

```powershell
rtk git commit -m "docs: enforce native Windows distribution boundary"
```

---

## Task 4: Commit the reviewed developer installer, then provision native build tools

**Files:**

- Modify only if profile wording needs reconciliation: `docs/WINDOWS_WORKSTATION.md`
- Existing unstaged implementation: `scripts/install_windows_toolchain.ps1`
- Existing unstaged contract: `tests/tooling/windows_installer_contract.ps1`
- Generated and ignored evidence only: `var/tooling/**`

### Step 1: Reconcile the installer with the new profile boundary

- [ ] Inspect the remaining unstaged Task 2 diff. The installer may provision Rust/MSVC/CMake/Ninja/Node for a developer workstation, but its default path must not provision, upgrade, reconfigure, or launch Docker/WSL and must not imply those are `HeadlessVst3` requirements.

- [ ] Ensure the documentation calls this a developer-workstation installer, not a musician-facing product installer.

- [ ] Rerun both contracts:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File tests/tooling/windows_installer_contract.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File tests/tooling/windows_toolchain_contract.ps1
```

Expected: installer contract exits 0 with 282 assertions; toolchain contract exits 0 with its new deterministic count.

- [ ] Run two `-PlanOnly` executions in one native process and compare outputs byte-for-byte:

```powershell
rtk powershell -NoProfile -Command '$first = (& .\scripts\install_windows_toolchain.ps1 -PlanOnly 2>&1 | Out-String); $second = (& .\scripts\install_windows_toolchain.ps1 -PlanOnly 2>&1 | Out-String); if ($first -cne $second) { throw "DBINST_PLAN_NONDETERMINISTIC" }'
```

Expected: exit 0. Confirm the installer contract's zero-write assertions cover installer state, PATH, registry, Docker, WSL, and Ableton paths.

### Step 2: Independent pre-commit review and installer commit

- [ ] Ask a fresh specification reviewer to check the installer against the original workstation lock plus the new orthogonal profile rules.
- [ ] Ask a fresh quality reviewer to recheck PowerShell 5.1 parsing, link/reparse-point safety, checksum enforcement, deterministic plan mode, resume checkpoints, and the Docker opt-in boundary.
- [ ] Resolve findings and rerun the full installer/toolchain contracts.
- [ ] Have the root/operator stage exactly:

```powershell
rtk git add scripts/install_windows_toolchain.ps1 tests/tooling/windows_installer_contract.ps1 docs/WINDOWS_WORKSTATION.md
rtk git diff --cached --check
rtk git diff --cached --stat
rtk git commit -m "build: add pinned Windows toolchain installer"
```

Expected: the repository working tree is clean except ignored local evidence.

### Step 3: Provision without Docker mutation

- [ ] Run the real installer from a native Windows process without `-UpgradeDockerDesktop`:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_windows_toolchain.ps1
```

Expected: it enforces the 40 GiB free-space floor, verifies every artifact hash, installs the pinned native toolchain, and leaves Docker/WSL/Ableton untouched.

- [ ] If the installer reports a pending reboot before mutation, stop and ask William to reboot. If Visual Studio returns reboot-required code 3010 after a checkpoint, stop at that checkpoint and resume only in a fresh native PowerShell process after William reboots. Docker is disabled for this run, and Rust does not use the 3010 checkpoint path. Do not reboot the machine automatically.

- [ ] Run the installer a second time after success. Expected: idempotent success with no downloads or modifications beyond evidence refresh.

### Step 4: Prove the native profile and Rust documentation tests

- [ ] In a fresh native Windows PowerShell process, run:

```powershell
rtk powershell -NoProfile -Command 'New-Item -ItemType Directory -Force -Path "var\tooling" | Out-Null'
rtk powershell -NoProfile -ExecutionPolicy Bypass -File scripts/doctor_windows.ps1 -Profile HeadlessVst3 -Json -ReportPath var/tooling/headless-vst3-doctor.json
rtk powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_native_tool.ps1 cargo test --locked --test decision_docs --test docs_current
```

Expected: both exit 0. The doctor report proves only native build capabilities; its success must be independent of installed/missing/drifted Docker, Node, and WSL executable metadata.

- [ ] Run wrapper descriptions for `cmake`, `cargo`, and `docker` using fixtures. Confirm native tools select `HeadlessVst3`, Docker selects `StatePlaneIntegration`, and Node-family tools still reject with `DBDOC_TOOL_PROFILE_REQUIRED`.

- [ ] Do not run a real Docker state-plane integration or upgrade unless a later roadmap task needs it. A fixture-backed routing proof is sufficient for this boundary milestone.

---

## Task 5: Final boundary verification and handoff

**Files:**

- Modify only files required by validated review findings.

### Step 1: Run all boundary gates from native Windows

- [ ] Run:

```powershell
rtk powershell -NoProfile -ExecutionPolicy Bypass -File tests/tooling/windows_toolchain_contract.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File tests/tooling/windows_installer_contract.ps1
rtk powershell -NoProfile -ExecutionPolicy Bypass -File scripts/doctor_windows.ps1 -Profile HeadlessVst3 -Json -ReportPath var/tooling/headless-vst3-doctor-final.json
rtk powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_native_tool.ps1 cargo test --locked --test decision_docs --test docs_current
rtk git diff --check
rtk git status --short
```

Expected: every command exits 0; tracked working tree is clean; no Ableton path was written.

- [ ] Scan tracked source and documentation for incomplete markers using split literals so the plan itself does not trigger the scan:

```powershell
$markerMatches = @(rtk rg -n 'T[B]D|T[O]DO|FIX[M]E|implement[ ]later|similar[ ]to|appropriate[ ]error[ ]handling' -- scripts tests docs tools Cargo.toml 2>&1)
$markerExit = $LASTEXITCODE
if ($markerExit -eq 0) { $markerMatches | ForEach-Object { Write-Output $_ }; throw 'incomplete markers found' }
if ($markerExit -ne 1) { $markerMatches | ForEach-Object { Write-Output $_ }; throw "marker scan failed with exit $markerExit" }
```

Expected: no incomplete marker introduced by this implementation; any historical match is documented and outside the changed lines.

### Step 2: Independent final reviews

- [ ] Ask one fresh reviewer for specification compliance across the approved design, doctor, wrapper, canonical docs, and tests.
- [ ] Ask a second fresh reviewer for code quality, regression risk, diagnostic stability, dependency-proof sufficiency, and installer safety.
- [ ] For every Critical or Important finding, add a failing focused test, implement the smallest correction, rerun focused and full gates, and have the root/operator commit only the reviewed correction.

### Step 3: Handoff

- [ ] Record commit hashes, assertion counts, installer outcome, doctor-report path, Rust test outcome, and any reboot checkpoint.
- [ ] State explicitly that this milestone implements the build boundary and encodes the future release gates. Task 15 proves the UI-NONE VST3 after that artifact exists; the later native-companion milestone reruns the reusable dependency and clean-target contract for its separately packaged artifacts.
- [ ] Do not push until William separately authorizes publication.
