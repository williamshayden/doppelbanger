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
    foreach ($name in @('rustc', 'cargo', 'cmake', 'ctest', 'ninja', 'cl', 'git', 'powershell', 'node', 'npm')) {
        $extension = if ($name -eq 'npm') { 'cmd' } else { 'exe' }
        $tools[$name] = "C:\doppelbanger-test-tools\$name.$extension"
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
        param([string]$Path, [string[]]$Arguments, [string]$WorkingDirectory)
        $Invocations.Add([pscustomobject]@{ Path = $Path; Arguments = @($Arguments); WorkingDirectory = $WorkingDirectory })
        if ($Path.EndsWith('rustc.exe', [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Output = "rustc 1.97.1`nhost: x86_64-pc-windows-msvc"; ExitCode = 0 }
        }
        if ($Path.EndsWith('node.exe', [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Output = 'v24.18.1'; ExitCode = 0 }
        }
        if ($Path.EndsWith('npm.cmd', [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Output = '11.16.0'; ExitCode = 0 }
        }
        return [pscustomobject]@{ Output = ''; ExitCode = 0 }
    }.GetNewClosure()
}

function New-ProcessFixture {
    param(
        [string[]]$Names = @('powershell.exe', 'cmd.exe', 'services.exe', 'wininit.exe'),
        [Nullable[int]]$FinalParentProcessId
    )

    $processIds = [System.Collections.Generic.List[int]]::new()
    $records = @{}
    $lookups = [System.Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt $Names.Count; $index++) {
        $processId = if ($index -eq 0) { $PID } else { $PID + 10000 + $index }
        $processIds.Add($processId)
    }
    for ($index = 0; $index -lt $Names.Count; $index++) {
        if ($index -lt ($Names.Count - 1)) {
            $parentProcessId = $processIds[$index + 1]
        }
        elseif ($PSBoundParameters.ContainsKey('FinalParentProcessId')) {
            $parentProcessId = [int]$FinalParentProcessId
        }
        elseif ([string]::Equals($Names[$index], 'wininit.exe', [StringComparison]::OrdinalIgnoreCase)) {
            $parentProcessId = $PID + 20000 + $Names.Count
        }
        else {
            $parentProcessId = 0
        }
        $records[$processIds[$index]] = [pscustomobject]@{
            Name = $Names[$index]
            ParentProcessId = $parentProcessId
        }
    }

    $lookup = {
        param([int]$Id)
        $lookups.Add($Id)
        if ($records.ContainsKey($Id)) { return $records[$Id] }
        return $null
    }.GetNewClosure()
    return [pscustomobject]@{
        Lookup = $lookup
        ProcessIds = $processIds
        Lookups = $lookups
    }
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
        [string[]]$ProcessNames = @('powershell.exe', 'cmd.exe', 'services.exe', 'wininit.exe'),
        [hashtable]$Tools = (New-NativeToolFixture),
        [bool]$IsWindows = $true,
        [object]$Platform
    )

    $invocations = [System.Collections.Generic.List[object]]::new()
    $processFixture = New-ProcessFixture -Names $ProcessNames
    try {
        $parameters = @{
            Task = $Task
            ProcessLookup = $processFixture.Lookup
            IsWindows = $IsWindows
            PlatformLookup = (New-PlatformLookup $(if ($null -ne $Platform) { $Platform } else { New-PlatformFixture }))
            CommandResolver = (New-CommandResolver $Tools)
            CommandRunner = (New-CommandRunner $invocations)
        }
        $null = & $devPath @parameters
        return [pscustomobject]@{ Error = ''; Invocations = $invocations; ProcessFixture = $processFixture }
    }
    catch {
        return [pscustomobject]@{ Error = $_.Exception.Message; Invocations = $invocations; ProcessFixture = $processFixture }
    }
}

$wslResult = Invoke-DevFixture -Task doctor -ProcessNames @('powershell.exe', 'wsl.exe', 'wininit.exe')
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

$failClosedRegressions = [System.Collections.Generic.List[string]]::new()

$pidZeroFixture = New-ProcessFixture -Names @('powershell.exe') -FinalParentProcessId 0
$pidZeroInvocations = [System.Collections.Generic.List[object]]::new()
try {
    $null = & $devPath -Task doctor -IsWindows $true `
        -ProcessLookup $pidZeroFixture.Lookup `
        -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
        -CommandResolver (New-CommandResolver (New-NativeToolFixture)) `
        -CommandRunner (New-CommandRunner $pidZeroInvocations)
    $pidZeroError = ''
}
catch {
    $pidZeroError = $_.Exception.Message
}
if ([string]::IsNullOrEmpty($pidZeroError)) {
    $failClosedRegressions.Add('PID zero before inspected wininit.exe was accepted')
}

$depthNames = @(0..31 | ForEach-Object { "native-$_.exe" })
$depthFixture = New-ProcessFixture -Names $depthNames -FinalParentProcessId ($PID + 30000)
$depthInvocations = [System.Collections.Generic.List[object]]::new()
try {
    $null = & $devPath -Task doctor -IsWindows $true `
        -ProcessLookup $depthFixture.Lookup `
        -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
        -CommandResolver (New-CommandResolver (New-NativeToolFixture)) `
        -CommandRunner (New-CommandRunner $depthInvocations)
    $depthError = ''
}
catch {
    $depthError = $_.Exception.Message
}
if ([string]::IsNullOrEmpty($depthError)) {
    $failClosedRegressions.Add('32-record exhaustion before inspected wininit.exe was accepted')
}

$bypassInvocations = [System.Collections.Generic.List[object]]::new()
try {
    $null = & $devPath -Task doctor -ProcessAncestry @('powershell.exe', 'wininit.exe') -IsWindows $true `
        -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
        -CommandResolver (New-CommandResolver (New-NativeToolFixture)) `
        -CommandRunner (New-CommandRunner $bypassInvocations)
    $bypassError = ''
}
catch {
    $bypassError = $_.Exception.Message
}
if ([string]::IsNullOrEmpty($bypassError)) {
    $failClosedRegressions.Add('direct ProcessAncestry list bypass was accepted')
}

$launchFixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("doppelbanger-native-launch-{0}" -f [guid]::NewGuid().ToString('N'))
$hadLastExitCode = Test-Path -LiteralPath 'variable:global:LASTEXITCODE'
$savedLastExitCode = $global:LASTEXITCODE
try {
    $null = New-Item -ItemType Directory -Path $launchFixtureRoot
    $unstartableCargoPath = Join-Path $launchFixtureRoot 'cargo.exe'
    [System.IO.File]::WriteAllBytes($unstartableCargoPath, [byte[]]@())
    $nativeLaunchTools = New-NativeToolFixture
    $nativeLaunchTools.rustc = (Get-Command -Name rustc -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $nativeLaunchTools.cargo = $unstartableCargoPath
    $nativeLaunchFixture = New-ProcessFixture
    $global:LASTEXITCODE = 0
    try {
        $null = & $devPath -Task test -IsWindows $true `
            -ProcessLookup $nativeLaunchFixture.Lookup `
            -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
            -CommandResolver (New-CommandResolver $nativeLaunchTools)
        $nativeLaunchError = ''
    }
    catch {
        $nativeLaunchError = $_.Exception.Message
    }
    if ([string]::IsNullOrEmpty($nativeLaunchError)) {
        $failClosedRegressions.Add('unstartable native cargo inherited seeded LASTEXITCODE 0')
    }
}
finally {
    if ($hadLastExitCode) { $global:LASTEXITCODE = $savedLastExitCode } else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $launchFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failClosedRegressions.Count -gt 0) {
    throw "ASSERTION FAILED: dispatcher fail-closed regressions:`n - $($failClosedRegressions -join "`n - ")"
}
Assert-Contains $pidZeroError 'DBDEV_WSL_FORBIDDEN' 'doctor fails closed when PID reaches zero before wininit.exe'
Assert-True ($pidZeroInvocations.Count -eq 0) 'PID-zero ancestry does not invoke tools'
Assert-Contains $depthError 'DBDEV_WSL_FORBIDDEN' 'doctor fails closed when ancestry depth is exhausted before wininit.exe'
Assert-True ($depthInvocations.Count -eq 0) 'depth-exhausted ancestry does not invoke tools'
Assert-Contains $bypassError 'ProcessAncestry' 'doctor exposes no direct ancestry-list bypass parameter'
Assert-True ($bypassInvocations.Count -eq 0) 'rejected ancestry-list bypass does not invoke tools'
Assert-Contains $nativeLaunchError 'DBDEV_TASK_FAILED' 'an unstartable native tool fails with the stable task code'

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
Assert-True ($nativeRootInvocations.Count -eq 3) 'native wininit-root ancestry probes Rust, Node, and npm versions'

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
$automaticProcessFixture = New-ProcessFixture -Names @('powershell.exe', 'wininit.exe')
$lookupInvocations = [System.Collections.Generic.List[object]]::new()
try {
    $null = & $devPath -Task doctor -IsWindows $true `
        -ProcessLookup $automaticProcessFixture.Lookup `
        -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
        -CommandResolver (New-CommandResolver (New-NativeToolFixture)) `
        -CommandRunner (New-CommandRunner $lookupInvocations)
    $processLookupError = ''
}
catch {
    $processLookupError = $_.Exception.Message
}
Assert-True ([string]::IsNullOrEmpty($processLookupError) -and $PID -eq $pidBeforeProcessLookup) "doctor accepts an injected native process lookup without overwriting the automatic process identifier ($processLookupError)"
Assert-Equal (($automaticProcessFixture.Lookups | ForEach-Object { [string]$_ }) -join ',') (($automaticProcessFixture.ProcessIds | ForEach-Object { [string]$_ }) -join ',') 'doctor inspects the complete native chain from the automatic process identifier through wininit.exe'
Assert-True ($lookupInvocations.Count -eq 3) 'complete injected native ancestry probes Rust, Node, and npm versions'

$missingTools = New-NativeToolFixture
$missingTools.Remove('cl')
$missingToolResult = Invoke-DevFixture -Task doctor -Tools $missingTools
Assert-Contains $missingToolResult.Error 'DBDEV_TOOL_MISSING' 'doctor reports a missing native tool with a stable code'

$wrongPlatformResult = Invoke-DevFixture -Task doctor -IsWindows $false
Assert-Contains $wrongPlatformResult.Error 'DBDEV_WINDOWS_REQUIRED' 'doctor rejects a non-Windows process with a stable code'

$wrongHostTools = New-NativeToolFixture
$wrongHostInvocations = [System.Collections.Generic.List[object]]::new()
$wrongHostProcessFixture = New-ProcessFixture
try {
    $null = & $devPath -Task doctor -ProcessLookup $wrongHostProcessFixture.Lookup -IsWindows $true `
        -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
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
$nonzeroProcessFixture = New-ProcessFixture
try {
    & $devPath -Task test -ProcessLookup $nonzeroProcessFixture.Lookup -IsWindows $true `
        -PlatformLookup (New-PlatformLookup (New-PlatformFixture)) `
        -CommandResolver (New-CommandResolver (New-NativeToolFixture)) `
        -CommandRunner {
            param([string]$Path, [string[]]$Arguments)
            $nonzeroRunnerInvocations.Add([pscustomobject]@{ Path = $Path; Arguments = @($Arguments) })
            if ($Path.EndsWith('rustc.exe', [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Output = "rustc 1.97.1`nhost: x86_64-pc-windows-msvc"; ExitCode = 0 }
            }
            if ($Path.EndsWith('node.exe', [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Output = 'v24.18.1'; ExitCode = 0 }
            }
            if ($Path.EndsWith('npm.cmd', [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Output = '11.16.0'; ExitCode = 0 }
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
Assert-True ($nonzeroRunnerInvocations.Count -eq 4) 'the dispatcher stops after the first nonzero task process result'

foreach ($task in @('format', 'test', 'configure', 'build', 'validate')) {
    $result = Invoke-DevFixture -Task $task
    Assert-True ([string]::IsNullOrEmpty($result.Error)) "$task succeeds with checked native tools"
    Assert-True ($result.Invocations.Count -gt 0) "$task delegates to a checked executable"
    foreach ($invocation in $result.Invocations) {
        Assert-True ($invocation.Path -match '^C:\\doppelbanger-test-tools\\.+\.(?:exe|cmd)$') "$task delegates only to checked native executables"
    }
}

$uiTestResult = Invoke-DevFixture -Task ui-test
$uiTestNpmInvocations = @($uiTestResult.Invocations | Where-Object { $_.Path.EndsWith('npm.cmd', [StringComparison]::OrdinalIgnoreCase) })
Assert-True ([string]::IsNullOrEmpty($uiTestResult.Error)) 'ui-test succeeds with checked native tools'
Assert-Equal $uiTestNpmInvocations.Count 2 'ui-test verifies npm and then runs the editor check'
Assert-ArgumentVector $uiTestNpmInvocations[0] @('--version') 'ui-test verifies the exact checked npm executable'
Assert-ArgumentVector $uiTestNpmInvocations[1] @('run', 'check') 'ui-test routes only the checked npm executable to the editor check'
Assert-Equal $uiTestNpmInvocations[1].WorkingDirectory (Join-Path $repoRoot 'plugin\ui') 'ui-test runs the editor check from plugin/ui'
$uiTestNodeInvocations = @($uiTestResult.Invocations | Where-Object { $_.Path.EndsWith('node.exe', [StringComparison]::OrdinalIgnoreCase) })
Assert-Equal $uiTestNodeInvocations.Count 1 'ui-test verifies the exact checked native Node executable'
Assert-ArgumentVector $uiTestNodeInvocations[0] @('--version') 'ui-test verifies the required Node version'

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
