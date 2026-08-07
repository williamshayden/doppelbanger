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

function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Message)
    Assert-True ($Actual -ceq $Expected) "$Message (expected '$Expected', got '$Actual')"
}

function New-NativeToolFixture {
    $tools = @{}
    foreach ($name in @('rustc', 'cargo', 'cmake', 'ctest', 'ninja', 'cl', 'git', 'powershell')) {
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

function Assert-ArgumentVector {
    param([object]$Invocation, [string[]]$Expected, [string]$Message)

    $actual = @($Invocation.Arguments)
    $matches = $actual.Count -eq $Expected.Count
    if ($matches) {
        for ($index = 0; $index -lt $Expected.Count; $index++) {
            if ($actual[$index] -cne $Expected[$index]) {
                $matches = $false
                break
            }
        }
    }
    Assert-True $matches "$Message (expected '$($Expected -join ' ')', got '$($actual -join ' ')')"
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

$nativeRootProcessIds = @(
    $PID,
    ($PID + 101),
    ($PID + 202),
    ($PID + 303),
    ($PID + 404),
    ($PID + 505),
    ($PID + 606)
)
$nativeRootProcesses = @{}
$nativeRootProcesses[$nativeRootProcessIds[0]] = [pscustomobject]@{ Name = 'powershell.exe'; ParentProcessId = $nativeRootProcessIds[1] }
$nativeRootProcesses[$nativeRootProcessIds[1]] = [pscustomobject]@{ Name = 'cmd.exe'; ParentProcessId = $nativeRootProcessIds[2] }
$nativeRootProcesses[$nativeRootProcessIds[2]] = [pscustomobject]@{ Name = 'WmiPrvSE.exe'; ParentProcessId = $nativeRootProcessIds[3] }
$nativeRootProcesses[$nativeRootProcessIds[3]] = [pscustomobject]@{ Name = 'svchost.exe'; ParentProcessId = $nativeRootProcessIds[4] }
$nativeRootProcesses[$nativeRootProcessIds[4]] = [pscustomobject]@{ Name = 'services.exe'; ParentProcessId = $nativeRootProcessIds[5] }
$nativeRootProcesses[$nativeRootProcessIds[5]] = [pscustomobject]@{ Name = 'wininit.exe'; ParentProcessId = $nativeRootProcessIds[6] }
$nativeRootLookups = [System.Collections.Generic.List[int]]::new()
$nativeRootInvocations = [System.Collections.Generic.List[object]]::new()
try {
    $null = & $devPath -Task doctor -IsWindows $true `
        -ProcessLookup {
            param([int]$Id)
            $nativeRootLookups.Add($Id)
            if ($nativeRootProcesses.ContainsKey($Id)) { return $nativeRootProcesses[$Id] }
            return $null
        }.GetNewClosure() `
        -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
        -CommandResolver (New-CommandResolver (New-NativeToolFixture)) `
        -CommandRunner (New-CommandRunner $nativeRootInvocations)
    $nativeRootError = ''
}
catch {
    $nativeRootError = $_.Exception.Message
}
Assert-True ([string]::IsNullOrEmpty($nativeRootError)) "doctor accepts a complete native chain ending at wininit.exe when its historical parent no longer resolves ($nativeRootError)"
Assert-Equal (($nativeRootLookups | ForEach-Object { [string]$_ }) -join ',') (($nativeRootProcessIds[0..5] | ForEach-Object { [string]$_ }) -join ',') 'doctor stops ancestry inspection after recording wininit.exe'
Assert-True ($nativeRootInvocations.Count -eq 1) 'native wininit-root ancestry only probes rustc host information'

$missingIntermediateParentId = $PID + 808
$missingIntermediateLookups = [System.Collections.Generic.List[int]]::new()
$missingIntermediateInvocations = [System.Collections.Generic.List[object]]::new()
try {
    $null = & $devPath -Task doctor -IsWindows $true `
        -ProcessLookup {
            param([int]$Id)
            $missingIntermediateLookups.Add($Id)
            if ($Id -eq $PID) {
                return [pscustomobject]@{ Name = 'powershell.exe'; ParentProcessId = $missingIntermediateParentId }
            }
            return $null
        }.GetNewClosure() `
        -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
        -CommandResolver (New-CommandResolver (New-NativeToolFixture)) `
        -CommandRunner (New-CommandRunner $missingIntermediateInvocations)
    $missingIntermediateError = ''
}
catch {
    $missingIntermediateError = $_.Exception.Message
}
Assert-Contains $missingIntermediateError 'DBDEV_WSL_FORBIDDEN' 'doctor fails closed when an intermediate process record is missing before wininit.exe'
Assert-Equal (($missingIntermediateLookups | ForEach-Object { [string]$_ }) -join ',') "$PID,$missingIntermediateParentId" 'doctor inspects the unresolved intermediate parent before failing closed'
Assert-True ($missingIntermediateInvocations.Count -eq 0) 'missing intermediate ancestry does not invoke tools'

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

$nonzeroRunnerInvocations = [System.Collections.Generic.List[object]]::new()
$nonzeroRunnerOutput = [System.Collections.Generic.List[string]]::new()
try {
    & $devPath -Task test -ProcessAncestry @('powershell.exe', 'wininit.exe') -IsWindows $true `
        -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
        -CommandResolver (New-CommandResolver (New-NativeToolFixture)) `
        -CommandRunner {
            param([string]$Path, [string[]]$Arguments)
            $nonzeroRunnerInvocations.Add([pscustomobject]@{ Path = $Path; Arguments = @($Arguments) })
            if ($Path.EndsWith('rustc.exe', [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Output = "rustc 1.97.1`nhost: x86_64-pc-windows-msvc"; ExitCode = 0 }
            }
            return [pscustomobject]@{ Output = 'simulated native command failure'; ExitCode = 23 }
        }.GetNewClosure() | ForEach-Object { $nonzeroRunnerOutput.Add([string]$_) }
    $nonzeroRunnerError = ''
}
catch {
    $nonzeroRunnerError = $_.Exception.Message
}
Assert-Contains $nonzeroRunnerError 'DBDEV_TASK_FAILED' 'a nonzero command-runner result retains the stable dispatcher failure code'
Assert-Contains $nonzeroRunnerError 'code 23' 'a nonzero command-runner result retains the exact process exit code'
Assert-Contains ($nonzeroRunnerOutput -join "`n") 'simulated native command failure' 'a nonzero task emits captured process diagnostics before failing'
Assert-True ($nonzeroRunnerInvocations.Count -eq 2) 'the dispatcher stops after the first nonzero task process result'

foreach ($task in @('format', 'test', 'configure', 'build', 'validate')) {
    $result = Invoke-DevFixture -Task $task
    Assert-True ([string]::IsNullOrEmpty($result.Error)) "$task succeeds with checked native tools"
    Assert-True ($result.Invocations.Count -gt 0) "$task delegates to a checked executable"
    foreach ($invocation in $result.Invocations) {
        Assert-True ($invocation.Path -match '^C:\\doppelbanger-test-tools\\.+\.exe$') "$task delegates only to checked native executables"
    }
}

$releasePreset = 'windows-msvc-x64-release'
$validatorBuildTree = 'build/windows-vst3-validator'
$validatorConfigureArguments = @(
    '-S', 'third_party/vst3sdk', '-B', $validatorBuildTree, '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DSMTG_ENABLE_VST3_HOSTING_EXAMPLES=ON',
    '-DSMTG_ENABLE_VST3_PLUGIN_EXAMPLES=OFF',
    '-DSMTG_ENABLE_VSTGUI_SUPPORT=OFF',
    '-DSMTG_RUN_VST_VALIDATOR=OFF',
    '-DSMTG_CREATE_PLUGIN_LINK=OFF'
)

$configureResult = Invoke-DevFixture -Task configure
$configureCmakeInvocations = @($configureResult.Invocations | Where-Object { $_.Path.EndsWith('cmake.exe', [StringComparison]::OrdinalIgnoreCase) })
Assert-True ([string]::IsNullOrEmpty($configureResult.Error)) 'configure succeeds with checked native tools'
Assert-Equal $configureCmakeInvocations.Count 2 'configure configures the product preset and pinned validator separately'
Assert-ArgumentVector $configureCmakeInvocations[0] @('--preset', $releasePreset) 'configure uses the committed Release product preset'
Assert-ArgumentVector $configureCmakeInvocations[1] $validatorConfigureArguments 'configure builds the pinned validator with hosting only and no deployment'

$buildResult = Invoke-DevFixture -Task build
$buildCmakeInvocations = @($buildResult.Invocations | Where-Object { $_.Path.EndsWith('cmake.exe', [StringComparison]::OrdinalIgnoreCase) })
$buildCtestInvocations = @($buildResult.Invocations | Where-Object { $_.Path.EndsWith('ctest.exe', [StringComparison]::OrdinalIgnoreCase) })
Assert-True ([string]::IsNullOrEmpty($buildResult.Error)) 'build succeeds with checked native tools'
Assert-Equal $buildCmakeInvocations.Count 2 'build builds the product preset and validator target'
Assert-ArgumentVector $buildCmakeInvocations[0] @('--build', '--preset', $releasePreset) 'build uses the committed Release product preset'
Assert-ArgumentVector $buildCmakeInvocations[1] @('--build', $validatorBuildTree, '--target', 'validator') 'build only builds the pinned validator target'
Assert-Equal $buildCtestInvocations.Count 1 'build runs the CTest preset after building native targets'
Assert-ArgumentVector $buildCtestInvocations[0] @('--preset', $releasePreset) 'build runs the committed Release CTest preset'

$validateResult = Invoke-DevFixture -Task validate
$validatePowerShellInvocations = @($validateResult.Invocations | Where-Object { $_.Path.EndsWith('powershell.exe', [StringComparison]::OrdinalIgnoreCase) })
$expectedWrapperPath = Join-Path $repoRoot 'tests\plugin\validate_vst3.ps1'
$expectedValidatorPath = Join-Path $repoRoot 'build\windows-vst3-validator\bin\validator.exe'
$expectedPluginPath = Join-Path $repoRoot 'build\windows-msvc-x64-release\artefacts\Release\VST3\Doppelbanger.vst3'
$expectedEvidencePath = Join-Path $repoRoot 'var\validation\native-foundation'
Assert-True ([string]::IsNullOrEmpty($validateResult.Error)) 'validate succeeds with checked native tools'
Assert-Equal $validatePowerShellInvocations.Count 1 'validate invokes the tracked wrapper through checked native PowerShell'
Assert-ArgumentVector $validatePowerShellInvocations[0] @(
    '-NoProfile', '-File', $expectedWrapperPath,
    '-ValidatorPath', $expectedValidatorPath,
    '-PluginPath', $expectedPluginPath,
    '-EvidenceDirectory', $expectedEvidencePath,
    '-TimeoutSeconds', '120'
) 'validate passes exact Release bundle, validator, evidence, and timeout paths to the wrapper'

$source = Get-Content -LiteralPath $devPath -Raw
foreach ($forbidden in @(
    'Invoke-WebRequest', 'Start-BitsTransfer', 'reg.exe', 'New-Service', 'Set-Service', 'Restart-Computer',
    'shutdown.exe', 'docker', 'postgres', 'steam', 'gaming services', 'ableton'
)) {
    Assert-True ($source.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -lt 0) "dispatcher contains no $forbidden operation"
}

Write-Host "dev entrypoint contract passed ($script:passed assertions)."
