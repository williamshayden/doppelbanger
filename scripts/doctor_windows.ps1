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

function Expand-LockedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -match '%[^%]+%') { throw "DBDOC_LOCK_INVALID: unresolved environment variable in path $Path" }
    if ($expanded -notmatch '^[A-Za-z]:\\') { throw "DBDOC_LOCK_INVALID: locked path is not an absolute Windows path: $expanded" }
    return [IO.Path]::GetFullPath($expanded).TrimEnd('\')
}

function Test-PathWithinRoot {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root, [switch]$AllowRoot)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($AllowRoot -and $fullPath -ieq $fullRoot) { return $true }
    return $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Expand-ProbePaths {
    param([Parameter(Mandatory = $true)]$Probe)
    function Expand-ObjectValue($Value) {
        if ($null -eq $Value) { return $null }
        if ($Value -is [string]) {
            if ($Value -match '%[^%]+%') { return [Environment]::ExpandEnvironmentVariables([string]$Value) }
            return $Value
        }
        if ($Value -is [Collections.IList]) {
            for ($i = 0; $i -lt $Value.Count; $i++) { $Value[$i] = Expand-ObjectValue $Value[$i] }
            return $Value
        }
        if ($Value.PSObject -and $Value.PSObject.Properties.Count -gt 0) {
            foreach ($property in @($Value.PSObject.Properties)) {
                $property.Value = Expand-ObjectValue $property.Value
            }
        }
        return $Value
    }
    return (Expand-ObjectValue $Probe)
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
        return Expand-ProbePaths -Probe (Merge-ProbeOverlay -Base $base -Overlay $probe)
    }
    return Expand-ProbePaths -Probe $probe
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
    param([string]$Path, [string[]]$Arguments, [scriptblock]$CommandRunner)
    if (-not $Path) { return '' }
    if ($CommandRunner) { return [string](& $CommandRunner $Path $Arguments) }
    try { return ((& $Path @Arguments 2>&1) -join "`n").Trim() }
    catch { return '' }
}

function Assert-DockerInvocationArguments {
    param([string[]]$Arguments)
    foreach ($argument in @($Arguments)) {
        $value = [string]$argument
        if ($value -cin @('--config', '--context', '-c', '--host', '-H') -or
            $value -match '^--(?:config|context|host)=' -or
            $value -cmatch '^-(?:c|H)(?:=|.).*') {
            throw "DBDOC_DOCKER_PROVENANCE_OVERRIDE_FORBIDDEN: Docker arguments may not override config, context, or host provenance: $value"
        }
    }
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

function Get-RustupHome {
    if ($env:RUSTUP_HOME) {
        if ([IO.Path]::IsPathRooted($env:RUSTUP_HOME)) { return [IO.Path]::GetFullPath($env:RUSTUP_HOME) }
        return [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $env:RUSTUP_HOME))
    }
    return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.rustup'))
}

