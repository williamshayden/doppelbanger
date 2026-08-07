[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$devPath = Join-Path $repoRoot 'scripts\dev.ps1'

if (-not (Test-Path -LiteralPath $devPath -PathType Leaf)) {
    throw "RED: scripts/dev.ps1 is missing"
}

$script:passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:passed++
}

function Assert-Contains {
    param([string]$Actual, [string]$Expected, [string]$Message)
    Assert-True ($Actual.Contains($Expected)) "$Message (expected '$Expected' in '$Actual')"
}

function New-NativeToolFixture {
    $tools = @{}
    foreach ($name in @('rustc', 'cargo', 'cmake', 'ninja', 'cl', 'git')) {
        $tools[$name] = "C:\doppelbanger-test-tools\$name.exe"
    }
    return $tools
}

function New-PlatformFixture {
    param(
        [string]$Version = '10.0.22631.0',
        [int]$ProductType = 1,
        [string]$OSArchitecture = '64-bit',
        [string]$SystemType = 'x64-based PC'
    )

    return [pscustomobject]@{
        Version = $Version
        ProductType = $ProductType
        OSArchitecture = $OSArchitecture
        SystemType = $SystemType
    }
}

function New-PlatformLookup {
    param([Parameter(Mandatory = $true)][object]$Platform)

    return {
        $Platform
    }.GetNewClosure()
}

function New-CommandResolver {
    param([hashtable]$Tools)
    return {
        param([string]$Name)
        if ($Tools.ContainsKey($Name)) { return $Tools[$Name] }
        return $null
    }.GetNewClosure()
}

