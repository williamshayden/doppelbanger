[CmdletBinding()]
param(
    [AllowEmptyString()][string]$ValidatorPath,
    [AllowEmptyString()][string]$PluginPath,
    [string]$EvidenceDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'var\validation\native-foundation'),
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

function Test-DbNativeDrivePath {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -cne $Path.Trim()) {
        return $false
    }
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Contains('/')) {
        return $false
    }
    if ($Path -match '[\*\?\[\]`"''\r\n;&|<>]') {
        return $false
    }
    return $true
}

function Get-DbValidationTargetError {
    param(
        [AllowEmptyString()][string]$ValidatorPath,
        [AllowEmptyString()][string]$PluginPath,
        [int]$TimeoutSeconds
    )

    if (-not (Test-DbNativeDrivePath $ValidatorPath)) {
        return 'DBVST3_INVALID_VALIDATOR: validator must be an exact absolute native drive path'
    }
    if (-not (Test-DbNativeDrivePath $PluginPath)) {
        return 'DBVST3_INVALID_PLUGIN: plugin must be an exact absolute native drive path'
    }
    if ($TimeoutSeconds -le 0 -or $TimeoutSeconds -gt 86400) {
        return 'DBVST3_INVALID_TIMEOUT: timeout must be a finite positive number of seconds'
    }

    try {
        $validator = Get-Item -LiteralPath $ValidatorPath -Force -ErrorAction Stop
    }
    catch {
        return 'DBVST3_INVALID_VALIDATOR: validator executable does not exist'
    }
    if ($validator.PSIsContainer -or $validator.Extension -cne '.exe') {
        return 'DBVST3_INVALID_VALIDATOR: validator must be an existing .exe file'
    }

    try {
        $plugin = Get-Item -LiteralPath $PluginPath -Force -ErrorAction Stop
    }
    catch {
        return 'DBVST3_INVALID_PLUGIN: plugin bundle does not exist'
    }
    if (-not $plugin.PSIsContainer -or $plugin.Extension -cne '.vst3') {
        return 'DBVST3_INVALID_PLUGIN: plugin must be an existing .vst3 directory'
    }

    return ''
}

function Write-DbValidationEvidenceFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [scriptblock]$EvidenceWriter
    )

    try {
        if ($EvidenceWriter) {
            return [bool](& $EvidenceWriter $Path $Content)
        }

        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Path, $Content, $encoding)
        $expectedLength = $encoding.GetByteCount($Content)
        $actualLength = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length
        if ($actualLength -ne $expectedLength) {
            return $false
        }
        return [System.IO.File]::ReadAllText($Path, $encoding) -ceq $Content
    }
    catch {
        return $false
    }
}

