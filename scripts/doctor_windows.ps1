[CmdletBinding()]
param(
    [ValidateSet('HeadlessVst3', 'Compatibility')]
    [string]$Profile = 'HeadlessVst3',
    [switch]$Json,
    [string]$ReportPath,
    [string]$ProbePath,
    [string]$LockPath,
    [switch]$NoRun
)

$ErrorActionPreference = 'Stop'

function Read-ToolchainLock {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $lock = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    if ($lock.schema_version -ne 1 -or $lock.platform -cne 'windows-x86_64-native') {
        throw "DBDOC_LOCK_INVALID: unsupported Windows toolchain lock at $resolved"
    }
    return $lock
}

function Merge-ProbeOverlay {
    param([Parameter(Mandatory = $true)]$Base, [Parameter(Mandatory = $true)]$Overlay)
    foreach ($property in $Overlay.PSObject.Properties) {
        if ($property.Name -notin @('extends', 'expected_code')) {
            $Base | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
    }
    return $Base
}

function Read-ProbeFixture {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $probe = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    if ($probe.extends) {
        $basePath = Join-Path (Split-Path -Parent $resolved) $probe.extends
        $base = Get-Content -LiteralPath $basePath -Raw | ConvertFrom-Json
        return Merge-ProbeOverlay -Base $base -Overlay $probe
    }
    return $probe
}

function Get-CommandPath {
    param([string]$Name)
    try {
        $command = Get-Command $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1
        return $command.Source
    }
    catch { return '' }
}

function Invoke-ProbeCommand {
    param([string]$Path, [string[]]$Arguments)
    if (-not $Path) { return '' }
    try { return ((& $Path @Arguments 2>&1) -join "`n").Trim() }
    catch { return '' }
}

function Get-NormalizedSemanticVersion {
    param([string]$Text)
    if ([string]$Text -match '(?<![0-9])v?([0-9]+\.[0-9]+\.[0-9]+)') { return $Matches[1] }
    return ''
}

function Get-FourthVersionComponent {
    param([string]$Text)
    if ([string]$Text -match '^[^0-9]*[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+)') { return $Matches[1] }
    return ''
}

function Get-PeMetadata {
    param([string]$Path)
    $result = [ordered]@{ pe_format = ''; machine = '' }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$result }
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = New-Object IO.BinaryReader($stream)
        try {
            if ($reader.ReadUInt16() -ne 0x5A4D) { return [pscustomobject]$result }
            $stream.Position = 0x3C
            $peOffset = $reader.ReadInt32()
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550) { return [pscustomobject]$result }
            $machine = $reader.ReadUInt16()
            $stream.Position = $peOffset + 24
            $magic = $reader.ReadUInt16()
            $result.pe_format = if ($magic -eq 0x20B) { 'PE32+' } elseif ($magic -eq 0x10B) { 'PE32' } else { '' }
            $result.machine = if ($machine -eq 0x8664) { 'AMD64' } else { ('0x{0:X4}' -f $machine) }
        }
        finally { $reader.Dispose(); $stream.Dispose() }
    }
    catch { }
    return [pscustomobject]$result
}

function Get-ProcessAncestors {
    $names = New-Object Collections.Generic.List[string]
    $processId = $PID
    for ($i = 0; $i -lt 32 -and $processId -gt 0; $i++) {
        try {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop
        }
        catch {
            try { $process = Get-WmiObject Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop }
            catch { break }
        }
        if (-not $process) { break }
        $names.Add([string]$process.Name)
        $processId = [int]$process.ParentProcessId
    }
    return $names.ToArray()
}

