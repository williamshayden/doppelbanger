# Native Windows Workstation

The Windows VST3 lane is native Windows x86_64 only. Use an ownership-correct clone on a drive-letter NTFS path, owned by the signed-in Windows user. Do not use a WSL, UNC, `\\wsl$`, GNU, or MinGW clone, and do not add the repository to global Git `safe.directory`; plain Git must work with the existing ownership.

## Locked profiles

`HeadlessVst3` is the strict build profile. It requires the exact versions and provenance recorded in `tools/windows-toolchain.lock.json`, MSVC target `x86_64-pc-windows-msvc`, PE32/PE32+ AMD64 executables, the Docker Desktop Compose plugin, and the `desktop-linux` Linux/amd64 engine. `Compatibility` reports the same facts for diagnosis but treats version drift as a warning; it is not release or build evidence.

Run the read-only doctor from native PowerShell 5.1 or later:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\doctor_windows.ps1 -Profile HeadlessVst3 -Json
```

`-ExecutionPolicy Bypass` applies only to that PowerShell process. The doctor reads process ancestry, executable metadata, registry and disk state, Docker information, Git provenance, pending-reboot markers, and WebView2/Ableton presence. It never installs software, starts or stops services, changes PATH or configuration, or modifies Ableton. It writes only when `-ReportPath` explicitly names a path beneath the ignored `var\` evidence tree.

Use `scripts\run_native_tool.ps1` for every native build, validator, and Docker command. `-Describe` resolves and validates paths and the imported MSVC/SDK environment without launching the requested tool. The wrapper rejects ambient shadows, WSL ancestry, GNU/ELF executables, an unexpected Visual Studio instance, and a user Compose plugin that wins over Docker Desktop.

## Native and container boundary

Cargo, rustc, MSVC, CMake, Ninja, Node, VST3 validators, and the VST3 bundle are native Windows AMD64 artifacts. Native `docker.exe` may address Docker Desktop's WSL2-backed `desktop-linux` engine; only that server may be Linux/amd64. No compilation or validator process runs inside WSL or a Linux container.

Ableton detection is read-only. The per-user VST3 deployment location is `%LOCALAPPDATA%\Programs\Common\VST3`; installation and Ableton validation belong to later tasks. Never remove or modify Ableton projects, packs, samples, installers, preferences, or installations.

Store local workstation evidence under `var\validation\m0-windows\`. The directory is ignored, so reports may include machine paths and tool provenance without becoming repository history.