function Invoke-DbDirectValidator {
    param(
        [AllowEmptyString()][string]$ValidatorPath,
        [AllowEmptyString()][string]$PluginPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $process = [System.Diagnostics.Process]::new()
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $ValidatorPath
        $startInfo.Arguments = '"' + $PluginPath + '"'
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
        $timeoutMilliseconds = [int]($TimeoutSeconds * 1000)
        $timedOut = -not $process.WaitForExit($timeoutMilliseconds)
        if ($timedOut) {
            $process.Kill()
            $process.WaitForExit()
        }

        $standardOutputTask.Wait()
        $standardErrorTask.Wait()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            TimedOut = $timedOut
            StdOut = $standardOutputTask.Result
            StdErr = $standardErrorTask.Result
            LaunchError = ''
        }
    }
    catch {
        return [pscustomobject]@{
            ExitCode = $null
            TimedOut = $false
            StdOut = ''
            StdErr = ''
            LaunchError = $_.Exception.Message
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-DbVst3Validation {
    param(
        [Parameter(Mandatory = $true)][string]$ValidatorPath,
        [Parameter(Mandatory = $true)][string]$PluginPath,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [int]$TimeoutSeconds = 120,
        [scriptblock]$ProcessLauncher,
        [scriptblock]$EvidenceWriter
    )

    $startedUtc = [datetime]::UtcNow.ToString('o')
    $validationError = ''
    $standardOutput = ''
    $standardError = ''
    $timedOut = $false
    $exitCode = $null
    $launchError = ''
    $evidenceDirectoryReady = $false

    try {
        $null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force -ErrorAction Stop
        $evidenceDirectoryReady = $true
    }
    catch {
        $validationError = "DBVST3_EVIDENCE_DIRECTORY: $($_.Exception.Message)"
    }

    if ([string]::IsNullOrEmpty($validationError)) {
        $validationError = Get-DbValidationTargetError -ValidatorPath $ValidatorPath -PluginPath $PluginPath -TimeoutSeconds $TimeoutSeconds
    }

    if ([string]::IsNullOrEmpty($validationError)) {
        if ($ProcessLauncher) {
            try {
                $processResult = & $ProcessLauncher $ValidatorPath $PluginPath $TimeoutSeconds
                if ($null -eq $processResult) {
                    throw 'process launcher returned no result'
                }
            }
            catch {
                $processResult = [pscustomobject]@{
                    ExitCode = $null
                    TimedOut = $false
                    StdOut = ''
                    StdErr = ''
                    LaunchError = $_.Exception.Message
                }
            }
        }
        else {
            $processResult = Invoke-DbDirectValidator -ValidatorPath $ValidatorPath -PluginPath $PluginPath -TimeoutSeconds $TimeoutSeconds
        }

        if ($processResult.PSObject.Properties['ExitCode']) { $exitCode = $processResult.ExitCode }
        if ($processResult.PSObject.Properties['TimedOut']) { $timedOut = [bool]$processResult.TimedOut }
        if ($processResult.PSObject.Properties['StdOut']) { $standardOutput = [string]$processResult.StdOut }
        if ($processResult.PSObject.Properties['StdErr']) { $standardError = [string]$processResult.StdErr }
        if ($processResult.PSObject.Properties['LaunchError']) { $launchError = [string]$processResult.LaunchError }
    }

    if ([string]::IsNullOrEmpty($validationError) -and
        [string]::IsNullOrEmpty($launchError) -and
        -not $timedOut -and
        $exitCode -eq 0) {
        $expectedVendor = 'Goblin City Records'
        $vendorPattern = "(?m)^[ `t]*vendor[ `t]*=[ `t]*$([regex]::Escape($expectedVendor))[ `t]*`r?$"
        if (-not [regex]::IsMatch($standardOutput, $vendorPattern)) {
            $validationError = "DBVST3_IDENTITY: validator factory vendor must be $expectedVendor"
        }
    }

    if (-not [string]::IsNullOrEmpty($validationError)) {
        $standardError = $validationError
    }
    elseif (-not [string]::IsNullOrEmpty($launchError)) {
        $standardError = $launchError
    }

    $endedUtc = [datetime]::UtcNow.ToString('o')
    $completedZeroExit = [string]::IsNullOrEmpty($validationError) -and
        [string]::IsNullOrEmpty($launchError) -and -not $timedOut -and $exitCode -eq 0
    $stdoutWritten = $false
    $stderrWritten = $false
    $resultWritten = $false

    $result = [ordered]@{
        ValidatorPath = $ValidatorPath
        PluginPath = $PluginPath
        StartedUtc = $startedUtc
        EndedUtc = $endedUtc
        TimeoutSeconds = $TimeoutSeconds
        TimedOut = $timedOut
        ValidatorExitCode = $exitCode
        LaunchError = $launchError
        ValidationError = $validationError
        EvidenceComplete = $false
        Success = $false
    }

    if ($evidenceDirectoryReady) {
        $stdoutWritten = Write-DbValidationEvidenceFile -Path (Join-Path $EvidenceDirectory 'validator.stdout.txt') -Content $standardOutput -EvidenceWriter $EvidenceWriter
        $stderrWritten = Write-DbValidationEvidenceFile -Path (Join-Path $EvidenceDirectory 'validator.stderr.txt') -Content $standardError -EvidenceWriter $EvidenceWriter
        $result.EvidenceComplete = $stdoutWritten -and $stderrWritten
        $result.Success = $completedZeroExit -and $result.EvidenceComplete
        $resultJson = $result | ConvertTo-Json -Depth 3
        $resultWritten = Write-DbValidationEvidenceFile -Path (Join-Path $EvidenceDirectory 'validator.result.json') -Content $resultJson -EvidenceWriter $EvidenceWriter
    }

    $result.EvidenceComplete = $stdoutWritten -and $stderrWritten -and $resultWritten
    $result.Success = $completedZeroExit -and $result.EvidenceComplete
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-DbVst3Validation -ValidatorPath $ValidatorPath -PluginPath $PluginPath -EvidenceDirectory $EvidenceDirectory -TimeoutSeconds $TimeoutSeconds
    $result | ConvertTo-Json -Depth 3
    if (-not $result.Success) {
        exit 1
    }
}