function Get-VisualStudioProbe {
    param($Lock)
    $result = [ordered]@{
        product_version = ''; installation_version = ''; instance_path = ''; vsdevcmd_path = ''
        msvc_component = ''; windows_sdk_component = ''
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return [pscustomobject]$result }
    try {
        $raw = & $vswhere -products Microsoft.VisualStudio.Product.BuildTools -version '[17.14,17.15)' `
            -requires $Lock.visual_studio.msvc_component $Lock.visual_studio.windows_sdk_component -format json -utf8 2>$null
        $instances = $raw | ConvertFrom-Json
        $instance = @($instances) | Where-Object { $_.installationVersion -ceq $Lock.visual_studio.installation_version } | Select-Object -First 1
        if (-not $instance) { $instance = @($instances) | Select-Object -First 1 }
        if ($instance) {
            $result.product_version = [string]$instance.catalog.productDisplayVersion
            $result.installation_version = [string]$instance.installationVersion
            $result.instance_path = [string]$instance.installationPath
            $result.vsdevcmd_path = Join-Path $instance.installationPath 'Common7\Tools\VsDevCmd.bat'
            $result.msvc_component = $Lock.visual_studio.msvc_component
            $result.windows_sdk_component = $Lock.visual_studio.windows_sdk_component
        }
    }
    catch { }
    return [pscustomobject]$result
}

function Add-BinaryProbe {
    param([Collections.Generic.List[object]]$List, [string]$Name, [string]$Path, [string]$LockedPath, [string]$AmbientPath, [bool]$UnderLockedRoot)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $pe = Get-PeMetadata -Path $Path
    $List.Add([pscustomobject][ordered]@{
        name = $Name; path = $Path; locked_path = $LockedPath; ambient_path = $AmbientPath
        pe_format = $pe.pe_format; machine = $pe.machine; under_locked_root = $UnderLockedRoot
    })
}

function Get-NativeWindowsProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Lock,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$ProbePath
    )

    if ($ProbePath) { return Read-ProbeFixture -Path $ProbePath }

    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $drive = [IO.Path]::GetPathRoot($repo)
    $filesystem = ''
    $freeGb = 0
    try {
        $driveInfo = New-Object IO.DriveInfo($drive)
        $filesystem = $driveInfo.DriveFormat
        $freeGb = [math]::Round($driveInfo.AvailableFreeSpace / 1GB, 2)
    }
    catch { }

    $vs = Get-VisualStudioProbe -Lock $Lock
    $cargoRoot = [Environment]::ExpandEnvironmentVariables([string]$Lock.rust.bin_root)
    $cargoLocked = Join-Path $cargoRoot 'cargo.exe'
    $rustcLocked = Join-Path $cargoRoot 'rustc.exe'
    $cmakeLocked = Join-Path $Lock.cmake.root 'bin\cmake.exe'
    $ninjaLocked = Join-Path $Lock.ninja.root 'ninja.exe'
    $nodeLocked = Join-Path $Lock.node.root 'node.exe'
    $npmLocked = Join-Path $Lock.node.root 'npm.cmd'
    $cargoAmbient = Get-CommandPath 'cargo.exe'
    $rustcAmbient = Get-CommandPath 'rustc.exe'
    $cmakeAmbient = Get-CommandPath 'cmake.exe'
    $ninjaAmbient = Get-CommandPath 'ninja.exe'
    $nodeAmbient = Get-CommandPath 'node.exe'
    $clAmbient = Get-CommandPath 'cl.exe'
    $cargoPath = if (Test-Path -LiteralPath $cargoLocked -PathType Leaf) { $cargoLocked } else { '' }
    $rustcPath = if (Test-Path -LiteralPath $rustcLocked -PathType Leaf) { $rustcLocked } else { '' }
    $cmakePath = if (Test-Path -LiteralPath $cmakeLocked -PathType Leaf) { $cmakeLocked } else { '' }
    $ninjaPath = if (Test-Path -LiteralPath $ninjaLocked -PathType Leaf) { $ninjaLocked } else { '' }
    $nodePath = if (Test-Path -LiteralPath $nodeLocked -PathType Leaf) { $nodeLocked } else { '' }
    $npmPath = if (Test-Path -LiteralPath $npmLocked -PathType Leaf) { $npmLocked } else { '' }
    $clPath = ''
    if ($vs.instance_path) {
        $msvcRoot = Join-Path $vs.instance_path 'VC\Tools\MSVC'
        $msvcFolder = Get-ChildItem -LiteralPath $msvcRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$($Lock.visual_studio.vcvars_version).*" } |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($msvcFolder) {
            $candidate = Join-Path $msvcFolder.FullName 'bin\Hostx64\x64\cl.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $clPath = $candidate }
        }
    }
    $rustInfo = Invoke-ProbeCommand $rustcPath @('-vV')
    $clInfo = Invoke-ProbeCommand $clPath @('/Bv')
    $cmakeInfo = Invoke-ProbeCommand $cmakePath @('--version')
    $ninjaInfo = Invoke-ProbeCommand $ninjaPath @('--version')
    $nodeInfo = Invoke-ProbeCommand $nodePath @('-p', 'JSON.stringify({version:process.versions.node,platform:process.platform,arch:process.arch})')
    $npmInfo = Invoke-ProbeCommand $npmPath @('--version')
    $nodeData = $null
    try { if ($nodeInfo) { $nodeData = $nodeInfo | ConvertFrom-Json } } catch { }

    $dockerLocked = [string]$Lock.docker.cli_path
    $dockerAmbient = Get-CommandPath 'docker.exe'
    $dockerPath = if (Test-Path -LiteralPath $dockerLocked -PathType Leaf) { $dockerLocked } else { '' }
    $composeExpected = [string]$Lock.docker.compose_plugin_path
    $userCompose = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.docker\cli-plugins\docker-compose.exe' } else { '' }
    $composeWinner = if ($userCompose -and (Test-Path -LiteralPath $userCompose -PathType Leaf)) { $userCompose } elseif (Test-Path -LiteralPath $composeExpected -PathType Leaf) { $composeExpected } else { '' }
    $dockerCliInfo = Invoke-ProbeCommand $dockerPath @('--version')
    $dockerServerInfo = Invoke-ProbeCommand $dockerPath @('version', '--format', '{{json .Server}}')
    $dockerContext = Invoke-ProbeCommand $dockerPath @('context', 'show')
    $composeInfo = ''
    if ($composeWinner) { $composeInfo = Invoke-ProbeCommand $composeWinner @('version', '--short') }
    $composeConfigValid = $false
    $composeFile = Join-Path $repo 'docker-compose.yml'
    if ((Test-Path -LiteralPath $composeExpected -PathType Leaf) -and (Test-Path -LiteralPath $composeFile -PathType Leaf)) {
        try {
            & $composeExpected -f $composeFile config --quiet 2>$null | Out-Null
            $composeConfigValid = $LASTEXITCODE -eq 0
        }
        catch { $composeConfigValid = $false }
    }
    $server = $null
    try { if ($dockerServerInfo) { $server = $dockerServerInfo | ConvertFrom-Json } } catch { }

    $desktopVersion = ''
    $desktopBuild = ''
    try {
        $desktop = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq 'Docker Desktop' } | Select-Object -First 1
        if (-not $desktop) {
            $desktop = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq 'Docker Desktop' } | Select-Object -First 1
        }
        if ($desktop) { $desktopVersion = ([string]$desktop.DisplayVersion -replace '^v', '') }
        $desktopExe = Join-Path $Lock.docker.root 'Docker Desktop.exe'
        if (Test-Path -LiteralPath $desktopExe) {
            $fv = [Diagnostics.FileVersionInfo]::GetVersionInfo($desktopExe)
            if (-not $desktopVersion) { $desktopVersion = [string]$fv.ProductVersion }
            $desktopBuild = Get-FourthVersionComponent ([string]$fv.FileVersion)
        }
    }
    catch { }

    $pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $webview = Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F1E7E2DD-D75B-430F-9B6C-4FC7E8A489AF}'
    $abletonRoots = @((Join-Path $env:ProgramData 'Ableton'), (Join-Path ${env:ProgramFiles} 'Ableton'))
    $ableton = @($abletonRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) }).Count -gt 0
    $wslVersion = ''
    $wslExe = Join-Path ${env:ProgramFiles} 'WSL\wsl.exe'
    if (Test-Path -LiteralPath $wslExe -PathType Leaf) {
        try { $wslVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($wslExe).ProductVersion } catch { }
    }

    $binaries = New-Object 'Collections.Generic.List[object]'
    Add-BinaryProbe $binaries 'cargo' $cargoPath $cargoLocked $cargoAmbient ($cargoPath -and $cargoPath.StartsWith($cargoRoot, [StringComparison]::OrdinalIgnoreCase))
    Add-BinaryProbe $binaries 'rustc' $rustcPath $rustcLocked $rustcAmbient ($rustcPath -and $rustcPath.StartsWith($cargoRoot, [StringComparison]::OrdinalIgnoreCase))
    Add-BinaryProbe $binaries 'cl' $clPath $clPath $clAmbient ([bool]$clPath)
    Add-BinaryProbe $binaries 'cmake' $cmakePath $cmakeLocked $cmakeAmbient ($cmakePath -and $cmakePath.StartsWith($Lock.cmake.root, [StringComparison]::OrdinalIgnoreCase))
    Add-BinaryProbe $binaries 'ninja' $ninjaPath $ninjaLocked $ninjaAmbient ($ninjaPath -and $ninjaPath.StartsWith($Lock.ninja.root, [StringComparison]::OrdinalIgnoreCase))
    Add-BinaryProbe $binaries 'node' $nodePath $nodeLocked $nodeAmbient ($nodePath -and $nodePath.StartsWith($Lock.node.root, [StringComparison]::OrdinalIgnoreCase))
    Add-BinaryProbe $binaries 'docker' $dockerPath $dockerLocked $dockerAmbient ($dockerPath -and $dockerPath.StartsWith($Lock.docker.root, [StringComparison]::OrdinalIgnoreCase))
    Add-BinaryProbe $binaries 'docker-compose' $composeWinner $composeExpected $composeWinner ($composeWinner -and $composeWinner.StartsWith($Lock.docker.root, [StringComparison]::OrdinalIgnoreCase))
    $validatorPath = Join-Path $repo $Lock.validators.steinberg_relative_path
    $pluginvalPath = Join-Path $Lock.validators.pluginval_root 'pluginval.exe'
    Add-BinaryProbe $binaries 'validator' $validatorPath $validatorPath $validatorPath ($validatorPath.StartsWith($repo, [StringComparison]::OrdinalIgnoreCase))
    Add-BinaryProbe $binaries 'pluginval' $pluginvalPath $pluginvalPath $pluginvalPath ($pluginvalPath.StartsWith($Lock.validators.pluginval_root, [StringComparison]::OrdinalIgnoreCase))

    $gitTop = Invoke-ProbeCommand (Get-CommandPath 'git.exe') @('-C', $repo, 'rev-parse', '--show-toplevel')
    $gitOwnerOk = $gitTop -and (([IO.Path]::GetFullPath($gitTop)).TrimEnd('\') -ieq $repo.TrimEnd('\'))
    return [pscustomobject][ordered]@{
        os = if ($env:OS -eq 'Windows_NT') { 'Windows' } else { [Environment]::OSVersion.Platform.ToString() }
        arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') { 'x86_64' } else { [string]$env:PROCESSOR_ARCHITECTURE }
        wsl = [bool]($env:WSL_DISTRO_NAME -or $env:WSL_INTEROP)
        wsl_distro_name = [string]$env:WSL_DISTRO_NAME; wsl_interop = [string]$env:WSL_INTEROP
        wsl_version = $wslVersion; ancestors = @(Get-ProcessAncestors)
        repo_path = $repo; repo_filesystem = $filesystem; git_owner_ok = [bool]$gitOwnerOk
        compiler = if ($clPath) { 'MSVC' } else { '' }
        compiler_version = if ($clInfo -match 'Compiler Version ([0-9.]+)') { $Matches[1] } else { '' }
        vs_product_version = $vs.product_version; vs_installation_version = $vs.installation_version; vs_instance_path = $vs.instance_path
        msvc_component = $vs.msvc_component; windows_sdk_component = $vs.windows_sdk_component
        windows_sdk_target = if ($vs.windows_sdk_component) { [string]$Lock.visual_studio.windows_sdk_target } else { '' }
        rust_version = if ($rustInfo -match 'rustc ([0-9.]+)') { $Matches[1] } else { '' }
        rust_target = if ($rustInfo -match '(?m)^host:\s*(\S+)') { $Matches[1] } else { '' }
        cmake_version = if ($cmakeInfo -match 'cmake version ([0-9.]+)') { $Matches[1] } else { '' }
        ninja_version = ($ninjaInfo -split "`n")[0]
        node_version = if ($nodeData) { [string]$nodeData.version } else { '' }
        node_platform = if ($nodeData) { [string]$nodeData.platform } else { '' }
        node_arch = if ($nodeData) { [string]$nodeData.arch } else { '' }
        npm_version = ($npmInfo -split "`n")[0]
        docker_desktop_version = $desktopVersion; docker_desktop_build = $desktopBuild
        docker_cli_version = Get-NormalizedSemanticVersion $dockerCliInfo
        docker_engine_version = if ($server) { [string]$server.Version } else { '' }
        docker_compose_version = Get-NormalizedSemanticVersion $composeInfo
        docker_server_os = if ($server) { [string]$server.Os } else { '' }
        docker_server_arch = if ($server) { [string]$server.Arch } else { '' }
        docker_context = $dockerContext; docker_running = [bool]$server
        docker_compose_config_valid = [bool]$composeConfigValid
        docker_compose_plugin_path = $composeWinner; docker_expected_compose_plugin_path = $composeExpected
        docker_user_compose_plugin_path = if (Test-Path -LiteralPath $userCompose -PathType Leaf) { $userCompose } else { '' }
        disk_free_gb = $freeGb; pending_reboot = [bool]$pendingReboot; docker_license_accepted = $null
        webview2_present = [bool]$webview; ableton_present = [bool]$ableton
        vsdevcmd = [pscustomobject]@{
            path = $vs.vsdevcmd_path; import_args = [string]$Lock.visual_studio.vsdevcmd_arguments
            include = [string]$env:INCLUDE; lib = [string]$env:LIB; windows_sdk_dir = [string]$env:WindowsSdkDir
        }
        binaries = $binaries.ToArray()
    }
}

