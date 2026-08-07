# Native Windows Workstation

The Windows VST3 lane runs from native Windows PowerShell on a normal drive-letter checkout. Do not run the native dispatcher from WSL, a UNC checkout, or a GNU/MinGW shell.

Customers use the product installer and do not install developer tools. Developers install Visual Studio Build Tools, Rust, CMake, and Ninja normally, then verify the native environment from the repository root:

```powershell
.\scripts\dev.ps1 -Task doctor
```

`doctor` is read-only. Every dispatcher task checks the required native executables and the Rust `x86_64-pc-windows-msvc` host before it runs anything. The dispatcher never downloads or installs tools, edits the registry, changes services, requests a reboot, or interacts with music applications.

## Dispatcher tasks

Run each task from native PowerShell:

```powershell
.\scripts\dev.ps1 -Task doctor
.\scripts\dev.ps1 -Task format
.\scripts\dev.ps1 -Task test
.\scripts\dev.ps1 -Task configure
.\scripts\dev.ps1 -Task build -Configuration Release
.\scripts\dev.ps1 -Task validate -Configuration Release
```

- `doctor` verifies the native compiler, build tools, Git, and Rust host without modifying the machine.
- `format` checks Rust formatting.
- `test` runs the locked Rust test suite.
- `configure` creates the native build files with Ninja.
- `build` builds the configured native target.
- `validate` invokes the configured native validation target.

`Release` is the default configuration; `Debug` is also accepted. Stable environment failures use `DBDEV_WINDOWS_REQUIRED`, `DBDEV_WSL_FORBIDDEN`, `DBDEV_TOOL_MISSING`, and `DBDEV_WRONG_RUST_HOST`.
