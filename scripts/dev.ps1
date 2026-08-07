[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('doctor', 'format', 'test', 'configure', 'build', 'validate', 'ui-install', 'ui-test')]
    [string]$Task,
    [ValidateSet('Release')]
    [string]$Configuration = 'Release',
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
    $reachedNativeRoot = $false
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
            $reachedNativeRoot = $true
            break
        }
        $currentProcessId = [int]$process.ParentProcessId
    }
    if (-not $reachedNativeRoot) {
        throw 'DBDEV_WSL_FORBIDDEN: process ancestry cannot be inspected through wininit.exe'
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
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory
    )

    if ($CommandRunner) {
        $result = & $CommandRunner $Path $Arguments $WorkingDirectory
        $output = if ($null -ne $result -and $result.PSObject.Properties['Output']) { [string]$result.Output } else { [string]$result }
        $launchError = if ($null -ne $result -and $result.PSObject.Properties['LaunchError']) { [string]$result.LaunchError } else { '' }
        if ($null -eq $result -or -not $result.PSObject.Properties['ExitCode'] -or $null -eq $result.ExitCode -or -not [string]::IsNullOrEmpty($launchError)) {
            if (-not [string]::IsNullOrEmpty($output)) { Write-Output $output }
            throw "DBDEV_TASK_FAILED: $Path could not be launched"
        }
        if ([int]$result.ExitCode -ne 0) {
            if (-not [string]::IsNullOrEmpty($output)) { Write-Output $output }
            throw "DBDEV_TASK_FAILED: $Path exited with code $($result.ExitCode)"
        }
        return $output
    }

    $process = [System.Diagnostics.Process]::new()
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $Path
        if (-not [string]::IsNullOrEmpty($WorkingDirectory)) {
            $startInfo.WorkingDirectory = $WorkingDirectory
        }
        $startInfo.Arguments = (@($Arguments | ForEach-Object {
            $escaped = $_ -replace '(\\*)"', '$1$1\"'
            $escaped = $escaped -replace '(\\+)$', '$1$1'
            '"' + $escaped + '"'
        }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'System.Diagnostics.Process.Start returned false'
        }
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $standardOutputTask.Wait()
        $standardErrorTask.Wait()
        $exitCode = $process.ExitCode
        $standardOutput = [string]$standardOutputTask.Result
        $standardError = [string]$standardErrorTask.Result
    }
    catch {
        throw "DBDEV_TASK_FAILED: $Path could not be launched: $($_.Exception.Message)"
    }
    finally {
        $process.Dispose()
    }
    $joinedOutput = @($standardOutput, $standardError) -join ''
    if ($exitCode -ne 0) {
        if (-not [string]::IsNullOrEmpty($joinedOutput)) { Write-Output $joinedOutput }
        throw "DBDEV_TASK_FAILED: $Path exited with code $exitCode"
    }
    return $joinedOutput
}

function Get-DbDevEditorDependencies {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $lockPath = Join-Path $RepositoryRoot 'tools\editor-dependencies.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw 'DBDEV_EDITOR_LOCK_MISSING: editor dependency lock is missing'
    }
    try {
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'DBDEV_EDITOR_LOCK_INVALID: editor dependency lock is invalid'
    }
    foreach ($name in @('node', 'npm')) {
        if (-not $lock.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$lock.$name)) {
            throw "DBDEV_EDITOR_LOCK_INVALID: editor dependency lock is missing '$name'"
        }
    }
    return $lock
}

function Assert-DbDevNativeEnvironment {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
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

    $ancestry = @(Get-DbDevProcessAncestry -Lookup $ProcessLookup)
    if (@($ancestry | Where-Object { $_ -match '(?i)^(wsl|wslhost|bash|zsh|sh)(?:\.exe)?$' }).Count -gt 0) {
        throw 'DBDEV_WSL_FORBIDDEN: run this dispatcher outside WSL'
    }

    $tools = @{}
    foreach ($name in @('rustc', 'cmake', 'ninja', 'cl', 'git', 'node', 'npm')) {
        $tools[$name] = Resolve-DbDevTool $name
    }

    $rustVersion = Invoke-DbDevTool -Path $tools.rustc -Arguments @('-vV')
    if ($rustVersion -notmatch '(?m)^host:\s*x86_64-pc-windows-msvc\s*$') {
        throw 'DBDEV_WRONG_RUST_HOST: rustc must report x86_64-pc-windows-msvc'
    }
    $editorDependencies = Get-DbDevEditorDependencies -RepositoryRoot $RepositoryRoot
    $nodeVersion = (Invoke-DbDevTool -Path $tools.node -Arguments @('--version')).Trim()
    if ($nodeVersion -cne "v$($editorDependencies.node)") {
        throw "DBDEV_WRONG_NODE_VERSION: node must report v$($editorDependencies.node)"
    }
    $npmVersion = (Invoke-DbDevTool -Path $tools.npm -Arguments @('--version')).Trim()
    if ($npmVersion -cne [string]$editorDependencies.npm) {
        throw "DBDEV_WRONG_NPM_VERSION: npm must report $($editorDependencies.npm)"
    }
    return $tools
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tools = Assert-DbDevNativeEnvironment -RepositoryRoot $repoRoot
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
        'ui-test' {
            $uiRoot = Join-Path $repoRoot 'plugin\ui'
            Invoke-DbDevTool -Path $tools.npm -Arguments @('run', 'check') -WorkingDirectory $uiRoot
            break
        }
        'ui-install' {
            $uiRoot = Join-Path $repoRoot 'plugin\ui'
            $previousPlaywrightSkipBrowserDownload = [Environment]::GetEnvironmentVariable('PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD', 'Process')
            try {
                [Environment]::SetEnvironmentVariable('PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD', '1', 'Process')
                Invoke-DbDevTool -Path $tools.npm -Arguments @('ci') -WorkingDirectory $uiRoot
            }
            finally {
                [Environment]::SetEnvironmentVariable('PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD', $previousPlaywrightSkipBrowserDownload, 'Process')
            }
            break
        }
    }
}
finally {
    Pop-Location
}
