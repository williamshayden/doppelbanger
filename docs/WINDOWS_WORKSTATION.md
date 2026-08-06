# Native Windows Workstation

The Windows VST3 lane is native Windows x86_64 only. Use an ownership-correct clone on a drive-letter NTFS path, owned by the signed-in Windows user. Do not use a WSL, UNC, `\\wsl$`, GNU, or MinGW clone, and do not add the repository to global Git `safe.directory`; plain Git must work with the existing ownership.

## Locked profiles

`HeadlessVst3` is the strict native build profile. It requires only the exact native compiler and build capabilities recorded in `tools/windows-toolchain.lock.json`, including MSVC target `x86_64-pc-windows-msvc` and PE32/PE32+ AMD64 executables. Native build tools use `HeadlessVst3`. Validators are on-demand; only the specifically requested validator is resolved and required. Installed, missing, old, or unknown WSL installations and all Docker and Node state are irrelevant to this profile. A current WSL environment or WSL launcher ancestor is still forbidden. A successful `HeadlessVst3` result is independent of Docker state; `DBDOC_DOCKER_STOPPED` is a `StatePlaneIntegration` diagnostic.

`StatePlaneIntegration` is the strict developer-service profile. It requires WSL >= 2.1.5 and the pinned Docker Desktop, Docker CLI, Docker Compose, and `desktop-linux` Linux/amd64 runtime, but it does not require MSVC, Rust, CMake, or Ninja. Docker commands use `StatePlaneIntegration` and never import the Visual Studio environment.

`Compatibility` is diagnostic-only and never constitutes build or release evidence. Only `Compatibility` inventories Node, WebView2, and Ableton. Until a `ReactEditorBuild` profile is designed, `node`, `npm`, and `npx` are rejected with `DBDOC_TOOL_PROFILE_REQUIRED`.

Portable CMake, Ninja, Node, and pluginval archives live in versioned directories beneath `%LOCALAPPDATA%\Programs\doppelbanger-devtools`; pluginval uses `pluginval-1.0.4`. Rust discovery uses only the physical `%RUSTUP_HOME%\toolchains\1.97.1-x86_64-pc-windows-msvc` installation (or `%USERPROFILE%\.rustup` when `RUSTUP_HOME` is unset), including its rustup manifests and physical rustfmt/clippy binaries. The doctor never invokes `%USERPROFILE%\.cargo\bin` rustup proxies.

Run the read-only doctor from native PowerShell 5.1 or later:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\doctor_windows.ps1 -Profile HeadlessVst3 -Json
```

`-ExecutionPolicy Bypass` applies only to that PowerShell process. Doctor inventory is profile-scoped: `HeadlessVst3` reads native build provenance, `StatePlaneIntegration` reads WSL/Docker provenance, and only `Compatibility` inventories Node, WebView2, and Ableton. Common read-only evidence includes process ancestry, registry and disk state, directory-owner SID, global Git configuration, and pending-reboot markers. The doctor never installs software, starts or stops services, changes PATH or configuration, or modifies Ableton. It writes only when `-ReportPath` explicitly names a canonical, non-reparse path beneath the ignored repository `var\` evidence tree.

Use `scripts\run_native_tool.ps1` for every native build, validator, and Docker command. Native build tools select `HeadlessVst3` and import the exact VS instance before verifying `VCToolsInstallDir`, `WindowsSDKVersion`, `INCLUDE`, `LIB`, and the physical cl/link/lib/dumpbin executables. Validators use the same profile on demand, and only the specifically requested validator is resolved. Docker selects `StatePlaneIntegration`, never imports VsDevCmd or other Visual Studio state, and checks only its WSL/Docker contract. Requests for `node`, `npm`, or `npx` fail with `DBDOC_TOOL_PROFILE_REQUIRED`. Live execution and live `-Describe` are hard-bound to the checked-in lock; `-Describe` reads metadata and resolves the selected profile without running VsDevCmd, rustup proxies, version commands, Docker commands, or the requested tool.

Docker Compose plugin resolution follows Docker CLI 29.6.2 order: configured `cliPluginsExtraDirs` in list order, then the effective `DOCKER_CONFIG\cli-plugins` (or `%USERPROFILE%\.docker\cli-plugins`), then `%ProgramFiles%\Docker\cli-plugins`. The first existing `docker-compose.exe` wins. Any winner other than the locked Docker Desktop plugin is rejected on every Docker invocation; diagnostics never move or delete a shadow.

## Native and container boundary

Cargo, rustc, MSVC, CMake, Ninja, Node, VST3 validators, and the VST3 bundle are native Windows AMD64 artifacts. Native `docker.exe` may address Docker Desktop's WSL2-backed `desktop-linux` engine; only that server may be Linux/amd64. No compilation or validator process runs inside WSL or a Linux container.

Ableton detection is read-only. The per-user VST3 deployment location is `%LOCALAPPDATA%\Programs\Common\VST3`; installation and Ableton validation belong to later tasks. Never remove or modify Ableton projects, packs, samples, installers, preferences, or installations.

Store local workstation evidence under `var\validation\m0-windows\`. The directory is ignored, so reports may include machine paths and tool provenance without becoming repository history.
