# Native Windows Workstation

The Windows VST3 lane is native Windows x86_64 only. Use an ownership-correct clone on a drive-letter NTFS path, owned by the signed-in Windows user. Do not use a WSL, UNC, `\\wsl$`, GNU, or MinGW clone, and do not add the repository to global Git `safe.directory`; plain Git must work with the existing ownership.

## Locked profiles

`HeadlessVst3` is the strict build profile. It requires the exact versions and provenance recorded in `tools/windows-toolchain.lock.json`, MSVC target `x86_64-pc-windows-msvc`, PE32/PE32+ AMD64 executables, the Docker Desktop Compose plugin, and the `desktop-linux` Linux/amd64 engine. `Compatibility` reports the same facts for diagnosis but treats version drift as a warning; it is not release or build evidence.

Portable CMake, Ninja, Node, and pluginval archives live in versioned directories beneath `%LOCALAPPDATA%\Programs\doppelbanger-devtools`; pluginval uses `pluginval-1.0.4`. Rust discovery uses only the physical `%RUSTUP_HOME%\toolchains\1.97.1-x86_64-pc-windows-msvc` installation (or `%USERPROFILE%\.rustup` when `RUSTUP_HOME` is unset), including its rustup manifests and physical rustfmt/clippy binaries. The doctor never invokes `%USERPROFILE%\.cargo\bin` rustup proxies.

Run the read-only doctor from native PowerShell 5.1 or later:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\doctor_windows.ps1 -Profile HeadlessVst3 -Json
```

`-ExecutionPolicy Bypass` applies only to that PowerShell process. The doctor reads process ancestry, executable metadata, registry and disk state, Docker information, directory-owner SID and global Git configuration, pending-reboot markers, and WebView2/Ableton presence. It never installs software, starts or stops services, changes PATH or configuration, or modifies Ableton. It writes only when `-ReportPath` explicitly names a canonical, non-reparse path beneath the ignored repository `var\` evidence tree.

Use `scripts\run_native_tool.ps1` for every native build, validator, and Docker command. Live execution and live `-Describe` are hard-bound to the checked-in lock. `-Describe` reads metadata and resolves the environment that would be imported without running VsDevCmd, rustup proxies, version commands, Docker commands, or the requested tool. Execution imports the exact VS instance, then verifies `VCToolsInstallDir`, `WindowsSDKVersion`, `INCLUDE`, `LIB`, and the physical cl/link/lib/dumpbin executables before launch.

Docker Compose plugin resolution follows Docker CLI 29.6.2 order: configured `cliPluginsExtraDirs` in list order, then the effective `DOCKER_CONFIG\cli-plugins` (or `%USERPROFILE%\.docker\cli-plugins`), then `%ProgramFiles%\Docker\cli-plugins`. The first existing `docker-compose.exe` wins. Any winner other than the locked Docker Desktop plugin is rejected on every Docker invocation; diagnostics never move or delete a shadow.

## Native and container boundary

Cargo, rustc, MSVC, CMake, Ninja, Node, VST3 validators, and the VST3 bundle are native Windows AMD64 artifacts. Native `docker.exe` may address Docker Desktop's WSL2-backed `desktop-linux` engine; only that server may be Linux/amd64. No compilation or validator process runs inside WSL or a Linux container.

Ableton detection is read-only. The per-user VST3 deployment location is `%LOCALAPPDATA%\Programs\Common\VST3`; installation and Ableton validation belong to later tasks. Never remove or modify Ableton projects, packs, samples, installers, preferences, or installations.

Store local workstation evidence under `var\validation\m0-windows\`. The directory is ignored, so reports may include machine paths and tool provenance without becoming repository history.