function New-CommandRunner {
    param([System.Collections.Generic.List[object]]$Invocations)
    return {
        param([string]$Path, [string[]]$Arguments)
        $Invocations.Add([pscustomobject]@{ Path = $Path; Arguments = @($Arguments) })
        if ($Path.EndsWith('rustc.exe', [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Output = "rustc 1.97.1`nhost: x86_64-pc-windows-msvc"; ExitCode = 0 }
        }
        return [pscustomobject]@{ Output = ''; ExitCode = 0 }
    }.GetNewClosure()
}

function Invoke-DevFixture {
    param(
        [string]$Task,
        [string[]]$ProcessAncestry = @('powershell.exe', 'explorer.exe'),
        [hashtable]$Tools = (New-NativeToolFixture),
        [bool]$IsWindows = $true,
        [object]$Platform
    )

    $invocations = [System.Collections.Generic.List[object]]::new()
    try {
        $parameters = @{
            Task = $Task
            ProcessAncestry = $ProcessAncestry
            IsWindows = $IsWindows
            CommandResolver = (New-CommandResolver $Tools)
            CommandRunner = (New-CommandRunner $invocations)
        }
        if ($null -ne $Platform) {
            $parameters.PlatformLookup = New-PlatformLookup $Platform
        }
        $null = & $devPath @parameters
        return [pscustomobject]@{ Error = ''; Invocations = $invocations }
    }
    catch {
        return [pscustomobject]@{ Error = $_.Exception.Message; Invocations = $invocations }
    }
}

$wslResult = Invoke-DevFixture -Task doctor -ProcessAncestry @('powershell.exe', 'wsl.exe', 'explorer.exe')
Assert-Contains $wslResult.Error 'DBDEV_WSL_FORBIDDEN' 'doctor rejects injected WSL ancestry'

foreach ($clientPlatform in @(
    (New-PlatformFixture -Version '10.0.19045.0'),
    (New-PlatformFixture -Version '10.0.22631.0')
)) {
    $clientResult = Invoke-DevFixture -Task doctor -Platform $clientPlatform
    Assert-True ([string]::IsNullOrEmpty($clientResult.Error)) "doctor accepts supported x64 client Windows $($clientPlatform.Version)"
}

foreach ($unsupportedPlatform in @(
    (New-PlatformFixture -ProductType 3),
    (New-PlatformFixture -Version '6.3.9600.0'),
    (New-PlatformFixture -SystemType 'ARM64-based PC')
)) {
    $unsupportedResult = Invoke-DevFixture -Task doctor -Platform $unsupportedPlatform
    Assert-Contains $unsupportedResult.Error 'DBDEV_WINDOWS_REQUIRED' "doctor rejects unsupported Windows platform $($unsupportedPlatform.Version)/$($unsupportedPlatform.ProductType)/$($unsupportedPlatform.SystemType)"
}

$missingLookupInvocations = [System.Collections.Generic.List[object]]::new()
try {
    $null = & $devPath -Task doctor -IsWindows $true `
        -ProcessLookup { $null } `
        -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
        -CommandResolver (New-CommandResolver (New-NativeToolFixture)) `
        -CommandRunner (New-CommandRunner $missingLookupInvocations)
    $missingLookupError = ''
}
catch {
    $missingLookupError = $_.Exception.Message
}
Assert-Contains $missingLookupError 'DBDEV_WSL_FORBIDDEN' 'doctor fails closed when process ancestry lookup returns no record'
Assert-True ($missingLookupInvocations.Count -eq 0) 'missing ancestry record does not invoke tools'

$failedLookupInvocations = [System.Collections.Generic.List[object]]::new()
try {
    $null = & $devPath -Task doctor -IsWindows $true `
        -ProcessLookup { throw 'simulated process lookup failure' } `
        -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
        -CommandResolver (New-CommandResolver (New-NativeToolFixture)) `
        -CommandRunner (New-CommandRunner $failedLookupInvocations)
    $failedLookupError = ''
}
catch {
    $failedLookupError = $_.Exception.Message
}
Assert-Contains $failedLookupError 'DBDEV_WSL_FORBIDDEN' 'doctor fails closed when process ancestry lookup fails'
Assert-True ($failedLookupInvocations.Count -eq 0) 'failed ancestry inspection does not invoke tools'

$pidBeforeProcessLookup = $PID
$lookedUpProcessIds = [System.Collections.Generic.List[int]]::new()
$lookupInvocations = [System.Collections.Generic.List[object]]::new()
try {
    $null = & $devPath -Task doctor -IsWindows $true `
        -ProcessLookup {
            param([int]$Id)
            $lookedUpProcessIds.Add($Id)
            [pscustomobject]@{ Name = 'powershell.exe'; ParentProcessId = 0 }
        }.GetNewClosure() `
        -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
        -CommandResolver (New-CommandResolver (New-NativeToolFixture)) `
        -CommandRunner (New-CommandRunner $lookupInvocations)
    $processLookupError = ''
}
catch {
    $processLookupError = $_.Exception.Message
}
Assert-True ([string]::IsNullOrEmpty($processLookupError) -and $PID -eq $pidBeforeProcessLookup) "doctor accepts an injected native process lookup without overwriting the automatic process identifier ($processLookupError)"
Assert-True ($lookupInvocations.Count -eq 1 -and $lookedUpProcessIds.Count -eq 1 -and $lookedUpProcessIds[0] -eq $pidBeforeProcessLookup) 'doctor starts ancestry lookup from the automatic process identifier and only probes rustc host information'

$missingTools = New-NativeToolFixture
$missingTools.Remove('cl')
$missingToolResult = Invoke-DevFixture -Task doctor -Tools $missingTools
Assert-Contains $missingToolResult.Error 'DBDEV_TOOL_MISSING' 'doctor reports a missing native tool with a stable code'

$wrongPlatformResult = Invoke-DevFixture -Task doctor -IsWindows $false
Assert-Contains $wrongPlatformResult.Error 'DBDEV_WINDOWS_REQUIRED' 'doctor rejects a non-Windows process with a stable code'

$wrongHostTools = New-NativeToolFixture
$wrongHostInvocations = [System.Collections.Generic.List[object]]::new()
try {
    $null = & $devPath -Task doctor -ProcessAncestry @('powershell.exe') -IsWindows $true `
        -CommandResolver (New-CommandResolver $wrongHostTools) `
        -CommandRunner {
            param([string]$Path, [string[]]$Arguments)
            [pscustomobject]@{ Output = "rustc 1.97.1`nhost: x86_64-unknown-linux-gnu"; ExitCode = 0 }
        }
    $wrongHostError = ''
}
catch {
    $wrongHostError = $_.Exception.Message
}
Assert-Contains $wrongHostError 'DBDEV_WRONG_RUST_HOST' 'doctor rejects a non-MSVC Rust host with a stable code'

foreach ($task in @('format', 'test', 'configure', 'build', 'validate')) {
    $result = Invoke-DevFixture -Task $task
    Assert-True ([string]::IsNullOrEmpty($result.Error)) "$task succeeds with checked native tools"
    Assert-True ($result.Invocations.Count -gt 0) "$task delegates to a checked executable"
    foreach ($invocation in $result.Invocations) {
        Assert-True ($invocation.Path -match '^C:\\doppelbanger-test-tools\\.+\.exe$') "$task delegates only to checked native executables"
    }
}

$source = Get-Content -LiteralPath $devPath -Raw
foreach ($forbidden in @(
    'Invoke-WebRequest', 'Start-BitsTransfer', 'reg.exe', 'New-Service', 'Set-Service', 'Restart-Computer',
    'shutdown.exe', 'docker', 'postgres', 'steam', 'gaming services', 'ableton'
)) {
    Assert-True ($source.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -lt 0) "dispatcher contains no $forbidden operation"
}

Write-Host "dev entrypoint contract passed ($script:passed assertions)."