function New-Diagnostic {
    param([string]$Code, [string]$Message)
    return [pscustomobject][ordered]@{ code = $Code; message = $Message }
}

function Test-VersionAtLeast {
    param([string]$Actual, [string]$Minimum)
    try {
        $actualParts = @($Actual -split '[^0-9]+' | Where-Object { $_ -ne '' } | Select-Object -First 4)
        $minimumParts = @($Minimum -split '[^0-9]+' | Where-Object { $_ -ne '' } | Select-Object -First 4)
        while ($actualParts.Count -lt 4) { $actualParts += '0' }
        while ($minimumParts.Count -lt 4) { $minimumParts += '0' }
        $actualVersion = New-Object Version ([int]$actualParts[0]), ([int]$actualParts[1]), ([int]$actualParts[2]), ([int]$actualParts[3])
        $minimumVersion = New-Object Version ([int]$minimumParts[0]), ([int]$minimumParts[1]), ([int]$minimumParts[2]), ([int]$minimumParts[3])
        return $actualVersion -ge $minimumVersion
    }
    catch { return $false }
}

function Test-NativeWindowsProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Probe,
        [Parameter(Mandatory = $true)]$Lock,
        [ValidateSet('HeadlessVst3', 'Compatibility')][string]$Profile = 'HeadlessVst3'
    )

    $errors = New-Object 'Collections.Generic.List[object]'
    $warnings = New-Object 'Collections.Generic.List[object]'
    $strict = $Profile -eq 'HeadlessVst3'
    function Add-Error([string]$Code, [string]$Message) { $errors.Add((New-Diagnostic $Code $Message)) }
    function Add-Warning([string]$Code, [string]$Message) { $warnings.Add((New-Diagnostic $Code $Message)) }
    function Check-Exact([string]$Name, $Actual, $Expected) {
        if ([string]::IsNullOrWhiteSpace([string]$Actual)) { Add-Error 'DBDOC_TOOL_MISSING' "$Name is missing"; return }
        if ([string]$Actual -cne [string]$Expected) {
            if ($strict) { Add-Error 'DBDOC_TOOL_VERSION_DRIFT' "$Name expected $Expected, found $Actual" }
            else { Add-Warning 'DBDOC_TOOL_VERSION_DRIFT' "$Name expected $Expected, found $Actual" }
        }
    }

    if ($Probe.os -cne 'Windows' -or $Probe.arch -cne 'x86_64') { Add-Error 'DBDOC_NATIVE_WINDOWS_REQUIRED' 'Windows x86_64 is required' }
    $forbiddenAncestors = @($Probe.ancestors | Where-Object { ([IO.Path]::GetFileName([string]$_)).ToLowerInvariant() -in @('wsl.exe', 'wslhost.exe', 'bash.exe') })
    if ($Probe.wsl -or $Probe.wsl_distro_name -or $Probe.wsl_interop -or $forbiddenAncestors.Count -gt 0) {
        Add-Error 'DBDOC_WSL_FORBIDDEN' 'WSL environment or launcher ancestry is forbidden for native compilation'
    }
    if ($Probe.wsl_version -and -not (Test-VersionAtLeast -Actual $Probe.wsl_version -Minimum $Lock.wsl.minimum_version)) {
        if ($strict) { Add-Error 'DBDOC_TOOL_VERSION_DRIFT' "WSL expected at least $($Lock.wsl.minimum_version), found $($Probe.wsl_version)" }
        else { Add-Warning 'DBDOC_TOOL_VERSION_DRIFT' "WSL expected at least $($Lock.wsl.minimum_version), found $($Probe.wsl_version)" }
    }
    if ([string]$Probe.repo_path -notmatch '^[A-Za-z]:\\' -or [string]$Probe.repo_path -match '^\\\\|\\\\wsl\$') {
        Add-Error 'DBDOC_REPO_PATH_INVALID' 'Repository must use a drive-letter Windows path'
    }
    if ($Probe.repo_filesystem -cne 'NTFS') { Add-Error 'DBDOC_REPO_FILESYSTEM_INVALID' 'Repository drive must be NTFS' }
    if ($null -ne $Probe.git_owner_ok -and -not $Probe.git_owner_ok) { Add-Error 'DBDOC_GIT_PROVENANCE_INVALID' 'Plain Git ownership/provenance check failed' }

    if ([string]::IsNullOrWhiteSpace([string]$Probe.compiler)) { Add-Error 'DBDOC_TOOL_MISSING' 'MSVC compiler is missing' }
    elseif ($Probe.compiler -cne 'MSVC' -or [string]$Probe.compiler_version -notmatch '^19\.44(?:\.|$)') { Add-Error 'DBDOC_TOOL_VERSION_DRIFT' 'MSVC 19.44 is required' }
    Check-Exact 'Visual Studio product' $Probe.vs_product_version $Lock.visual_studio.product_version
    Check-Exact 'Visual Studio installation' $Probe.vs_installation_version $Lock.visual_studio.installation_version
    Check-Exact 'MSVC component' $Probe.msvc_component $Lock.visual_studio.msvc_component
    Check-Exact 'Windows SDK component' $Probe.windows_sdk_component $Lock.visual_studio.windows_sdk_component
    Check-Exact 'Windows SDK target' $Probe.windows_sdk_target $Lock.visual_studio.windows_sdk_target
    Check-Exact 'Rust' $Probe.rust_version $Lock.rust.toolchain
    Check-Exact 'Rust target' $Probe.rust_target $Lock.rust.target
    Check-Exact 'CMake' $Probe.cmake_version $Lock.cmake.version
    Check-Exact 'Ninja' $Probe.ninja_version $Lock.ninja.version
    Check-Exact 'Node' $Probe.node_version $Lock.node.version
    Check-Exact 'Node platform' $Probe.node_platform 'win32'
    Check-Exact 'Node architecture' $Probe.node_arch 'x64'
    Check-Exact 'npm' $Probe.npm_version $Lock.node.npm_version
    Check-Exact 'Docker Desktop' $Probe.docker_desktop_version $Lock.docker.desktop_version
    Check-Exact 'Docker Desktop build' $Probe.docker_desktop_build $Lock.docker.desktop_build
    Check-Exact 'Docker CLI' $Probe.docker_cli_version $Lock.docker.cli_version
    Check-Exact 'Docker Engine' $Probe.docker_engine_version $Lock.docker.engine_version
    Check-Exact 'Docker Compose' $Probe.docker_compose_version $Lock.docker.compose_version

    if ($Probe.docker_user_compose_plugin_path -or
        ([string]$Probe.docker_compose_plugin_path -and [string]$Probe.docker_compose_plugin_path -ine [string]$Probe.docker_expected_compose_plugin_path)) {
        Add-Error 'DBDOC_DOCKER_PLUGIN_SHADOW' "Docker Compose resolves outside Docker Desktop: $($Probe.docker_compose_plugin_path)"
    }
    if ($null -ne $Probe.docker_compose_config_valid -and -not $Probe.docker_compose_config_valid) {
        Add-Error 'DBDOC_COMPOSE_CONFIG_INVALID' 'Docker Compose could not validate docker-compose.yml through the Docker Desktop plugin'
    }
    if (-not $Probe.docker_running) { Add-Error 'DBDOC_DOCKER_STOPPED' 'Docker Desktop engine is not running' }
    else {
        Check-Exact 'Docker context' $Probe.docker_context $Lock.docker.context
        Check-Exact 'Docker server OS' $Probe.docker_server_os $Lock.docker.server_os
        Check-Exact 'Docker server architecture' $Probe.docker_server_arch $Lock.docker.server_arch
    }

    foreach ($binary in @($Probe.binaries)) {
        if ($binary.pe_format -notin @('PE32', 'PE32+') -or $binary.machine -cne 'AMD64') {
            Add-Error 'DBDOC_BINARY_NOT_PE' "$($binary.name) is not a PE32/PE32+ AMD64 executable: $($binary.path)"
        }
        if ($null -ne $binary.under_locked_root -and -not $binary.under_locked_root) {
            Add-Error 'DBDOC_TOOL_PATH_SHADOW' "$($binary.name) resolves outside its locked root: $($binary.path)"
        }
        if ($binary.name -in @('cmake', 'ninja', 'docker') -and $binary.ambient_path -and $binary.locked_path -and
            ([IO.Path]::GetFullPath([string]$binary.ambient_path) -ine [IO.Path]::GetFullPath([string]$binary.locked_path))) {
            Add-Error 'DBDOC_TOOL_PATH_SHADOW' "ambient $($binary.name) shadows the locked executable: $($binary.ambient_path)"
        }
    }

    if ([double]$Probe.disk_free_gb -lt 40) { Add-Warning 'DBDOC_LOW_DISK' "Only $($Probe.disk_free_gb) GiB is free" }
    if ($Probe.pending_reboot) { Add-Warning 'DBDOC_PENDING_REBOOT' 'Windows reports a pending reboot' }
    if ($Probe.docker_license_accepted -ne $true) { Add-Warning 'DBDOC_DOCKER_LICENSE_UNKNOWN' 'Docker Desktop license acceptance is not confirmed' }
    if (-not $Probe.ableton_present) { Add-Warning 'DBDOC_ABLETON_NOT_FOUND' 'Ableton Live was not detected; no files were changed' }
    if (-not $Probe.webview2_present) { Add-Warning 'DBDOC_WEBVIEW2_NOT_FOUND' 'WebView2 Runtime was not detected' }

    return [pscustomobject][ordered]@{
        success = ($errors.Count -eq 0); profile = $Profile
        timestamp_utc = [DateTime]::UtcNow.ToString('o')
        errors = $errors.ToArray(); warnings = $warnings.ToArray(); probe = $Probe
    }
}

