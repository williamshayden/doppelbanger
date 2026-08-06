[CmdletBinding()]
param(
    [switch]$PlanOnly,
    [switch]$UpgradeDockerDesktop,
    [string]$DockerBackupManifest,
    [switch]$BackupShadowingComposePlugin,
    [switch]$Resume,
    [string]$LockPath,
    [string]$CheckpointPath,
    [switch]$NoRun
)

$ErrorActionPreference = 'Stop'

function Stop-Installer {
    param([string]$Code, [string]$Message)
    throw "$Code`: $Message"
}

function Get-FileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Installer 'DBINST_ARTIFACT_MISSING' "artifact is missing: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ByteArraySha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return (($algorithm.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $algorithm.Dispose() }
}

function Get-StringSha256 {
    param([Parameter(Mandatory = $true)][string]$Value)
    return Get-ByteArraySha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($Value))
}

function Assert-ArtifactHash {
    param([string]$Path, [string]$Sha256)
    $expected = [string]$Sha256
    if ($expected -cnotmatch '^[0-9a-f]{64}$') { Stop-Installer 'DBINST_LOCK_INVALID' 'artifact SHA-256 is not an exact lowercase 64-character hexadecimal value' }
    $actual = Get-FileSha256 -Path $Path
    if ($actual -cne $expected) { Stop-Installer 'DBINST_CHECKSUM_MISMATCH' "SHA-256 mismatch for $Path (expected $expected, found $actual)" }
}

function Initialize-InstallerNativeMethods {
    if ('DoppelbangerInstallerNativeMethods' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class DoppelbangerInstallerNativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    public struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetFileInformationByHandle(
        SafeFileHandle file,
        out BY_HANDLE_FILE_INFORMATION information
    );
}
'@
}

function Get-InstallerHandleInformation {
    param([Parameter(Mandatory = $true)]$Handle)
    Initialize-InstallerNativeMethods
    $information = New-Object DoppelbangerInstallerNativeMethods+BY_HANDLE_FILE_INFORMATION
    if (-not [DoppelbangerInstallerNativeMethods]::GetFileInformationByHandle($Handle, [ref]$information)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' "artifact handle metadata could not be read (Win32 $errorCode)"
    }
    return $information
}

function Open-InstallerDirectoryLease {
    param([Parameter(Mandatory = $true)][string]$Path)
    Initialize-InstallerNativeMethods
    $fileReadAttributes = [uint32]0x80
    $fileShareRead = [uint32]0x1
    $openExisting = [uint32]0x3
    $backupSemantics = [uint32]0x02000000
    $openReparsePoint = [uint32]0x00200000
    $handle = [DoppelbangerInstallerNativeMethods]::CreateFile(
        [IO.Path]::GetFullPath($Path),
        $fileReadAttributes,
        $fileShareRead,
        [IntPtr]::Zero,
        $openExisting,
        ($backupSemantics -bor $openReparsePoint),
        [IntPtr]::Zero
    )
    if ($null -eq $handle -or $handle.IsInvalid) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($handle) { $handle.Dispose() }
        Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' "artifact ancestor could not be leased: $Path (Win32 $errorCode)"
    }
    $information = Get-InstallerHandleInformation -Handle $handle
    if (([uint32]$information.FileAttributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0) {
        $handle.Dispose()
        Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' "artifact ancestor is a reparse point: $Path"
    }
    return $handle
}

function Open-InstallerPhysicalLeafHandle {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][uint32]$DesiredAccess
    )
    Initialize-InstallerNativeMethods
    $fileShareRead = [uint32]0x1
    $openExisting = [uint32]0x3
    $fileAttributeNormal = [uint32]0x80
    $openReparsePoint = [uint32]0x00200000
    $handle = [DoppelbangerInstallerNativeMethods]::CreateFile(
        [IO.Path]::GetFullPath($Path),
        $DesiredAccess,
        $fileShareRead,
        [IntPtr]::Zero,
        $openExisting,
        ($fileAttributeNormal -bor $openReparsePoint),
        [IntPtr]::Zero
    )
    if ($null -eq $handle -or $handle.IsInvalid) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($handle) { $handle.Dispose() }
        Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' "bootstrap artifact leaf could not be opened without following reparses: $Path (Win32 $errorCode)"
    }
    $information = Get-InstallerHandleInformation -Handle $handle
    if (([uint32]$information.FileAttributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0 -or [uint32]$information.NumberOfLinks -ne 1) {
        $handle.Dispose()
        Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' "bootstrap artifact leaf must be one physical, non-hardlinked file: $Path"
    }
    return $handle
}

function Get-InstallerPhysicalLeafPathInformation {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fileReadAttributes = [uint32]0x80
    $handle = Open-InstallerPhysicalLeafHandle -Path $Path -DesiredAccess $fileReadAttributes
    try { return Get-InstallerHandleInformation -Handle $handle }
    finally { $handle.Dispose() }
}

function Test-InstallerSameFileIdentity {
    param($Left, $Right)
    return [uint32]$Left.VolumeSerialNumber -eq [uint32]$Right.VolumeSerialNumber -and
        [uint32]$Left.FileIndexHigh -eq [uint32]$Right.FileIndexHigh -and
        [uint32]$Left.FileIndexLow -eq [uint32]$Right.FileIndexLow
}

function Open-InstallerPhysicalLeafReadStream {
    param([Parameter(Mandatory = $true)][string]$Path)
    $genericRead = [Convert]::ToUInt32('80000000', 16)
    $handle = Open-InstallerPhysicalLeafHandle -Path $Path -DesiredAccess $genericRead
    try {
        $stream = New-Object IO.FileStream($handle, [IO.FileAccess]::Read)
        $handle = $null
        return $stream
    }
    finally { if ($handle) { $handle.Dispose() } }
}

function Close-VerifiedBootstrapArtifactLease {
    param($Lease)
    if ($null -eq $Lease) { return }
    if ($Lease.stream) { $Lease.stream.Dispose() }
    $handles = @($Lease.ancestor_handles)
    for ($index = $handles.Count - 1; $index -ge 0; $index--) {
        if ($handles[$index]) { $handles[$index].Dispose() }
    }
}

function Assert-VerifiedBootstrapArtifactLeaseStillValid {
    param([Parameter(Mandatory = $true)]$Lease)
    if ($null -eq $Lease.stream -or $Lease.stream.SafeFileHandle.IsInvalid -or $Lease.stream.SafeFileHandle.IsClosed) {
        Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' 'bootstrap artifact lease is not open'
    }
    $information = Get-InstallerHandleInformation -Handle $Lease.stream.SafeFileHandle
    if (([uint32]$information.FileAttributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0 -or [uint32]$information.NumberOfLinks -ne 1) {
        Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' "bootstrap artifact lease no longer names one physical, non-hardlinked leaf: $($Lease.path)"
    }
    $pathInformation = Get-InstallerPhysicalLeafPathInformation -Path $Lease.path
    if (-not (Test-InstallerSameFileIdentity -Left $information -Right $pathInformation)) {
        Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' "bootstrap artifact launch pathname no longer identifies the exact leased file: $($Lease.path)"
    }
    return $true
}

function Open-VerifiedBootstrapArtifactLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [scriptblock]$LeafStreamFactory
    )
    if ($Sha256 -cnotmatch '^[0-9a-f]{64}$') { Stop-Installer 'DBINST_LOCK_INVALID' 'artifact SHA-256 is not an exact lowercase 64-character hexadecimal value' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Installer 'DBINST_ARTIFACT_MISSING' "artifact is missing: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    try { Assert-NoReparsePath -Path $full -Root $root | Out-Null }
    catch { Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' "artifact path has unsafe ancestry: $full" }

    $ancestorHandles = New-Object 'Collections.Generic.List[object]'
    $stream = $null
    try {
        $parent = Split-Path -Parent $full
        $current = $root
        if (Test-Path -LiteralPath $current -PathType Container) { $ancestorHandles.Add((Open-InstallerDirectoryLease -Path $current)) }
        $relativeParent = $parent.Substring($root.Length).TrimStart('\')
        foreach ($segment in @($relativeParent -split '\\')) {
            if (-not $segment) { continue }
            $current = Join-Path $current $segment
            if (Test-Path -LiteralPath $current -PathType Container) { $ancestorHandles.Add((Open-InstallerDirectoryLease -Path $current)) }
        }

        $stream = if ($LeafStreamFactory) { & $LeafStreamFactory $full } else { Open-InstallerPhysicalLeafReadStream -Path $full }
        if ($stream -isnot [IO.FileStream]) { Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' 'bootstrap leaf stream factory did not return one file stream' }
        $leafInformation = Get-InstallerHandleInformation -Handle $stream.SafeFileHandle
        if (([uint32]$leafInformation.FileAttributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0 -or [uint32]$leafInformation.NumberOfLinks -ne 1) {
            Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' "bootstrap artifact must be one physical, non-hardlinked leaf: $full"
        }
        try { Assert-NoReparsePath -Path $full -Root $root | Out-Null }
        catch { Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' "artifact ancestry changed while acquiring its lease: $full" }
        if (Test-HardlinkedLeaf -Path $full) { Stop-Installer 'DBINST_ARTIFACT_PROVENANCE_INVALID' "bootstrap artifact is hardlinked: $full" }
        $stream.Position = 0
        $actual = Get-StreamSha256 -Stream $stream
        if ($actual -cne $Sha256) { Stop-Installer 'DBINST_CHECKSUM_MISMATCH' "SHA-256 mismatch for $full (expected $Sha256, found $actual)" }
        $stream.Position = 0
        $lease = [pscustomobject]@{ path = $full; stream = $stream; ancestor_handles = $ancestorHandles.ToArray(); sha256 = $actual }
        Assert-VerifiedBootstrapArtifactLeaseStillValid -Lease $lease | Out-Null
        return $lease
    }
    catch {
        if ($stream) { $stream.Dispose() }
        for ($index = $ancestorHandles.Count - 1; $index -ge 0; $index--) { $ancestorHandles[$index].Dispose() }
        throw
    }
}

function Read-InstallerLockFromObject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Lock)
    if ($Lock.schema_version -ne 1 -or $Lock.platform -cne 'windows-x86_64-native') {
        Stop-Installer 'DBINST_LOCK_INVALID' 'unsupported Windows toolchain lock object'
    }
    foreach ($artifact in @(
        @($Lock.visual_studio.url, $Lock.visual_studio.sha256),
        @($Lock.rust.rustup_url, $Lock.rust.rustup_sha256),
        @($Lock.cmake.url, $Lock.cmake.sha256),
        @($Lock.ninja.url, $Lock.ninja.sha256),
        @($Lock.node.url, $Lock.node.sha256),
        @($Lock.docker.url, $Lock.docker.sha256)
    )) {
        if ([string]$artifact[0] -notmatch '^https://') { Stop-Installer 'DBINST_LOCK_INVALID' 'every installer artifact URL must use HTTPS' }
        if ([string]$artifact[1] -cnotmatch '^[0-9a-f]{64}$') { Stop-Installer 'DBINST_LOCK_INVALID' 'every installer artifact must have an exact lowercase SHA-256' }
    }
    return $Lock
}

function Read-InstallerLock {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $lock = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    return Read-InstallerLockFromObject -Lock $lock
}

function Convert-InstallerLockedPath {
    param([string]$Path, [string]$LocalAppData)
    $expanded = $Path.Replace('%LOCALAPPDATA%', $LocalAppData)
    if ($expanded -match '%[^%]+%') { Stop-Installer 'DBINST_LOCK_INVALID' "unresolved environment variable in locked path: $Path" }
    return [IO.Path]::GetFullPath($expanded).TrimEnd('\')
}

function Assert-InstallerLockRoots {
    param([Parameter(Mandatory = $true)]$Lock, [Parameter(Mandatory = $true)][string]$LocalAppData)
    if ([string]$Lock.toolchain_root -cne '%LOCALAPPDATA%\Programs\doppelbanger-devtools') { Stop-Installer 'DBINST_LOCK_ROOT_INVALID' 'toolchain_root must be the canonical per-user devtools root' }
    $root = [IO.Path]::GetFullPath((Join-Path $LocalAppData 'Programs\doppelbanger-devtools')).TrimEnd('\')
    $expected = [ordered]@{
        cmake = Join-Path $root "cmake-$($Lock.cmake.version)-windows-x86_64"
        ninja = Join-Path $root "ninja-$($Lock.ninja.version)"
        node = Join-Path $root "node-v$($Lock.node.version)-win-x64"
    }
    foreach ($name in $expected.Keys) {
        $actual = Convert-InstallerLockedPath -Path ([string]$Lock.$name.root) -LocalAppData $LocalAppData
        if ($actual -ine [IO.Path]::GetFullPath($expected[$name]).TrimEnd('\')) { Stop-Installer 'DBINST_LOCK_ROOT_INVALID' "$name root is not its exact version-named devtools descendant" }
    }
    return [pscustomobject]$expected
}

function Get-ArtifactCacheName {
    param([string]$Url, [string]$Fallback)
    try {
        $name = [Uri]::UnescapeDataString([IO.Path]::GetFileName(([Uri]$Url).AbsolutePath))
        if ($name) { return $name }
    }
    catch { }
    return $Fallback
}

function New-WindowsToolchainInstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Lock,
        [Parameter(Mandatory = $true)][string]$LocalAppData,
        [switch]$UpgradeDocker
    )
    $localRoot = [IO.Path]::GetFullPath($LocalAppData).TrimEnd('\')
    Assert-InstallerLockRoots -Lock $Lock -LocalAppData $localRoot | Out-Null
    $cacheRoot = Join-Path $localRoot 'doppelbanger\downloads'
    $toolchainRoot = Join-Path $localRoot 'Programs\doppelbanger-devtools'
    $cmakeRoot = Convert-InstallerLockedPath -Path ([string]$Lock.cmake.root) -LocalAppData $localRoot
    $ninjaRoot = Convert-InstallerLockedPath -Path ([string]$Lock.ninja.root) -LocalAppData $localRoot
    $nodeRoot = Convert-InstallerLockedPath -Path ([string]$Lock.node.root) -LocalAppData $localRoot
    $actions = @(
        [pscustomobject][ordered]@{
            name = 'visual_studio'; kind = 'installer'; enabled = $true
            url = [string]$Lock.visual_studio.url; sha256 = [string]$Lock.visual_studio.sha256
            cache_path = Join-Path $cacheRoot (Get-ArtifactCacheName $Lock.visual_studio.url 'vs_BuildTools.exe')
            arguments = @('--quiet', '--wait', '--norestart', '--installPath', 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools', '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--add', [string]$Lock.visual_studio.msvc_component, '--add', [string]$Lock.visual_studio.windows_sdk_component)
        },
        [pscustomobject][ordered]@{
            name = 'rustup'; kind = 'installer'; enabled = $true
            url = [string]$Lock.rust.rustup_url; sha256 = [string]$Lock.rust.rustup_sha256
            cache_path = Join-Path $cacheRoot (Get-ArtifactCacheName $Lock.rust.rustup_url 'rustup-init.exe')
            arguments = @('-y', '--no-modify-path', '--default-host', [string]$Lock.rust.target, '--default-toolchain', "$($Lock.rust.toolchain)-$($Lock.rust.target)", '--profile', [string]$Lock.rust.profile, '--component', (@($Lock.rust.components) -join ','))
        },
        [pscustomobject][ordered]@{
            name = 'cmake'; kind = 'archive'; enabled = $true
            url = [string]$Lock.cmake.url; sha256 = [string]$Lock.cmake.sha256
            cache_path = Join-Path $cacheRoot (Get-ArtifactCacheName $Lock.cmake.url 'cmake.zip'); target_root = $cmakeRoot
            archive_subdirectory = [IO.Path]::GetFileName($cmakeRoot); arguments = @()
        },
        [pscustomobject][ordered]@{
            name = 'ninja'; kind = 'archive'; enabled = $true
            url = [string]$Lock.ninja.url; sha256 = [string]$Lock.ninja.sha256
            cache_path = Join-Path $cacheRoot (Get-ArtifactCacheName $Lock.ninja.url 'ninja.zip'); target_root = $ninjaRoot
            archive_subdirectory = ''; arguments = @()
        },
        [pscustomobject][ordered]@{
            name = 'node'; kind = 'archive'; enabled = $true
            url = [string]$Lock.node.url; sha256 = [string]$Lock.node.sha256
            cache_path = Join-Path $cacheRoot (Get-ArtifactCacheName $Lock.node.url 'node.zip'); target_root = $nodeRoot
            archive_subdirectory = [IO.Path]::GetFileName($nodeRoot); arguments = @()
        },
        [pscustomobject][ordered]@{
            name = 'docker'; kind = 'installer'; enabled = [bool]$UpgradeDocker
            gate = 'requires explicit -UpgradeDockerDesktop plus validated schema-v1 backup manifest, exact backup bytes, and live Desktop-stopped confirmation'
            url = [string]$Lock.docker.url; sha256 = [string]$Lock.docker.sha256
            cache_path = Join-Path $cacheRoot (Get-ArtifactCacheName $Lock.docker.url 'Docker Desktop Installer.exe')
            install_mode = 'all-users'; install_path = [string]$Lock.docker.root
            arguments = @('install', '--quiet', '--backend=wsl-2')
        }
    )
    $rustupHome = if ($env:RUSTUP_HOME) { [IO.Path]::GetFullPath($env:RUSTUP_HOME) } else { Join-Path $env:USERPROFILE '.rustup' }
    $pathEntries = @(
        (Join-Path $rustupHome "toolchains\$($Lock.rust.toolchain_directory)\bin"),
        (Join-Path $cmakeRoot 'bin'),
        $ninjaRoot,
        $nodeRoot
    )
    return [pscustomobject][ordered]@{
        schema_version = 1
        platform = 'windows-x86_64-native'
        cache_root = $cacheRoot
        toolchain_root = $toolchainRoot
        preconditions = [pscustomobject][ordered]@{ minimum_free_gib_per_target_volume = 40; pending_reboot_required = $false; plan_only_probes_machine = $false }
        actions = $actions
        user_path_entries = $pathEntries
    }
}

function New-WindowsToolchainLiveActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$ActionDefinitions,
        [switch]$UpgradeDocker
    )
    $topologyId = if ($UpgradeDocker) { 'windows-dev-v1-docker-opt-in' } else { 'windows-dev-v1-default' }
    $names = New-Object 'Collections.Generic.List[string]'
    foreach ($name in @('visual_studio', 'rustup', 'cmake', 'ninja', 'node')) { $names.Add($name) }
    if ($UpgradeDocker) { $names.Add('docker') }
    $names.Add('user_path')
    $actions = New-Object 'Collections.Generic.List[object]'
    foreach ($name in $names) {
        if (-not $ActionDefinitions.Contains($name) -or $null -eq $ActionDefinitions[$name] -or -not $ActionDefinitions[$name].invoke) {
            Stop-Installer 'DBINST_LIVE_TOPOLOGY_INVALID' "live topology $topologyId has no injected definition for $name"
        }
        $definition = $ActionDefinitions[$name]
        $actions.Add([pscustomobject][ordered]@{
            topology_id = $topologyId
            name = $name
            plan = if ($definition.PSObject.Properties['plan']) { $definition.plan } else { $null }
            checkpoint_on_3010 = [bool]$definition.checkpoint_on_3010
            invoke = $definition.invoke
            postcondition = $definition.postcondition
            rollback = if ($definition.PSObject.Properties['rollback']) { $definition.rollback } else { $null }
        })
    }
    return $actions.ToArray()
}

function Invoke-WindowsToolchainLiveActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Actions,
        [Parameter(Mandatory = $true)][string]$CheckpointPath,
        [string]$CheckpointRoot,
        [Parameter(Mandatory = $true)][string]$LockSha256,
        $InstallOptions = @{},
        [string]$BootSessionMarker = 'test-unspecified-boot',
        [scriptblock]$EnvironmentCheck = { },
        [Parameter(Mandatory = $true)][scriptblock]$PreconditionCheck,
        [scriptblock]$CheckpointWriter,
        [switch]$Resume
    )
    $topologyIds = @($Actions | Select-Object -ExpandProperty topology_id -Unique)
    if ($topologyIds.Count -ne 1 -or $topologyIds[0] -notin @('windows-dev-v1-default', 'windows-dev-v1-docker-opt-in')) {
        Stop-Installer 'DBINST_LIVE_TOPOLOGY_INVALID' 'live action descriptors do not share one recognized topology identifier'
    }
    $expected = if ($topologyIds[0] -ceq 'windows-dev-v1-default') {
        'visual_studio,rustup,cmake,ninja,node,user_path'
    }
    else { 'visual_studio,rustup,cmake,ninja,node,docker,user_path' }
    if ((@($Actions | ForEach-Object { [string]$_.name }) -join ',') -cne $expected) {
        Stop-Installer 'DBINST_LIVE_TOPOLOGY_INVALID' "live action order does not match $($topologyIds[0])"
    }
    return Invoke-InstallActionSequence -Actions $Actions -CheckpointPath $CheckpointPath -CheckpointRoot $CheckpointRoot -LockSha256 $LockSha256 -InstallOptions $InstallOptions -BootSessionMarker $BootSessionMarker -EnvironmentCheck $EnvironmentCheck -PreconditionCheck $PreconditionCheck -CheckpointWriter $CheckpointWriter -Resume:$Resume
}

function Assert-InstallPreconditions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$TargetPaths,
        [scriptblock]$VolumeProbe,
        [scriptblock]$PendingRebootProbe
    )
    if (-not $PendingRebootProbe) {
        $PendingRebootProbe = { return Get-PendingRebootState }
    }
    try { $pendingState = & $PendingRebootProbe }
    catch { Stop-Installer 'DBINST_PENDING_REBOOT_UNKNOWN' "pending reboot state could not be read: $($_.Exception.Message)" }
    if ($pendingState -isnot [bool]) { Stop-Installer 'DBINST_PENDING_REBOOT_UNKNOWN' 'pending reboot state could not be determined exactly' }
    if ($pendingState) { Stop-Installer 'DBINST_PENDING_REBOOT' 'Windows reports a pending reboot; reboot before provisioning or resuming' }
    if (-not $VolumeProbe) {
        $VolumeProbe = { param($Root) return [math]::Round((New-Object IO.DriveInfo($Root)).AvailableFreeSpace / 1GB, 2) }
    }
    $seen = @{}
    $volumes = New-Object 'Collections.Generic.List[object]'
    foreach ($path in $TargetPaths) {
        $full = [IO.Path]::GetFullPath($path)
        $root = [IO.Path]::GetPathRoot($full)
        if (-not $root) { Stop-Installer 'DBINST_TARGET_INVALID' "target path has no volume: $path" }
        $key = $root.ToUpperInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $free = [double](& $VolumeProbe $root)
        if ([double]::IsNaN($free) -or [double]::IsInfinity($free)) { Stop-Installer 'DBINST_FREE_SPACE_UNKNOWN' "free space could not be determined for target volume $root" }
        $volumes.Add([pscustomobject][ordered]@{ root = $root; free_gib = $free })
        if ($free -lt 40) { Stop-Installer 'DBINST_LOW_DISK' "target volume $root has $free GiB free; 40 GiB is required" }
    }
    return [pscustomobject][ordered]@{ pending_reboot = $false; volumes = $volumes.ToArray() }
}

function Get-PendingRebootState {
    foreach ($marker in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) {
        if (Test-Path -LiteralPath $marker -ErrorAction Stop) { return $true }
    }
    $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
    if ($sessionManager.PSObject.Properties.Name -contains 'PendingFileRenameOperations') { return @($sessionManager.PendingFileRenameOperations).Count -gt 0 }
    return $false
}

function Assert-NativeInstallEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Probe)
    $forbiddenAncestors = @($Probe.ancestors | Where-Object { ([IO.Path]::GetFileName([string]$_)).ToLowerInvariant() -in @('wsl.exe', 'wslhost.exe', 'bash.exe') })
    if ([string]$Probe.os -cne 'Windows' -or [string]$Probe.arch -cne 'x86_64' -or $Probe.wsl -or $Probe.wsl_distro_name -or $Probe.wsl_interop -or $forbiddenAncestors.Count -gt 0) {
        Stop-Installer 'DBINST_NATIVE_WINDOWS_REQUIRED' 'native Windows x64 without WSL, wslhost, or bash ancestry is required'
    }
    return $true
}

