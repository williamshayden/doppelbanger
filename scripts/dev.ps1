[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('doctor', 'format', 'test', 'configure', 'build', 'validate')]
    [string]$Task,
    [ValidateSet('Release')]
    [string]$Configuration = 'Release',
    [string[]]$ProcessAncestry,
    [bool]$IsWindows = ($env:OS -eq 'Windows_NT'),
    [scriptblock]$ProcessLookup,
    [scriptblock]$PlatformLookup,
    [scriptblock]$CommandResolver,
    [scriptblock]$CommandRunner
)

$ErrorActionPreference = 'Stop'

function Get-DbDevProcessAncestry {
    param([scriptblock]$Lookup)

    $names = [System.Collections.Generic.List[string]]::new()
    $currentProcessId = $PID
    for ($i = 0; $i -lt 32 -and $currentProcessId -gt 0; $i++) {
        try {
            $process = if ($Lookup) {
                & $Lookup $currentProcessId
            }
            else {
                Get-CimInstance Win32_Process -Filter "ProcessId=$currentProcessId" -ErrorAction Stop
            }
        }
        catch {
            throw 'DBDEV_WSL_FORBIDDEN: process ancestry cannot be inspected'
        }
        if (-not $process) {
            throw 'DBDEV_WSL_FORBIDDEN: process ancestry cannot be inspected'
        }
        $processName = [string]$process.Name
        $names.Add($processName)
        if ([string]::Equals($processName, 'wininit.exe', [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $currentProcessId = [int]$process.ParentProcessId
    }
    return $names.ToArray()
}

function Get-DbDevPlatform {
    param([scriptblock]$Lookup)

    try {
        if ($Lookup) {
            return & $Lookup
        }

        $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        return [pscustomobject]@{
            Version = [string]$operatingSystem.Version
            ProductType = [int]$operatingSystem.ProductType
            OSArchitecture = [string]$operatingSystem.OSArchitecture
            SystemType = [string]$computerSystem.SystemType
        }
    }
    catch {
        throw 'DBDEV_WINDOWS_REQUIRED: run this dispatcher from supported native Windows x64'
    }
}

function Resolve-DbDevTool {
    param([Parameter(Mandatory = $true)][string]$Name)

    $path = if ($CommandResolver) {
        & $CommandResolver $Name
    }
    else {
        try {
            (Get-Command -Name $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        }
        catch { '' }
    }

    if (-not $path -or $path -notmatch '^[A-Za-z]:\\' -or $path -match '(?i)\\\\wsl\\$') {
        throw "DBDEV_TOOL_MISSING: required native executable '$Name' was not found"
    }
    return [string]$path
}

function Invoke-DbDevTool {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if ($CommandRunner) {
        $result = & $CommandRunner $Path $Arguments
        $output = if ($null -ne $result -and $result.PSObject.Properties['Output']) { [string]$result.Output } else { [string]$result }
        if ($null -ne $result -and $result.PSObject.Properties['ExitCode'] -and [int]$result.ExitCode -ne 0) {
            if (-not [string]::IsNullOrEmpty($output)) { Write-Output $output }
            throw "DBDEV_TASK_FAILED: $Path exited with code $($result.ExitCode)"
        }
        return $output
    }

    $callerErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Path @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $callerErrorActionPreference
    }
    $joinedOutput = $output -join "`n"
    if ($exitCode -ne 0) {
        if (-not [string]::IsNullOrEmpty($joinedOutput)) { Write-Output $joinedOutput }
        throw "DBDEV_TASK_FAILED: $Path exited with code $exitCode"
    }
    return $joinedOutput
}

function Assert-DbDevNativeEnvironment {
    param([string[]]$Ancestry)

    if (-not $IsWindows) {
        throw 'DBDEV_WINDOWS_REQUIRED: run this dispatcher from native Windows PowerShell'
    }

    $platform = Get-DbDevPlatform -Lookup $PlatformLookup
    try {
        $version = [version][string]$platform.Version
        $supportedPlatform = ([int]$platform.ProductType -eq 1) -and
            ($version.Major -eq 10) -and
            ($version.Minor -eq 0) -and
            ($version.Build -ge 10240) -and
            ([string]$platform.OSArchitecture -match '(?i)^64-bit$') -and
            ([string]$platform.SystemType -match '(?i)^x64-based PC$')
    }
    catch {
        throw 'DBDEV_WINDOWS_REQUIRED: run this dispatcher from supported native Windows x64'
    }
    if (-not $supportedPlatform) {
        throw 'DBDEV_WINDOWS_REQUIRED: run this dispatcher from supported native Windows x64'
    }

    $ancestry = if ($null -ne $Ancestry) { @($Ancestry) } else { @(Get-DbDevProcessAncestry -Lookup $ProcessLookup) }
    if (@($ancestry | Where-Object { $_ -match '(?i)^(wsl|wslhost|bash|zsh|sh)(?:\.exe)?$' }).Count -gt 0) {
        throw 'DBDEV_WSL_FORBIDDEN: run this dispatcher outside WSL'
    }

    $tools = @{}
    foreach ($name in @('rustc', 'cmake', 'ninja', 'cl', 'git')) {
        $tools[$name] = Resolve-DbDevTool $name
    }

    $rustVersion = Invoke-DbDevTool -Path $tools.rustc -Arguments @('-vV')
    if ($rustVersion -notmatch '(?m)^host:\s*x86_64-pc-windows-msvc\s*$') {
        throw 'DBDEV_WRONG_RUST_HOST: rustc must report x86_64-pc-windows-msvc'
    }
    return $tools
}

$tools = Assert-DbDevNativeEnvironment -Ancestry $ProcessAncestry
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releasePreset = 'windows-msvc-x64-release'
$validatorBuildTree = 'build/windows-vst3-validator'

Push-Location -LiteralPath $repoRoot
try {
    switch ($Task) {
        'doctor' {
            Write-Output 'DBDEV_DOCTOR_OK: native developer prerequisites are available'
            break
        }
        'format' {
            $cargo = Resolve-DbDevTool 'cargo'
            Invoke-DbDevTool -Path $cargo -Arguments @('fmt', '--all', '--', '--check')
            break
        }
        'test' {
            $cargo = Resolve-DbDevTool 'cargo'
            Invoke-DbDevTool -Path $cargo -Arguments @('test', '--locked', '--all-targets')
            break
        }
        'configure' {
            Invoke-DbDevTool -Path $tools.cmake -Arguments @('--preset', $releasePreset)
            Invoke-DbDevTool -Path $tools.cmake -Arguments @(
                '-S', 'third_party/vst3sdk', '-B', $validatorBuildTree, '-G', 'Ninja',
                '-DCMAKE_BUILD_TYPE=Release',
                '-DSMTG_ENABLE_VST3_HOSTING_EXAMPLES=ON',
                '-DSMTG_ENABLE_VST3_PLUGIN_EXAMPLES=OFF',
                '-DSMTG_ENABLE_VSTGUI_SUPPORT=OFF',
                '-DSMTG_RUN_VST_VALIDATOR=OFF',
                '-DSMTG_CREATE_PLUGIN_LINK=OFF'
            )
            break
        }
        'build' {
            $ctest = Resolve-DbDevTool 'ctest'
            Invoke-DbDevTool -Path $tools.cmake -Arguments @('--build', '--preset', $releasePreset)
            Invoke-DbDevTool -Path $tools.cmake -Arguments @('--build', $validatorBuildTree, '--target', 'validator')
            Invoke-DbDevTool -Path $ctest -Arguments @('--preset', $releasePreset)
            break
        }
        'validate' {
            $powershell = Resolve-DbDevTool 'powershell'
            $wrapperPath = Join-Path $repoRoot 'tests\plugin\validate_vst3.ps1'
            $validatorPath = Join-Path $repoRoot 'build\windows-vst3-validator\bin\validator.exe'
            $pluginPath = Join-Path $repoRoot 'build\windows-msvc-x64-release\artefacts\Release\VST3\Doppelbanger.vst3'
            $evidencePath = Join-Path $repoRoot 'var\validation\native-foundation'
            Invoke-DbDevTool -Path $powershell -Arguments @(
                '-NoProfile', '-File', $wrapperPath,
                '-ValidatorPath', $validatorPath,
                '-PluginPath', $pluginPath,
                '-EvidenceDirectory', $evidencePath,
                '-TimeoutSeconds', '120'
            )
            break
        }
    }
}
finally {
    Pop-Location
}
