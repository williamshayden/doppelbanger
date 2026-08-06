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

## Pinned developer-workstation toolchain installer

This script provisions a Doppelbanger developer workstation; it is not a musician-facing product installer. Its ordinary invocation may install the pinned Rust, MSVC, CMake, Ninja, and Node developer tools, but Node remains outside the `HeadlessVst3` profile and Docker/WSL remain outside the ordinary installer path.

Preview the deterministic provisioning plan from an ordinary native PowerShell before allowing any machine change:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\install_windows_toolchain.ps1 -PlanOnly
```

Plan-only mode is hard-bound to the checked-in lock. It reports the exact artifact URLs, SHA-256 values, target roots, installer arguments, 40 GiB-per-volume requirement, pending-reboot gate, disabled-by-default Docker action, and intended user PATH entries. It does not probe the machine, download bytes, create the cache or tool roots, extract archives, execute an installer, write a checkpoint, move a Compose plugin, or change PATH.

Non-plan provisioning uses `%LOCALAPPDATA%\doppelbanger\downloads` as its verified artifact cache. Cached artifacts are hashed again on every use. New downloads temporarily add TLS 1.2 to the process security protocols, restore the previous protocols afterward, write to a unique partial file, verify SHA-256, and atomically move into the trusted cache only after verification. CMake, Ninja, and Node use same-volume staging followed by a no-merge directory rename into their versioned lock roots below `%LOCALAPPDATA%\Programs\doppelbanger-devtools`; an existing matching managed root is reused and an unknown or mismatched root fails closed. Their version identity is proven without launching CMake, CTest, Ninja, Node, npm, or any PATH-resolved command: the installer statically binds each locked version to its release URL, exact ZIP SHA-256, and required top-level prefix, keeps a read-only file-share guard on that cached ZIP through verification and extraction, and streams every entry hash into a safe manifest. Fresh installs, exact-state probes, reuse, and sequence postconditions all require byte-for-byte equality with that same authenticated manifest, including zero-byte files and the exact file set; only the installer-owned root marker is excluded. Unsafe ZIP paths, canonical aliases, duplicates, file/directory collisions, symlink/device/reparse attributes, excessive entry counts or aggregate sizes, descendant reparse points, hardlinks, nonphysical npm metadata, and non-AMD64 executables fail closed. An exact root uses the verified cached ZIP without re-extraction; if the cache is absent it may be downloaded and verified again, while an unavailable archive fails closed with no marker fallback. VS Build Tools uses the exact all-users root `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools`; exact state additionally requires physical instance/version metadata and an exit-0 query of the bundled absolute `vswhere.exe` using `-products Microsoft.VisualStudio.Product.BuildTools -requires` for the pinned workload, VC, and SDK IDs, with the fixed installation path returned. The Build Tools root, Windows Kits 10 SDK root, ProgramData `Microsoft\VisualStudio\Packages\_Instances` metadata root and selected `state.json`, and bundled `Microsoft Visual Studio\Installer\vswhere.exe` are each validated from their volume root so an otherwise physical child beneath any ancestor junction is rejected. Those canonical Build Tools, SDK, `_Instances`, and VS Installer roots are also preflight mutation targets, and unsafe ancestry stops the run before the bootstrapper. Unrelated junctions outside the owned paths do not change exact-state classification. The installer then requires physical VsDevCmd, the `14.44` toolset root and AMD64 cl/link/lib/dumpbin executables, and the `10.0.26100.0` SDK include/lib layout without reparse or hardlink provenance. `state.json` is used only for exact installation path/version metadata, not as an unsupported package inventory. Rustup receives the exact target-qualified toolchain `1.97.1-x86_64-pc-windows-msvc`, minimal profile, and combined `rustfmt,clippy` component request under consistent process `RUSTUP_HOME` and `CARGO_HOME` values. Rust reuse rejects child junctions and hardlinks and requires physical AMD64 rustc/cargo/rustfmt/clippy-driver/cargo-clippy executables owned by the exact manifests. Both installers are awaited through their top-level process, and exact installed components/manifests are revalidated after exit 0. Only exact installed directories are added through the user PATH API; machine PATH and unrelated user entry order/text are untouched.

Every bootstrap artifact is opened from a physical, non-reparse ancestry with exactly one link, hashed from the same read-only leaf handle, and kept under read-only ancestor and leaf leases through awaited process completion. The leaf itself is opened with Windows `OPEN_REPARSE_POINT`, so the exact opened handle is rejected rather than following a leaf symlink; the launch pathname's volume serial and file index must still match that handle. Path identity and leaf link count are rechecked after hashing, immediately before launch, and after the awaited runner returns. This applies equally to a cache reuse, a newly downloaded partial file, the final cache placement, and an injected test runner, so a hardlink, leaf symlink, ancestor junction, replacement, rename, or delete cannot cross the hash-to-launch boundary unnoticed.

Rust exact state additionally requires an external installer-owned receipt beneath `%LOCALAPPDATA%\doppelbanger`. An unreceipted pre-existing locked toolchain root is quarantined before rustup runs against an absent target; only a successful current locked rustup action may create a receipt binding the checked-in lock hash, rustup bootstrap hash, target, and exact file/directory manifest. A failed action moves any new partial tree into an explicit failure quarantine, restores the pre-existing quarantine when present, and never enrolls its bytes; a successful action retains the old quarantine for explicit operator recovery. The Rust receipt detects later drift; it is not a cryptographic defense against a malicious process running as the same Windows user that forges both the tree and receipt. A stronger guarantee would require lock-pinned component or complete-tree digests from an independently authenticated source.

Visual Studio trust stops at the pinned bootstrap SHA-256 plus Microsoft Visual Studio installer/package registration and physical installed metadata/layout; it is not a full installed-byte manifest or an Authenticode proof. In particular, the physical AMD64 and component/layout checks prevent structural and path-provenance substitution, while Microsoft installer registration remains the authority for the selected workload and components.

The default live topology is exactly Visual Studio, Rust, CMake, Ninja, Node, then user PATH; Docker appears only in the explicit Docker opt-in topology immediately before user PATH. These stable topology identifiers and injected action descriptors let the non-plan execution order be tested without invoking installers. A live user PATH append expands environment variables for comparison only, then re-proves exact Visual Studio, Rust, CMake, Ninja, and Node state, rejects a concurrent baseline change, and verifies the exact stored readback. Expansion never rewrites existing PATH text, and no PATH write occurs if provenance or the baseline changes.

Immediately before each provisioning action, the installer requires a native Windows x64 process with no WSL ancestry, at least 40 GiB free on every destination volume, and no Windows pending-reboot marker, including pending file renames. If a bootstrap installer returns 3010, the installer writes `installer-checkpoint-v1.json` beneath `%LOCALAPPDATA%\doppelbanger`, stops before every later installer, extraction, move, or PATH action, and requires an explicit `-Resume` after reboot. Resume rejects the same native Windows boot session, then validates the checkpoint's checked-in-lock hash, enabled action topology, option hash, exact next/completed action, UTC timestamp, and reboot provenance before rerunning all preconditions. The installer never initiates a reboot.

If Docker returns 3010 but checkpoint persistence fails, the installer removes any partial checkpoint and restores the exact moved Compose shadow from its rollback receipt before failing. Restoration is idempotent when the source already contains the receipt's exact bytes and the backup is absent. A restoration failure has a separate stable error with the validated source, backup, hash, and size evidence, so later actions never proceed with an ambiguous partial transaction.

Docker Desktop is never upgraded by the ordinary installer run. An upgrade requires the separate `-UpgradeDockerDesktop -DockerBackupManifest <path>` opt-in and preserves the detected all-users installation at `C:\Program Files\Docker\Docker` with the exact payload `install --quiet --backend=wsl-2`. The schema-v1 manifest must contain:

- `source_desktop_version`, matching the installed source version;
- `install_mode` equal to `all-users` and `install_path` equal to `C:\Program Files\Docker\Docker`;
- an absolute `source_data_path` outside the Docker installation;
- exact positive `source_size_bytes` and lowercase `source_sha256` for the live source;
- an existing, nonempty `backup_path` outside Docker install, data, and plugin roots;
- exact `backup_size_bytes` and lowercase `backup_sha256` for that backup;
- a `created_utc` timestamp with a UTC `Z` suffix; and
- `desktop_stopped` equal to `true`.

The installer independently confirms that Docker Desktop processes are stopped before hashing the live source and again in a final callback after the installer's last SHA-256 check, immediately before the runner or `Start-Process` launch. Source and backup must be physical, non-reparse, non-hardlinked files whose recorded sizes and hashes prove they are byte-identical. The preservation and Compose-provenance gates run before any Docker installer download. It never prunes, resets, uninstalls, migrates install/data roots, changes container mode, invokes WSL, or updates WSL. The actual first Compose winner under Docker CLI precedence blocks the upgrade when it shadows Docker Desktop; it may only be moved to a timestamped sibling backup when `-BackupShadowingComposePlugin` is also supplied. A failed final callback or installer restores that exact moved file or fails closed; the plugin is never deleted and the lock is never rewritten to accept it. Success requires Docker Desktop's exact version and build: `4.85.0` build `235549`.

The Docker source is the uniquely detected, nonempty `docker_data.vhdx`, normally `%LOCALAPPDATA%\Docker\wsl\data\docker_data.vhdx` and, on newer layouts, potentially beneath the sibling `disk` directory. Absolute disk locations in Docker's settings are considered as well. Zero or multiple live candidates fail closed; the manifest's `source_data_path` must match that independently detected file exactly, and its backup must be outside the source data directory.

Machine provisioning and Docker upgrade are deliberate operator steps after the plan-only change has been reviewed and committed. The contract test and plan preview are safe to run beforehand:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\tooling\windows_installer_contract.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\install_windows_toolchain.ps1 -PlanOnly
```