function Get-NativeInstallEnvironmentProbe {
    $ancestors = New-Object 'Collections.Generic.List[string]'
    $processId = $PID
    for ($index = 0; $index -lt 32 -and $processId -gt 0; $index++) {
        try { $process = Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop }
        catch {
            try { $process = Get-WmiObject Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop }
            catch { Stop-Installer 'DBINST_NATIVE_WINDOWS_REQUIRED' 'native process ancestry could not be read completely' }
        }
        if (-not $process) { Stop-Installer 'DBINST_NATIVE_WINDOWS_REQUIRED' 'native process ancestry returned an unknown process' }
        $ancestors.Add([string]$process.Name)
        $processId = [int]$process.ParentProcessId
    }
    return [pscustomobject][ordered]@{
        os = if ($env:OS -ceq 'Windows_NT') { 'Windows' } else { [Environment]::OSVersion.Platform.ToString() }
        arch = if ($env:PROCESSOR_ARCHITECTURE -ceq 'AMD64') { 'x86_64' } else { [string]$env:PROCESSOR_ARCHITECTURE }
        wsl = [bool]($env:WSL_DISTRO_NAME -or $env:WSL_INTEROP); wsl_distro_name = [string]$env:WSL_DISTRO_NAME; wsl_interop = [string]$env:WSL_INTEROP
        ancestors = $ancestors.ToArray()
    }
}

function Get-NativeBootSessionMarker {
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
    catch {
        try { $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop }
        catch { Stop-Installer 'DBINST_BOOT_SESSION_UNKNOWN' 'native Windows boot-session marker could not be read' }
    }
    $boot = [string]$os.LastBootUpTime
    if ([string]::IsNullOrWhiteSpace($boot)) { Stop-Installer 'DBINST_BOOT_SESSION_UNKNOWN' 'native Windows boot-session marker is empty' }
    return Get-StringSha256 -Value ("$env:COMPUTERNAME|$boot")
}

function Get-InstallPreflightTargets {
    [CmdletBinding()]
    param($Plan, $Lock, [string]$RustupHome, [string]$CargoHome, [string]$CheckpointPath, [string[]]$DockerPaths)
    $targets = New-Object 'Collections.Generic.List[string]'
    $programFilesX86 = if (${env:ProgramFiles(x86)}) { [IO.Path]::GetFullPath(${env:ProgramFiles(x86)}) } else { 'C:\Program Files (x86)' }
    $programData = if ($env:ProgramData) { [IO.Path]::GetFullPath($env:ProgramData) } else { 'C:\ProgramData' }
    foreach ($path in @(
        [string]$Plan.cache_root,
        [string](@($Plan.actions | Where-Object name -eq 'cmake')[0].target_root),
        [string](@($Plan.actions | Where-Object name -eq 'ninja')[0].target_root),
        [string](@($Plan.actions | Where-Object name -eq 'node')[0].target_root),
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools',
        (Join-Path $programFilesX86 'Windows Kits\10'),
        (Join-Path $programData 'Microsoft\VisualStudio\Packages\_Instances'),
        (Join-Path $programFilesX86 'Microsoft Visual Studio\Installer'),
        $RustupHome, [IO.Path]::Combine($RustupHome, 'toolchains', [string]$Lock.rust.toolchain_directory),
        $CargoHome, [IO.Path]::Combine($CargoHome, 'bin'), (Split-Path -Parent $CheckpointPath)
    ) + @($DockerPaths)) {
        if ($path -and -not @($targets | Where-Object { $_ -ieq $path }).Count) { $targets.Add($path) }
    }
    return $targets.ToArray()
}

function Assert-InstallPreflightTargetAncestry {
    [CmdletBinding()]
    param([string[]]$TargetPaths)
    foreach ($targetPath in @($TargetPaths)) {
        if (-not $targetPath) { continue }
        $targetFull = [IO.Path]::GetFullPath([string]$targetPath)
        Assert-NoReparsePath -Path $targetFull -Root ([IO.Path]::GetPathRoot($targetFull)) -AllowMissingLeaf | Out-Null
    }
    return $true
}

function Invoke-Tls12Download {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [scriptblock]$DownloadOperation
    )
    $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]([int]$previousProtocol -bor 3072)
        if ($DownloadOperation) { & $DownloadOperation $Url $Destination }
        else {
            $client = New-Object Net.WebClient
            try { $client.DownloadFile($Url, $Destination) }
            finally { $client.Dispose() }
        }
    }
    finally { [Net.ServicePointManager]::SecurityProtocol = $previousProtocol }
}

function Get-VerifiedArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$CachePath,
        [switch]$PlanOnly,
        [scriptblock]$Downloader
    )
    if ($PlanOnly) { return [pscustomobject][ordered]@{ url = $Url; sha256 = $Sha256; cache_path = $CachePath; mutation = $false } }
    if (Test-Path -LiteralPath $CachePath -PathType Leaf) {
        $cachedLease = Open-VerifiedBootstrapArtifactLease -Path $CachePath -Sha256 $Sha256
        Close-VerifiedBootstrapArtifactLease -Lease $cachedLease
        return [IO.Path]::GetFullPath($CachePath)
    }
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($CachePath))
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = Join-Path $parent ('.download-{0}.partial' -f [Guid]::NewGuid().ToString('N'))
    try {
        Invoke-Tls12Download -Url $Url -Destination $temporary -DownloadOperation $Downloader
        $downloadLease = Open-VerifiedBootstrapArtifactLease -Path $temporary -Sha256 $Sha256
        Close-VerifiedBootstrapArtifactLease -Lease $downloadLease
        if (Test-Path -LiteralPath $CachePath) {
            $raceWinnerLease = Open-VerifiedBootstrapArtifactLease -Path $CachePath -Sha256 $Sha256
            Close-VerifiedBootstrapArtifactLease -Lease $raceWinnerLease
        }
        else { [IO.File]::Move($temporary, [IO.Path]::GetFullPath($CachePath)) }
        $placedLease = Open-VerifiedBootstrapArtifactLease -Path $CachePath -Sha256 $Sha256
        Close-VerifiedBootstrapArtifactLease -Lease $placedLease
        return [IO.Path]::GetFullPath($CachePath)
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Invoke-BootstrapProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [scriptblock]$ProcessStarter
    )
    $commandLineArguments = New-Object 'Collections.Generic.List[string]'
    foreach ($argument in $Arguments) {
        if ([string]$argument -match '"') { Stop-Installer 'DBINST_ARGUMENT_INVALID' 'locked bootstrap arguments may not contain embedded quotes' }
        if ([string]$argument -match '\s') { $commandLineArguments.Add('"' + [string]$argument + '"') }
        else { $commandLineArguments.Add([string]$argument) }
    }
    $startArguments = @{
        FilePath = $Path
        ArgumentList = ($commandLineArguments.ToArray() -join ' ')
        Wait = $true
        PassThru = $true
    }
    $process = if ($ProcessStarter) { & $ProcessStarter $startArguments } else { Start-Process @startArguments }
    if ($null -eq $process -or $null -eq $process.ExitCode) { Stop-Installer 'DBINST_PROCESS_RESULT_INVALID' 'bootstrap process did not return an authoritative exit code' }
    return [int]$process.ExitCode
}

function Invoke-IdempotentInstallAction {
    [CmdletBinding()]
    param([string]$Name, [scriptblock]$StateProbe, [scriptblock]$Mutation)
    $state = [string](& $StateProbe)
    if ($state -ceq 'exact') { return [pscustomobject][ordered]@{ name = $Name; status = 'already_installed'; exit_code = 0 } }
    if ($state -ceq 'conflict') { Stop-Installer 'DBINST_INSTALLED_STATE_CONFLICT' "$Name has conflicting installed state at its fixed root" }
    if ($state -cne 'missing' -and $state -cne 'repairable') { Stop-Installer 'DBINST_INSTALLED_STATE_UNKNOWN' "$Name installed state could not be determined exactly" }
    return & $Mutation
}

function Invoke-VerifiedBootstrapInstaller {
    param([string]$ArtifactPath, [string]$Sha256, [string[]]$Arguments, [scriptblock]$BeforeLaunch, [scriptblock]$Runner, [switch]$PlanOnly)
    if ($PlanOnly) { return [pscustomobject][ordered]@{ artifact_path = $ArtifactPath; sha256 = $Sha256; arguments = $Arguments; mutation = $false } }
    $lease = Open-VerifiedBootstrapArtifactLease -Path $ArtifactPath -Sha256 $Sha256
    try {
        if ($BeforeLaunch) { & $BeforeLaunch }
        Assert-VerifiedBootstrapArtifactLeaseStillValid -Lease $lease | Out-Null
        $exitCode = if ($Runner) { [int](& $Runner $lease.path $Arguments) }
        else { Invoke-BootstrapProcess -Path $lease.path -Arguments $Arguments }
        Assert-VerifiedBootstrapArtifactLeaseStillValid -Lease $lease | Out-Null
        return $exitCode
    }
    finally { Close-VerifiedBootstrapArtifactLease -Lease $lease }
}

function Test-InstallerPhysicalLeaf {
    param([string]$Path, [string]$TrustedRoot)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { Assert-NoReparsePath -Path $Path -Root $TrustedRoot | Out-Null } catch { return $false }
    return -not (Test-HardlinkedLeaf -Path $Path)
}

function Test-InstallerPhysicalContainer {
    param([string]$Path, [string]$TrustedRoot)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    try { Assert-NoReparsePath -Path $Path -Root $TrustedRoot | Out-Null; return $true } catch { return $false }
}

function Get-SafeNamedDescendantFiles {
    param([string]$Root, [string]$Name)
    $files = New-Object 'Collections.Generic.List[string]'
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return [pscustomobject]@{ files = @(); unsafe = $false } }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if ([bool]($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return [pscustomobject]@{ files = @(); unsafe = $true } }
    $unsafe = $false
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push([IO.Path]::GetFullPath($Root))
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $unsafe = $true; continue }
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            if ($item.Name -ceq $Name) {
                if (Test-HardlinkedLeaf -Path $item.FullName) { $unsafe = $true }
                else { $files.Add($item.FullName) }
            }
        }
    }
    return [pscustomobject]@{ files = $files.ToArray(); unsafe = $unsafe }
}

function Assert-InstallerPhysicalTree {
    param([string]$Root, [string]$Code, [string]$Description)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { Stop-Installer $Code "$Description root is missing: $Root" }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if ([bool]($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Stop-Installer $Code "$Description root is a reparse point: $Root" }
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push([IO.Path]::GetFullPath($Root))
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Stop-Installer $Code "$Description contains a reparse descendant: $($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            elseif (Test-HardlinkedLeaf -Path $item.FullName) { Stop-Installer $Code "$Description contains a hardlinked file: $($item.FullName)" }
        }
    }
}

function Get-VisualStudioStateRecord {
    param($Lock, [string]$InstallPath, [string]$InstancesRoot)
    if (-not $InstancesRoot) { $InstancesRoot = Join-Path $env:ProgramData 'Microsoft\VisualStudio\Packages\_Instances' }
    $instancesFull = [IO.Path]::GetFullPath($InstancesRoot).TrimEnd('\')
    try { Assert-NoReparsePath -Path $instancesFull -Root ([IO.Path]::GetPathRoot($instancesFull)) -AllowMissingLeaf | Out-Null }
    catch { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'Visual Studio instance metadata root has unsafe path ancestry' }
    $scan = Get-SafeNamedDescendantFiles -Root $instancesFull -Name 'state.json'
    if ($scan.unsafe) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'Visual Studio instance metadata contains unsafe links' }
    $matchedPath = $false
    foreach ($statePath in @($scan.files)) {
        try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { continue }
        if (-not $state.installationPath) { continue }
        if ([IO.Path]::GetFullPath([string]$state.installationPath).TrimEnd('\') -ine [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')) { continue }
        $matchedPath = $true
        if ([string]$state.installationVersion -cne [string]$Lock.visual_studio.installation_version -or [string]$state.catalogInfo.productDisplayVersion -cne [string]$Lock.visual_studio.product_version) {
            Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'the fixed VS root belongs to a different or unknown instance version'
        }
        return [pscustomobject]@{ state = $state; state_path = $statePath }
    }
    if ($matchedPath) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'matching VS state could not be validated' }
    Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'the fixed VS root has no exact physical instance state record'
}

function Assert-VisualStudioRequiredComponents {
    param($Lock, [string]$InstallPath, [string]$VswherePath, [scriptblock]$VswhereRunner)
    if (-not $VswherePath) { $VswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe' }
    if (-not [IO.Path]::IsPathRooted($VswherePath)) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'vswhere path must be absolute' }
    $vswhereFull = [IO.Path]::GetFullPath($VswherePath)
    try { Assert-NoReparsePath -Path $vswhereFull -Root ([IO.Path]::GetPathRoot($vswhereFull)) | Out-Null }
    catch { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'bundled vswhere has unsafe path ancestry' }
    if (-not (Test-InstallerPhysicalLeaf -Path $vswhereFull -TrustedRoot (Split-Path -Parent $vswhereFull))) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'bundled vswhere executable is missing or unsafe' }
    $arguments = @(
        '-products', 'Microsoft.VisualStudio.Product.BuildTools', '-requires',
        'Microsoft.VisualStudio.Workload.VCTools',
        [string]$Lock.visual_studio.msvc_component,
        [string]$Lock.visual_studio.windows_sdk_component,
        '-property', 'installationPath'
    )
    if ($VswhereRunner) { $result = & $VswhereRunner $vswhereFull $arguments }
    else {
        $output = & $vswhereFull @arguments 2>&1 | Out-String
        $result = [pscustomobject]@{ exit_code = [int]$LASTEXITCODE; output = [string]$output }
    }
    if ($null -eq $result -or $null -eq $result.exit_code -or [int]$result.exit_code -ne 0) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'vswhere required-component query failed' }
    $fixedFull = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
    $matched = $false
    foreach ($line in @([string]$result.output -split "`r?`n")) {
        $candidate = $line.Trim()
        if (-not $candidate -or -not [IO.Path]::IsPathRooted($candidate)) { continue }
        if ([IO.Path]::GetFullPath($candidate).TrimEnd('\') -ieq $fixedFull) { $matched = $true; break }
    }
    if (-not $matched) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'vswhere did not return the fixed VS root for all required components' }
}