function Write-DoctorReport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Result, [switch]$Json, [string]$ReportPath)
    $output = if ($Json) { $Result | ConvertTo-Json -Depth 12 } else {
        $lines = @("Doppelbanger Windows doctor: success=$($Result.success) profile=$($Result.profile)")
        $lines += @($Result.errors | ForEach-Object { "ERROR $($_.code): $($_.message)" })
        $lines += @($Result.warnings | ForEach-Object { "WARN  $($_.code): $($_.message)" })
        $lines -join [Environment]::NewLine
    }
    if ($ReportPath) {
        $parent = Split-Path -Parent $ReportPath
        if (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw 'DBDOC_REPORT_PATH_INVALID: ReportPath parent must already exist'
        }
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath), $output, (New-Object Text.UTF8Encoding($false)))
    }
    return $output
}

function Invoke-WindowsDoctorMain {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $effectiveLock = if ($LockPath) { $LockPath } else { Join-Path $repoRoot 'tools\windows-toolchain.lock.json' }
    if ($ReportPath) {
        $fullReport = [IO.Path]::GetFullPath($ReportPath)
        $evidenceRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'var'))
        if (-not $fullReport.StartsWith($evidenceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'DBDOC_REPORT_PATH_INVALID: ReportPath must be beneath the ignored var directory'
        }
    }
    $lock = Read-ToolchainLock -Path $effectiveLock
    $probe = Get-NativeWindowsProbe -Lock $lock -RepoRoot $repoRoot -ProbePath $ProbePath
    $result = Test-NativeWindowsProbe -Probe $probe -Lock $lock -Profile $Profile
    Write-DoctorReport -Result $result -Json:$Json -ReportPath $ReportPath
    if (-not $result.success) { exit 1 }
}

if ($MyInvocation.InvocationName -ne '.' -and -not $NoRun) { Invoke-WindowsDoctorMain }
