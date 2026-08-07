[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('doctor', 'format', 'test', 'configure', 'build', 'validate')]
    [string]$Task,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string[]]$ProcessAncestry,
    [bool]$IsWindows = ($env:OS -eq 'Windows_NT'),
    [scriptblock]$ProcessLookup,
    [scriptblock]$CommandResolver,
    [scriptblock]$CommandRunner
)

$ErrorActionPreference = 'Stop'

function Get-DbDevProcessAncestry {
    param([scriptblock]$Lookup)

    $names = [System.Collections.Generic.List[string]]::new()
    $currentProcessId = $PID
    for ($i = 0; $i -lt 32 -and $currentProcessId -gt 0; $i++) {
        $process = if ($Lookup) {
            & $Lookup $currentProcessId
        }
        else {
            try {
                Get-CimInstance Win32_Process -Filter "ProcessId=$currentProcessId" -ErrorAction Stop
            }
            catch { $null }
        }
        if (-not $process) { break }
        $names.Add([string]$process.Name)
        $currentProcessId = [int]$process.ParentProcessId
    }
    return $names.ToArray()
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
        if ($null -ne $result -and $result.PSObject.Properties['ExitCode'] -and [int]$result.ExitCode -ne 0) {
            throw "DBDEV_TASK_FAILED: $Path exited with code $($result.ExitCode)"
        }
        $output = if ($null -ne $result -and $result.PSObject.Properties['Output']) { [string]$result.Output } else { [string]$result }
        return $output
    }

    $output = & $Path @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "DBDEV_TASK_FAILED: $Path exited with code $LASTEXITCODE"
    }
    return ($output -join "`n")
}

function Assert-DbDevNativeEnvironment {
    param([string[]]$Ancestry)

    if (-not $IsWindows) {
        throw 'DBDEV_WINDOWS_REQUIRED: run this dispatcher from native Windows PowerShell'
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
        Invoke-DbDevTool -Path $tools.cmake -Arguments @('-S', '.', '-B', 'build/windows-v1', '-G', 'Ninja', "-DCMAKE_BUILD_TYPE=$Configuration")
        break
    }
    'build' {
        Invoke-DbDevTool -Path $tools.cmake -Arguments @('--build', 'build/windows-v1', '--config', $Configuration)
        break
    }
    'validate' {
        Invoke-DbDevTool -Path $tools.cmake -Arguments @('--build', 'build/windows-v1', '--target', 'validate', '--config', $Configuration)
        break
    }
}