function Test-VisualStudioOwnedPathsUnsafe {
    param($Lock, [string]$InstallPath, [string]$InstancesRoot, [string]$WindowsSdkRoot, [string]$VswherePath)
    $installFull = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
    $auxiliaryPaths = New-Object 'Collections.Generic.List[string]'
    $auxiliaryPaths.Add($installFull)
    if ($InstancesRoot) { $auxiliaryPaths.Add([IO.Path]::GetFullPath($InstancesRoot).TrimEnd('\')) }
    if ($WindowsSdkRoot) { $auxiliaryPaths.Add([IO.Path]::GetFullPath($WindowsSdkRoot).TrimEnd('\')) }
    if ($VswherePath) {
        $vswhereFull = [IO.Path]::GetFullPath($VswherePath)
        $auxiliaryPaths.Add((Split-Path -Parent $vswhereFull))
        $auxiliaryPaths.Add($vswhereFull)
    }
    foreach ($auxiliaryPath in $auxiliaryPaths) {
        try { Assert-NoReparsePath -Path $auxiliaryPath -Root ([IO.Path]::GetPathRoot($auxiliaryPath)) -AllowMissingLeaf | Out-Null }
        catch { return $true }
    }
    $owned = New-Object 'Collections.Generic.List[object]'
    $owned.Add([pscustomobject]@{ path = Join-Path $installFull 'Common7\Tools\VsDevCmd.bat'; root = $installFull })
    $versionPath = Join-Path $installFull 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
    $owned.Add([pscustomobject]@{ path = $versionPath; root = $installFull })
    if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
        $toolsetVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
        if ($toolsetVersion -match '^14\.44\.[0-9]+(?:\.[0-9]+)?$') {
            $toolsetRoot = Join-Path $installFull "VC\Tools\MSVC\$toolsetVersion"
            foreach ($relative in @('include', 'lib\x64', 'bin\Hostx64\x64', 'bin\Hostx64\x64\cl.exe', 'bin\Hostx64\x64\link.exe', 'bin\Hostx64\x64\lib.exe', 'bin\Hostx64\x64\dumpbin.exe')) { $owned.Add([pscustomobject]@{ path = Join-Path $toolsetRoot $relative; root = $installFull }) }
        }
    }
    if ($WindowsSdkRoot) {
        $sdkFull = [IO.Path]::GetFullPath($WindowsSdkRoot).TrimEnd('\')
        $sdkTarget = [string]$Lock.visual_studio.windows_sdk_target
        foreach ($relative in @("Include\$sdkTarget\ucrt", "Include\$sdkTarget\shared", "Include\$sdkTarget\um", "Include\$sdkTarget\winrt", "Include\$sdkTarget\cppwinrt", "Lib\$sdkTarget\ucrt\x64", "Lib\$sdkTarget\um\x64", "Include\$sdkTarget\um\Windows.h", "Lib\$sdkTarget\um\x64\kernel32.lib", "Lib\$sdkTarget\ucrt\x64\ucrt.lib")) { $owned.Add([pscustomobject]@{ path = Join-Path $sdkFull $relative; root = $sdkFull }) }
    }
    if ($VswherePath) { $owned.Add([pscustomobject]@{ path = [IO.Path]::GetFullPath($VswherePath); root = Split-Path -Parent ([IO.Path]::GetFullPath($VswherePath)) }) }
    if ($InstancesRoot) {
        $instanceScan = Get-SafeNamedDescendantFiles -Root ([IO.Path]::GetFullPath($InstancesRoot)) -Name 'state.json'
        if ($instanceScan.unsafe) { return $true }
        foreach ($statePath in @($instanceScan.files)) { $owned.Add([pscustomobject]@{ path = $statePath; root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($statePath)) }) }
    }
    foreach ($entry in $owned) {
        if (-not (Test-Path -LiteralPath $entry.path)) { continue }
        try { Assert-NoReparsePath -Path $entry.path -Root $entry.root | Out-Null } catch { return $true }
        if (Test-Path -LiteralPath $entry.path -PathType Leaf) { if (Test-HardlinkedLeaf -Path $entry.path) { return $true } }
    }
    return $false
}

function Assert-VisualStudioInstallPostcondition {
    param($Lock, [string]$InstallPath = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools', [string]$InstancesRoot, [string]$WindowsSdkRoot, [string]$VswherePath, [scriptblock]$VswhereRunner)
    if (-not (Test-Path -LiteralPath $InstallPath -PathType Container)) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' "exact VS Build Tools root is missing: $InstallPath" }
    if (-not $InstancesRoot) { $InstancesRoot = Join-Path $env:ProgramData 'Microsoft\VisualStudio\Packages\_Instances' }
    if (-not $WindowsSdkRoot) { $WindowsSdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10' }
    if (-not $VswherePath) { $VswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe' }
    $installFull = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
    try { Assert-NoReparsePath -Path $installFull -Root ([IO.Path]::GetPathRoot($installFull)) | Out-Null }
    catch { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'the fixed VS root has unsafe path ancestry' }
    foreach ($auxiliaryPath in @([IO.Path]::GetFullPath($InstancesRoot), [IO.Path]::GetFullPath($WindowsSdkRoot), (Split-Path -Parent ([IO.Path]::GetFullPath($VswherePath))), [IO.Path]::GetFullPath($VswherePath))) {
        try { Assert-NoReparsePath -Path $auxiliaryPath -Root ([IO.Path]::GetPathRoot($auxiliaryPath)) | Out-Null }
        catch { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' "Visual Studio auxiliary path has unsafe ancestry: $auxiliaryPath" }
    }
    $record = Get-VisualStudioStateRecord -Lock $Lock -InstallPath $installFull -InstancesRoot $InstancesRoot
    try { Assert-NoReparsePath -Path $record.state_path -Root ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($record.state_path))) | Out-Null }
    catch { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'VS instance state has unsafe path ancestry' }
    if (-not (Test-InstallerPhysicalLeaf -Path $record.state_path -TrustedRoot ([IO.Path]::GetFullPath($InstancesRoot)))) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'VS instance state is not one physical file' }
    Assert-VisualStudioRequiredComponents -Lock $Lock -InstallPath $installFull -VswherePath $VswherePath -VswhereRunner $VswhereRunner
    $vsdevcmd = Join-Path $installFull 'Common7\Tools\VsDevCmd.bat'
    $versionPath = Join-Path $installFull 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
    foreach ($supportFile in @($vsdevcmd, $versionPath)) {
        if (-not (Test-InstallerPhysicalLeaf -Path $supportFile -TrustedRoot $installFull)) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' "VS support/version file is missing or unsafe: $supportFile" }
    }
    $toolsetVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
    if ($toolsetVersion -cnotmatch '^14\.44\.[0-9]+(?:\.[0-9]+)?$') { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' 'VS default toolset is not an exact 14.44 version' }
    $toolsetRoot = Join-Path $installFull "VC\Tools\MSVC\$toolsetVersion"
    foreach ($directory in @((Join-Path $toolsetRoot 'include'), (Join-Path $toolsetRoot 'lib\x64'), (Join-Path $toolsetRoot 'bin\Hostx64\x64'))) {
        if (-not (Test-InstallerPhysicalContainer -Path $directory -TrustedRoot $installFull)) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' "VS toolset directory is missing or unsafe: $directory" }
    }
    foreach ($binaryName in @('cl.exe', 'link.exe', 'lib.exe', 'dumpbin.exe')) {
        $binaryPath = Join-Path $toolsetRoot "bin\Hostx64\x64\$binaryName"
        if (-not (Test-PhysicalAmd64Pe -Path $binaryPath) -or -not (Test-InstallerPhysicalLeaf -Path $binaryPath -TrustedRoot $installFull)) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' "VS toolset binary is not one physical AMD64 PE file: $binaryName" }
    }
    $sdkFull = [IO.Path]::GetFullPath($WindowsSdkRoot).TrimEnd('\')
    $sdkTarget = [string]$Lock.visual_studio.windows_sdk_target
    foreach ($directory in @(
        (Join-Path $sdkFull "Include\$sdkTarget\ucrt"), (Join-Path $sdkFull "Include\$sdkTarget\shared"),
        (Join-Path $sdkFull "Include\$sdkTarget\um"), (Join-Path $sdkFull "Include\$sdkTarget\winrt"),
        (Join-Path $sdkFull "Include\$sdkTarget\cppwinrt"), (Join-Path $sdkFull "Lib\$sdkTarget\ucrt\x64"),
        (Join-Path $sdkFull "Lib\$sdkTarget\um\x64")
    )) {
        if (-not (Test-InstallerPhysicalContainer -Path $directory -TrustedRoot $sdkFull)) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' "Windows SDK directory is missing or unsafe: $directory" }
    }
    foreach ($supportFile in @(
        (Join-Path $sdkFull "Include\$sdkTarget\um\Windows.h"),
        (Join-Path $sdkFull "Lib\$sdkTarget\um\x64\kernel32.lib"),
        (Join-Path $sdkFull "Lib\$sdkTarget\ucrt\x64\ucrt.lib")
    )) {
        if (-not (Test-InstallerPhysicalLeaf -Path $supportFile -TrustedRoot $sdkFull)) { Stop-Installer 'DBINST_VS_POSTCONDITION_FAILED' "Windows SDK support file is missing or unsafe: $supportFile" }
    }
}

function Assert-RustToolchainPayloadPostcondition {
    param($Lock, [string]$RustupHome)
    $root = Join-Path (Join-Path $RustupHome 'toolchains') $Lock.rust.toolchain_directory
    try { Assert-NoReparsePath -Path $root -Root ([IO.Path]::GetFullPath($RustupHome)) | Out-Null }
    catch { Stop-Installer 'DBINST_RUST_POSTCONDITION_FAILED' 'locked Rust toolchain has unsafe path ancestry' }
    Assert-InstallerPhysicalTree -Root $root -Code 'DBINST_RUST_POSTCONDITION_FAILED' -Description 'locked Rust toolchain'
    $rustlib = Join-Path $root 'lib\rustlib'
    $installerVersion = Join-Path $rustlib 'rust-installer-version'
    $channelManifest = Join-Path $rustlib 'multirust-channel-manifest.toml'
    $configManifest = Join-Path $rustlib 'multirust-config.toml'
    $componentsPath = Join-Path $rustlib 'components'
    foreach ($required in @($installerVersion, $channelManifest, $configManifest, $componentsPath)) {
        if (-not (Test-InstallerPhysicalLeaf -Path $required -TrustedRoot $root)) { Stop-Installer 'DBINST_RUST_POSTCONDITION_FAILED' "physical Rust manifest is missing or unsafe: $required" }
    }
    if ((Get-Content -LiteralPath $installerVersion -Raw).Trim() -cne '3') { Stop-Installer 'DBINST_RUST_POSTCONDITION_FAILED' 'physical Rust installer manifest version is invalid' }
    $channel = Get-Content -LiteralPath $channelManifest -Raw
    $channelSection = ''
    $channelVersion = ''
    foreach ($line in @($channel -split "`r?`n")) {
        if ($line -match '^\s*\[([^]]+)\]\s*(?:#.*)?$') { $channelSection = $Matches[1].Trim(); continue }
        if ($channelSection -ceq 'pkg.rustc' -and $line -match '^\s*version\s*=\s*[''"]([^''"]+)[''"]') { $channelVersion = $Matches[1]; break }
    }
    if ($channelVersion -notmatch ('^' + [regex]::Escape([string]$Lock.rust.toolchain) + '(?:\s|\(|$)')) { Stop-Installer 'DBINST_RUST_POSTCONDITION_FAILED' 'physical Rust channel manifest does not identify the locked rustc toolchain' }
    $components = @(Get-Content -LiteralPath $componentsPath)
    $componentFiles = @{
        "rustc-$($Lock.rust.target)" = @('rustc.exe')
        "cargo-$($Lock.rust.target)" = @('cargo.exe')
        "rustfmt-preview-$($Lock.rust.target)" = @('rustfmt.exe')
        "clippy-preview-$($Lock.rust.target)" = @('clippy-driver.exe', 'cargo-clippy.exe')
    }
    foreach ($component in $componentFiles.Keys) {
        $componentManifest = Join-Path $rustlib "manifest-$component"
        if ($components -notcontains $component -or -not (Test-InstallerPhysicalLeaf -Path $componentManifest -TrustedRoot $root)) { Stop-Installer 'DBINST_RUST_POSTCONDITION_FAILED' "physical Rust component manifest is missing or unsafe: $component" }
        $ownedFiles = @(Get-Content -LiteralPath $componentManifest)
        foreach ($file in $componentFiles[$component]) {
            $binaryPath = Join-Path $root "bin\$file"
            if ($ownedFiles -notcontains "file:bin/$file" -or -not (Test-PhysicalAmd64Pe -Path $binaryPath) -or -not (Test-InstallerPhysicalLeaf -Path $binaryPath -TrustedRoot $root)) { Stop-Installer 'DBINST_RUST_POSTCONDITION_FAILED' "physical Rust component does not own one AMD64 executable: $file" }
        }
    }
}

function Get-RustToolchainTreeManifest {
    param($Lock, [string]$RustupHome)
    $root = Join-Path (Join-Path $RustupHome 'toolchains') $Lock.rust.toolchain_directory
    Assert-RustToolchainPayloadPostcondition -Lock $Lock -RustupHome $RustupHome
    $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
    $files = New-Object 'Collections.Generic.List[object]'
    $directories = New-Object 'Collections.Generic.List[string]'
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($rootFull)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Stop-Installer 'DBINST_RUST_POSTCONDITION_FAILED' "Rust tree contains a reparse descendant: $($item.FullName)" }
            $relative = $item.FullName.Substring($rootFull.Length).TrimStart('\')
            if ($item.PSIsContainer) {
                $directories.Add($relative)
                $pending.Push($item.FullName)
            }
            else {
                if (Test-HardlinkedLeaf -Path $item.FullName) { Stop-Installer 'DBINST_RUST_POSTCONDITION_FAILED' "Rust tree contains a hardlinked file: $($item.FullName)" }
                $files.Add([pscustomobject][ordered]@{
                    relative_path = $relative
                    length = [long]$item.Length
                    sha256 = Get-FileSha256 -Path $item.FullName
                })
            }
        }
    }
    return [pscustomobject][ordered]@{
        directories = @($directories.ToArray() | Sort-Object)
        files = @($files.ToArray() | Sort-Object -Property relative_path)
    }
}

function Assert-RustReceiptPath {
    param([string]$ReceiptPath, [string]$RustRoot, [switch]$AllowMissingLeaf)
    if (-not $ReceiptPath -or -not [IO.Path]::IsPathRooted($ReceiptPath)) { Stop-Installer 'DBINST_RUST_RECEIPT_INVALID' 'Rust integrity receipt path must be absolute' }
    $full = [IO.Path]::GetFullPath($ReceiptPath)
    if (Test-PathNested -Path $full -Root $RustRoot -AllowRoot) { Stop-Installer 'DBINST_RUST_RECEIPT_INVALID' 'Rust integrity receipt must remain outside the Rust toolchain tree' }
    try { Assert-NoReparsePath -Path $full -Root ([IO.Path]::GetPathRoot($full)) -AllowMissingLeaf:$AllowMissingLeaf | Out-Null }
    catch { Stop-Installer 'DBINST_RUST_RECEIPT_INVALID' 'Rust integrity receipt has unsafe path ancestry' }
    if (Test-Path -LiteralPath $full) {
        if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Test-HardlinkedLeaf -Path $full)) { Stop-Installer 'DBINST_RUST_RECEIPT_INVALID' 'Rust integrity receipt is not one physical file' }
    }
    return $full
}

function Read-ValidatedRustToolchainReceipt {
    param($Lock, [string]$RustupHome, [string]$ReceiptPath, [string]$LockSha256)
    $root = Join-Path (Join-Path $RustupHome 'toolchains') $Lock.rust.toolchain_directory
    $full = Assert-RustReceiptPath -ReceiptPath $ReceiptPath -RustRoot $root -AllowMissingLeaf
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Stop-Installer 'DBINST_RUST_RECEIPT_MISSING' 'Rust exact reuse requires an external clean-install integrity receipt' }
    try { $receipt = Get-Content -LiteralPath $full -Raw | ConvertFrom-Json }
    catch { Stop-Installer 'DBINST_RUST_RECEIPT_INVALID' 'Rust integrity receipt is not valid JSON' }
    if ($LockSha256 -cnotmatch '^[0-9a-f]{64}$' -or $receipt.schema_version -ne 1 -or
        [string]$receipt.toolchain_directory -cne [string]$Lock.rust.toolchain_directory -or
        [string]$receipt.lock_sha256 -cne $LockSha256 -or
        [string]$receipt.rustup_bootstrap_sha256 -cne [string]$Lock.rust.rustup_sha256 -or
        [string]$receipt.provenance -cne 'locked-rustup-clean-current-action') {
        Stop-Installer 'DBINST_RUST_RECEIPT_INVALID' 'Rust integrity receipt schema or lock/bootstrap provenance is invalid'
    }
    $directorySeen = @{}
    foreach ($relative in @($receipt.directories)) {
        $value = [string]$relative
        if (-not $value -or [IO.Path]::IsPathRooted($value) -or $value -match '(^|[\\/])\.\.([\\/]|$)' -or $value -match ':') { Stop-Installer 'DBINST_RUST_RECEIPT_INVALID' 'Rust receipt contains an unsafe directory path' }
        $key = $value.ToUpperInvariant()
        if ($directorySeen.ContainsKey($key)) { Stop-Installer 'DBINST_RUST_RECEIPT_INVALID' 'Rust receipt repeats a directory path' }
        $directorySeen[$key] = $true
    }
    $fileSeen = @{}
    foreach ($file in @($receipt.files)) {
        $relative = [string]$file.relative_path
        $lengthIsInteger = $file.length -is [int] -or $file.length -is [long]
        if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or $relative -match ':' -or
            -not $lengthIsInteger -or [long]$file.length -lt 0 -or [string]$file.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            Stop-Installer 'DBINST_RUST_RECEIPT_INVALID' 'Rust receipt contains an invalid file entry'
        }
        $key = $relative.ToUpperInvariant()
        if ($fileSeen.ContainsKey($key)) { Stop-Installer 'DBINST_RUST_RECEIPT_INVALID' 'Rust receipt repeats a file path' }
        $fileSeen[$key] = $true
    }
    if (@($receipt.files).Count -eq 0) { Stop-Installer 'DBINST_RUST_RECEIPT_INVALID' 'Rust receipt contains no authenticated files' }
    return $receipt
}

function Assert-RustToolchainReceiptMatchesTree {
    param($Lock, [string]$RustupHome, $Receipt)
    $actual = Get-RustToolchainTreeManifest -Lock $Lock -RustupHome $RustupHome
    $wantedDirectories = @($Receipt.directories | ForEach-Object { [string]$_ })
    if (($actual.directories -join "`n") -cne ($wantedDirectories -join "`n")) { Stop-Installer 'DBINST_RUST_CONTENT_MISMATCH' 'Rust directory set drifted from its clean-install receipt' }
    $wantedFiles = @($Receipt.files)
    if ($actual.files.Count -ne $wantedFiles.Count) { Stop-Installer 'DBINST_RUST_CONTENT_MISMATCH' 'Rust file set drifted from its clean-install receipt' }
    for ($index = 0; $index -lt $actual.files.Count; $index++) {
        $actualFile = $actual.files[$index]
        $wantedFile = $wantedFiles[$index]
        if ([string]$actualFile.relative_path -cne [string]$wantedFile.relative_path -or
            [long]$actualFile.length -ne [long]$wantedFile.length -or
            [string]$actualFile.sha256 -cne [string]$wantedFile.sha256) {
            Stop-Installer 'DBINST_RUST_CONTENT_MISMATCH' "Rust file drifted from its clean-install receipt: $($actualFile.relative_path)"
        }
    }
    return $true
}

function Write-RustToolchainIntegrityReceipt {
    param($Lock, [string]$RustupHome, [string]$ReceiptPath, [string]$LockSha256)
    $root = Join-Path (Join-Path $RustupHome 'toolchains') $Lock.rust.toolchain_directory
    $full = Assert-RustReceiptPath -ReceiptPath $ReceiptPath -RustRoot $root -AllowMissingLeaf
    if (Test-Path -LiteralPath $full) { Stop-Installer 'DBINST_RUST_RECEIPT_CONFLICT' 'refusing to overwrite existing Rust integrity evidence' }
    $manifest = Get-RustToolchainTreeManifest -Lock $Lock -RustupHome $RustupHome
    $receipt = [pscustomobject][ordered]@{
        schema_version = 1
        provenance = 'locked-rustup-clean-current-action'
        toolchain_directory = [string]$Lock.rust.toolchain_directory
        lock_sha256 = $LockSha256
        rustup_bootstrap_sha256 = [string]$Lock.rust.rustup_sha256
        created_utc = [DateTime]::UtcNow.ToString('o')
        directories = $manifest.directories
        files = $manifest.files
    }
    $parent = Split-Path -Parent $full
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    Assert-RustReceiptPath -ReceiptPath $full -RustRoot $root -AllowMissingLeaf | Out-Null
    $temporary = Join-Path $parent ('.rust-receipt-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = New-Object IO.StreamWriter($stream, $encoding)
        try { $writer.Write(($receipt | ConvertTo-Json -Depth 12 -Compress)); $writer.Flush(); $stream.Flush($true) }
        finally { $writer.Dispose(); $stream.Dispose() }
        [IO.File]::Move($temporary, $full)
    }
    finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
    return $full
}

function Assert-RustToolchainPostcondition {
    param($Lock, [string]$RustupHome, [string]$ReceiptPath, [string]$LockSha256)
    $receipt = Read-ValidatedRustToolchainReceipt -Lock $Lock -RustupHome $RustupHome -ReceiptPath $ReceiptPath -LockSha256 $LockSha256
    Assert-RustToolchainReceiptMatchesTree -Lock $Lock -RustupHome $RustupHome -Receipt $receipt | Out-Null
}

function Install-VsBuildTools {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Lock, [Parameter(Mandatory = $true)][string]$ArtifactPath, [scriptblock]$Runner, [scriptblock]$PostconditionCheck, [switch]$PlanOnly)
    $arguments = @('--quiet', '--wait', '--norestart', '--installPath', 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools', '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--add', [string]$Lock.visual_studio.msvc_component, '--add', [string]$Lock.visual_studio.windows_sdk_component)
    $result = Invoke-VerifiedBootstrapInstaller -ArtifactPath $ArtifactPath -Sha256 $Lock.visual_studio.sha256 -Arguments $arguments -Runner $Runner -PlanOnly:$PlanOnly
    if (-not $PlanOnly -and [int]$result -eq 0) {
        if ($PostconditionCheck) { & $PostconditionCheck }
        else { Assert-VisualStudioInstallPostcondition -Lock $Lock }
    }
    return $result
}

function Install-RustToolchain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Lock,
        [Parameter(Mandatory = $true)][string]$ArtifactPath,
        [string]$RustupHome,
        [string]$CargoHome,
        [string]$ReceiptPath,
        [string]$LockSha256,
        [scriptblock]$Runner,
        [scriptblock]$PostconditionCheck,
        [switch]$PlanOnly
    )
    $arguments = @('-y', '--no-modify-path', '--default-host', [string]$Lock.rust.target, '--default-toolchain', "$($Lock.rust.toolchain)-$($Lock.rust.target)", '--profile', [string]$Lock.rust.profile, '--component', (@($Lock.rust.components) -join ','))
    if ($PlanOnly) { return Invoke-VerifiedBootstrapInstaller -ArtifactPath $ArtifactPath -Sha256 $Lock.rust.rustup_sha256 -Arguments $arguments -Runner $Runner -PlanOnly }
    if (-not $RustupHome) { $RustupHome = if ($env:RUSTUP_HOME) { [IO.Path]::GetFullPath($env:RUSTUP_HOME) } else { Join-Path $env:USERPROFILE '.rustup' } }
    if (-not $CargoHome) { $CargoHome = if ($env:CARGO_HOME) { [IO.Path]::GetFullPath($env:CARGO_HOME) } else { Join-Path $env:USERPROFILE '.cargo' } }
    $savedRustupHome = $env:RUSTUP_HOME
    $savedCargoHome = $env:CARGO_HOME
    try {
        $env:RUSTUP_HOME = [IO.Path]::GetFullPath($RustupHome)
        $env:CARGO_HOME = [IO.Path]::GetFullPath($CargoHome)
        if ($PostconditionCheck) {
            $result = Invoke-VerifiedBootstrapInstaller -ArtifactPath $ArtifactPath -Sha256 $Lock.rust.rustup_sha256 -Arguments $arguments -Runner $Runner
            if ([int]$result -eq 0) { & $PostconditionCheck }
            return $result
        }

        if ($LockSha256 -cnotmatch '^[0-9a-f]{64}$') { Stop-Installer 'DBINST_RUST_RECEIPT_INVALID' 'checked-in lock SHA-256 is required for Rust enrollment' }
        $root = Join-Path (Join-Path $env:RUSTUP_HOME 'toolchains') $Lock.rust.toolchain_directory
        $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
        $receiptFull = Assert-RustReceiptPath -ReceiptPath $ReceiptPath -RustRoot $rootFull -AllowMissingLeaf
        $receiptExisted = Test-Path -LiteralPath $receiptFull -PathType Leaf
        $trustedReceipt = $null
        if ($receiptExisted) { $trustedReceipt = Read-ValidatedRustToolchainReceipt -Lock $Lock -RustupHome $env:RUSTUP_HOME -ReceiptPath $receiptFull -LockSha256 $LockSha256 }
        if (-not (Test-Path -LiteralPath $rootFull) -and $receiptExisted) { Stop-Installer 'DBINST_RUST_RECEIPT_CONFLICT' 'Rust receipt exists without its toolchain root' }

        $quarantine = ''
        if (Test-Path -LiteralPath $rootFull) {
            if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { Stop-Installer 'DBINST_INSTALLED_STATE_CONFLICT' 'Rust toolchain root is not a directory' }
            try { Assert-InstallerPhysicalTree -Root $rootFull -Code 'DBINST_INSTALLED_STATE_CONFLICT' -Description 'preexisting Rust toolchain' }
            catch { Stop-Installer 'DBINST_INSTALLED_STATE_CONFLICT' 'preexisting Rust toolchain is unsafe and cannot be quarantined' }
            $quarantine = '{0}.dbq-{1}' -f $rootFull, [Guid]::NewGuid().ToString('N').Substring(0, 8)
            if (Test-Path -LiteralPath $quarantine) { Stop-Installer 'DBINST_RUST_QUARANTINE_CONFLICT' "Rust quarantine path already exists: $quarantine" }
            [IO.Directory]::Move($rootFull, $quarantine)
        }

        $success = $false
        try {
            $result = Invoke-VerifiedBootstrapInstaller -ArtifactPath $ArtifactPath -Sha256 $Lock.rust.rustup_sha256 -Arguments $arguments -Runner $Runner
            if ([int]$result -eq 0) {
                Assert-RustToolchainPayloadPostcondition -Lock $Lock -RustupHome $env:RUSTUP_HOME
                if ($receiptExisted) {
                    Assert-RustToolchainReceiptMatchesTree -Lock $Lock -RustupHome $env:RUSTUP_HOME -Receipt $trustedReceipt | Out-Null
                }
                else {
                    Write-RustToolchainIntegrityReceipt -Lock $Lock -RustupHome $env:RUSTUP_HOME -ReceiptPath $receiptFull -LockSha256 $LockSha256 | Out-Null
                }
                Assert-RustToolchainPostcondition -Lock $Lock -RustupHome $env:RUSTUP_HOME -ReceiptPath $receiptFull -LockSha256 $LockSha256
                $success = $true
            }
            return $result
        }
        finally {
            if (-not $success) {
                if (-not $receiptExisted -and (Test-Path -LiteralPath $receiptFull -PathType Leaf)) { [IO.File]::Delete($receiptFull) }
                if (Test-Path -LiteralPath $rootFull) {
                    $failedRoot = '{0}.dbf-{1}' -f $rootFull, [Guid]::NewGuid().ToString('N').Substring(0, 8)
                    try {
                        if (Test-Path -LiteralPath $rootFull -PathType Container) { [IO.Directory]::Move($rootFull, $failedRoot) }
                        else { [IO.File]::Move($rootFull, $failedRoot) }
                    }
                    catch { Stop-Installer 'DBINST_RUST_FAILED_ROOT_QUARANTINE_FAILED' "failed Rust payload could not be moved away from the canonical target: $($_.Exception.Message)" }
                }
                if ($quarantine) {
                    if (Test-Path -LiteralPath $rootFull) { Stop-Installer 'DBINST_RUST_QUARANTINE_RESTORE_FAILED' "cannot restore Rust quarantine because the original root is occupied: $rootFull" }
                    try { [IO.Directory]::Move($quarantine, $rootFull) }
                    catch { Stop-Installer 'DBINST_RUST_QUARANTINE_RESTORE_FAILED' "preexisting Rust quarantine could not be restored: $($_.Exception.Message)" }
                }
            }
        }
    }
    finally {
        $env:RUSTUP_HOME = $savedRustupHome
        $env:CARGO_HOME = $savedCargoHome
    }
}

