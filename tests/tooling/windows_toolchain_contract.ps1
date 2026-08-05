[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$doctorPath = Join-Path $repoRoot 'scripts\doctor_windows.ps1'
$wrapperPath = Join-Path $repoRoot 'scripts\run_native_tool.ps1'
$lockPath = Join-Path $repoRoot 'tools\windows-toolchain.lock.json'
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'
$powerShellHost = (Get-Process -Id $PID).Path

$missing = @($doctorPath, $wrapperPath, $lockPath) | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
if ($missing.Count -gt 0) {
    throw "RED: missing production contract files: $($missing -join ', ')"
}

. $doctorPath -LockPath $lockPath -NoRun

$script:passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:passed++
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -cne [string]$Expected) {
        throw "ASSERTION FAILED: $Message (expected '$Expected', got '$Actual')"
    }
    $script:passed++
}

function Assert-Code {
    param($Result, [string]$Code)
    Assert-True ($Result.Errors.Code -contains $Code) "expected diagnostic code $Code"
}

function Read-Fixture {
    param([string]$Name)
    $path = Join-Path $fixtureRoot $Name
    $overlay = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if (-not $overlay.extends) { return $overlay }
    $base = Get-Content -LiteralPath (Join-Path $fixtureRoot $overlay.extends) -Raw | ConvertFrom-Json
    foreach ($property in $overlay.PSObject.Properties) {
        if ($property.Name -notin @('extends', 'expected_code')) {
            $base | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
    }
    $base | Add-Member -NotePropertyName expected_code -NotePropertyValue $overlay.expected_code -Force
    return $base
}

function Invoke-Describe {
    param([string]$FixturePath, [string]$Tool = 'cmake')
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $powerShellHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wrapperPath -Describe -Tool $Tool -ProbePath $FixturePath -LockPath $lockPath 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    return [pscustomobject]@{ ExitCode = $code; Text = ($lines -join [Environment]::NewLine) }
}

function Invoke-InjectedExecution {
    param([string]$FixturePath)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $powerShellHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wrapperPath -Tool cmake -ProbePath $FixturePath -LockPath $lockPath 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    return [pscustomobject]@{ ExitCode = $code; Text = ($lines -join [Environment]::NewLine) }
}

function Write-Variant {
    param([scriptblock]$Mutate)
    $probe = Read-Fixture 'windows-native-valid.json'
    & $Mutate $probe
    $path = Join-Path $script:testTemp ("probe-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    $probe | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

$lock = Read-ToolchainLock -Path $lockPath
Assert-Equal $lock.rust.toolchain '1.97.1' 'Rust toolchain is pinned'
Assert-Equal $lock.rust.target 'x86_64-pc-windows-msvc' 'Rust target is MSVC x64'
Assert-Equal ($lock.rust.components -join ',') 'rustfmt,clippy' 'Rust components are pinned'
Assert-Equal $lock.node.version '24.19.0' 'Node is pinned'
Assert-Equal $lock.node.npm_version '11.17.0' 'npm is pinned'
Assert-Equal $lock.docker.compose_version '5.3.1' 'Compose is pinned'
Assert-Equal $lock.wsl.minimum_version '2.1.5' 'minimum WSL version is recorded'
Assert-Equal (Get-NormalizedSemanticVersion 'Docker version 29.6.2, build deadbeef') '29.6.2' 'Docker CLI version is available while its server is stopped'
Assert-Equal (Get-NormalizedSemanticVersion 'Docker Compose version v2.39.4-desktop.1') '2.39.4' 'Compose desktop suffix is normalized'
Assert-Equal (Get-FourthVersionComponent '4.46.0.204649') '204649' 'Docker Desktop build is read from executable metadata'

$validProbe = Read-Fixture 'windows-native-valid.json'
$valid = Test-NativeWindowsProbe -Probe $validProbe -Lock $lock -Profile HeadlessVst3
Assert-True $valid.Success 'native Windows fixture passes'
Assert-Equal $valid.Errors.Count 0 'valid fixture has no errors'

$oldWslProbe = Read-Fixture 'windows-native-valid.json'
$oldWslProbe.wsl_version = '2.0.0'
$oldWsl = Test-NativeWindowsProbe -Probe $oldWslProbe -Lock $lock -Profile HeadlessVst3
Assert-Code $oldWsl 'DBDOC_TOOL_VERSION_DRIFT'

$badComposeConfigProbe = Read-Fixture 'windows-native-valid.json'
$badComposeConfigProbe.docker_compose_config_valid = $false
$badComposeConfig = Test-NativeWindowsProbe -Probe $badComposeConfigProbe -Lock $lock -Profile HeadlessVst3
Assert-Code $badComposeConfig 'DBDOC_COMPOSE_CONFIG_INVALID'

$ambientShadowProbe = Read-Fixture 'windows-native-valid.json'
($ambientShadowProbe.binaries | Where-Object name -eq 'cmake').ambient_path = 'C:\shadow\cmake.exe'
$ambientShadow = Test-NativeWindowsProbe -Probe $ambientShadowProbe -Lock $lock -Profile HeadlessVst3
Assert-Code $ambientShadow 'DBDOC_TOOL_PATH_SHADOW'

foreach ($fixtureName in @(
    'windows-wsl-invalid.json',
    'windows-wsl-parent-invalid.json',
    'windows-compose-shadow-invalid.json',
    'windows-version-drift-invalid.json'
)) {
    $probe = Read-Fixture $fixtureName
    $result = Test-NativeWindowsProbe -Probe $probe -Lock $lock -Profile HeadlessVst3
    Assert-True (-not $result.Success) "$fixtureName fails"
    Assert-Code $result $probe.expected_code
}

$testTemp = Join-Path ([IO.Path]::GetTempPath()) ("doppelbanger-tooling-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testTemp | Out-Null
$script:testTemp = $testTemp
try {
    $validFixture = Join-Path $fixtureRoot 'windows-native-valid.json'
    $describe = Invoke-Describe -FixturePath $validFixture
    Assert-Equal $describe.ExitCode 0 '-Describe accepts the locked native fixture'
    $description = $describe.Text | ConvertFrom-Json
    Assert-Equal $description.tool 'cmake' '-Describe reports requested tool'
    Assert-Equal $description.resolved_path 'C:\DoppelbangerToolchain\cmake-4.4.2-windows-x86_64\bin\cmake.exe' '-Describe reports locked path'
    Assert-Equal $description.environment.WindowsSdkDir 'C:\Program Files (x86)\Windows Kits\10\' '-Describe reports imported SDK environment'

    $injectedExecution = Invoke-InjectedExecution -FixturePath $validFixture
    Assert-True ($injectedExecution.ExitCode -ne 0) 'injected probes can never launch tools'
    Assert-True ($injectedExecution.Text -match 'DBDOC_PROBE_EXECUTION_FORBIDDEN') 'injected execution rejection has a stable code'

    $ancestry = Invoke-Describe -FixturePath (Join-Path $fixtureRoot 'windows-wsl-parent-invalid.json')
    Assert-True ($ancestry.ExitCode -ne 0) '-Describe rejects WSL ancestry'
    Assert-True ($ancestry.Text -match 'DBDOC_WSL_FORBIDDEN') 'WSL ancestry has stable code'

    foreach ($tool in @('cmake', 'ninja', 'docker')) {
        $shadowPath = Write-Variant { param($p) ($p.binaries | Where-Object name -eq $tool).ambient_path = "C:\shadow\$tool.exe" }
        $shadow = Invoke-Describe -FixturePath $shadowPath -Tool $tool
        Assert-True ($shadow.ExitCode -ne 0) "$tool ambient shadow is rejected"
        Assert-True ($shadow.Text -match 'DBDOC_TOOL_PATH_SHADOW') "$tool shadow has stable code"
    }

    $compose = Invoke-Describe -FixturePath (Join-Path $fixtureRoot 'windows-compose-shadow-invalid.json') -Tool docker
    Assert-True ($compose.ExitCode -ne 0) 'Docker describe rechecks user Compose shadow'
    Assert-True ($compose.Text -match 'DBDOC_DOCKER_PLUGIN_SHADOW') 'Compose shadow has stable code'

    $nonPePath = Write-Variant { param($p) ($p.binaries | Where-Object name -eq 'cmake').pe_format = 'ELF64' }
    $nonPe = Invoke-Describe -FixturePath $nonPePath
    Assert-True ($nonPe.ExitCode -ne 0) '-Describe rejects non-PE tools'
    Assert-True ($nonPe.Text -match 'DBDOC_BINARY_NOT_PE') 'non-PE rejection has stable code'

    $wrongVsPath = Write-Variant { param($p) $p.vs_installation_version = '17.13.99999.0' }
    $wrongVs = Invoke-Describe -FixturePath $wrongVsPath
    Assert-True ($wrongVs.ExitCode -ne 0) '-Describe rejects wrong VS instance'
    Assert-True ($wrongVs.Text -match 'DBDOC_TOOL_VERSION_DRIFT') 'wrong VS has stable version code'

    foreach ($field in @('include', 'lib', 'windows_sdk_dir')) {
        $missingEnvPath = Write-Variant { param($p) $p.vsdevcmd.$field = '' }
        $missingEnv = Invoke-Describe -FixturePath $missingEnvPath
        Assert-True ($missingEnv.ExitCode -ne 0) "-Describe rejects missing $field after VsDevCmd"
        Assert-True ($missingEnv.Text -match 'DBDOC_VS_ENV_INCOMPLETE') "missing $field has stable code"
    }

    $reportPath = Join-Path $testTemp 'doctor.json'
    $reportJson = Write-DoctorReport -Result $valid -Json
    Assert-True (-not (Test-Path -LiteralPath $reportPath)) 'report is not written without ReportPath'
    Assert-True (($reportJson | ConvertFrom-Json).success) 'JSON report is returned in memory'
    Write-DoctorReport -Result $valid -Json -ReportPath $reportPath | Out-Null
    Assert-True (Test-Path -LiteralPath $reportPath -PathType Leaf) 'explicit ReportPath is written'
}
finally {
    if (Test-Path -LiteralPath $testTemp) { Remove-Item -LiteralPath $testTemp -Recurse -Force }
}

Write-Host "PASS: $script:passed Windows toolchain contract assertions"
