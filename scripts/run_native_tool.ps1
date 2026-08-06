[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Tool,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ToolArguments,
    [switch]$Describe,
    [string]$ProbePath,
    [string]$LockPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$doctorPath = Join-Path $PSScriptRoot 'doctor_windows.ps1'
$requestedLockPath = $LockPath
$requestedProbePath = $ProbePath
. $doctorPath -LockPath $requestedLockPath -ProbePath $requestedProbePath -NoRun
$LockPath = $requestedLockPath
$ProbePath = $requestedProbePath

function Stop-NativeTool {
    param([string]$Code, [string]$Message)
    throw "$Code`: $Message"
}

function Get-ProbeBinary {
    param($Probe, [string]$Name)
    return @($Probe.binaries | Where-Object { $_.name -ceq $Name }) | Select-Object -First 1
}

function Import-LockedVisualStudioEnvironment {
    param($Lock)
    $vs = Get-VisualStudioProbe -Lock $Lock
    if ($vs.installation_version -cne $Lock.visual_studio.installation_version -or
        $vs.product_version -cne $Lock.visual_studio.product_version) {
        Stop-NativeTool 'DBDOC_TOOL_VERSION_DRIFT' "exact Visual Studio $($Lock.visual_studio.product_version) / $($Lock.visual_studio.installation_version) was not found"
    }
    if (-not $vs.vsdevcmd_path -or -not (Test-Path -LiteralPath $vs.vsdevcmd_path -PathType Leaf)) {
        Stop-NativeTool 'DBDOC_VS_ENV_INCOMPLETE' 'the locked VsDevCmd.bat was not found'
    }
    $command = '"{0}" {1} >nul && set' -f $vs.vsdevcmd_path, $Lock.visual_studio.vsdevcmd_arguments
    $environment = & $env:ComSpec /d /s /c $command
    if ($LASTEXITCODE -ne 0) { Stop-NativeTool 'DBDOC_VS_ENV_INCOMPLETE' 'VsDevCmd.bat import failed' }
    foreach ($line in $environment) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            [Environment]::SetEnvironmentVariable($line.Substring(0, $separator), $line.Substring($separator + 1), 'Process')
        }
    }
    foreach ($name in @('INCLUDE', 'LIB', 'WindowsSdkDir', 'WindowsSDKVersion', 'VCToolsInstallDir')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, 'Process'))) {
            Stop-NativeTool 'DBDOC_VS_ENV_INCOMPLETE' "$name is empty after the exact VsDevCmd.bat import"
        }
    }
    $sdkVersion = ([string]$env:WindowsSDKVersion).TrimEnd('\')
    if ($sdkVersion -cne [string]$Lock.visual_studio.windows_sdk_target -or
        [string]$env:INCLUDE -notmatch [regex]::Escape("\$($Lock.visual_studio.windows_sdk_target)\") -or
        [string]$env:LIB -notmatch [regex]::Escape("\$($Lock.visual_studio.windows_sdk_target)\")) {
        Stop-NativeTool 'DBDOC_WINDOWS_SDK_DRIFT' "VsDevCmd.bat did not import Windows SDK $($Lock.visual_studio.windows_sdk_target)"
    }
    $toolsetRoot = [IO.Path]::GetFullPath([string]$env:VCToolsInstallDir).TrimEnd('\')
    $instanceToolsets = Join-Path $vs.instance_path 'VC\Tools\MSVC'
    if (-not (Test-PathWithinRoot -Path $toolsetRoot -Root $instanceToolsets)) {
        Stop-NativeTool 'DBDOC_TOOL_PATH_SHADOW' 'VCToolsInstallDir escaped the exact selected Visual Studio instance'
    }
    foreach ($name in @('cl', 'link', 'lib', 'dumpbin')) {
        $path = Join-Path $toolsetRoot "bin\Hostx64\x64\$name.exe"
        $pe = Get-PeMetadata -Path $path
        if ($pe.pe_format -notin @('PE32', 'PE32+') -or $pe.machine -cne 'AMD64') {
            Stop-NativeTool 'DBDOC_BINARY_NOT_PE' "$name from the exact selected MSVC toolset is not PE AMD64: $path"
        }
    }
}

function Add-LockedPath {
    param($Lock)
    $rustRoot = (Get-RustToolchainMetadata -Lock $Lock).bin
    $paths = @(
        $rustRoot,
        (Join-Path (Expand-LockedPath $Lock.cmake.root) 'bin'),
        (Expand-LockedPath $Lock.ninja.root),
        (Expand-LockedPath $Lock.node.root),
        (Join-Path $Lock.docker.root 'resources\bin')
    )
    $env:PATH = (($paths | Where-Object { $_ }) -join ';') + ';' + $env:PATH
}

function Get-LiveToolPath {
    param($Lock, $Probe, [string]$Name)
    $rustBin = (Get-RustToolchainMetadata -Lock $Lock).bin
    $vctools = ([string]$Probe.vsdevcmd.vctools_install_dir).TrimEnd('\')
    switch ($Name) {
        'cargo' { return (Join-Path $rustBin 'cargo.exe') }
        'rustc' { return (Join-Path $rustBin 'rustc.exe') }
        'rustfmt' { return (Join-Path $rustBin 'rustfmt.exe') }
        'clippy-driver' { return (Join-Path $rustBin 'clippy-driver.exe') }
        'cl' { return (Join-Path $vctools 'bin\Hostx64\x64\cl.exe') }
        'link' { return (Join-Path $vctools 'bin\Hostx64\x64\link.exe') }
        'lib' { return (Join-Path $vctools 'bin\Hostx64\x64\lib.exe') }
        'dumpbin' { return (Join-Path $vctools 'bin\Hostx64\x64\dumpbin.exe') }
        'cmake' { return (Join-Path (Expand-LockedPath $Lock.cmake.root) 'bin\cmake.exe') }
        'ctest' { return (Join-Path (Expand-LockedPath $Lock.cmake.root) 'bin\ctest.exe') }
        'ninja' { return (Join-Path (Expand-LockedPath $Lock.ninja.root) 'ninja.exe') }
        'node' { return (Join-Path (Expand-LockedPath $Lock.node.root) 'node.exe') }
        'npm' { return (Join-Path (Expand-LockedPath $Lock.node.root) 'node.exe') }
        'npx' { return (Join-Path (Expand-LockedPath $Lock.node.root) 'node.exe') }
        'docker' { return [string]$Lock.docker.cli_path }
        'validator' { return (Join-Path $repoRoot $Lock.validators.steinberg_relative_path) }
        'pluginval' { return (Join-Path (Expand-LockedPath $Lock.validators.pluginval_root) 'pluginval.exe') }
        default { return '' }
    }
}

function Get-LiveToolRoot {
    param($Lock, $Probe, [string]$Name)
    if ($Name -in @('cargo','rustc','rustfmt','clippy-driver')) { return (Get-RustToolchainMetadata -Lock $Lock).root }
    if ($Name -in @('cl','link','lib','dumpbin')) { return ([string]$Probe.vsdevcmd.vctools_install_dir).TrimEnd('\') }
    if ($Name -in @('cmake','ctest')) { return Expand-LockedPath $Lock.cmake.root }
    if ($Name -eq 'ninja') { return Expand-LockedPath $Lock.ninja.root }
    if ($Name -in @('node','npm','npx')) { return Expand-LockedPath $Lock.node.root }
    if ($Name -eq 'docker') { return [string]$Lock.docker.root }
    if ($Name -eq 'validator') { return $repoRoot }
    if ($Name -eq 'pluginval') { return Expand-LockedPath $Lock.validators.pluginval_root }
    return ''
}

function Test-SteinbergValidatorProvenance {
    param($Lock, [string]$Path)
    $canonical = [IO.Path]::GetFullPath((Join-Path $repoRoot $Lock.validators.steinberg_relative_path))
    if ([IO.Path]::GetFullPath($Path) -ine $canonical) {
        Stop-NativeTool 'DBDOC_VALIDATOR_PROVENANCE' 'Steinberg Validator is outside its canonical repository build directory'
    }
    $submodule = Join-Path $repoRoot $Lock.validators.steinberg_submodule
    $git = Get-CommandPath 'git.exe'
    $treeLine = Invoke-ProbeCommand $git @('-C', $repoRoot, 'ls-tree', 'HEAD', '--', $Lock.validators.steinberg_submodule)
    $actual = Invoke-ProbeCommand $git @('-C', $submodule, 'rev-parse', 'HEAD')
    $expected = if ($treeLine -match 'commit\s+([0-9a-f]{40})') { $Matches[1] } else { '' }
    if (-not $expected -or $actual -cne $expected) {
        Stop-NativeTool 'DBDOC_VALIDATOR_PROVENANCE' 'Steinberg SDK submodule does not match the superproject pin'
    }
    $buildNinja = Join-Path (Split-Path (Split-Path (Split-Path $canonical -Parent) -Parent) -Parent) 'build.ninja'
    if (-not (Test-Path -LiteralPath $buildNinja -PathType Leaf) -or
        -not (Select-String -LiteralPath $buildNinja -Pattern 'validator(?:\.exe)?' -Quiet)) {
        Stop-NativeTool 'DBDOC_VALIDATOR_PROVENANCE' 'the producing validator target cannot be verified'
    }
}

function Test-ResolvedTool {
    param($Lock, $Probe, [string]$Name, [string]$Path, [string]$Root, [bool]$Injected)
    if (-not $Path) { Stop-NativeTool 'DBDOC_TOOL_MISSING' "$Name is missing" }
    if (-not $Injected -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-NativeTool 'DBDOC_TOOL_MISSING' "$Name is missing at $Path"
    }
    $binary = Get-ProbeBinary -Probe $Probe -Name $Name
    $pe = if ($Injected -and $binary) { [pscustomobject]@{ pe_format = $binary.pe_format; machine = $binary.machine } } else { Get-PeMetadata -Path $Path }
    if ($pe.pe_format -notin @('PE32', 'PE32+') -or $pe.machine -cne 'AMD64') {
        Stop-NativeTool 'DBDOC_BINARY_NOT_PE' "$Name must be a PE32/PE32+ AMD64 executable: $Path"
    }
    if ($Root -and -not $Injected -and -not (Test-PathWithinRoot -Path $Path -Root $Root)) {
        Stop-NativeTool 'DBDOC_TOOL_PATH_SHADOW' "$Name escaped its canonical locked root: $Path"
    }
    if ($binary -and $null -ne $binary.under_locked_root -and -not $binary.under_locked_root) {
        Stop-NativeTool 'DBDOC_TOOL_PATH_SHADOW' "$Name resolves outside its locked root: $Path"
    }
    if ($Name -in @('cmake', 'ninja', 'docker') -and $binary -and $binary.ambient_path -and
        ([IO.Path]::GetFullPath([string]$binary.ambient_path) -ine [IO.Path]::GetFullPath([string]$binary.locked_path))) {
        Stop-NativeTool 'DBDOC_TOOL_PATH_SHADOW' "ambient $Name shadows the locked executable: $($binary.ambient_path)"
    }
}

function Invoke-NativeToolMain {
    if ([string]::IsNullOrWhiteSpace($Tool)) { Stop-NativeTool 'DBDOC_TOOL_REQUIRED' 'specify a native tool name' }
    $supported = @('cargo', 'rustc', 'rustfmt', 'clippy-driver', 'cl', 'link', 'lib', 'dumpbin', 'cmake', 'ctest', 'ninja', 'node', 'npm', 'npx', 'docker', 'validator', 'pluginval')
    if ($Tool -notin $supported) { Stop-NativeTool 'DBDOC_TOOL_FORBIDDEN' "unsupported native tool: $Tool" }
    if ($Tool -eq 'docker') { Assert-DockerInvocationArguments -Arguments @($ToolArguments) }
    $injected = -not [string]::IsNullOrWhiteSpace($ProbePath)
    $canonicalLock = [IO.Path]::GetFullPath((Join-Path $repoRoot 'tools\windows-toolchain.lock.json'))
    $effectiveLock = if ($LockPath) { [IO.Path]::GetFullPath($LockPath) } else { $canonicalLock }
    if ($effectiveLock -ine $canonicalLock -and -not ($injected -and $Describe)) {
        Stop-NativeTool 'DBDOC_LOCK_OVERRIDE_FORBIDDEN' 'live Describe and live execution are hard-bound to the checked-in Windows toolchain lock'
    }
    $lock = Read-ToolchainLock -Path $effectiveLock
    if ($injected -and -not $Describe) {
        Stop-NativeTool 'DBDOC_PROBE_EXECUTION_FORBIDDEN' 'ProbePath is test-only and may be used only with -Describe'
    }

    if ($injected) {
        $probe = Get-NativeWindowsProbe -Lock $lock -RepoRoot $repoRoot -ProbePath $ProbePath
    }
    elseif ($Describe) {
        $probe = Get-NativeWindowsProbe -Lock $lock -RepoRoot $repoRoot -MetadataOnly
    }
    else {
        $initial = Get-NativeWindowsProbe -Lock $lock -RepoRoot $repoRoot -MetadataOnly
        $forbidden = @($initial.ancestors | Where-Object { ([IO.Path]::GetFileName([string]$_)).ToLowerInvariant() -in @('wsl.exe', 'wslhost.exe', 'bash.exe') })
        if ($initial.wsl -or $initial.wsl_distro_name -or $initial.wsl_interop -or $forbidden.Count -gt 0) {
            Stop-NativeTool 'DBDOC_WSL_FORBIDDEN' 'WSL environment or launcher ancestry is forbidden'
        }
        foreach ($name in @('cmake', 'ninja', 'docker', 'cl', 'link', 'lib', 'dumpbin')) {
            $binary = Get-ProbeBinary -Probe $initial -Name $name
            if ($binary -and $binary.ambient_path -and $binary.locked_path -and
                ([IO.Path]::GetFullPath([string]$binary.ambient_path) -ine [IO.Path]::GetFullPath([string]$binary.locked_path))) {
                Stop-NativeTool 'DBDOC_TOOL_PATH_SHADOW' "ambient $name shadows the locked executable: $($binary.ambient_path)"
            }
        }
        Import-LockedVisualStudioEnvironment -Lock $lock
        Add-LockedPath -Lock $lock
        $probe = Get-NativeWindowsProbe -Lock $lock -RepoRoot $repoRoot
    }

    $validation = Test-NativeWindowsProbe -Probe $probe -Lock $lock -Profile HeadlessVst3
    if (-not $validation.success) {
        $first = $validation.errors | Select-Object -First 1
        Stop-NativeTool $first.code $first.message
    }
    if (($injected -or -not $Describe) -and (-not $probe.vsdevcmd.include -or -not $probe.vsdevcmd.lib -or -not $probe.vsdevcmd.windows_sdk_dir -or -not $probe.vsdevcmd.windows_sdk_version -or -not $probe.vsdevcmd.vctools_install_dir)) {
        Stop-NativeTool 'DBDOC_VS_ENV_INCOMPLETE' 'INCLUDE, LIB, and WindowsSdkDir are required after VsDevCmd.bat import'
    }

    $binaryName = if ($Tool -in @('npm', 'npx')) { 'node' } else { $Tool }
    $probeBinary = if ($injected) { Get-ProbeBinary -Probe $probe -Name $binaryName } else { $null }
    $path = if ($probeBinary) { [string]$probeBinary.path } else { Get-LiveToolPath -Lock $lock -Probe $probe -Name $Tool }
    $toolRoot = if ($injected) { '' } else { Get-LiveToolRoot -Lock $lock -Probe $probe -Name $Tool }
    Test-ResolvedTool -Lock $lock -Probe $probe -Name $binaryName -Path $path -Root $toolRoot -Injected:$injected

    if ($Tool -eq 'docker') {
        if ($probe.docker_user_compose_plugin_path -or [string]$probe.docker_compose_plugin_path -ine [string]$lock.docker.compose_plugin_path) {
            Stop-NativeTool 'DBDOC_DOCKER_PLUGIN_SHADOW' "Docker Compose resolves outside Docker Desktop: $($probe.docker_compose_plugin_path)"
        }
        Test-ResolvedTool -Lock $lock -Probe $probe -Name 'docker-compose' -Path $probe.docker_compose_plugin_path -Root (Split-Path -Parent $lock.docker.compose_plugin_path) -Injected:$injected
    }
    elseif ($Tool -eq 'validator' -and -not $injected -and -not $Describe) { Test-SteinbergValidatorProvenance -Lock $lock -Path $path }
    elseif ($Tool -eq 'pluginval' -and -not (Test-PathWithinRoot -Path $path -Root (Expand-LockedPath $lock.validators.pluginval_root))) {
        Stop-NativeTool 'DBDOC_VALIDATOR_PROVENANCE' 'pluginval is outside its locked download root'
    }

    $environment = [ordered]@{
        INCLUDE = [string]$probe.vsdevcmd.include
        LIB = [string]$probe.vsdevcmd.lib
        WindowsSdkDir = [string]$probe.vsdevcmd.windows_sdk_dir
        WindowsSDKVersion = [string]$probe.vsdevcmd.windows_sdk_version
        VCToolsInstallDir = [string]$probe.vsdevcmd.vctools_install_dir
        VSCMD_ARG_TGT_ARCH = 'x64'
        VSCMD_ARG_HOST_ARCH = 'x64'
    }
    $description = [pscustomobject][ordered]@{
        tool = $Tool; resolved_path = $path; pe_format = if ($probeBinary) { $probeBinary.pe_format } else { (Get-PeMetadata $path).pe_format }
        machine = 'AMD64'; environment = $environment; vsdevcmd_path = [string]$probe.vsdevcmd.path; vsdevcmd_import_args = [string]$probe.vsdevcmd.import_args
        docker_compose_plugin_path = if ($Tool -eq 'docker') { $probe.docker_compose_plugin_path } else { $null }
    }
    if ($Describe) { $description | ConvertTo-Json -Depth 6; return }

    $arguments = @($ToolArguments)
    if ($Tool -eq 'npm') { $arguments = @((Join-Path (Expand-LockedPath $lock.node.root) 'node_modules\npm\bin\npm-cli.js')) + $arguments }
    elseif ($Tool -eq 'npx') { $arguments = @((Join-Path (Expand-LockedPath $lock.node.root) 'node_modules\npm\bin\npx-cli.js')) + $arguments }
    & $path @arguments
    exit $LASTEXITCODE
}

Invoke-NativeToolMain