function Get-InstallerPeMetadata {
    param([string]$Path)
    $result = [ordered]@{ pe_format = ''; machine = '' }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$result }
    $item = Get-Item -LiteralPath $Path -Force
    if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return [pscustomobject]$result }
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $reader = New-Object IO.BinaryReader($stream)
        try {
            if ($reader.ReadUInt16() -ne 0x5A4D) { return [pscustomobject]$result }
            $stream.Position = 0x3C; $offset = $reader.ReadInt32(); $stream.Position = $offset
            if ($reader.ReadUInt32() -ne 0x00004550) { return [pscustomobject]$result }
            $machine = $reader.ReadUInt16(); $stream.Position = $offset + 24; $magic = $reader.ReadUInt16()
            $result.pe_format = if ($magic -eq 0x20B) { 'PE32+' } elseif ($magic -eq 0x10B) { 'PE32' } else { '' }
            $result.machine = if ($machine -eq 0x8664) { 'AMD64' } else { ('0x{0:X4}' -f $machine) }
        }
        finally { $reader.Dispose(); $stream.Dispose() }
    }
    catch { }
    return [pscustomobject]$result
}

function Test-PhysicalAmd64Pe {
    param([string]$Path)
    if (Test-HardlinkedLeaf -Path $Path) { return $false }
    $pe = Get-InstallerPeMetadata -Path $Path
    return $pe.pe_format -in @('PE32', 'PE32+') -and $pe.machine -ceq 'AMD64'
}