function Test-PhysicalLeaf {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { return -not ([bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) }
    catch { return $false }
}

function Get-RustToolchainMetadata {
    param($Lock, [string]$RustupHome)
    $rustupRoot = if ($RustupHome) { [IO.Path]::GetFullPath($RustupHome) } else { Get-RustupHome }
    $root = Join-Path (Join-Path $rustupRoot 'toolchains') $Lock.rust.toolchain_directory
    $bin = Join-Path $root 'bin'
    $componentsPath = Join-Path $root 'lib\rustlib\components'
    $installerVersion = Join-Path $root 'lib\rustlib\rust-installer-version'
    $channelManifest = Join-Path $root 'lib\rustlib\multirust-channel-manifest.toml'
    $configManifest = Join-Path $root 'lib\rustlib\multirust-config.toml'
    $componentLines = if (Test-PhysicalLeaf $componentsPath) { @(Get-Content -LiteralPath $componentsPath) } else { @() }
    function Test-RustComponent([string]$ComponentName, [string]$ManifestName, [string[]]$RequiredFiles) {
        if ($componentLines -notcontains $ComponentName) { return $false }
        $manifest = Join-Path $root "lib\rustlib\manifest-$ManifestName"
        if (-not (Test-PhysicalLeaf $manifest)) { return $false }
        $manifestLines = @(Get-Content -LiteralPath $manifest)
        foreach ($file in $RequiredFiles) {
            if ($manifestLines -notcontains "file:$file" -or -not (Test-PhysicalLeaf (Join-Path $root ($file -replace '/', '\')))) { return $false }
        }
        return $true
    }
    $installerValue = if (Test-PhysicalLeaf $installerVersion) { (Get-Content -LiteralPath $installerVersion -Raw).Trim() } else { '' }
    $channelContent = if (Test-PhysicalLeaf $channelManifest) { Get-Content -LiteralPath $channelManifest -Raw } else { '' }
    $channelVersion = ''
    $channelSection = ''
    foreach ($line in @($channelContent -split "`r?`n")) {
        if ($line -match '^\s*\[([^]]+)\]\s*(?:#.*)?$') { $channelSection = $Matches[1].Trim(); continue }
        if ($channelSection -ceq 'pkg.rustc' -and $line -match '^\s*version\s*=\s*[''"]([^''"]+)[''"]') {
            $channelVersion = $Matches[1]
            break
        }
    }
    $lockedVersionPattern = '^' + [regex]::Escape([string]$Lock.rust.toolchain) + '(?:\s|\(|$)'
    $baseValid = $installerValue -ceq '3' -and $channelVersion -match $lockedVersionPattern -and (Test-PhysicalLeaf $configManifest)
    return [pscustomobject][ordered]@{
        root = $root; bin = $bin; base_valid = [bool]$baseValid; installer_version = $installerValue; channel_version = $channelVersion
        rustc = [bool]($baseValid -and (Test-RustComponent "rustc-$($Lock.rust.target)" "rustc-$($Lock.rust.target)" @('bin/rustc.exe')))
        cargo = [bool]($baseValid -and (Test-RustComponent "cargo-$($Lock.rust.target)" "cargo-$($Lock.rust.target)" @('bin/cargo.exe')))
        rustfmt = [bool]($baseValid -and (Test-RustComponent "rustfmt-preview-$($Lock.rust.target)" "rustfmt-preview-$($Lock.rust.target)" @('bin/rustfmt.exe')))
        clippy = [bool]($baseValid -and (Test-RustComponent "clippy-preview-$($Lock.rust.target)" "clippy-preview-$($Lock.rust.target)" @('bin/clippy-driver.exe', 'bin/cargo-clippy.exe')))
    }
}

function Get-VisualStudioProbe {
    param($Lock, [string]$InstancesRoot, [string]$WindowsSdkRoot)
    $result = [ordered]@{
        product_version=''; installation_version=''; instance_path=''; vsdevcmd_path=''; msvc_component=''; windows_sdk_component=''
        vctools_install_dir=''; windows_sdk_dir=''; windows_sdk_version=''; include=''; lib=''
    }
    $instancesRoot = if ($InstancesRoot) { [IO.Path]::GetFullPath($InstancesRoot) } else { Join-Path $env:ProgramData 'Microsoft\VisualStudio\Packages\_Instances' }
    $sdkRoot = if ($WindowsSdkRoot) { [IO.Path]::GetFullPath($WindowsSdkRoot) } else { Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10' }
    foreach ($statePath in @(Get-ChildItem -LiteralPath $instancesRoot -Filter state.json -File -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
        try {
            $raw = Get-Content -LiteralPath $statePath -Raw
            $state = $raw | ConvertFrom-Json
            if ([string]$state.installationVersion -cne [string]$Lock.visual_studio.installation_version) { continue }
            $instancePath = [string]$state.installationPath
            if (-not $instancePath) { continue }
            $result.installation_version = [string]$state.installationVersion
            $result.product_version = if ($state.catalogInfo.productDisplayVersion) { [string]$state.catalogInfo.productDisplayVersion } else { '' }
            $result.instance_path = [IO.Path]::GetFullPath($instancePath)
            $result.vsdevcmd_path = Join-Path $result.instance_path 'Common7\Tools\VsDevCmd.bat'
            if ($raw -match [regex]::Escape([string]$Lock.visual_studio.msvc_component)) { $result.msvc_component = $Lock.visual_studio.msvc_component }
            if ($raw -match [regex]::Escape([string]$Lock.visual_studio.windows_sdk_component)) { $result.windows_sdk_component = $Lock.visual_studio.windows_sdk_component }
            $versionFile = Join-Path $result.instance_path 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
            if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
                $toolsetVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
                if ($toolsetVersion -like "$($Lock.visual_studio.vcvars_version).*") {
                    $toolset = Join-Path $result.instance_path "VC\Tools\MSVC\$toolsetVersion"
                    if (Test-Path -LiteralPath $toolset -PathType Container) { $result.vctools_install_dir = [IO.Path]::GetFullPath($toolset).TrimEnd('\') + '\' }
                }
            }
            $sdkTarget = [string]$Lock.visual_studio.windows_sdk_target
            $toolsetRoot = ([string]$result.vctools_install_dir).TrimEnd('\')
            $includePaths = @(
                (Join-Path $toolsetRoot 'include'),
                (Join-Path $sdkRoot "Include\$sdkTarget\ucrt"),
                (Join-Path $sdkRoot "Include\$sdkTarget\shared"),
                (Join-Path $sdkRoot "Include\$sdkTarget\um"),
                (Join-Path $sdkRoot "Include\$sdkTarget\winrt"),
                (Join-Path $sdkRoot "Include\$sdkTarget\cppwinrt")
            )
            $libPaths = @(
                (Join-Path $toolsetRoot 'lib\x64'),
                (Join-Path $sdkRoot "Lib\$sdkTarget\ucrt\x64"),
                (Join-Path $sdkRoot "Lib\$sdkTarget\um\x64")
            )
            $metadataPaths = @($includePaths + $libPaths)
            if ($toolsetRoot -and (Test-PhysicalLeaf $result.vsdevcmd_path) -and
                @($metadataPaths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) }).Count -eq 0) {
                $result.windows_sdk_dir = $sdkRoot.TrimEnd('\') + '\'
                $result.windows_sdk_version = $sdkTarget + '\'
                $result.include = $includePaths -join ';'
                $result.lib = $libPaths -join ';'
            }
            break
        }
        catch { }
    }
    return [pscustomobject]$result
}

function Get-DockerComposeMetadata {
    param($Lock)
    $configDir = if ($env:DOCKER_CONFIG) {
        if ([IO.Path]::IsPathRooted($env:DOCKER_CONFIG)) { [IO.Path]::GetFullPath($env:DOCKER_CONFIG) } else { '' }
    } else { Join-Path $env:USERPROFILE '.docker' }
    $valid = [bool]$configDir
    $extraDirs = New-Object 'Collections.Generic.List[string]'
    if ($configDir) {
        $configPath = Join-Path $configDir 'config.json'
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            try {
                $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
                if ($config.PSObject.Properties.Name -contains 'cliPluginsExtraDirs') {
                    foreach ($dir in @($config.cliPluginsExtraDirs)) {
                        if (-not [IO.Path]::IsPathRooted([string]$dir)) { $valid = $false; continue }
                        $extraDirs.Add([IO.Path]::GetFullPath([string]$dir))
                    }
                }
            }
            catch { $valid = $false }
        }
    }
    $dirs = New-Object 'Collections.Generic.List[string]'
    foreach ($dir in $extraDirs) { $dirs.Add($dir) }
    if ($configDir) { $dirs.Add((Join-Path $configDir 'cli-plugins')) }
    if ($env:ProgramFiles) { $dirs.Add((Join-Path $env:ProgramFiles 'Docker\cli-plugins')) } else { $valid = $false }
    $candidates = @($dirs | ForEach-Object { Join-Path $_ 'docker-compose.exe' })
    $winner = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) | Select-Object -First 1
    return [pscustomobject][ordered]@{ config_dir=$configDir; extra_dirs=$extraDirs.ToArray(); candidates=$candidates; winner=[string]$winner; config_valid=$valid }
}

function Get-GlobalSafeDirectoryInspection {
    [CmdletBinding()]
    param([string]$RootFile, [scriptblock]$ContentReader)

    $results = New-Object 'Collections.Generic.List[string]'
    $active = @{}
    $completed = @{}

    function Resolve-GitConfigPath([string]$Path, [string]$BaseDirectory) {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Git config path is empty' }
        $expanded = [Environment]::ExpandEnvironmentVariables($Path)
        if ($expanded -match '^~(?=$|[\\/])') { $expanded = $env:USERPROFILE + $expanded.Substring(1) }
        if ($expanded -match '%[^%]+%') { throw "Git config path contains an unresolved environment variable: $Path" }
        if (-not [IO.Path]::IsPathRooted($expanded)) {
            if (-not $BaseDirectory) { $BaseDirectory = (Get-Location).Path }
            $expanded = Join-Path $BaseDirectory $expanded
        }
        return [IO.Path]::GetFullPath($expanded)
    }

    function Convert-GitConfigValue([string]$RawValue, [string]$Source, [int]$LineNumber) {
        $value = $RawValue.Trim()
        if ($value.StartsWith('"')) {
            if ($value -notmatch '^"((?:[^"\\]|\\.)*)"\s*(?:[#;].*)?$') { throw "Malformed quoted Git config value at $Source`:$LineNumber" }
            return ($Matches[1] -replace '\\"', '"' -replace '\\\\', '\')
        }
        return ($value -replace '\s+[#;].*$', '').Trim()
    }

    function Read-GitConfig([string]$Path, [string]$BaseDirectory, [bool]$Required) {
        $full = Resolve-GitConfigPath -Path $Path -BaseDirectory $BaseDirectory
        if ($active.ContainsKey($full)) { throw "Git config include cycle detected at $full" }
        if ($completed.ContainsKey($full)) { return }
        if (-not (Test-Path -LiteralPath $full)) {
            if ($Required) { throw "Declared Git config file is missing: $full" }
            return
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Git config path is not a file: $full" }
        $active[$full] = $true
        try {
            try { $lines = if ($ContentReader) { @(& $ContentReader $full) } else { @(Get-Content -LiteralPath $full -ErrorAction Stop) } }
            catch { throw "Could not read Git config $full`: $($_.Exception.Message)" }
            $section = ''
            for ($index = 0; $index -lt $lines.Count; $index++) {
                $trimmed = ([string]$lines[$index]).Trim()
                $lineNumber = $index + 1
                if (-not $trimmed -or $trimmed -match '^[#;]') { continue }
                if ($trimmed -match '^\[([A-Za-z0-9.-]+)(?:\s+"(?:[^"\\]|\\.)*")?\]\s*(?:[#;].*)?$') {
                    $section = $Matches[1].ToLowerInvariant()
                    continue
                }
                if ($trimmed.StartsWith('[') -or $trimmed -notmatch '^([A-Za-z][A-Za-z0-9-]*)\s*(?:=\s*(.*))?$') {
                    throw "Unsupported or malformed Git config syntax at $full`:$lineNumber"
                }
                $key = $Matches[1].ToLowerInvariant()
                $rawValue = if ($null -ne $Matches[2]) { [string]$Matches[2] } else { 'true' }
                $value = Convert-GitConfigValue -RawValue $rawValue -Source $full -LineNumber $lineNumber
                if ($section -eq 'safe' -and $key -eq 'directory') { $results.Add($value); continue }
                if ($section -like 'include*' -and $key -eq 'path') {
                    if ([string]::IsNullOrWhiteSpace($value)) { throw "Declared Git config include is empty at $full`:$lineNumber" }
                    Read-GitConfig -Path $value -BaseDirectory (Split-Path -Parent $full) -Required $true
                }
            }
            $completed[$full] = $true
        }
        finally { $active.Remove($full) }
    }

    try {
        $rootPaths = if ($RootFile) {
            @($RootFile)
        }
        elseif ($env:GIT_CONFIG_GLOBAL) {
            @([string]$env:GIT_CONFIG_GLOBAL)
        }
        else {
            if ([string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) { throw 'USERPROFILE is unavailable for global Git config inspection' }
            $xdgRoot = if ($env:XDG_CONFIG_HOME) { [string]$env:XDG_CONFIG_HOME } else { Join-Path $env:USERPROFILE '.config' }
            @((Join-Path $xdgRoot 'git\config'), (Join-Path $env:USERPROFILE '.gitconfig'))
        }
        foreach ($rootPath in $rootPaths) { Read-GitConfig -Path $rootPath -BaseDirectory '' -Required $false }
        return [pscustomobject][ordered]@{ entries=$results.ToArray(); inspection_valid=$true; error='' }
    }
    catch {
        return [pscustomobject][ordered]@{ entries=@(); inspection_valid=$false; error=$_.Exception.Message }
    }
}

function Test-AbletonPresent {
    param([string[]]$CandidatePaths)
    return @($CandidatePaths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }).Count -gt 0
}

function Add-BinaryProbe {
    param([Collections.Generic.List[object]]$List, [string]$Name, [string]$Path, [string]$LockedPath, [string]$AmbientPath, [string]$Root)
    if (-not (Test-PhysicalLeaf $Path)) { return }
    $pe = Get-PeMetadata -Path $Path
    $List.Add([pscustomobject][ordered]@{ name=$Name; path=[IO.Path]::GetFullPath($Path); locked_path=[IO.Path]::GetFullPath($LockedPath); ambient_path=$AmbientPath; pe_format=$pe.pe_format; machine=$pe.machine; under_locked_root=(Test-PathWithinRoot -Path $Path -Root $Root -AllowRoot) })
}

function Get-NativeWindowsProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Lock, [Parameter(Mandatory=$true)][string]$RepoRoot, [string]$ProbePath, [switch]$MetadataOnly, [scriptblock]$CommandRunner, [Collections.IDictionary]$MetadataPaths)
    if ($ProbePath) { return Read-ProbeFixture -Path $ProbePath }
    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $drive = [IO.Path]::GetPathRoot($repo); $filesystem=''; $freeGb=0
    try { $driveInfo=New-Object IO.DriveInfo($drive); $filesystem=$driveInfo.DriveFormat; $freeGb=[math]::Round($driveInfo.AvailableFreeSpace/1GB,2) } catch { }

    $rustupHome = if ($MetadataPaths) { [string]$MetadataPaths.RustupHome } else { '' }
    $rust = Get-RustToolchainMetadata -Lock $Lock -RustupHome $rustupHome
    $cmakeRoot=Expand-LockedPath $Lock.cmake.root; $ninjaRoot=Expand-LockedPath $Lock.ninja.root; $nodeRoot=Expand-LockedPath $Lock.node.root
    $cmakePath=Join-Path $cmakeRoot 'bin\cmake.exe'; $ninjaPath=Join-Path $ninjaRoot 'ninja.exe'; $nodePath=Join-Path $nodeRoot 'node.exe'; $npmPath=Join-Path $nodeRoot 'npm.cmd'
    $instancesRoot=if($MetadataPaths){[string]$MetadataPaths.VisualStudioInstancesRoot}else{''}
    $sdkRoot=if($MetadataPaths-and$MetadataPaths.WindowsSdkRoot){[IO.Path]::GetFullPath([string]$MetadataPaths.WindowsSdkRoot)}else{Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'}
    $vs=Get-VisualStudioProbe -Lock $Lock -InstancesRoot $instancesRoot -WindowsSdkRoot $sdkRoot
    $msvcBin=if($vs.vctools_install_dir){Join-Path $vs.vctools_install_dir 'bin\Hostx64\x64'}else{''}
    $clPath=if($msvcBin){Join-Path $msvcBin 'cl.exe'}else{''}
    $rustcPath=Join-Path $rust.bin 'rustc.exe'
    $rustInfo='';$clInfo='';$cmakeInfo='';$ninjaInfo='';$nodeInfo='';$npmInfo=''
    if(-not $MetadataOnly){
        $rustInfo=Invoke-ProbeCommand $rustcPath @('-vV') $CommandRunner; $clInfo=Invoke-ProbeCommand $clPath @('/Bv') $CommandRunner
        $cmakeInfo=Invoke-ProbeCommand $cmakePath @('--version') $CommandRunner; $ninjaInfo=Invoke-ProbeCommand $ninjaPath @('--version') $CommandRunner
        $nodeInfo=Invoke-ProbeCommand $nodePath @('-p','JSON.stringify({version:process.versions.node,platform:process.platform,arch:process.arch})') $CommandRunner
        $npmInfo=Invoke-ProbeCommand $npmPath @('--version') $CommandRunner
    }
    $nodeData=$null; try{if($nodeInfo){$nodeData=$nodeInfo|ConvertFrom-Json}}catch{}

    $dockerPath=[string]$Lock.docker.cli_path; $compose=Get-DockerComposeMetadata -Lock $Lock; $composeExpected=[string]$Lock.docker.compose_plugin_path
    $dockerCliInfo='';$dockerServerInfo='';$dockerContext='';$composeInfo='';$composeConfigValid=$MetadataOnly
    if(-not $MetadataOnly){
        $dockerCliInfo=Invoke-ProbeCommand $dockerPath @('--version') $CommandRunner; $dockerServerInfo=Invoke-ProbeCommand $dockerPath @('version','--format','{{json .Server}}') $CommandRunner
        $dockerContext=Invoke-ProbeCommand $dockerPath @('context','show') $CommandRunner
        if ($compose.winner -and [string]$compose.winner -ieq [string]$composeExpected -and (Test-PhysicalLeaf $composeExpected)) {
            $composeInfo=Invoke-ProbeCommand $composeExpected @('version','--short') $CommandRunner
        } elseif ($compose.winner -and (Test-PhysicalLeaf $compose.winner)) {
            $composeInfo=[Diagnostics.FileVersionInfo]::GetVersionInfo($compose.winner).ProductVersion
        }
        if((Test-PhysicalLeaf $composeExpected) -and (Test-Path -LiteralPath (Join-Path $repo 'docker-compose.yml') -PathType Leaf)){
            try{& $composeExpected -f (Join-Path $repo 'docker-compose.yml') config --quiet 2>$null|Out-Null;$composeConfigValid=$LASTEXITCODE-eq 0}catch{$composeConfigValid=$false}
        }
    }
    $server=$null;try{if($dockerServerInfo){$server=$dockerServerInfo|ConvertFrom-Json}}catch{}
    $desktopVersion='';$desktopBuild='';$desktopExe=Join-Path $Lock.docker.root 'Docker Desktop.exe'
    if(Test-PhysicalLeaf $desktopExe){$fv=[Diagnostics.FileVersionInfo]::GetVersionInfo($desktopExe);$desktopVersion=Get-NormalizedSemanticVersion $fv.ProductVersion;$desktopBuild=Get-FourthVersionComponent $fv.FileVersion}
    $dockerCliVersion=if($MetadataOnly -and (Test-PhysicalLeaf $dockerPath)){Get-NormalizedSemanticVersion ([Diagnostics.FileVersionInfo]::GetVersionInfo($dockerPath).ProductVersion)}else{Get-NormalizedSemanticVersion $dockerCliInfo}
    $composeVersion=if($MetadataOnly -and (Test-PhysicalLeaf $compose.winner)){Get-NormalizedSemanticVersion ([Diagnostics.FileVersionInfo]::GetVersionInfo($compose.winner).ProductVersion)}else{Get-NormalizedSemanticVersion $composeInfo}

    $wslCandidates=@((Join-Path $env:ProgramFiles 'WSL\wsl.exe'),(Join-Path $env:SystemRoot 'System32\wsl.exe'))
    $wslExe=@($wslCandidates|Where-Object{Test-PhysicalLeaf $_})|Select-Object -First 1
    $wslPresent=[bool]$wslExe;$wslVersion='';if($wslPresent){try{$wslVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($wslExe).ProductVersion}catch{}}
    $currentSid='';$ownerSid='';try{$currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$ownerSid=(Get-Acl -LiteralPath $repo).GetOwner([Security.Principal.SecurityIdentifier]).Value}catch{}
    $sdkTarget=[string]$Lock.visual_studio.windows_sdk_target
    $sdkInstalled=(Test-Path -LiteralPath (Join-Path $sdkRoot "Include\$sdkTarget") -PathType Container)-and(Test-Path -LiteralPath (Join-Path $sdkRoot "Lib\$sdkTarget") -PathType Container)

    $binaries=New-Object 'Collections.Generic.List[object]'
    foreach($name in @('cargo','rustc','rustfmt','clippy-driver')){Add-BinaryProbe $binaries $name (Join-Path $rust.bin "$name.exe") (Join-Path $rust.bin "$name.exe") (Join-Path $rust.bin "$name.exe") $rust.root}
    foreach($name in @('cl','link','lib','dumpbin')){if($msvcBin){$p=Join-Path $msvcBin "$name.exe";Add-BinaryProbe $binaries $name $p $p (Get-CommandPath "$name.exe") $vs.vctools_install_dir}}
    Add-BinaryProbe $binaries 'cmake' $cmakePath $cmakePath (Get-CommandPath 'cmake.exe') $cmakeRoot;Add-BinaryProbe $binaries 'ninja' $ninjaPath $ninjaPath (Get-CommandPath 'ninja.exe') $ninjaRoot
    Add-BinaryProbe $binaries 'node' $nodePath $nodePath (Get-CommandPath 'node.exe') $nodeRoot;Add-BinaryProbe $binaries 'docker' $dockerPath $dockerPath (Get-CommandPath 'docker.exe') $Lock.docker.root
    Add-BinaryProbe $binaries 'docker-compose' $compose.winner $composeExpected $compose.winner (Split-Path -Parent (Split-Path -Parent $composeExpected))
    $validatorPath=Join-Path $repo $Lock.validators.steinberg_relative_path;$pluginvalRoot=Expand-LockedPath $Lock.validators.pluginval_root;$pluginvalPath=Join-Path $pluginvalRoot 'pluginval.exe'
    Add-BinaryProbe $binaries 'validator' $validatorPath $validatorPath $validatorPath $repo;Add-BinaryProbe $binaries 'pluginval' $pluginvalPath $pluginvalPath $pluginvalPath $pluginvalRoot

    $gitInspection=Get-GlobalSafeDirectoryInspection
    $pending=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')-or(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $abletonRoots=if($MetadataPaths-and$MetadataPaths.AbletonRoots){@($MetadataPaths.AbletonRoots)}else{@((Join-Path $env:ProgramData 'Ableton'),(Join-Path $env:ProgramFiles 'Ableton'))}
    $ableton=Test-AbletonPresent -CandidatePaths $abletonRoots
    return [pscustomobject][ordered]@{
        metadata_only=[bool]$MetadataOnly;os=if($env:OS-eq'Windows_NT'){'Windows'}else{[Environment]::OSVersion.Platform.ToString()};arch=if($env:PROCESSOR_ARCHITECTURE-eq'AMD64'){'x86_64'}else{[string]$env:PROCESSOR_ARCHITECTURE}
        wsl=[bool]($env:WSL_DISTRO_NAME-or$env:WSL_INTEROP);wsl_present=[bool]$wslPresent;wsl_distro_name=[string]$env:WSL_DISTRO_NAME;wsl_interop=[string]$env:WSL_INTEROP;wsl_version=$wslVersion;ancestors=@(Get-ProcessAncestors)
        repo_path=$repo;repo_filesystem=$filesystem;current_user_sid=$currentSid;repo_owner_sid=$ownerSid;git_global_safe_directories=@($gitInspection.entries);git_global_safe_directory_inspection_valid=[bool]$gitInspection.inspection_valid;git_global_safe_directory_inspection_error=[string]$gitInspection.error
        compiler=if(Test-PhysicalLeaf $clPath){'MSVC'}else{''};compiler_version=if($MetadataOnly-and(Test-PhysicalLeaf $clPath)){$Lock.visual_studio.msvc_version_prefix}elseif($clInfo-match'Compiler Version ([0-9.]+)'){$Matches[1]}else{''}
        vs_product_version=$vs.product_version;vs_installation_version=$vs.installation_version;vs_instance_path=$vs.instance_path;msvc_component=$vs.msvc_component;windows_sdk_component=$vs.windows_sdk_component;windows_sdk_target=if($sdkInstalled){$sdkTarget}else{''}
        rust_version=if($MetadataOnly-and$rust.rustc){$Lock.rust.toolchain}elseif($rustInfo-match'rustc ([0-9.]+)'){$Matches[1]}else{''};rust_target=if($MetadataOnly-and$rust.rustc){$Lock.rust.target}elseif($rustInfo-match'(?m)^host:\s*(\S+)'){$Matches[1]}else{''};rust_toolchain_root=$rust.root;rust_components=[pscustomobject]@{cargo=$rust.cargo;rustfmt=$rust.rustfmt;clippy=$rust.clippy;metadata_valid=$rust.base_valid;installer_version=$rust.installer_version;channel_version=$rust.channel_version}
        cmake_version=if($MetadataOnly-and(Test-PhysicalLeaf $cmakePath)){$Lock.cmake.version}elseif($cmakeInfo-match'cmake version ([0-9.]+)'){$Matches[1]}else{''};ninja_version=if($MetadataOnly-and(Test-PhysicalLeaf $ninjaPath)){$Lock.ninja.version}else{($ninjaInfo-split"`n")[0]}
        node_version=if($MetadataOnly-and(Test-PhysicalLeaf $nodePath)){$Lock.node.version}elseif($nodeData){[string]$nodeData.version}else{''};node_platform=if(Test-PhysicalLeaf $nodePath){'win32'}else{''};node_arch=if(Test-PhysicalLeaf $nodePath){'x64'}else{''};npm_version=if($MetadataOnly-and(Test-Path -LiteralPath $npmPath)){$Lock.node.npm_version}else{($npmInfo-split"`n")[0]}
        docker_desktop_version=$desktopVersion;docker_desktop_build=$desktopBuild;docker_cli_version=$dockerCliVersion;docker_engine_version=if($server){[string]$server.Version}else{''};docker_compose_version=$composeVersion;docker_server_os=if($server){[string]$server.Os}else{''};docker_server_arch=if($server){[string]$server.Arch}else{''};docker_context=$dockerContext;docker_running=[bool]$server;docker_compose_config_valid=[bool]$composeConfigValid
        docker_config_dir=$compose.config_dir;docker_cli_plugin_extra_dirs=$compose.extra_dirs;docker_compose_candidates=$compose.candidates;docker_plugin_config_valid=$compose.config_valid;docker_compose_plugin_path=$compose.winner;docker_expected_compose_plugin_path=$composeExpected;docker_user_compose_plugin_path=if($compose.winner-and$compose.winner.StartsWith($compose.config_dir,[StringComparison]::OrdinalIgnoreCase)){$compose.winner}else{''}
        disk_free_gb=$freeGb;pending_reboot=[bool]$pending;docker_license_accepted=$null;webview2_present=(Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F1E7E2DD-D75B-430F-9B6C-4FC7E8A489AF}');ableton_present=[bool]$ableton
        vsdevcmd=[pscustomobject]@{path=$vs.vsdevcmd_path;import_args=$Lock.visual_studio.vsdevcmd_arguments;include=if($MetadataOnly){$vs.include}else{[string]$env:INCLUDE};lib=if($MetadataOnly){$vs.lib}else{[string]$env:LIB};windows_sdk_dir=if($MetadataOnly){$vs.windows_sdk_dir}else{[string]$env:WindowsSdkDir};windows_sdk_version=if($MetadataOnly){$vs.windows_sdk_version}else{[string]$env:WindowsSDKVersion};vctools_install_dir=if($MetadataOnly){$vs.vctools_install_dir}elseif($env:VCToolsInstallDir){[string]$env:VCToolsInstallDir}else{$vs.vctools_install_dir}}
        binaries=$binaries.ToArray()
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

function Test-SafeDirectoryCoversRepo {
    param([string]$Entry, [string]$RepoPath)
    if (-not $Entry) { return $false }
    if ($Entry.Trim() -eq '*') { return $true }
    $expanded = [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"') -replace '^~', $env:USERPROFILE)
    if ($expanded.EndsWith('/*') -or $expanded.EndsWith('\*')) {
        $root = $expanded.Substring(0, $expanded.Length - 2)
        try { return Test-PathWithinRoot -Path $RepoPath -Root $root -AllowRoot } catch { return $false }
    }
    try { return [IO.Path]::GetFullPath($expanded).TrimEnd('\') -ieq [IO.Path]::GetFullPath($RepoPath).TrimEnd('\') } catch { return $false }
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
    if ($Probe.wsl_present -and [string]::IsNullOrWhiteSpace([string]$Probe.wsl_version)) {
        Add-Error 'DBDOC_WSL_VERSION_UNKNOWN' 'WSL is present but its executable version could not be resolved without launching it'
    }
    if ($Probe.wsl_version -and -not (Test-VersionAtLeast -Actual $Probe.wsl_version -Minimum $Lock.wsl.minimum_version)) {
        if ($strict) { Add-Error 'DBDOC_TOOL_VERSION_DRIFT' "WSL expected at least $($Lock.wsl.minimum_version), found $($Probe.wsl_version)" }
        else { Add-Warning 'DBDOC_TOOL_VERSION_DRIFT' "WSL expected at least $($Lock.wsl.minimum_version), found $($Probe.wsl_version)" }
    }
    if ([string]$Probe.repo_path -notmatch '^[A-Za-z]:\\' -or [string]$Probe.repo_path -match '^\\\\|\\\\wsl\$') {
        Add-Error 'DBDOC_REPO_PATH_INVALID' 'Repository must use a drive-letter Windows path'
    }
    if ($Probe.repo_filesystem -cne 'NTFS') { Add-Error 'DBDOC_REPO_FILESYSTEM_INVALID' 'Repository drive must be NTFS' }
    if ([string]::IsNullOrWhiteSpace([string]$Probe.current_user_sid) -or
        [string]::IsNullOrWhiteSpace([string]$Probe.repo_owner_sid) -or
        [string]$Probe.current_user_sid -cne [string]$Probe.repo_owner_sid) {
        Add-Error 'DBDOC_GIT_OWNERSHIP_INVALID' 'Repository directory owner SID does not match the current Windows user SID'
    }
    if ($Probe.git_global_safe_directory_inspection_valid -ne $true) {
        Add-Error 'DBDOC_GIT_CONFIG_INSPECTION_FAILED' "Global Git config inspection did not complete: $($Probe.git_global_safe_directory_inspection_error)"
    }
    foreach ($safeEntry in @($Probe.git_global_safe_directories)) {
        if (Test-SafeDirectoryCoversRepo -Entry ([string]$safeEntry) -RepoPath ([string]$Probe.repo_path)) {
            Add-Error 'DBDOC_GIT_SAFE_DIRECTORY_BYPASS' "Global Git safe.directory bypass covers this repository: $safeEntry"
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Probe.compiler)) { Add-Error 'DBDOC_TOOL_MISSING' 'MSVC compiler is missing' }
    elseif ($Probe.compiler -cne 'MSVC') { Add-Error 'DBDOC_COMPILER_FORBIDDEN' "Native compiler must be MSVC, found $($Probe.compiler)" }
    elseif ([string]$Probe.compiler_version -notmatch '^19\.44(?:\.|$)') {
        if ($strict) { Add-Error 'DBDOC_TOOL_VERSION_DRIFT' 'MSVC 19.44 is required' } else { Add-Warning 'DBDOC_TOOL_VERSION_DRIFT' "MSVC 19.44 expected, found $($Probe.compiler_version)" }
    }
    Check-Exact 'Visual Studio product' $Probe.vs_product_version $Lock.visual_studio.product_version
    Check-Exact 'Visual Studio installation' $Probe.vs_installation_version $Lock.visual_studio.installation_version
    Check-Exact 'MSVC component' $Probe.msvc_component $Lock.visual_studio.msvc_component
    Check-Exact 'Windows SDK component' $Probe.windows_sdk_component $Lock.visual_studio.windows_sdk_component
    Check-Exact 'Windows SDK target' $Probe.windows_sdk_target $Lock.visual_studio.windows_sdk_target
    Check-Exact 'Rust' $Probe.rust_version $Lock.rust.toolchain
    if ([string]::IsNullOrWhiteSpace([string]$Probe.rust_target)) { Add-Error 'DBDOC_TOOL_MISSING' 'Rust target is missing' }
    elseif ([string]$Probe.rust_target -cne [string]$Lock.rust.target) { Add-Error 'DBDOC_RUST_TARGET_FORBIDDEN' "Rust target must be $($Lock.rust.target), found $($Probe.rust_target)" }
    if (-not $Probe.rust_components.cargo) { Add-Error 'DBDOC_RUST_COMPONENT_MISSING' 'Cargo is not installed in the exact physical Rust toolchain' }
    if (-not $Probe.rust_components.rustfmt) { Add-Error 'DBDOC_RUST_COMPONENT_MISSING' 'rustfmt is not installed in the exact physical Rust toolchain' }
    if (-not $Probe.rust_components.clippy) { Add-Error 'DBDOC_RUST_COMPONENT_MISSING' 'clippy is not installed in the exact physical Rust toolchain' }
    Check-Exact 'CMake' $Probe.cmake_version $Lock.cmake.version
    Check-Exact 'Ninja' $Probe.ninja_version $Lock.ninja.version
    Check-Exact 'Node' $Probe.node_version $Lock.node.version
    if ($Probe.node_platform -and $Probe.node_platform -cne 'win32') { Add-Error 'DBDOC_NODE_PLATFORM_FORBIDDEN' "Node platform must be win32, found $($Probe.node_platform)" } elseif (-not $Probe.node_platform) { Add-Error 'DBDOC_TOOL_MISSING' 'Node platform is missing' }
    if ($Probe.node_arch -and $Probe.node_arch -cne 'x64') { Add-Error 'DBDOC_NODE_PLATFORM_FORBIDDEN' "Node architecture must be x64, found $($Probe.node_arch)" } elseif (-not $Probe.node_arch) { Add-Error 'DBDOC_TOOL_MISSING' 'Node architecture is missing' }
    Check-Exact 'npm' $Probe.npm_version $Lock.node.npm_version
    Check-Exact 'Docker Desktop' $Probe.docker_desktop_version $Lock.docker.desktop_version
    Check-Exact 'Docker Desktop build' $Probe.docker_desktop_build $Lock.docker.desktop_build
    Check-Exact 'Docker CLI' $Probe.docker_cli_version $Lock.docker.cli_version
    if (-not $Probe.metadata_only) { Check-Exact 'Docker Engine' $Probe.docker_engine_version $Lock.docker.engine_version }
    Check-Exact 'Docker Compose' $Probe.docker_compose_version $Lock.docker.compose_version

    if ($Probe.docker_plugin_config_valid -eq $false) { Add-Error 'DBDOC_DOCKER_PLUGIN_CONFIG_INVALID' 'Docker CLI plugin configuration is malformed or contains a relative path' }
    if ([string]$Probe.docker_compose_plugin_path -ine [string]$Probe.docker_expected_compose_plugin_path) {
        Add-Error 'DBDOC_DOCKER_PLUGIN_SHADOW' "Docker Compose resolves outside Docker Desktop: $($Probe.docker_compose_plugin_path)"
    }
    if (-not $Probe.metadata_only) {
        if ($null -ne $Probe.docker_compose_config_valid -and -not $Probe.docker_compose_config_valid) {
            Add-Error 'DBDOC_COMPOSE_CONFIG_INVALID' 'Docker Compose could not validate docker-compose.yml through the Docker Desktop plugin'
        }
        if (-not $Probe.docker_running) { Add-Error 'DBDOC_DOCKER_STOPPED' 'Docker Desktop engine is not running' }
        else {
            Check-Exact 'Docker context' $Probe.docker_context $Lock.docker.context
            Check-Exact 'Docker server OS' $Probe.docker_server_os $Lock.docker.server_os
            Check-Exact 'Docker server architecture' $Probe.docker_server_arch $Lock.docker.server_arch
        }
    }

    if ($strict) {
        foreach ($requiredMsvcTool in @('cl', 'link', 'lib', 'dumpbin')) {
            if (@($Probe.binaries | Where-Object { $_.name -ceq $requiredMsvcTool }).Count -eq 0) {
                Add-Error 'DBDOC_TOOL_MISSING' "Required exact MSVC tool is missing: $requiredMsvcTool.exe"
            }
        }
    }

    foreach ($binary in @($Probe.binaries)) {
        if ($binary.pe_format -notin @('PE32', 'PE32+') -or $binary.machine -cne 'AMD64') {
            Add-Error 'DBDOC_BINARY_NOT_PE' "$($binary.name) is not a PE32/PE32+ AMD64 executable: $($binary.path)"
        }
        if ($null -ne $binary.under_locked_root -and -not $binary.under_locked_root) {
            Add-Error 'DBDOC_TOOL_PATH_SHADOW' "$($binary.name) resolves outside its locked root: $($binary.path)"
        }
        if ($binary.name -in @('cmake', 'ninja', 'docker', 'cl', 'link', 'lib', 'dumpbin') -and $binary.ambient_path -and $binary.locked_path -and
            ([IO.Path]::GetFullPath([string]$binary.ambient_path) -ine [IO.Path]::GetFullPath([string]$binary.locked_path))) {
            Add-Error 'DBDOC_TOOL_PATH_SHADOW' "ambient $($binary.name) shadows the locked executable: $($binary.ambient_path)"
        }
    }

    if ($Probe.vsdevcmd) {
        $sdkVersion = ([string]$Probe.vsdevcmd.windows_sdk_version).TrimEnd('\')
        if ($sdkVersion -and $sdkVersion -cne [string]$Lock.visual_studio.windows_sdk_target) {
            Add-Error 'DBDOC_WINDOWS_SDK_DRIFT' "VsDevCmd imported Windows SDK $sdkVersion instead of $($Lock.visual_studio.windows_sdk_target)"
        }
        foreach ($sdkPath in @($Probe.vsdevcmd.include, $Probe.vsdevcmd.lib)) {
            if ($sdkPath -and [string]$sdkPath -notmatch [regex]::Escape("\$($Lock.visual_studio.windows_sdk_target)")) {
                Add-Error 'DBDOC_WINDOWS_SDK_DRIFT' "VsDevCmd imported a path outside Windows SDK $($Lock.visual_studio.windows_sdk_target): $sdkPath"
            }
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
    param([Parameter(Mandatory = $true)]$Result, [switch]$Json, [string]$ReportPath, [string]$RepoRoot)
    $output = if ($Json) { $Result | ConvertTo-Json -Depth 12 } else {
        $lines = @("Doppelbanger Windows doctor: success=$($Result.success) profile=$($Result.profile)")
        $lines += @($Result.errors | ForEach-Object { "ERROR $($_.code): $($_.message)" })
        $lines += @($Result.warnings | ForEach-Object { "WARN  $($_.code): $($_.message)" })
        $lines -join [Environment]::NewLine
    }
    if ($ReportPath) {
        if (-not $RepoRoot) { throw 'DBDOC_REPORT_PATH_INVALID: RepoRoot is required when ReportPath is used' }
        $pathTail = if ($ReportPath.Length -gt 2) { $ReportPath.Substring(2) } else { '' }
        if ($ReportPath -match '^\\\\[?.]\\' -or $ReportPath -match '^\\\\' -or $pathTail -match ':') {
            throw 'DBDOC_REPORT_PATH_INVALID: device, UNC, and alternate-data-stream paths are forbidden'
        }
        $repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
        $varPath = Join-Path $repo 'var'
        if (-not (Test-Path -LiteralPath $varPath -PathType Container)) { throw 'DBDOC_REPORT_PATH_INVALID: repository var directory does not exist' }
        $varResolved = (Resolve-Path -LiteralPath $varPath).Path.TrimEnd('\')
        $fullReport = [IO.Path]::GetFullPath($ReportPath)
        $parent = Split-Path -Parent $fullReport
        if (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'DBDOC_REPORT_PATH_INVALID: ReportPath parent must already exist' }
        $parentResolved = (Resolve-Path -LiteralPath $parent).Path.TrimEnd('\')
        if (-not (Test-PathWithinRoot -Path $parentResolved -Root $varResolved -AllowRoot)) { throw 'DBDOC_REPORT_PATH_INVALID: ReportPath must remain beneath repository var' }
        $current = $repo
        if ([bool]((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'DBDOC_REPORT_PATH_INVALID: repository root cannot be a reparse point' }
        foreach ($segment in @($varResolved.Substring($repo.Length).TrimStart('\').Split('\')) + @($parentResolved.Substring($varResolved.Length).TrimStart('\').Split('\'))) {
            if (-not $segment) { continue }
            $current = Join-Path $current $segment
            if (Test-Path -LiteralPath $current) {
                $item = Get-Item -LiteralPath $current -Force
                if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'DBDOC_REPORT_PATH_INVALID: reparse points are forbidden in report path' }
            }
        }
        if (Test-Path -LiteralPath $fullReport) {
            $target = Get-Item -LiteralPath $fullReport -Force
            $linkType = if ($target.PSObject.Properties.Name -contains 'LinkType') { [string]$target.LinkType } else { '' }
            $linkTargets = if ($target.PSObject.Properties.Name -contains 'Target') { @($target.Target | Where-Object { $_ }) } else { @() }
            if ($linkType -ieq 'HardLink' -or $linkTargets.Count -gt 1) { throw 'DBDOC_REPORT_PATH_INVALID: report target cannot be a hardlink' }
            if ([bool]($target.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'DBDOC_REPORT_PATH_INVALID: report target cannot be a reparse point' }
        }
        [IO.File]::WriteAllText($fullReport, $output, (New-Object Text.UTF8Encoding($false)))
    }
    return $output
}

function Invoke-WindowsDoctorMain {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $canonicalLock = [IO.Path]::GetFullPath((Join-Path $repoRoot 'tools\windows-toolchain.lock.json'))
    $effectiveLock = if ($LockPath) { [IO.Path]::GetFullPath($LockPath) } else { $canonicalLock }
    if ($effectiveLock -ine $canonicalLock) { throw 'DBDOC_LOCK_OVERRIDE_FORBIDDEN: live doctor is hard-bound to the checked-in Windows toolchain lock' }
    if ($ProbePath) { throw 'DBDOC_PROBE_INJECTION_FORBIDDEN: ProbePath is test-only and cannot be used by the public doctor entry point' }
    $lock = Read-ToolchainLock -Path $effectiveLock
    $probe = Get-NativeWindowsProbe -Lock $lock -RepoRoot $repoRoot
    $result = Test-NativeWindowsProbe -Probe $probe -Lock $lock -Profile $Profile
    Write-DoctorReport -Result $result -Json:$Json -ReportPath $ReportPath -RepoRoot $repoRoot
    if (-not $result.success) { exit 1 }
}

if ($MyInvocation.InvocationName -ne '.' -and -not $NoRun) { Invoke-WindowsDoctorMain }