function Get-StreamSha256 {
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return (($algorithm.ComputeHash($Stream) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $algorithm.Dispose() }
}

function Assert-ArchiveLockBinding {
    param([string]$Name, $Lock, [string]$ArchiveSubdirectory, [string]$Sha256)
    $lockedSha256 = ''
    switch ($Name) {
        'cmake' {
            $lockedSha256 = [string]$Lock.cmake.sha256
            $prefix = "cmake-$($Lock.cmake.version)-windows-x86_64"
            if ([string]$Lock.cmake.url -cnotmatch ('/v' + [regex]::Escape([string]$Lock.cmake.version) + '/') -or $ArchiveSubdirectory -cne $prefix) { Stop-Installer 'DBINST_LOCK_INVALID' 'CMake version, release URL, and archive prefix are not statically bound' }
        }
        'ninja' {
            $lockedSha256 = [string]$Lock.ninja.sha256
            if ([string]$Lock.ninja.url -cnotmatch ('/v' + [regex]::Escape([string]$Lock.ninja.version) + '/') -or $ArchiveSubdirectory) { Stop-Installer 'DBINST_LOCK_INVALID' 'Ninja version, release URL, and root archive mapping are not statically bound' }
        }
        'node' {
            $lockedSha256 = [string]$Lock.node.sha256
            $prefix = "node-v$($Lock.node.version)-win-x64"
            if ([string]$Lock.node.url -cnotmatch ('/v' + [regex]::Escape([string]$Lock.node.version) + '/') -or $ArchiveSubdirectory -cne $prefix) { Stop-Installer 'DBINST_LOCK_INVALID' 'Node version, release URL, and archive prefix are not statically bound' }
        }
        default { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "unsupported authenticated archive tool: $Name" }
    }
    if ($Sha256 -cnotmatch '^[0-9a-f]{64}$' -or $lockedSha256 -cne $Sha256) { Stop-Installer 'DBINST_LOCK_INVALID' "$Name archive SHA-256 is not the exact digest selected by the lock" }
}

function Test-WindowsReservedArchiveSegment {
    param([string]$Segment)
    $base = @($Segment -split '\.')[0]
    return $base -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
}

function Get-SafeArchiveEntryPath {
    param([string]$Name, [string]$RawPath, [switch]$Directory)
    if (-not $RawPath -or $RawPath.StartsWith('/') -or $RawPath.StartsWith('\') -or $RawPath -match ':') { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive entry is rooted, UNC-like, drive-qualified, ADS-like, or empty: $RawPath" }
    $normalized = $RawPath.Replace('\', '/')
    $isDirectory = $Directory -or $normalized.EndsWith('/')
    $pathText = if ($isDirectory) { $normalized.TrimEnd('/') } else { $normalized }
    if (-not $pathText) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive contains an empty root entry" }
    $segments = @($pathText.Split([char]'/', [StringSplitOptions]::None))
    foreach ($segment in $segments) {
        if (-not $segment -or $segment -in @('.', '..') -or $segment -match '[<>"|?*\x00-\x1F]' -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or (Test-WindowsReservedArchiveSegment -Segment $segment)) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive entry has an unsafe Windows path segment: $RawPath" }
    }
    return [pscustomobject]@{ normalized = $normalized; path_text = $pathText; segments = $segments; is_directory = $isDirectory }
}

function Open-AuthenticatedZipManifest {
    param(
        [string]$Name, [string]$ArchivePath, [string]$Sha256, $Lock, [string]$ArchiveSubdirectory,
        [int]$MaximumEntries = 100000, [long]$MaximumUncompressedBytes = 17179869184
    )
    Assert-ArchiveLockBinding -Name $Name -Lock $Lock -ArchiveSubdirectory $ArchiveSubdirectory -Sha256 $Sha256
    Assert-SafeArchiveSubdirectory -ArchiveSubdirectory $ArchiveSubdirectory
    $guard = $null
    $zip = $null
    try {
        $guard = New-Object IO.FileStream([IO.Path]::GetFullPath($ArchivePath), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $actualHash = Get-StreamSha256 -Stream $guard
        if ($actualHash -cne [string]$Sha256) { Stop-Installer 'DBINST_CHECKSUM_MISMATCH' "SHA-256 mismatch for $ArchivePath (expected $Sha256, found $actualHash)" }
        $guard.Position = 0
        Add-Type -AssemblyName System.IO.Compression
        $zip = New-Object IO.Compression.ZipArchive($guard, [IO.Compression.ZipArchiveMode]::Read, $true)
        if ($zip.Entries.Count -gt $MaximumEntries) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive exceeds the bounded entry count" }
        $files = New-Object 'Collections.Generic.List[object]'
        $sourceSeen = @{}
        $nodes = @{}
        $explicitDirectories = @{}
        [long]$total = 0
        foreach ($entry in @($zip.Entries)) {
            $raw = [string]$entry.FullName
            if (-not $raw) { Get-SafeArchiveEntryPath -Name $Name -RawPath $raw | Out-Null }
            $normalized = $raw.Replace('\', '/')
            $external = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
            $unixType = ([int](($external -shr 16) -band 0xF000))
            if ($unixType -in @(0xA000, 0x2000, 0x6000, 0x1000, 0xC000) -or (($external -band 0x400) -ne 0) -or (($external -band 0x40) -ne 0)) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive entry has symlink, device, or reparse attributes: $raw" }
            $isDirectory = $normalized.EndsWith('/') -or $unixType -eq 0x4000 -or (($external -band 0x10) -ne 0)
            if (($unixType -eq 0x8000 -and $isDirectory) -or ($unixType -eq 0x4000 -and -not $isDirectory)) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive entry type conflicts with its path: $raw" }
            $safePath = Get-SafeArchiveEntryPath -Name $Name -RawPath $raw -Directory:$isDirectory
            $pathText = [string]$safePath.path_text
            $segments = @($safePath.segments)
            [long]$length = $entry.Length
            if ($length -lt 0 -or $length -gt $MaximumUncompressedBytes -or $total -gt ($MaximumUncompressedBytes - $length)) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive exceeds the bounded aggregate uncompressed size" }
            $total += $length
            $sourceKey = ($segments -join '/').ToUpperInvariant()
            if ($sourceSeen.ContainsKey($sourceKey)) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive contains a case-insensitive normalized duplicate: $raw" }
            $sourceSeen[$sourceKey] = $true
            if ($ArchiveSubdirectory) {
                if ($segments[0] -cne $ArchiveSubdirectory) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive entry escapes the exact top-level prefix: $raw" }
                if ($segments.Count -eq 1) {
                    if (-not $isDirectory) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive prefix is a file" }
                    continue
                }
                $segments = @($segments | Select-Object -Skip 1)
            }
            $relative = $segments -join '/'
            if ($relative -ieq '.doppelbanger-tool.json') { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive cannot own the installer marker" }
            $key = $relative.ToUpperInvariant()
            $parentParts = New-Object 'Collections.Generic.List[string]'
            for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
                $parentParts.Add($segments[$index])
                $parentKey = ($parentParts.ToArray() -join '/').ToUpperInvariant()
                if ($nodes.ContainsKey($parentKey) -and $nodes[$parentKey] -ceq 'file') { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive has a file/directory canonical collision: $raw" }
                if (-not $nodes.ContainsKey($parentKey)) { $nodes[$parentKey] = 'directory' }
            }
            if ($isDirectory) {
                if ($nodes.ContainsKey($key) -and $nodes[$key] -ceq 'file') { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive has a file/directory canonical collision: $raw" }
                if ($explicitDirectories.ContainsKey($key)) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive repeats an explicit directory: $raw" }
                $nodes[$key] = 'directory'; $explicitDirectories[$key] = $true
                continue
            }
            if ($nodes.ContainsKey($key)) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive has a duplicate or file/directory collision: $raw" }
            $nodes[$key] = 'file'
            $entryStream = $entry.Open()
            try { $entryHash = Get-StreamSha256 -Stream $entryStream }
            finally { $entryStream.Dispose() }
            $files.Add([pscustomobject][ordered]@{ relative_path = $relative.Replace('/', '\'); length = $length; sha256 = $entryHash })
        }
        if ($files.Count -eq 0) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive contains no authenticated files" }
        return [pscustomobject]@{ guard = $guard; zip = $zip; files = $files.ToArray(); total_uncompressed_bytes = $total }
    }
    catch {
        if ($zip) { $zip.Dispose() }
        if ($guard) { $guard.Dispose() }
        if ($_.Exception.Message -match '^DBINST_[A-Z0-9_]+:') { throw }
        Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive could not be parsed and authenticated safely: $($_.Exception.Message)"
    }
}

function Assert-InstalledFilesMatchArchiveManifest {
    param([string]$Name, [string]$Root, [object[]]$ManifestFiles)
    Assert-InstallerPhysicalTree -Root $Root -Code 'DBINST_TOOL_LAYOUT_INVALID' -Description "$Name payload"
    $expected = @{}
    foreach ($file in $ManifestFiles) { $expected[([string]$file.relative_path).ToUpperInvariant()] = $file }
    $seen = @{}
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pending.Push($rootFull)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            $relative = $item.FullName.Substring($rootFull.Length).TrimStart('\')
            if ($relative -ieq '.doppelbanger-tool.json') { continue }
            $key = $relative.ToUpperInvariant()
            if (-not $expected.ContainsKey($key)) { Stop-Installer 'DBINST_ARCHIVE_CONTENT_MISMATCH' "$Name installed root contains an extra file: $relative" }
            $wanted = $expected[$key]
            if ([long]$item.Length -ne [long]$wanted.length -or (Get-FileSha256 -Path $item.FullName) -cne [string]$wanted.sha256) { Stop-Installer 'DBINST_ARCHIVE_CONTENT_MISMATCH' "$Name installed file content drifted from the locked archive: $relative" }
            $seen[$key] = $true
        }
    }
    foreach ($key in $expected.Keys) { if (-not $seen.ContainsKey($key)) { Stop-Installer 'DBINST_ARCHIVE_CONTENT_MISMATCH' "$Name installed root is missing a locked archive file: $($expected[$key].relative_path)" } }
}

function Test-VersionedToolLayout {
    [CmdletBinding()]
    param([string]$Name, [string]$Root, $Lock)
    $requiredExecutables = @()
    switch ($Name) {
        'cmake' { $requiredExecutables = @('bin\cmake.exe', 'bin\ctest.exe') }
        'ninja' { $requiredExecutables = @('ninja.exe') }
        'node' { $requiredExecutables = @('node.exe') }
        default { return $true }
    }
    Assert-InstallerPhysicalTree -Root $Root -Code 'DBINST_TOOL_LAYOUT_INVALID' -Description "$Name payload"
    foreach ($relative in $requiredExecutables) {
        $path = Join-Path $Root $relative
        if (-not (Test-PhysicalAmd64Pe -Path $path)) { Stop-Installer 'DBINST_TOOL_LAYOUT_INVALID' "$Name required executable is not a physical AMD64 PE file: $relative" }
    }
    if ($Name -ceq 'node') {
        foreach ($relative in @('npm.cmd', 'npx.cmd', 'node_modules\npm\bin\npm-cli.js', 'node_modules\npm\bin\npx-cli.js', 'node_modules\npm\package.json')) {
            $path = Join-Path $Root $relative
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or [bool]((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { Stop-Installer 'DBINST_TOOL_LAYOUT_INVALID' "Node npm payload is missing or nonphysical: $relative" }
        }
        try { $package = Get-Content -LiteralPath (Join-Path $Root 'node_modules\npm\package.json') -Raw | ConvertFrom-Json }
        catch { Stop-Installer 'DBINST_TOOL_LAYOUT_INVALID' 'Node npm package metadata is invalid JSON' }
        if ([string]$package.version -cne [string]$Lock.node.npm_version) { Stop-Installer 'DBINST_TOOL_LAYOUT_INVALID' "Node npm payload must be exactly $($Lock.node.npm_version)" }
    }
    return $true
}

function Assert-VersionedToolMatchesArchive {
    param(
        [string]$Name, [string]$Root, [string]$ArchivePath, [string]$Sha256,
        $Lock, [string]$ArchiveSubdirectory
    )
    $authenticated = Open-AuthenticatedZipManifest -Name $Name -ArchivePath $ArchivePath -Sha256 $Sha256 -Lock $Lock -ArchiveSubdirectory $ArchiveSubdirectory
    try {
        Test-VersionedToolLayout -Name $Name -Root $Root -Lock $Lock | Out-Null
        Assert-InstalledFilesMatchArchiveManifest -Name $Name -Root $Root -ManifestFiles $authenticated.files
    }
    finally {
        $authenticated.zip.Dispose()
        $authenticated.guard.Dispose()
    }
    return $true
}

function Assert-SafeArchiveSubdirectory {
    param([string]$ArchiveSubdirectory)
    if (-not $ArchiveSubdirectory) { return }
    if ([IO.Path]::IsPathRooted($ArchiveSubdirectory) -or $ArchiveSubdirectory -match '(^|[\\/])\.\.([\\/]|$)' -or $ArchiveSubdirectory -match '[:*?"<>|]') { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' 'archive subdirectory must be one safe relative directory name' }
}

function Expand-VersionedTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [string]$ArchiveSubdirectory,
        $Lock,
        [scriptblock]$Expander,
        [switch]$PlanOnly
    )
    Assert-SafeArchiveSubdirectory -ArchiveSubdirectory $ArchiveSubdirectory
    if ($PlanOnly) { return [pscustomobject][ordered]@{ name = $Name; archive_path = $ArchivePath; sha256 = $Sha256; target_root = $TargetRoot; status = 'planned'; mutation = $false } }
    $target = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    $parent = Split-Path -Parent $target
    $trustedParent = Split-Path -Parent $parent
    if (-not $trustedParent) { Stop-Installer 'DBINST_TOOL_ROOT_CONFLICT' "tool root has no safe managed ancestor: $target" }
    try { Assert-NoReparsePath -Path $target -Root $trustedParent -AllowMissingLeaf | Out-Null }
    catch { Stop-Installer 'DBINST_TOOL_ROOT_CONFLICT' "tool root has a reparse-backed ancestor or target: $target" }
    $authenticated = Open-AuthenticatedZipManifest -Name $Name -ArchivePath $ArchivePath -Sha256 $Sha256 -Lock $Lock -ArchiveSubdirectory $ArchiveSubdirectory
    try {
        $marker = Join-Path $target '.doppelbanger-tool.json'
        if (Test-Path -LiteralPath $target -PathType Container) {
            if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { Stop-Installer 'DBINST_TOOL_ROOT_CONFLICT' "existing tool root is not managed by this installer: $target" }
            $metadata = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
            if ($metadata.schema_version -eq 1 -and [string]$metadata.name -ceq $Name -and [string]$metadata.archive_sha256 -ceq ([string]$Sha256).ToLowerInvariant()) {
                Test-VersionedToolLayout -Name $Name -Root $target -Lock $Lock | Out-Null
                Assert-InstalledFilesMatchArchiveManifest -Name $Name -Root $target -ManifestFiles $authenticated.files
                return [pscustomobject][ordered]@{ name = $Name; target_root = $target; status = 'already_installed' }
            }
            Stop-Installer 'DBINST_TOOL_ROOT_CONFLICT' "existing managed tool root does not match the locked archive: $target"
        }
        if (Test-Path -LiteralPath $target) { Stop-Installer 'DBINST_TOOL_ROOT_CONFLICT' "existing tool root is not a directory: $target" }
        [IO.Directory]::CreateDirectory($parent) | Out-Null
        try { Assert-NoReparsePath -Path $target -Root $trustedParent -AllowMissingLeaf | Out-Null }
        catch { Stop-Installer 'DBINST_TOOL_ROOT_CONFLICT' "tool root has a reparse-backed ancestor or target: $target" }
        $staging = Join-Path $parent ('.{0}-{1}.staging' -f $Name, [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        try {
            if ($Expander) { & $Expander $ArchivePath $staging }
            else { Expand-Archive -LiteralPath $ArchivePath -DestinationPath $staging }
            $contentRoot = $staging
            if ($ArchiveSubdirectory) {
                $candidate = Join-Path $staging $ArchiveSubdirectory
                if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { Stop-Installer 'DBINST_ARCHIVE_LAYOUT_INVALID' "$Name archive does not contain $ArchiveSubdirectory" }
                $contentRoot = $candidate
            }
            Test-VersionedToolLayout -Name $Name -Root $contentRoot -Lock $Lock | Out-Null
            Assert-InstalledFilesMatchArchiveManifest -Name $Name -Root $contentRoot -ManifestFiles $authenticated.files
            $markerData = [pscustomobject][ordered]@{ schema_version = 1; name = $Name; archive_sha256 = ([string]$Sha256).ToLowerInvariant() }
            [IO.File]::WriteAllText((Join-Path $contentRoot '.doppelbanger-tool.json'), ($markerData | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
            if ($contentRoot -ieq $staging) { [IO.Directory]::Move($staging, $target) }
            else { [IO.Directory]::Move($contentRoot, $target) }
            return [pscustomobject][ordered]@{ name = $Name; target_root = $target; status = 'installed' }
        }
        finally { if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force } }
    }
    finally { $authenticated.zip.Dispose(); $authenticated.guard.Dispose() }
}

function Set-DoppelbangerUserPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$RequiredDirectories,
        [string]$CurrentUserPath,
        [switch]$PlanOnly,
        [scriptblock]$PathReader,
        [scriptblock]$ProvenanceCheck,
        [scriptblock]$PathWriter
    )
    if (-not $PathReader) { $PathReader = { return [Environment]::GetEnvironmentVariable('Path', 'User') } }
    if (-not $PSBoundParameters.ContainsKey('CurrentUserPath')) { $CurrentUserPath = [string](& $PathReader) }
    if ($null -eq $CurrentUserPath) { $CurrentUserPath = '' }
    function Get-PathComparisonKey([string]$Value) {
        $candidate = $Value.Trim()
        if ($candidate.Length -ge 2 -and $candidate.StartsWith('"') -and $candidate.EndsWith('"')) { $candidate = $candidate.Substring(1, $candidate.Length - 2) }
        if (-not $candidate) { return '' }
        $candidate = [Environment]::ExpandEnvironmentVariables($candidate)
        try { $candidate = [IO.Path]::GetFullPath($candidate) } catch { }
        return $candidate.TrimEnd('\').ToUpperInvariant()
    }
    $seen = @{}
    foreach ($entry in @([string]$CurrentUserPath -split ';')) {
        $key = Get-PathComparisonKey ([string]$entry)
        if ($key) { $seen[$key] = $true }
    }
    $missing = New-Object 'Collections.Generic.List[string]'
    foreach ($required in $RequiredDirectories) {
        $full = [IO.Path]::GetFullPath($required).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { Stop-Installer 'DBINST_PATH_TARGET_MISSING' "refusing to add an uninstalled directory to user PATH: $full" }
        $key = Get-PathComparisonKey $full
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $missing.Add($full) }
    }
    $newPath = [string]$CurrentUserPath
    if ($missing.Count -gt 0) {
        if ($newPath -and -not $newPath.EndsWith(';')) { $newPath += ';' }
        $newPath += ($missing.ToArray() -join ';')
    }
    $changed = $missing.Count -gt 0
    if ($changed -and -not $PlanOnly) {
        if (-not $ProvenanceCheck) { Stop-Installer 'DBINST_PATH_PROVENANCE_INVALID' 'live user PATH mutation requires an exact developer-tool provenance check' }
        & $ProvenanceCheck
        $concurrentBaseline = [string](& $PathReader)
        if ($concurrentBaseline -cne [string]$CurrentUserPath) {
            Stop-Installer 'DBINST_PATH_CONCURRENT_CHANGE' 'user PATH changed after the append baseline was read; no write was attempted'
        }
        if ($PathWriter) { & $PathWriter $newPath }
        else { [Environment]::SetEnvironmentVariable('Path', $newPath, 'User') }
        $storedPath = [string](& $PathReader)
        $storedKeys = @{}
        foreach ($entry in @($storedPath -split ';')) {
            $storedKey = Get-PathComparisonKey ([string]$entry)
            if ($storedKey) { $storedKeys[$storedKey] = $true }
        }
        $readbackValid = $storedPath -ceq $newPath
        foreach ($required in $RequiredDirectories) {
            $requiredKey = Get-PathComparisonKey ([IO.Path]::GetFullPath($required).TrimEnd('\'))
            if (-not $storedKeys.ContainsKey($requiredKey)) { $readbackValid = $false }
        }
        if (-not $readbackValid) { Stop-Installer 'DBINST_PATH_WRITE_FAILED' 'user PATH readback did not match the exact append-only value with every required directory present' }
    }
    return [pscustomobject][ordered]@{ changed = $changed; path = $newPath; scope = 'User'; mutation = [bool]($changed -and -not $PlanOnly) }
}

function Test-PathNested {
    param([string]$Path, [string]$Root, [switch]$AllowRoot)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($AllowRoot -and $fullPath -ieq $fullRoot) { return $true }
    return $fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-InstallerDockerComposeMetadata {
    [CmdletBinding()]
    param([string]$DockerConfig, [string]$UserProfile, [string]$ProgramFilesRoot)
    if (-not $UserProfile) { $UserProfile = $env:USERPROFILE }
    if (-not $ProgramFilesRoot) { $ProgramFilesRoot = $env:ProgramFiles }
    if (-not $DockerConfig) { $DockerConfig = if ($env:DOCKER_CONFIG) { [string]$env:DOCKER_CONFIG } else { Join-Path $UserProfile '.docker' } }
    if (-not [IO.Path]::IsPathRooted($DockerConfig)) { Stop-Installer 'DBINST_DOCKER_PLUGIN_CONFIG_INVALID' 'effective DOCKER_CONFIG must be absolute' }
    $roots = New-Object 'Collections.Generic.List[string]'
    $settingsPath = Join-Path $DockerConfig 'config.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try { $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json }
        catch { Stop-Installer 'DBINST_DOCKER_PLUGIN_CONFIG_INVALID' 'Docker CLI config is invalid JSON' }
        if ($settings.PSObject.Properties.Name -contains 'cliPluginsExtraDirs') {
            foreach ($directory in @($settings.cliPluginsExtraDirs)) {
                if (-not [IO.Path]::IsPathRooted([string]$directory)) { Stop-Installer 'DBINST_DOCKER_PLUGIN_CONFIG_INVALID' 'Docker cliPluginsExtraDirs entries must be absolute' }
                $roots.Add([IO.Path]::GetFullPath([string]$directory))
            }
        }
    }
    $roots.Add((Join-Path ([IO.Path]::GetFullPath($DockerConfig)) 'cli-plugins'))
    $roots.Add((Join-Path $ProgramFilesRoot 'Docker\cli-plugins'))
    $candidates = @($roots | ForEach-Object { Join-Path $_ 'docker-compose.exe' })
    $winner = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) | Select-Object -First 1
    return [pscustomobject][ordered]@{ docker_config = [IO.Path]::GetFullPath($DockerConfig); plugin_roots = $roots.ToArray(); candidates = $candidates; winner = [string]$winner }
}

function Test-DockerEvidenceFileUnsafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $true }
    $item = Get-Item -LiteralPath $Path -Force
    if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Test-HardlinkedLeaf -Path $Path)) { return $true }
    $current = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    while ($current -and $current -ne [IO.Path]::GetPathRoot($current)) {
        if (Test-Path -LiteralPath $current) {
            if ([bool]((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $true }
        }
        $next = Split-Path -Parent $current
        if ($next -eq $current) { break }
        $current = $next
    }
    return $false
}

function Read-DockerBackupManifest {
    param([string]$Path, $Lock, [string]$CurrentDesktopVersion, [string]$DetectedSourceDataPath, [string[]]$DockerPluginRoots, [string[]]$DockerDataRoots)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Installer 'DBINST_DOCKER_BACKUP_INVALID' 'Docker backup manifest is required and must exist' }
    try { $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { Stop-Installer 'DBINST_DOCKER_BACKUP_INVALID' 'Docker backup manifest is not valid JSON' }
    function Invalid([string]$Reason) { Stop-Installer 'DBINST_DOCKER_BACKUP_INVALID' $Reason }
    if ($manifest.schema_version -ne 1) { Invalid 'Docker backup manifest schema_version must be 1' }
    if ([string]$manifest.source_desktop_version -cne $CurrentDesktopVersion) { Invalid 'Docker backup source version does not match the installed Desktop version' }
    if ([string]$manifest.install_mode -cne 'all-users') { Invalid 'Docker backup must record all-users installation mode' }
    if ([IO.Path]::GetFullPath([string]$manifest.install_path).TrimEnd('\') -ine [IO.Path]::GetFullPath([string]$Lock.docker.root).TrimEnd('\')) { Invalid 'Docker backup install path does not match the locked all-users path' }
    if (-not [IO.Path]::IsPathRooted([string]$manifest.source_data_path)) { Invalid 'Docker source data path must be absolute' }
    if (Test-PathNested -Path $manifest.source_data_path -Root $Lock.docker.root -AllowRoot) { Invalid 'Docker source data path cannot be inside the Docker installation' }
    if (Test-DockerEvidenceFileUnsafe -Path $manifest.source_data_path) { Invalid 'Docker source data file is missing, reparse-backed, or hardlinked' }
    $source = Get-Item -LiteralPath $manifest.source_data_path
    if ($source.Length -le 0) { Invalid 'Docker source data file is empty' }
    if ($DetectedSourceDataPath -and [IO.Path]::GetFullPath([string]$manifest.source_data_path) -ine [IO.Path]::GetFullPath($DetectedSourceDataPath)) { Invalid 'Docker backup source does not match the uniquely detected live data path' }
    if (-not [IO.Path]::IsPathRooted([string]$manifest.backup_path)) { Invalid 'Docker backup path must be absolute' }
    foreach ($forbiddenRoot in @($Lock.docker.root, (Split-Path -Parent $manifest.source_data_path), (Split-Path -Parent $Lock.docker.compose_plugin_path)) + @($DockerPluginRoots) + @($DockerDataRoots)) {
        if (-not $forbiddenRoot) { continue }
        if (Test-PathNested -Path $manifest.backup_path -Root $forbiddenRoot -AllowRoot) { Invalid "Docker backup path is inside a forbidden Docker root: $forbiddenRoot" }
    }
    if (Test-DockerEvidenceFileUnsafe -Path $manifest.backup_path) { Invalid 'Docker backup file is missing, reparse-backed, or hardlinked' }
    $backup = Get-Item -LiteralPath $manifest.backup_path
    $sourceSizeInteger = $manifest.source_size_bytes -is [int] -or $manifest.source_size_bytes -is [long]
    $backupSizeInteger = $manifest.backup_size_bytes -is [int] -or $manifest.backup_size_bytes -is [long]
    if (-not $sourceSizeInteger -or [long]$manifest.source_size_bytes -le 0 -or [long]$manifest.source_size_bytes -ne $source.Length) { Invalid 'Docker source size is missing, nonintegral, empty, or changed' }
    if (-not $backupSizeInteger -or $backup.Length -le 0 -or [long]$manifest.backup_size_bytes -ne $backup.Length) { Invalid 'Docker backup size is empty, nonintegral, or does not match the manifest' }
    if ([string]$manifest.source_sha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileSha256 -Path $source.FullName) -cne [string]$manifest.source_sha256) { Invalid 'Docker source SHA-256 does not match live source bytes' }
    if ([string]$manifest.backup_sha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileSha256 -Path $backup.FullName) -cne [string]$manifest.backup_sha256) { Invalid 'Docker backup SHA-256 does not match the manifest' }
    if ([long]$manifest.source_size_bytes -ne [long]$manifest.backup_size_bytes -or [string]$manifest.source_sha256 -cne [string]$manifest.backup_sha256) { Invalid 'Docker source and backup evidence are not byte-identical' }
    $timestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$manifest.created_utc, [ref]$timestamp) -or $timestamp.Offset -ne [TimeSpan]::Zero -or [string]$manifest.created_utc -notmatch 'Z$') { Invalid 'Docker backup creation timestamp must be UTC with a Z suffix' }
    if ($manifest.desktop_stopped -ne $true) { Invalid 'Docker backup manifest must record desktop_stopped=true' }
    return $manifest
}

function Resolve-DockerDataPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$CandidatePaths)
    $matches = New-Object 'Collections.Generic.List[string]'
    $seen = @{}
    foreach ($candidate in $CandidatePaths) {
        if (-not $candidate) { continue }
        $full = [IO.Path]::GetFullPath($candidate)
        if ($seen.ContainsKey($full.ToUpperInvariant())) { continue }
        $seen[$full.ToUpperInvariant()] = $true
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $item = Get-Item -LiteralPath $full
            if ($item.Length -gt 0) { $matches.Add($full) }
        }
    }
    if ($matches.Count -ne 1) { Stop-Installer 'DBINST_DOCKER_DATA_AMBIGUOUS' "expected exactly one existing nonempty Docker data disk, found $($matches.Count)" }
    return $matches[0]
}

function Get-DockerDataCandidatePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LocalAppData,
        [string]$SettingsRoot
    )
    if (-not $SettingsRoot) { $SettingsRoot = Join-Path $env:APPDATA 'Docker' }
    $candidates = New-Object 'Collections.Generic.List[string]'
    $candidates.Add((Join-Path $LocalAppData 'Docker\wsl\data\docker_data.vhdx'))
    $candidates.Add((Join-Path $LocalAppData 'Docker\wsl\disk\docker_data.vhdx'))
    foreach ($settingsName in @('settings-store.json', 'settings.json')) {
        $settingsPath = Join-Path $SettingsRoot $settingsName
        if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { continue }
        try { $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json }
        catch { Stop-Installer 'DBINST_DOCKER_SETTINGS_INVALID' "Docker settings are not valid JSON: $settingsPath" }
        foreach ($propertyName in @('diskImageLocation', 'dataFolder', 'wslDataRoot')) {
            if ($settings.PSObject.Properties.Name -notcontains $propertyName) { continue }
            $configured = [string]$settings.$propertyName
            if (-not $configured -or -not [IO.Path]::IsPathRooted($configured)) { Stop-Installer 'DBINST_DOCKER_SETTINGS_INVALID' "Docker $propertyName must be an absolute path" }
            if ([IO.Path]::GetExtension($configured) -ieq '.vhdx') { $candidates.Add([IO.Path]::GetFullPath($configured)) }
            else {
                $candidates.Add((Join-Path $configured 'docker_data.vhdx'))
                $candidates.Add((Join-Path $configured 'data\docker_data.vhdx'))
                $candidates.Add((Join-Path $configured 'disk\docker_data.vhdx'))
            }
        }
    }
    return $candidates.ToArray()
}

function Test-DockerDesktopExactState {
    [CmdletBinding()]
    param($Lock, $Metadata)
    return [string]$Metadata.version -ceq [string]$Lock.docker.desktop_version -and [string]$Metadata.build -ceq [string]$Lock.docker.desktop_build
}

function Restore-ComposeShadowFromReceipt {
    param([Parameter(Mandatory = $true)]$Receipt)
    $source = [IO.Path]::GetFullPath([string]$Receipt.source)
    $backup = [IO.Path]::GetFullPath([string]$Receipt.backup)
    try {
        if (Test-Path -LiteralPath $source) {
            if (Test-Path -LiteralPath $backup) { Stop-Installer 'DBINST_COMPOSE_ROLLBACK_FAILED' "Compose rollback source and backup both exist: $source; $backup" }
            if (Test-DockerEvidenceFileUnsafe -Path $source) { Stop-Installer 'DBINST_COMPOSE_ROLLBACK_FAILED' "Compose rollback source is occupied by an unsafe file: $source" }
            $existingSourceItem = Get-Item -LiteralPath $source
            if ([long]$existingSourceItem.Length -ne [long]$Receipt.length -or (Get-FileSha256 -Path $source) -cne [string]$Receipt.sha256) {
                Stop-Installer 'DBINST_COMPOSE_ROLLBACK_FAILED' "Compose rollback source is occupied by different bytes: $source; expected recovery backup: $backup"
            }
            return [pscustomobject][ordered]@{ restored = $true; already_restored = $true; source = $source; backup = $backup; length = [long]$Receipt.length; sha256 = [string]$Receipt.sha256 }
        }
        if (Test-DockerEvidenceFileUnsafe -Path $backup) { Stop-Installer 'DBINST_COMPOSE_ROLLBACK_FAILED' "Compose rollback backup is missing or unsafe: $backup; intended source: $source" }
        $backupItem = Get-Item -LiteralPath $backup
        if ([long]$backupItem.Length -ne [long]$Receipt.length -or (Get-FileSha256 -Path $backup) -cne [string]$Receipt.sha256) {
            Stop-Installer 'DBINST_COMPOSE_ROLLBACK_FAILED' "Compose rollback backup bytes changed: $backup; intended source: $source"
        }
        [IO.File]::Move($backup, $source)
        if (Test-DockerEvidenceFileUnsafe -Path $source) { Stop-Installer 'DBINST_COMPOSE_ROLLBACK_FAILED' "Compose rollback did not restore one physical source: $source; backup was $backup" }
        $sourceItem = Get-Item -LiteralPath $source
        if ([long]$sourceItem.Length -ne [long]$Receipt.length -or (Get-FileSha256 -Path $source) -cne [string]$Receipt.sha256 -or (Test-Path -LiteralPath $backup)) {
            Stop-Installer 'DBINST_COMPOSE_ROLLBACK_FAILED' "Compose rollback could not prove exact restored bytes at $source; backup path: $backup"
        }
        return [pscustomobject][ordered]@{ restored = $true; already_restored = $false; source = $source; backup = $backup; length = [long]$Receipt.length; sha256 = [string]$Receipt.sha256 }
    }
    catch {
        if ($_.Exception.Message -match '^DBINST_COMPOSE_ROLLBACK_FAILED:') { throw }
        Stop-Installer 'DBINST_COMPOSE_ROLLBACK_FAILED' "Compose rollback failed for source $source from backup $backup`: $($_.Exception.Message)"
    }
}

function Upgrade-DockerDesktop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Lock,
        [string]$ArtifactPath,
        [scriptblock]$ArtifactProvider,
        [Parameter(Mandatory = $true)][string]$DockerBackupManifest,
        [Parameter(Mandatory = $true)][string]$CurrentDesktopVersion,
        [string]$DetectedSourceDataPath,
        [string[]]$DockerDataRoots,
        [scriptblock]$DesktopStoppedProbe,
        [string]$ComposeShadowPath,
        $ComposeMetadata,
        [switch]$BackupShadowingComposePlugin,
        [DateTime]$TimestampUtc,
        [scriptblock]$Runner,
        [switch]$PlanOnly
    )
    if (-not $ComposeMetadata) {
        $winner = if ($ComposeShadowPath -and (Test-Path -LiteralPath $ComposeShadowPath -PathType Leaf)) { $ComposeShadowPath } else { [string]$Lock.docker.compose_plugin_path }
        $ComposeMetadata = [pscustomobject]@{ winner = $winner; plugin_roots = @((Split-Path -Parent $winner), (Split-Path -Parent $Lock.docker.compose_plugin_path)); candidates = @($winner, [string]$Lock.docker.compose_plugin_path) }
    }
    if (-not $DesktopStoppedProbe) {
        $DesktopStoppedProbe = { return @((Get-Process -ErrorAction SilentlyContinue) | Where-Object { $_.ProcessName -match '^(Docker Desktop|Docker Desktop Backend|com\.docker\..+|dockerd|vpnkit)$' }).Count -eq 0 }
    }
    if (-not (& $DesktopStoppedProbe)) { Stop-Installer 'DBINST_DOCKER_DESKTOP_RUNNING' 'Docker Desktop processes must be fully stopped immediately before upgrade' }
    $manifest = Read-DockerBackupManifest -Path $DockerBackupManifest -Lock $Lock -CurrentDesktopVersion $CurrentDesktopVersion -DetectedSourceDataPath $DetectedSourceDataPath -DockerPluginRoots @($ComposeMetadata.plugin_roots) -DockerDataRoots $DockerDataRoots
    $composeWinner = [string]$ComposeMetadata.winner
    if (-not $composeWinner -or (Test-DockerEvidenceFileUnsafe -Path $composeWinner)) { Stop-Installer 'DBINST_DOCKER_PLUGIN_PROVENANCE' 'actual Compose winner must be one exact physical plugin file without reparse ancestors' }
    $shadowed = [IO.Path]::GetFullPath($composeWinner) -ine [IO.Path]::GetFullPath([string]$Lock.docker.compose_plugin_path)
    if ($shadowed -and -not $BackupShadowingComposePlugin) { Stop-Installer 'DBINST_COMPOSE_SHADOW_OPT_IN_REQUIRED' 'actual shadowing Compose winner requires -BackupShadowingComposePlugin' }
    $shadowBackup = ''
    $shadowReceipt = $null
    if ($shadowed) {
        $ComposeShadowPath = $composeWinner
        if ($TimestampUtc -eq [DateTime]::MinValue) {
            if ($PlanOnly) { $TimestampUtc = ([DateTimeOffset]::Parse([string]$manifest.created_utc)).UtcDateTime }
            else { $TimestampUtc = [DateTime]::UtcNow }
        }
        $shadowBackup = '{0}.doppelbanger-backup-{1}' -f $ComposeShadowPath, $TimestampUtc.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
        if (Test-Path -LiteralPath $shadowBackup) { Stop-Installer 'DBINST_COMPOSE_BACKUP_CONFLICT' "Compose backup path already exists: $shadowBackup" }
        $shadowItem = Get-Item -LiteralPath $ComposeShadowPath
        $shadowReceipt = [pscustomobject][ordered]@{
            source = [IO.Path]::GetFullPath($ComposeShadowPath)
            backup = [IO.Path]::GetFullPath($shadowBackup)
            length = [long]$shadowItem.Length
            sha256 = Get-FileSha256 -Path $ComposeShadowPath
        }
    }
    $arguments = @('install', '--quiet', '--backend=wsl-2')
    if ($PlanOnly) {
        return [pscustomobject][ordered]@{
            status = 'planned'; install_mode = 'all-users'; install_path = [string]$Lock.docker.root; arguments = $arguments
            backup_path = [string]$manifest.backup_path; compose_shadow_source = $ComposeShadowPath; compose_shadow_backup = $shadowBackup
            exit_code = $null; mutation = $false
        }
    }
    if (-not $ArtifactPath) {
        if (-not $ArtifactProvider) { Stop-Installer 'DBINST_ARTIFACT_MISSING' 'Docker artifact provider is required after preservation gates pass' }
        $ArtifactPath = [string](& $ArtifactProvider)
    }
    Assert-ArtifactHash -Path $ArtifactPath -Sha256 $Lock.docker.sha256
    $exitCode = $null
    $movedShadow = $false
    try {
        if ($shadowed) { [IO.File]::Move([IO.Path]::GetFullPath($ComposeShadowPath), [IO.Path]::GetFullPath($shadowBackup)); $movedShadow = $true }
        $exitCode = Invoke-VerifiedBootstrapInstaller -ArtifactPath $ArtifactPath -Sha256 $Lock.docker.sha256 -Arguments $arguments -BeforeLaunch {
            if (-not (& $DesktopStoppedProbe)) { Stop-Installer 'DBINST_DOCKER_DESKTOP_RUNNING' 'Docker Desktop processes restarted before verified installer launch' }
        } -Runner $Runner
        if ($exitCode -notin @(0, 3010) -and $movedShadow) {
            Restore-ComposeShadowFromReceipt -Receipt $shadowReceipt | Out-Null
            $movedShadow = $false
        }
    }
    catch {
        $originalError = $_
        if ($movedShadow) {
            Restore-ComposeShadowFromReceipt -Receipt $shadowReceipt | Out-Null
            $movedShadow = $false
        }
        throw $originalError
    }
    $checkpointRollback = $null
    if ($exitCode -eq 3010 -and $movedShadow) {
        $receiptForClosure = $shadowReceipt
        $checkpointRollback = { Restore-ComposeShadowFromReceipt -Receipt $receiptForClosure }.GetNewClosure()
    }
    return [pscustomobject][ordered]@{
        status = 'executed'
        install_mode = 'all-users'; install_path = [string]$Lock.docker.root; arguments = $arguments
        backup_path = [string]$manifest.backup_path; compose_shadow_source = $ComposeShadowPath; compose_shadow_backup = $shadowBackup
        exit_code = $exitCode; mutation = $true
        checkpoint_rollback = $checkpointRollback
        rollback_receipt = $shadowReceipt
    }
}

function Test-InstallerPathWithinRoot {
    param([string]$Path, [string]$Root, [switch]$AllowRoot)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($AllowRoot -and $fullPath -ieq $fullRoot) { return $true }
    return $fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePath {
    param([string]$Path, [string]$Root, [switch]$AllowMissingLeaf)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootFull = [IO.Path]::GetFullPath($Root)
    if ($rootFull -ine [IO.Path]::GetPathRoot($rootFull)) { $rootFull = $rootFull.TrimEnd('\') }
    if (-not (Test-InstallerPathWithinRoot -Path $full -Root $rootFull -AllowRoot)) { Stop-Installer 'DBINST_PATH_UNSAFE' "path escapes its trusted root: $full" }
    $current = $rootFull
    if (Test-Path -LiteralPath $current) {
        if ([bool]((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { Stop-Installer 'DBINST_PATH_UNSAFE' "reparse root is forbidden: $current" }
    }
    $relative = $full.Substring($rootFull.Length).TrimStart('\')
    foreach ($segment in @($relative -split '\\')) {
        if (-not $segment) { continue }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            if ([bool]((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { Stop-Installer 'DBINST_PATH_UNSAFE' "reparse path is forbidden: $current" }
        }
        elseif (-not $AllowMissingLeaf -or $current -ine $full) { continue }
    }
    return $full
}

function Test-HardlinkedLeaf {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    $linkType = if ($item.PSObject.Properties.Name -contains 'LinkType') { [string]$item.LinkType } else { '' }
    $targets = if ($item.PSObject.Properties.Name -contains 'Target') { @($item.Target | Where-Object { $_ }) } else { @() }
    return $linkType -ieq 'HardLink' -or $targets.Count -gt 1
}

function Assert-InstallerCheckpointPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    try {
        $tail = if ($Path.Length -gt 2) { $Path.Substring(2) } else { '' }
        if ($Path -match '^\\\\' -or $Path -match '^\\\\[?.]\\' -or $tail -match ':') { Stop-Installer 'DBINST_CHECKPOINT_PATH_INVALID' 'device, UNC, and alternate-data-stream checkpoint paths are forbidden' }
        $rootFull = [IO.Path]::GetFullPath($Root)
        try { Assert-NoReparsePath -Path $rootFull -Root ([IO.Path]::GetPathRoot($rootFull)) -AllowMissingLeaf | Out-Null }
        catch { Stop-Installer 'DBINST_CHECKPOINT_PATH_INVALID' $_.Exception.Message }
        $full = [IO.Path]::GetFullPath($Path)
        if (-not (Test-InstallerPathWithinRoot -Path $full -Root $Root)) { Stop-Installer 'DBINST_CHECKPOINT_PATH_INVALID' 'checkpoint must remain canonically beneath its installer root' }
        try { Assert-NoReparsePath -Path $full -Root $Root -AllowMissingLeaf | Out-Null }
        catch { Stop-Installer 'DBINST_CHECKPOINT_PATH_INVALID' $_.Exception.Message }
        if ((Test-Path -LiteralPath $full) -and ((Get-Item -LiteralPath $full -Force).PSIsContainer -or (Test-HardlinkedLeaf -Path $full))) { Stop-Installer 'DBINST_CHECKPOINT_PATH_INVALID' 'checkpoint target cannot be a directory or hardlink' }
        return $full
    }
    catch {
        if ($_.Exception.Message -match '^DBINST_CHECKPOINT_PATH_INVALID:') { throw }
        Stop-Installer 'DBINST_CHECKPOINT_PATH_INVALID' $_.Exception.Message
    }
}

function Get-InstallOptionsHash {
    param($InstallOptions)
    if ($null -eq $InstallOptions) { $InstallOptions = @{} }
    return Get-StringSha256 -Value ($InstallOptions | ConvertTo-Json -Depth 12 -Compress)
}

function Get-InstallTopologyHash {
    param([object[]]$Actions, $InstallOptions)
    $names = @($Actions | ForEach-Object { [string]$_.name })
    return Get-StringSha256 -Value ((($names -join "`n") + "`n--options--`n" + (Get-InstallOptionsHash $InstallOptions)))
}

function Write-InstallCheckpoint {
    param([string]$Path, [string]$Root, [string]$LockSha256, [object[]]$Actions, $InstallOptions, [int]$NextActionIndex, [string]$CompletedAction, [string]$BootSessionMarker)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = Assert-InstallerCheckpointPath -Path $Path -Root $rootFull
    if (-not (Test-Path -LiteralPath $rootFull)) { [IO.Directory]::CreateDirectory($rootFull) | Out-Null }
    $fullPath = Assert-InstallerCheckpointPath -Path $fullPath -Root $rootFull
    $parent = Split-Path -Parent $fullPath
    $nextName = if ($NextActionIndex -lt $Actions.Count) { [string]$Actions[$NextActionIndex].name } else { '' }
    $checkpoint = [pscustomobject][ordered]@{
        schema_version = 1; lock_sha256 = $LockSha256
        action_topology_sha256 = Get-InstallTopologyHash -Actions $Actions -InstallOptions $InstallOptions
        install_options_sha256 = Get-InstallOptionsHash $InstallOptions
        enabled_action_names = @($Actions | ForEach-Object { [string]$_.name })
        next_action_index = $NextActionIndex; next_action_name = $nextName; completed_action = $CompletedAction
        exit_code = 3010; requires_reboot = $true; created_utc = [DateTime]::UtcNow.ToString('o'); boot_session_marker = $BootSessionMarker
    }
    $temporary = Join-Path $parent ('.checkpoint-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = New-Object IO.StreamWriter($stream, $encoding)
        try { $writer.Write(($checkpoint | ConvertTo-Json -Depth 12 -Compress)); $writer.Flush(); $stream.Flush($true) }
        finally { $writer.Dispose(); $stream.Dispose() }
        Assert-InstallerCheckpointPath -Path $fullPath -Root $Root | Out-Null
        if (Test-Path -LiteralPath $fullPath) { [IO.File]::Replace($temporary, $fullPath, $null, $true) }
        else { [IO.File]::Move($temporary, $fullPath) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Read-ValidatedInstallCheckpoint {
    param([string]$Path, [string]$Root, [string]$LockSha256, [object[]]$Actions, $InstallOptions, [string]$BootSessionMarker)
    $full = Assert-InstallerCheckpointPath -Path $Path -Root $Root
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Stop-Installer 'DBINST_CHECKPOINT_MISSING' 'resume requested but no checkpoint exists' }
    try { $checkpoint = Get-Content -LiteralPath $full -Raw | ConvertFrom-Json }
    catch { Stop-Installer 'DBINST_CHECKPOINT_INVALID' 'checkpoint is not valid JSON' }
    $indexIsInteger = $checkpoint.next_action_index -is [int] -or $checkpoint.next_action_index -is [long]
    if (-not $indexIsInteger -or [long]$checkpoint.next_action_index -lt 0 -or [long]$checkpoint.next_action_index -gt $Actions.Count) { Stop-Installer 'DBINST_CHECKPOINT_INVALID' 'checkpoint next_action_index is not an exact in-range integer' }
    $index = [int]$checkpoint.next_action_index
    $expectedNext = if ($index -lt $Actions.Count) { [string]$Actions[$index].name } else { '' }
    $expectedCompleted = if ($index -gt 0) { [string]$Actions[$index - 1].name } else { '' }
    $timestamp = [DateTimeOffset]::MinValue
    $timestampValid = [DateTimeOffset]::TryParse([string]$checkpoint.created_utc, [ref]$timestamp) -and $timestamp.Offset -eq [TimeSpan]::Zero -and [string]$checkpoint.created_utc -match 'Z$'
    $expectedNames = @($Actions | ForEach-Object { [string]$_.name }) -join "`n"
    $actualNames = @($checkpoint.enabled_action_names | ForEach-Object { [string]$_ }) -join "`n"
    if ($checkpoint.schema_version -ne 1 -or [string]$checkpoint.lock_sha256 -cne $LockSha256 -or
        [string]$checkpoint.action_topology_sha256 -cne (Get-InstallTopologyHash -Actions $Actions -InstallOptions $InstallOptions) -or
        [string]$checkpoint.install_options_sha256 -cne (Get-InstallOptionsHash $InstallOptions) -or $actualNames -cne $expectedNames -or
        [string]$checkpoint.next_action_name -cne $expectedNext -or [string]$checkpoint.completed_action -cne $expectedCompleted -or
        $checkpoint.exit_code -ne 3010 -or $checkpoint.requires_reboot -ne $true -or -not $timestampValid -or
        [string]::IsNullOrWhiteSpace([string]$checkpoint.boot_session_marker)) { Stop-Installer 'DBINST_CHECKPOINT_INVALID' 'checkpoint schema, topology, options, action, reboot, time, or lock provenance is invalid' }
    if ([string]$checkpoint.boot_session_marker -ceq $BootSessionMarker) { Stop-Installer 'DBINST_RESUME_SAME_BOOT' 'resume requires a different native Windows boot session' }
    return $checkpoint
}

function Remove-ValidatedInstallCheckpoint {
    param([string]$Path, [string]$Root)
    $full = Assert-InstallerCheckpointPath -Path $Path -Root $Root
    if (Test-Path -LiteralPath $full -PathType Leaf) { [IO.File]::Delete($full) }
}

function Invoke-InstallActionSequence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Actions,
        [Parameter(Mandatory = $true)][string]$CheckpointPath,
        [string]$CheckpointRoot,
        [Parameter(Mandatory = $true)][string]$LockSha256,
        $InstallOptions = @{},
        [string]$BootSessionMarker = 'test-unspecified-boot',
        [scriptblock]$EnvironmentCheck = { },
        [Parameter(Mandatory = $true)][scriptblock]$PreconditionCheck,
        [scriptblock]$CheckpointWriter,
        [switch]$Resume
    )
    & $EnvironmentCheck
    if (-not $CheckpointRoot) { $CheckpointRoot = Split-Path -Parent ([IO.Path]::GetFullPath($CheckpointPath)) }
    $checkpointFull = Assert-InstallerCheckpointPath -Path $CheckpointPath -Root $CheckpointRoot
    $start = 0
    if ($Resume) {
        $checkpoint = Read-ValidatedInstallCheckpoint -Path $checkpointFull -Root $CheckpointRoot -LockSha256 $LockSha256 -Actions $Actions -InstallOptions $InstallOptions -BootSessionMarker $BootSessionMarker
        $start = [int]$checkpoint.next_action_index
        & $PreconditionCheck
        for ($completedIndex = 0; $completedIndex -lt $start; $completedIndex++) {
            if ($Actions[$completedIndex].postcondition) { & $Actions[$completedIndex].postcondition $Actions[$completedIndex] }
        }
    }
    elseif (Test-Path -LiteralPath $checkpointFull) { Stop-Installer 'DBINST_CHECKPOINT_RESUME_REQUIRED' 'an installer checkpoint exists; explicitly pass -Resume after reboot' }
    for ($index = $start; $index -lt $Actions.Count; $index++) {
        & $EnvironmentCheck
        & $PreconditionCheck
        $result = & $Actions[$index].invoke $Actions[$index]
        $exitCode = if ($result -is [int]) { [int]$result } elseif ($null -ne $result.exit_code) { [int]$result.exit_code } else { 0 }
        if ($exitCode -eq 3010 -and $Actions[$index].checkpoint_on_3010 -eq $true) {
            try {
                if ($CheckpointWriter) { & $CheckpointWriter }
                else { Write-InstallCheckpoint -Path $checkpointFull -Root $CheckpointRoot -LockSha256 $LockSha256 -Actions $Actions -InstallOptions $InstallOptions -NextActionIndex ($index + 1) -CompletedAction $Actions[$index].name -BootSessionMarker $BootSessionMarker }
            }
            catch {
                $checkpointFailure = $_
                $checkpointCleanupError = ''
                try {
                    Assert-InstallerCheckpointPath -Path $checkpointFull -Root $CheckpointRoot | Out-Null
                    if (Test-Path -LiteralPath $checkpointFull -PathType Leaf) { [IO.File]::Delete($checkpointFull) }
                }
                catch { $checkpointCleanupError = $_.Exception.Message }
                if ($null -ne $result -and $result.PSObject.Properties['checkpoint_rollback'] -and $result.checkpoint_rollback) {
                    try { & $result.checkpoint_rollback | Out-Null }
                    catch {
                        $receiptText = if ($result.PSObject.Properties['rollback_receipt']) { $result.rollback_receipt | ConvertTo-Json -Compress } else { '{}' }
                        Stop-Installer 'DBINST_COMPOSE_ROLLBACK_FAILED' "checkpoint persistence failed and Compose compensation failed; recovery receipt=$receiptText; checkpoint cleanup=$checkpointCleanupError; cause=$($checkpointFailure.Exception.Message); rollback=$($_.Exception.Message)"
                    }
                }
                Stop-Installer 'DBINST_CHECKPOINT_WRITE_FAILED' "checkpoint persistence failed after $($Actions[$index].name); compensating rollback completed when required; checkpoint cleanup=$checkpointCleanupError; cause=$($checkpointFailure.Exception.Message)"
            }
            Stop-Installer 'DBINST_REBOOT_REQUIRED' "action $($Actions[$index].name) returned 3010; reboot and explicitly resume before any later action"
        }
        if ($exitCode -ne 0) { Stop-Installer 'DBINST_ACTION_FAILED' "action $($Actions[$index].name) exited with $exitCode" }
        if ($Actions[$index].postcondition) { & $Actions[$index].postcondition $Actions[$index] }
    }
    if (Test-Path -LiteralPath $checkpointFull) { Remove-ValidatedInstallCheckpoint -Path $checkpointFull -Root $CheckpointRoot }
    return [pscustomobject][ordered]@{ status = 'complete'; actions_completed = $Actions.Count - $start }
}

function Get-VisualStudioInstalledState {
    param($Lock, [string]$InstallPath = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools', [string]$InstancesRoot, [string]$WindowsSdkRoot, [string]$VswherePath, [scriptblock]$VswhereRunner)
    if (-not (Test-Path -LiteralPath $InstallPath)) { return 'missing' }
    if (-not (Test-Path -LiteralPath $InstallPath -PathType Container)) { return 'conflict' }
    try { Assert-VisualStudioInstallPostcondition -Lock $Lock -InstallPath $InstallPath -InstancesRoot $InstancesRoot -WindowsSdkRoot $WindowsSdkRoot -VswherePath $VswherePath -VswhereRunner $VswhereRunner; return 'exact' }
    catch {
        try {
            if (-not $InstancesRoot) { $InstancesRoot = Join-Path $env:ProgramData 'Microsoft\VisualStudio\Packages\_Instances' }
            if (-not $WindowsSdkRoot) { $WindowsSdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10' }
            if (-not $VswherePath) { $VswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe' }
            if (Test-VisualStudioOwnedPathsUnsafe -Lock $Lock -InstallPath $InstallPath -InstancesRoot $InstancesRoot -WindowsSdkRoot $WindowsSdkRoot -VswherePath $VswherePath) { return 'conflict' }
            Get-VisualStudioStateRecord -Lock $Lock -InstallPath $InstallPath -InstancesRoot $InstancesRoot | Out-Null
            return 'repairable'
        }
        catch { return 'conflict' }
    }
}

function Get-RustInstalledState {
    param($Lock, [string]$RustupHome, [string]$ReceiptPath, [string]$LockSha256)
    $root = Join-Path (Join-Path $RustupHome 'toolchains') $Lock.rust.toolchain_directory
    if (-not (Test-Path -LiteralPath $root)) {
        if ($ReceiptPath -and (Test-Path -LiteralPath $ReceiptPath)) { return 'conflict' }
        return 'missing'
    }
    try {
        Assert-NoReparsePath -Path $root -Root ([IO.Path]::GetFullPath($RustupHome)) | Out-Null
        Assert-InstallerPhysicalTree -Root $root -Code 'DBINST_RUST_POSTCONDITION_FAILED' -Description 'locked Rust toolchain'
    }
    catch { return 'conflict' }
    if (-not $ReceiptPath -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { return 'repairable' }
    try { Read-ValidatedRustToolchainReceipt -Lock $Lock -RustupHome $RustupHome -ReceiptPath $ReceiptPath -LockSha256 $LockSha256 | Out-Null }
    catch { return 'conflict' }
    try { Assert-RustToolchainPostcondition -Lock $Lock -RustupHome $RustupHome -ReceiptPath $ReceiptPath -LockSha256 $LockSha256; return 'exact' }
    catch { return 'repairable' }
}

function Get-VersionedToolInstalledState {
    param([string]$Name, [string]$Root, [string]$ArchivePath, [string]$Sha256, $Lock, [string]$ArchiveSubdirectory)
    if (-not (Test-Path -LiteralPath $Root)) { return 'missing' }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return 'conflict' }
    $marker = Join-Path $Root '.doppelbanger-tool.json'
    try {
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return 'conflict' }
        $metadata = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        if ($metadata.schema_version -ne 1 -or [string]$metadata.name -cne $Name -or [string]$metadata.archive_sha256 -cne $Sha256) { return 'conflict' }
        Assert-VersionedToolMatchesArchive -Name $Name -Root $Root -ArchivePath $ArchivePath -Sha256 $Sha256 -Lock $Lock -ArchiveSubdirectory $ArchiveSubdirectory | Out-Null
        return 'exact'
    }
    catch { return 'conflict' }
}

function Assert-WindowsToolchainPathProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Lock,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$RustupHome,
        [Parameter(Mandatory = $true)][string]$RustReceiptPath,
        [Parameter(Mandatory = $true)][string]$LockSha256,
        [scriptblock]$StateProbe
    )
    foreach ($name in @('visual_studio', 'rustup', 'cmake', 'ninja', 'node')) {
        $matches = @($Plan.actions | Where-Object { [string]$_.name -ceq $name })
        if ($matches.Count -ne 1) { Stop-Installer 'DBINST_PATH_PROVENANCE_INVALID' "install plan does not contain exactly one $name action" }
        $action = $matches[0]
        try {
            if ($StateProbe) { $state = [string](& $StateProbe $name $action) }
            else {
                switch ($name) {
                    'visual_studio' { $state = Get-VisualStudioInstalledState -Lock $Lock }
                    'rustup' { $state = Get-RustInstalledState -Lock $Lock -RustupHome $RustupHome -ReceiptPath $RustReceiptPath -LockSha256 $LockSha256 }
                    default {
                        $state = Get-VersionedToolInstalledState -Name $name -Root $action.target_root -ArchivePath $action.cache_path -Sha256 $action.sha256 -ArchiveSubdirectory ([string]$action.archive_subdirectory) -Lock $Lock
                    }
                }
            }
        }
        catch { Stop-Installer 'DBINST_PATH_PROVENANCE_INVALID' "$name provenance could not be reproven immediately before the user PATH write: $($_.Exception.Message)" }
        if ([string]$state -cne 'exact') { Stop-Installer 'DBINST_PATH_PROVENANCE_INVALID' "$name provenance is $state rather than exact immediately before the user PATH write" }
    }
    return $true
}

function Get-DockerDesktopInstalledMetadata {
    param($Lock)
    $desktopExe = Join-Path $Lock.docker.root 'Docker Desktop.exe'
    if (-not (Test-Path -LiteralPath $desktopExe -PathType Leaf)) { return $null }
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($desktopExe)
    $version = if ([string]$info.ProductVersion -match '([0-9]+\.[0-9]+\.[0-9]+)') { $Matches[1] } else { '' }
    $build = if ([string]$info.FileVersion -match '^[^0-9]*[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+)') { $Matches[1] } else { '' }
    return [pscustomobject]@{ version = $version; build = $build }
}

function New-WindowsToolchainInstallerMainSeams {
    [CmdletBinding()]
    param()
    return [ordered]@{
        environment_probe = {
            $userProfile = [string]$env:USERPROFILE
            return [pscustomobject][ordered]@{
                local_app_data = [string]$env:LOCALAPPDATA
                user_profile = $userProfile
                rustup_home = [string]$env:RUSTUP_HOME
                cargo_home = [string]$env:CARGO_HOME
            }
        }
        environment_check = { Assert-NativeInstallEnvironment -Probe (Get-NativeInstallEnvironmentProbe) | Out-Null }
        boot_session_probe = { return Get-NativeBootSessionMarker }
        preflight_check = { param($Targets); Assert-InstallPreflightTargetAncestry -TargetPaths $Targets | Out-Null }
        precondition_check = { param($Targets); Assert-InstallPreconditions -TargetPaths $Targets | Out-Null }
        checkpoint_writer = $null
        live_execute = {
            param($Request)
            return Invoke-WindowsToolchainLiveActions -Actions $Request.actions -CheckpointPath $Request.checkpoint_path -CheckpointRoot $Request.checkpoint_root -LockSha256 $Request.lock_sha256 -InstallOptions $Request.install_options -BootSessionMarker $Request.boot_session_marker -EnvironmentCheck $Request.environment_check -PreconditionCheck $Request.precondition_check -CheckpointWriter $Request.checkpoint_writer -Resume:$Request.resume
        }
        completion_writer = { param($Message); Write-Host $Message }
        process_runner = { param($Path, $Arguments); return Invoke-BootstrapProcess -Path $Path -Arguments $Arguments }
        wsl_runner = { Stop-Installer 'DBINST_SIDE_EFFECT_FORBIDDEN' 'the Windows workstation installer has no WSL execution path' }
        service_runner = { Stop-Installer 'DBINST_SIDE_EFFECT_FORBIDDEN' 'the Windows workstation installer has no service-control path' }
        path_reader = { return [Environment]::GetEnvironmentVariable('Path', 'User') }
        path_writer = { param($Value); [Environment]::SetEnvironmentVariable('Path', $Value, 'User') }
        docker_prepare = {
            param($Request)
            $metadata = Get-DockerDesktopInstalledMetadata -Lock $Request.lock
            $isExact = $null -ne $metadata -and (Test-DockerDesktopExactState -Lock $Request.lock -Metadata $metadata)
            if ((-not $isExact -or [bool]$Request.resume) -and -not $Request.backup_manifest_path) {
                Stop-Installer 'DBINST_DOCKER_BACKUP_INVALID' '-DockerBackupManifest is required for a Docker upgrade or reboot resume'
            }
            $manifestHash = ''
            $manifest = $null
            $composeMetadata = $null
            $detectedDataPath = ''
            $dataRoots = @()
            $preflightPaths = @([string]$Request.lock.docker.root)
            if ($Request.backup_manifest_path) {
                if (-not (Test-Path -LiteralPath $Request.backup_manifest_path -PathType Leaf)) { Stop-Installer 'DBINST_DOCKER_BACKUP_INVALID' 'Docker backup manifest is missing' }
                $manifestHash = Get-FileSha256 -Path $Request.backup_manifest_path
                try { $manifest = Get-Content -LiteralPath $Request.backup_manifest_path -Raw | ConvertFrom-Json }
                catch { Stop-Installer 'DBINST_DOCKER_BACKUP_INVALID' 'Docker backup manifest is not valid JSON' }
                $composeMetadata = Get-InstallerDockerComposeMetadata
                $candidates = @(Get-DockerDataCandidatePaths -LocalAppData $Request.local_app_data)
                $dataRoots = @($candidates | ForEach-Object { Split-Path -Parent ([IO.Path]::GetFullPath([string]$_)) } | Select-Object -Unique)
                if (-not $isExact) { $detectedDataPath = Resolve-DockerDataPath -CandidatePaths $candidates }
                $preflightPaths += @(
                    [string]$manifest.source_data_path,
                    [string]$manifest.backup_path,
                    [string]$Request.backup_manifest_path,
                    [string]$composeMetadata.winner
                ) + @($composeMetadata.plugin_roots) + @($dataRoots)
            }
            return [pscustomobject][ordered]@{
                installed_metadata = $metadata
                manifest_sha256 = $manifestHash
                manifest = $manifest
                compose_metadata = $composeMetadata
                detected_data_path = $detectedDataPath
                data_roots = $dataRoots
                preflight_paths = $preflightPaths
            }
        }
        docker_execute = {
            param($Request)
            if ([string]$Request.phase -ceq 'postcondition') {
                $metadata = Get-DockerDesktopInstalledMetadata -Lock $Request.lock
                if ($null -eq $metadata -or -not (Test-DockerDesktopExactState -Lock $Request.lock -Metadata $metadata)) {
                    Stop-Installer 'DBINST_DOCKER_POSTCONDITION_FAILED' 'exact locked Docker Desktop version and build are not installed'
                }
                return 0
            }
            if ([string]$Request.phase -cne 'invoke') { Stop-Installer 'DBINST_DOCKER_INSTALL_INVALID' 'Docker execution seam received an unknown phase' }
            $stateLock = $Request.lock
            $stateProbe = {
                $metadata = Get-DockerDesktopInstalledMetadata -Lock $stateLock
                if ($null -eq $metadata) { return 'conflict' }
                if (Test-DockerDesktopExactState -Lock $stateLock -Metadata $metadata) { return 'exact' }
                return 'repairable'
            }.GetNewClosure()
            $mutationRequest = $Request
            $mutation = {
                $current = Get-DockerDesktopInstalledMetadata -Lock $mutationRequest.lock
                if ($null -eq $current -or -not $current.version) { Stop-Installer 'DBINST_DOCKER_INSTALL_INVALID' 'the existing all-users Docker Desktop version could not be determined' }
                $artifactAction = $mutationRequest.action
                $artifactProvider = { Get-VerifiedArtifact -Url $artifactAction.url -Sha256 $artifactAction.sha256 -CachePath $artifactAction.cache_path }.GetNewClosure()
                return Upgrade-DockerDesktop -Lock $mutationRequest.lock -ArtifactProvider $artifactProvider -DockerBackupManifest $mutationRequest.backup_manifest_path -CurrentDesktopVersion $current.version -DetectedSourceDataPath $mutationRequest.detected_data_path -DockerDataRoots $mutationRequest.data_roots -ComposeMetadata $mutationRequest.compose_metadata -BackupShadowingComposePlugin:$mutationRequest.backup_shadowing_compose_plugin -Runner $mutationRequest.process_runner
            }.GetNewClosure()
            return Invoke-IdempotentInstallAction -Name 'docker' -StateProbe $stateProbe -Mutation $mutation
        }
    }
}

function Assert-WindowsToolchainInstallerMainSeams {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$MainSeams)
    $required = @(
        'environment_probe', 'environment_check', 'boot_session_probe', 'preflight_check', 'precondition_check',
        'checkpoint_writer', 'live_execute', 'completion_writer', 'process_runner', 'wsl_runner', 'service_runner',
        'path_reader', 'path_writer', 'docker_prepare', 'docker_execute'
    )
    foreach ($name in $required) {
        if (-not $MainSeams.Contains($name)) { Stop-Installer 'DBINST_MAIN_SEAMS_INVALID' "installer main seam is missing: $name" }
        if ($name -ceq 'checkpoint_writer' -and $null -eq $MainSeams[$name]) { continue }
        if ($MainSeams[$name] -isnot [scriptblock]) { Stop-Installer 'DBINST_MAIN_SEAMS_INVALID' "installer main seam is not a scriptblock: $name" }
    }
    return $true
}

function Invoke-WindowsToolchainInstallerMain {
    [CmdletBinding()]
    param(
        [switch]$PlanOnly,
        [switch]$UpgradeDockerDesktop,
        [string]$DockerBackupManifest,
        [switch]$BackupShadowingComposePlugin,
        [switch]$Resume,
        [string]$LockPath,
        [string]$CheckpointPath,
        [Collections.IDictionary]$MainSeams
    )
    if (-not $MainSeams) { $MainSeams = New-WindowsToolchainInstallerMainSeams }
    Assert-WindowsToolchainInstallerMainSeams -MainSeams $MainSeams | Out-Null
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $canonicalLock = [IO.Path]::GetFullPath((Join-Path $repoRoot 'tools\windows-toolchain.lock.json'))
    $effectiveLock = if ($LockPath) { [IO.Path]::GetFullPath($LockPath) } else { $canonicalLock }
    if ($effectiveLock -ine $canonicalLock) { Stop-Installer 'DBINST_LOCK_OVERRIDE_FORBIDDEN' 'live installer is hard-bound to the checked-in Windows toolchain lock' }
    $lock = Read-InstallerLock -Path $canonicalLock
    $environment = & $MainSeams.environment_probe
    if ($null -eq $environment -or -not $environment.local_app_data) { Stop-Installer 'DBINST_ENVIRONMENT_INVALID' 'LOCALAPPDATA is required' }
    if (-not $environment.user_profile) { Stop-Installer 'DBINST_ENVIRONMENT_INVALID' 'USERPROFILE is required' }
    $checkpointRoot = [IO.Path]::GetFullPath((Join-Path ([string]$environment.local_app_data) 'doppelbanger')).TrimEnd('\')
    $canonicalCheckpoint = Join-Path $checkpointRoot 'installer-checkpoint-v1.json'
    $checkpoint = if ($CheckpointPath) { [IO.Path]::GetFullPath($CheckpointPath) } else { $canonicalCheckpoint }
    if ($checkpoint -ine $canonicalCheckpoint) { Stop-Installer 'DBINST_CHECKPOINT_PATH_INVALID' 'live installer checkpoint is hard-bound beneath %LOCALAPPDATA%\doppelbanger' }
    $plan = New-WindowsToolchainInstallPlan -Lock $lock -LocalAppData ([string]$environment.local_app_data) -UpgradeDocker:$UpgradeDockerDesktop
    if ($PlanOnly) {
        $plan | ConvertTo-Json -Depth 10
        return
    }

    & $MainSeams.environment_check | Out-Null
    $environmentCheck = $MainSeams.environment_check
    $bootSessionMarker = [string](& $MainSeams.boot_session_probe)
    if (-not $bootSessionMarker) { Stop-Installer 'DBINST_BOOT_SESSION_UNKNOWN' 'native Windows boot session marker could not be determined' }
    $lockSha256 = Get-FileSha256 -Path $canonicalLock
    $rustupHome = if ($environment.rustup_home) { [IO.Path]::GetFullPath([string]$environment.rustup_home) } else { Join-Path ([string]$environment.user_profile) '.rustup' }
    $cargoHome = if ($environment.cargo_home) { [IO.Path]::GetFullPath([string]$environment.cargo_home) } else { Join-Path ([string]$environment.user_profile) '.cargo' }
    $rustReceiptPath = Join-Path $checkpointRoot ("rust-toolchain-{0}-receipt-v1.json" -f [string]$lock.rust.toolchain_directory)

    $dockerPreparationCalled = $false
    $dockerInstalledMetadata = $null
    $dockerManifestHash = ''
    $dockerManifest = $null
    $dockerComposeMetadata = $null
    $dockerDetectedDataPath = ''
    $dockerDataRoots = @()
    $dockerPaths = @()
    if ($UpgradeDockerDesktop) {
        $dockerPreparationCalled = $true
        $dockerPreparation = & $MainSeams.docker_prepare ([pscustomobject][ordered]@{
            lock = $lock
            local_app_data = [string]$environment.local_app_data
            backup_manifest_path = [string]$DockerBackupManifest
            resume = [bool]$Resume
        })
        if ($null -eq $dockerPreparation -or $null -eq $dockerPreparation.preflight_paths) { Stop-Installer 'DBINST_DOCKER_PREPARATION_INVALID' 'Docker preparation seam returned incomplete context' }
        $dockerInstalledMetadata = $dockerPreparation.installed_metadata
        $dockerManifestHash = [string]$dockerPreparation.manifest_sha256
        $dockerManifest = $dockerPreparation.manifest
        $dockerComposeMetadata = $dockerPreparation.compose_metadata
        $dockerDetectedDataPath = [string]$dockerPreparation.detected_data_path
        $dockerDataRoots = @($dockerPreparation.data_roots)
        $dockerPaths = @($dockerPreparation.preflight_paths)
    }
    $installOptions = [pscustomobject][ordered]@{
        upgrade_docker = [bool]$UpgradeDockerDesktop
        docker_manifest_sha256 = $dockerManifestHash
        backup_shadowing_compose_plugin = [bool]$BackupShadowingComposePlugin
    }
    $targets = Get-InstallPreflightTargets -Plan $plan -Lock $lock -RustupHome $rustupHome -CargoHome $cargoHome -CheckpointPath $checkpoint -DockerPaths $dockerPaths
    & $MainSeams.preflight_check $targets | Out-Null
    $preconditionTargets = @($targets)
    $precondition = { & $MainSeams.precondition_check $preconditionTargets | Out-Null }.GetNewClosure()
    $actionDefinitions = @{}
    foreach ($planned in @($plan.actions | Where-Object { $_.enabled })) {
        $checkpointOn3010 = $planned.name -in @('visual_studio', 'docker')
        $actionDefinitions[$planned.name] = [pscustomobject]@{ name = $planned.name; plan = $planned; checkpoint_on_3010 = $checkpointOn3010; postcondition = {
            param($sequenceAction)
            $completed = $sequenceAction.plan
            switch ($completed.name) {
                'visual_studio' { Assert-VisualStudioInstallPostcondition -Lock $lock }
                'rustup' { Assert-RustToolchainPostcondition -Lock $lock -RustupHome $rustupHome -ReceiptPath $rustReceiptPath -LockSha256 $lockSha256 }
                'cmake' { Assert-VersionedToolMatchesArchive -Name 'cmake' -Root $completed.target_root -ArchivePath $completed.cache_path -Sha256 $completed.sha256 -ArchiveSubdirectory $completed.archive_subdirectory -Lock $lock | Out-Null }
                'ninja' { Assert-VersionedToolMatchesArchive -Name 'ninja' -Root $completed.target_root -ArchivePath $completed.cache_path -Sha256 $completed.sha256 -Lock $lock | Out-Null }
                'node' { Assert-VersionedToolMatchesArchive -Name 'node' -Root $completed.target_root -ArchivePath $completed.cache_path -Sha256 $completed.sha256 -ArchiveSubdirectory $completed.archive_subdirectory -Lock $lock | Out-Null }
                'docker' {
                    & $MainSeams.docker_execute ([pscustomobject][ordered]@{ phase = 'postcondition'; lock = $lock }) | Out-Null
                }
            }
        }; invoke = {
            param($sequenceAction)
            $action = $sequenceAction.plan
            switch ($action.name) {
                'visual_studio' {
                    return Invoke-IdempotentInstallAction -Name 'visual_studio' -StateProbe { Get-VisualStudioInstalledState -Lock $lock } -Mutation {
                        $artifact = Get-VerifiedArtifact -Url $action.url -Sha256 $action.sha256 -CachePath $action.cache_path
                        return Install-VsBuildTools -Lock $lock -ArtifactPath $artifact -Runner $MainSeams.process_runner
                    }
                }
                'rustup' {
                    return Invoke-IdempotentInstallAction -Name 'rustup' -StateProbe { Get-RustInstalledState -Lock $lock -RustupHome $rustupHome -ReceiptPath $rustReceiptPath -LockSha256 $lockSha256 } -Mutation {
                        $artifact = Get-VerifiedArtifact -Url $action.url -Sha256 $action.sha256 -CachePath $action.cache_path
                        return Install-RustToolchain -Lock $lock -ArtifactPath $artifact -RustupHome $rustupHome -CargoHome $cargoHome -ReceiptPath $rustReceiptPath -LockSha256 $lockSha256 -Runner $MainSeams.process_runner
                    }
                }
                'cmake' {
                    $artifact = Get-VerifiedArtifact -Url $action.url -Sha256 $action.sha256 -CachePath $action.cache_path
                    return Invoke-IdempotentInstallAction -Name 'cmake' -StateProbe { Get-VersionedToolInstalledState -Name 'cmake' -Root $action.target_root -ArchivePath $artifact -Sha256 $action.sha256 -ArchiveSubdirectory $action.archive_subdirectory -Lock $lock } -Mutation {
                        Expand-VersionedTool -Name 'cmake' -ArchivePath $artifact -Sha256 $action.sha256 -TargetRoot $action.target_root -ArchiveSubdirectory $action.archive_subdirectory -Lock $lock | Out-Null
                        return 0
                    }
                }
                'ninja' {
                    $artifact = Get-VerifiedArtifact -Url $action.url -Sha256 $action.sha256 -CachePath $action.cache_path
                    return Invoke-IdempotentInstallAction -Name 'ninja' -StateProbe { Get-VersionedToolInstalledState -Name 'ninja' -Root $action.target_root -ArchivePath $artifact -Sha256 $action.sha256 -Lock $lock } -Mutation {
                        Expand-VersionedTool -Name 'ninja' -ArchivePath $artifact -Sha256 $action.sha256 -TargetRoot $action.target_root -Lock $lock | Out-Null
                        return 0
                    }
                }
                'node' {
                    $artifact = Get-VerifiedArtifact -Url $action.url -Sha256 $action.sha256 -CachePath $action.cache_path
                    return Invoke-IdempotentInstallAction -Name 'node' -StateProbe { Get-VersionedToolInstalledState -Name 'node' -Root $action.target_root -ArchivePath $artifact -Sha256 $action.sha256 -ArchiveSubdirectory $action.archive_subdirectory -Lock $lock } -Mutation {
                        Expand-VersionedTool -Name 'node' -ArchivePath $artifact -Sha256 $action.sha256 -TargetRoot $action.target_root -ArchiveSubdirectory $action.archive_subdirectory -Lock $lock | Out-Null
                        return 0
                    }
                }
                'docker' {
                    return & $MainSeams.docker_execute ([pscustomobject][ordered]@{
                        phase = 'invoke'
                        lock = $lock
                        action = $action
                        backup_manifest_path = [string]$DockerBackupManifest
                        detected_data_path = $dockerDetectedDataPath
                        data_roots = $dockerDataRoots
                        compose_metadata = $dockerComposeMetadata
                        backup_shadowing_compose_plugin = [bool]$BackupShadowingComposePlugin
                        process_runner = $MainSeams.process_runner
                    })
                }
            }
        } }
    }
    $actionDefinitions['user_path'] = [pscustomobject]@{
        name = 'user_path'
        checkpoint_on_3010 = $false
        postcondition = $null
        invoke = {
            Set-DoppelbangerUserPath -RequiredDirectories $plan.user_path_entries -ProvenanceCheck {
                Assert-WindowsToolchainPathProvenance -Lock $lock -Plan $plan -RustupHome $rustupHome -RustReceiptPath $rustReceiptPath -LockSha256 $lockSha256 | Out-Null
            } -PathReader $MainSeams.path_reader -PathWriter $MainSeams.path_writer | Out-Null
            return 0
        }
    }
    $liveActions = @(New-WindowsToolchainLiveActions -ActionDefinitions $actionDefinitions -UpgradeDocker:$UpgradeDockerDesktop)
    $liveRequest = [pscustomobject][ordered]@{
        actions = $liveActions
        action_definitions = $actionDefinitions
        docker_context = [pscustomobject][ordered]@{
            prepared = $dockerPreparationCalled
            installed_metadata = $dockerInstalledMetadata
            manifest_sha256 = $dockerManifestHash
            manifest = $dockerManifest
            compose_metadata = $dockerComposeMetadata
            detected_data_path = $dockerDetectedDataPath
            data_roots = $dockerDataRoots
            preflight_paths = $dockerPaths
        }
        checkpoint_path = $checkpoint
        checkpoint_root = $checkpointRoot
        checkpoint_writer = $MainSeams.checkpoint_writer
        lock_sha256 = $lockSha256
        install_options = $installOptions
        boot_session_marker = $bootSessionMarker
        environment_check = $environmentCheck
        precondition_check = $precondition
        resume = [bool]$Resume
    }
    & $MainSeams.live_execute $liveRequest | Out-Null
    & $MainSeams.completion_writer 'Doppelbanger Windows toolchain provisioning complete. Open a fresh native PowerShell.' | Out-Null
}

if ($MyInvocation.InvocationName -ne '.' -and -not $NoRun) {
    Invoke-WindowsToolchainInstallerMain -PlanOnly:$PlanOnly -UpgradeDockerDesktop:$UpgradeDockerDesktop -DockerBackupManifest $DockerBackupManifest -BackupShadowingComposePlugin:$BackupShadowingComposePlugin -Resume:$Resume -LockPath $LockPath -CheckpointPath $CheckpointPath
}
