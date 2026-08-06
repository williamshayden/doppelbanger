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
    if (-not $overlay.extends) { return (Expand-ProbePaths -Probe $overlay) }
    $base = Get-Content -LiteralPath (Join-Path $fixtureRoot $overlay.extends) -Raw | ConvertFrom-Json
    foreach ($property in $overlay.PSObject.Properties) {
        if ($property.Name -notin @('extends', 'expected_code')) {
            $base | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
    }
    $base | Add-Member -NotePropertyName expected_code -NotePropertyValue $overlay.expected_code -Force
    return (Expand-ProbePaths -Probe $base)
}

function Invoke-WrapperCase {
    param([string[]]$ArgumentList)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $powerShellHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wrapperPath @ArgumentList 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    return [pscustomobject]@{ ExitCode = $code; Text = ($lines -join [Environment]::NewLine) }
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

function Invoke-DoctorCase {
    param([string[]]$ArgumentList)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $powerShellHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $doctorPath @ArgumentList 2>&1
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
Assert-Equal $lock.toolchain_root '%LOCALAPPDATA%\Programs\doppelbanger-devtools' 'approved per-user devtools root is locked'
Assert-Equal $lock.rust.toolchain_directory '1.97.1-x86_64-pc-windows-msvc' 'physical Rust toolchain directory is locked'
Assert-Equal $lock.validators.pluginval_root '%LOCALAPPDATA%\Programs\doppelbanger-devtools\pluginval-1.0.4' 'pluginval uses approved versioned root'
Assert-Equal (Expand-LockedPath -Path $lock.cmake.root) (Join-Path $env:LOCALAPPDATA 'Programs\doppelbanger-devtools\cmake-4.4.2-windows-x86_64') 'environment-variable root expands canonically'
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

$metadataOnlyValidProbe = Read-Fixture 'windows-native-valid.json'
$metadataOnlyValidProbe | Add-Member -NotePropertyName metadata_only -NotePropertyValue $true -Force
$metadataOnlyValidProbe.docker_engine_version = ''
$metadataOnlyValidProbe.docker_context = ''
$metadataOnlyValidProbe.docker_server_os = ''
$metadataOnlyValidProbe.docker_server_arch = ''
$metadataOnlyValidProbe.docker_running = $false
$metadataOnlyValidProbe.docker_compose_config_valid = $false
$metadataOnlyValid = Test-NativeWindowsProbe -Probe $metadataOnlyValidProbe -Lock $lock -Profile HeadlessVst3
Assert-True $metadataOnlyValid.Success 'metadata-only validation ignores intentionally absent Docker runtime fields'
Assert-Equal $metadataOnlyValid.Errors.Count 0 'metadata-only fixture has no Docker runtime errors'

$metadataLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$metadataLock.rust.toolchain_directory = 'intentionally-missing-rust-toolchain'
$script:recordedLaunches = New-Object 'Collections.Generic.List[string]'
$recordingRunner = { param($Path, $Arguments) $script:recordedLaunches.Add("$Path $($Arguments -join ' ')"); return '' }
$metadataProbe = Get-NativeWindowsProbe -Lock $metadataLock -RepoRoot $repoRoot -MetadataOnly -CommandRunner $recordingRunner
Assert-Equal $script:recordedLaunches.Count 0 'metadata-only discovery never launches a rustup proxy or any tool'
Assert-True (@($metadataProbe.binaries | Where-Object { $_.path -match '\\.cargo\\bin' }).Count -eq 0) 'Rust discovery never resolves cargo-home proxy binaries'

foreach ($componentFixture in @('windows-cargo-missing-invalid.json', 'windows-rustfmt-missing-invalid.json', 'windows-clippy-missing-invalid.json')) {
    $componentProbe = Read-Fixture $componentFixture
    $componentResult = Test-NativeWindowsProbe -Probe $componentProbe -Lock $lock -Profile HeadlessVst3
    Assert-Code $componentResult 'DBDOC_RUST_COMPONENT_MISSING'
}

$ownerMismatchProbe = Read-Fixture 'windows-native-valid.json'
$ownerMismatchProbe.repo_owner_sid = 'S-1-5-21-9999-9999-9999-1002'
Assert-Code (Test-NativeWindowsProbe -Probe $ownerMismatchProbe -Lock $lock -Profile HeadlessVst3) 'DBDOC_GIT_OWNERSHIP_INVALID'

foreach ($missingSid in @('current_user_sid', 'repo_owner_sid')) {
    $missingOwnerProbe = Read-Fixture 'windows-native-valid.json'
    $missingOwnerProbe.$missingSid = ''
    Assert-Code (Test-NativeWindowsProbe -Probe $missingOwnerProbe -Lock $lock -Profile HeadlessVst3) 'DBDOC_GIT_OWNERSHIP_INVALID'
}

$missingAbletonPathOne = Join-Path $repoRoot 'var\never-created-ableton-one'
$missingAbletonPathTwo = Join-Path $repoRoot 'var\never-created-ableton-two'
Assert-True (-not (Test-AbletonPresent -CandidatePaths @($missingAbletonPathOne, $missingAbletonPathTwo))) 'Ableton detection filters every missing candidate path'
$missingAbletonProbe = Read-Fixture 'windows-native-valid.json'
$missingAbletonProbe.ableton_present = $false
$missingAbletonResult = Test-NativeWindowsProbe -Probe $missingAbletonProbe -Lock $lock -Profile HeadlessVst3
Assert-Equal $missingAbletonResult.Warnings.Count 1 'missing Ableton adds only one warning to an otherwise valid probe'
Assert-True ($missingAbletonResult.Warnings.Code -contains 'DBDOC_ABLETON_NOT_FOUND') 'missing Ableton warning has a stable code'

foreach ($dockerArguments in @(
    @( '--config', 'C:\shadow' ), @( '--config=C:\shadow' ),
    @( '--context', 'shadow' ), @( '--context=shadow' ), @( '-c', 'shadow' ), @( '-c=shadow' ), @( '-cshadow' ),
    @( '--host', 'tcp://shadow' ), @( '--host=tcp://shadow' ), @( '-H', 'tcp://shadow' ), @( '-H=tcp://shadow' ), @( '-Htcp://shadow' )
)) {
    $overrideRejected = $false
    try { Assert-DockerInvocationArguments -Arguments $dockerArguments }
    catch { $overrideRejected = $_.Exception.Message -match 'DBDOC_DOCKER_PROVENANCE_OVERRIDE_FORBIDDEN' }
    Assert-True $overrideRejected "Docker provenance override is rejected: $($dockerArguments -join ' ')"
}
Assert-DockerInvocationArguments -Arguments @('build', '--pull', '.')
Assert-True $true 'ordinary Docker subcommand arguments remain allowed'

$safeDirectoryProbe = Read-Fixture 'windows-native-valid.json'
$safeDirectoryProbe.git_global_safe_directories = @('*')
Assert-Code (Test-NativeWindowsProbe -Probe $safeDirectoryProbe -Lock $lock -Profile HeadlessVst3) 'DBDOC_GIT_SAFE_DIRECTORY_BYPASS'

$failedGitInspectionProbe = Read-Fixture 'windows-native-valid.json'
$failedGitInspectionProbe.git_global_safe_directory_inspection_valid = $false
$failedGitInspectionProbe.git_global_safe_directory_inspection_error = 'simulated read failure'
Assert-Code (Test-NativeWindowsProbe -Probe $failedGitInspectionProbe -Lock $lock -Profile HeadlessVst3) 'DBDOC_GIT_CONFIG_INSPECTION_FAILED'

foreach ($requiredMsvcTool in @('cl', 'link', 'lib', 'dumpbin')) {
    $missingMsvcProbe = Read-Fixture 'windows-native-valid.json'
    $missingMsvcProbe.binaries = @($missingMsvcProbe.binaries | Where-Object { $_.name -cne $requiredMsvcTool })
    Assert-Code (Test-NativeWindowsProbe -Probe $missingMsvcProbe -Lock $lock -Profile HeadlessVst3) 'DBDOC_TOOL_MISSING'
}

$compatProbe = Read-Fixture 'windows-native-valid.json'
$compatProbe.compiler_version = '19.43.34810'
$compatResult = Test-NativeWindowsProbe -Probe $compatProbe -Lock $lock -Profile Compatibility
Assert-True $compatResult.Success 'Compatibility warns for MSVC version drift'
Assert-True ($compatResult.Warnings.Code -contains 'DBDOC_TOOL_VERSION_DRIFT') 'Compatibility records MSVC version warning'

$gnuProbe = Read-Fixture 'windows-native-valid.json'
$gnuProbe.compiler = 'GNU'
$gnuProbe.compiler_version = '13.2.0'
Assert-Code (Test-NativeWindowsProbe -Probe $gnuProbe -Lock $lock -Profile Compatibility) 'DBDOC_COMPILER_FORBIDDEN'

$unknownWslProbe = Read-Fixture 'windows-native-valid.json'
$unknownWslProbe.wsl_present = $true
$unknownWslProbe.wsl_version = ''
Assert-Code (Test-NativeWindowsProbe -Probe $unknownWslProbe -Lock $lock -Profile HeadlessVst3) 'DBDOC_WSL_VERSION_UNKNOWN'

$wrongSdkProbe = Read-Fixture 'windows-native-valid.json'
$wrongSdkProbe.vsdevcmd.windows_sdk_version = '10.0.22621.0\'
$wrongSdkProbe.vsdevcmd.include = 'C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0'
$wrongSdkProbe.vsdevcmd.lib = 'C:\Program Files (x86)\Windows Kits\10\Lib\10.0.22621.0'
Assert-Code (Test-NativeWindowsProbe -Probe $wrongSdkProbe -Lock $lock -Profile HeadlessVst3) 'DBDOC_WINDOWS_SDK_DRIFT'

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
    'windows-compose-extra-dir-shadow-invalid.json',
    'windows-cargo-missing-invalid.json',
    'windows-rustfmt-missing-invalid.json',
    'windows-clippy-missing-invalid.json',
    'windows-version-drift-invalid.json'
)) {
    $probe = Read-Fixture $fixtureName
    $result = Test-NativeWindowsProbe -Probe $probe -Lock $lock -Profile HeadlessVst3
    Assert-True (-not $result.Success) "$fixtureName fails"
    Assert-Code $result $probe.expected_code
}

$varRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'var'))
$testTemp = Join-Path $varRoot ("tooling-contract-{0}" -f [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testTemp) | Out-Null
$script:testTemp = $testTemp
try {
    $absentGlobalConfig = Join-Path $testTemp 'absent-global.gitconfig'
    $absentGitInspection = Get-GlobalSafeDirectoryInspection -RootFile $absentGlobalConfig
    Assert-True $absentGitInspection.inspection_valid 'absent global Git config is a valid empty inspection'
    Assert-Equal $absentGitInspection.entries.Count 0 'absent global Git config has no safe.directory entries'

    $xdgUserProfile = Join-Path $testTemp 'xdg-user-profile'
    $xdgConfigHome = Join-Path $testTemp 'xdg-config-home'
    $xdgGitDirectory = Join-Path $xdgConfigHome 'git'
    [IO.Directory]::CreateDirectory($xdgUserProfile) | Out-Null
    [IO.Directory]::CreateDirectory($xdgGitDirectory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $xdgGitDirectory 'config'), "[safe]`ndirectory = *`n")
    $savedUserProfile = $env:USERPROFILE
    $savedXdgConfigHome = $env:XDG_CONFIG_HOME
    $savedGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
    try {
        [Environment]::SetEnvironmentVariable('USERPROFILE', $xdgUserProfile, 'Process')
        [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $xdgConfigHome, 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $null, 'Process')
        $xdgGitInspection = Get-GlobalSafeDirectoryInspection
    }
    finally {
        [Environment]::SetEnvironmentVariable('USERPROFILE', $savedUserProfile, 'Process')
        [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $savedXdgConfigHome, 'Process')
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $savedGitConfigGlobal, 'Process')
    }
    Assert-True $xdgGitInspection.inspection_valid 'XDG Git config inspection is valid when home config is absent'
    Assert-Equal $xdgGitInspection.entries.Count 1 'XDG Git config contributes one safe.directory entry'
    Assert-Equal $xdgGitInspection.entries[0] '*' 'XDG safe.directory is visible when home config is absent'

    $directoryGlobalConfig = Join-Path $testTemp 'directory-global.gitconfig'
    [IO.Directory]::CreateDirectory($directoryGlobalConfig) | Out-Null
    $directoryGitInspection = Get-GlobalSafeDirectoryInspection -RootFile $directoryGlobalConfig
    Assert-True (-not $directoryGitInspection.inspection_valid) 'existing non-file global Git config path fails inspection closed'

    $knownGlobalConfig = Join-Path $testTemp 'known-global.gitconfig'
    [IO.File]::WriteAllText($knownGlobalConfig, "[safe]`ndirectory = `"$repoRoot`"`n")
    $knownGitInspection = Get-GlobalSafeDirectoryInspection -RootFile $knownGlobalConfig
    Assert-True $knownGitInspection.inspection_valid 'known global Git config parses successfully'
    Assert-Equal $knownGitInspection.entries.Count 1 'known global Git config exposes one safe.directory entry'
    Assert-Equal $knownGitInspection.entries[0] $repoRoot 'known safe.directory value is preserved'

    $readerFailureConfig = Join-Path $testTemp 'reader-failure.gitconfig'
    [IO.File]::WriteAllText($readerFailureConfig, "[safe]`ndirectory = C:\\should-not-be-read`n")
    $readerFailureInspection = Get-GlobalSafeDirectoryInspection -RootFile $readerFailureConfig -ContentReader { param($Path) throw 'simulated access failure' }
    Assert-True (-not $readerFailureInspection.inspection_valid) 'global Git config reader exception fails inspection closed'
    Assert-True (-not [string]::IsNullOrWhiteSpace($readerFailureInspection.error)) 'global Git config reader exception records an error'

    $malformedGlobalConfig = Join-Path $testTemp 'malformed-global.gitconfig'
    [IO.File]::WriteAllText($malformedGlobalConfig, "[safe`ndirectory = *`n")
    $malformedGitInspection = Get-GlobalSafeDirectoryInspection -RootFile $malformedGlobalConfig
    Assert-True (-not $malformedGitInspection.inspection_valid) 'malformed global Git config fails inspection closed'

    $missingIncludeConfig = Join-Path $testTemp 'missing-include-global.gitconfig'
    [IO.File]::WriteAllText($missingIncludeConfig, "[include]`npath = missing-declared-include.gitconfig`n")
    $missingIncludeInspection = Get-GlobalSafeDirectoryInspection -RootFile $missingIncludeConfig
    Assert-True (-not $missingIncludeInspection.inspection_valid) 'missing declared Git config include fails inspection closed'

    $cycleConfigOne = Join-Path $testTemp 'cycle-one.gitconfig'
    $cycleConfigTwo = Join-Path $testTemp 'cycle-two.gitconfig'
    [IO.File]::WriteAllText($cycleConfigOne, "[include]`npath = cycle-two.gitconfig`n")
    [IO.File]::WriteAllText($cycleConfigTwo, "[include]`npath = cycle-one.gitconfig`n")
    $cycleInspection = Get-GlobalSafeDirectoryInspection -RootFile $cycleConfigOne
    Assert-True (-not $cycleInspection.inspection_valid) 'global Git config include cycle fails inspection closed'

    $fakeRustupHome = Join-Path $testTemp 'rustup-home'
    $fakeRustRoot = Join-Path $fakeRustupHome "toolchains\$($lock.rust.toolchain_directory)"
    $fakeRustlib = Join-Path $fakeRustRoot 'lib\rustlib'
    $fakeRustBin = Join-Path $fakeRustRoot 'bin'
    [IO.Directory]::CreateDirectory($fakeRustlib) | Out-Null
    [IO.Directory]::CreateDirectory($fakeRustBin) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeRustlib 'rust-installer-version'), '3')
    $validRustChannelManifest = "manifest-version = '2'`n[pkg.cargo]`nversion = '9.99.9 (misleading earlier package)'`n[pkg.rustc]`nversion = '1.97.1 (fake provenance)'`n"
    [IO.File]::WriteAllText((Join-Path $fakeRustlib 'multirust-channel-manifest.toml'), $validRustChannelManifest)
    [IO.File]::WriteAllText((Join-Path $fakeRustlib 'multirust-config.toml'), "[components]`n")
    $rustComponents = @(
        @{ Name = "rustc-$($lock.rust.target)"; Files = @('bin/rustc.exe') },
        @{ Name = "cargo-$($lock.rust.target)"; Files = @('bin/cargo.exe') },
        @{ Name = "rustfmt-preview-$($lock.rust.target)"; Files = @('bin/rustfmt.exe') },
        @{ Name = "clippy-preview-$($lock.rust.target)"; Files = @('bin/clippy-driver.exe', 'bin/cargo-clippy.exe') }
    )
    [IO.File]::WriteAllLines((Join-Path $fakeRustlib 'components'), @($rustComponents.Name))
    foreach ($component in $rustComponents) {
        foreach ($relativeFile in $component.Files) {
            [IO.File]::WriteAllText((Join-Path $fakeRustRoot ($relativeFile -replace '/', '\')), 'physical test executable')
        }
        [IO.File]::WriteAllLines((Join-Path $fakeRustlib "manifest-$($component.Name)"), @($component.Files | ForEach-Object { "file:$_" }))
    }
    $rustMetadata = Get-RustToolchainMetadata -Lock $lock -RustupHome $fakeRustupHome
    Assert-True $rustMetadata.base_valid 'exact Rust installer and channel metadata is accepted'
    Assert-True $rustMetadata.cargo 'Cargo component owns a physical cargo.exe in the exact toolchain'
    [IO.File]::WriteAllText((Join-Path $fakeRustlib 'rust-installer-version'), 'malformed')
    Assert-True (-not (Get-RustToolchainMetadata -Lock $lock -RustupHome $fakeRustupHome).base_valid) 'malformed rust-installer-version fails closed'
    [IO.File]::WriteAllText((Join-Path $fakeRustlib 'rust-installer-version'), '3')
    [IO.File]::WriteAllText((Join-Path $fakeRustlib 'multirust-channel-manifest.toml'), "manifest-version = '2'`n[pkg.cargo]`nversion = '1.97.1 (misleading locked version)'`n[pkg.rustc]`nversion = '1.96.0 (wrong channel)'`n")
    Assert-True (-not (Get-RustToolchainMetadata -Lock $lock -RustupHome $fakeRustupHome).base_valid) 'mismatched channel manifest rustc version fails closed'
    [IO.File]::WriteAllText((Join-Path $fakeRustlib 'multirust-channel-manifest.toml'), $validRustChannelManifest)

    $fakeVsInstances = Join-Path $testTemp 'vs-instances'
    $fakeVsStateRoot = Join-Path $fakeVsInstances 'exact-instance'
    $fakeVsRoot = Join-Path $testTemp 'Microsoft Visual Studio\2022\BuildTools'
    $fakeToolsetVersion = '14.44.35207'
    $fakeToolsetRoot = Join-Path $fakeVsRoot "VC\Tools\MSVC\$fakeToolsetVersion"
    $fakeSdkRoot = Join-Path $testTemp 'Windows Kits\10'
    foreach ($directory in @(
        $fakeVsStateRoot,
        (Join-Path $fakeVsRoot 'Common7\Tools'),
        (Join-Path $fakeVsRoot 'VC\Auxiliary\Build'),
        (Join-Path $fakeToolsetRoot 'include'),
        (Join-Path $fakeToolsetRoot 'lib\x64'),
        (Join-Path $fakeToolsetRoot 'bin\Hostx64\x64'),
        (Join-Path $fakeSdkRoot "Include\$($lock.visual_studio.windows_sdk_target)\ucrt"),
        (Join-Path $fakeSdkRoot "Include\$($lock.visual_studio.windows_sdk_target)\shared"),
        (Join-Path $fakeSdkRoot "Include\$($lock.visual_studio.windows_sdk_target)\um"),
        (Join-Path $fakeSdkRoot "Include\$($lock.visual_studio.windows_sdk_target)\winrt"),
        (Join-Path $fakeSdkRoot "Include\$($lock.visual_studio.windows_sdk_target)\cppwinrt"),
        (Join-Path $fakeSdkRoot "Lib\$($lock.visual_studio.windows_sdk_target)\ucrt\x64"),
        (Join-Path $fakeSdkRoot "Lib\$($lock.visual_studio.windows_sdk_target)\um\x64")
    )) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $fakeVsRoot 'Common7\Tools\VsDevCmd.bat'), '@rem metadata only')
    [IO.File]::WriteAllText((Join-Path $fakeVsRoot 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'), $fakeToolsetVersion)
    [IO.File]::WriteAllText((Join-Path $fakeToolsetRoot 'bin\Hostx64\x64\cl.exe'), 'physical test executable')
    @{
        installationVersion = $lock.visual_studio.installation_version
        installationPath = $fakeVsRoot
        catalogInfo = @{ productDisplayVersion = $lock.visual_studio.product_version }
        packages = @($lock.visual_studio.msvc_component, $lock.visual_studio.windows_sdk_component)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fakeVsStateRoot 'state.json') -Encoding UTF8

    $savedVsEnvironment = @{}
    foreach ($name in @('INCLUDE', 'LIB', 'WindowsSdkDir', 'WindowsSDKVersion', 'VCToolsInstallDir')) {
        $savedVsEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, 'C:\stale-ambient', 'Process')
    }
    $script:metadataLayoutLaunches = 0
    try {
        $layoutProbe = Get-NativeWindowsProbe -Lock $lock -RepoRoot $repoRoot -MetadataOnly -MetadataPaths @{
            RustupHome = $fakeRustupHome
            VisualStudioInstancesRoot = $fakeVsInstances
            WindowsSdkRoot = $fakeSdkRoot
            AbletonRoots = @((Join-Path $testTemp 'missing-ableton-one'), (Join-Path $testTemp 'missing-ableton-two'))
        } -CommandRunner { param($Path, $Arguments) $script:metadataLayoutLaunches++; return '' }
    }
    finally {
        foreach ($name in $savedVsEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedVsEnvironment[$name], 'Process') }
    }
    Assert-Equal $script:metadataLayoutLaunches 0 'complete metadata-only layout never executes VsDevCmd or any tool'
    Assert-Equal $layoutProbe.vsdevcmd.path (Join-Path $fakeVsRoot 'Common7\Tools\VsDevCmd.bat') 'metadata-only probe describes exact VsDevCmd path'
    Assert-Equal $layoutProbe.vsdevcmd.import_args $lock.visual_studio.vsdevcmd_arguments 'metadata-only probe describes exact VsDevCmd arguments'
    Assert-Equal $layoutProbe.vsdevcmd.vctools_install_dir ($fakeToolsetRoot.TrimEnd('\') + '\') 'metadata-only probe derives exact VCToolsInstallDir'
    Assert-Equal $layoutProbe.vsdevcmd.windows_sdk_dir ($fakeSdkRoot.TrimEnd('\') + '\') 'metadata-only probe derives exact WindowsSdkDir'
    Assert-Equal $layoutProbe.vsdevcmd.windows_sdk_version ($lock.visual_studio.windows_sdk_target + '\') 'metadata-only probe derives exact WindowsSDKVersion'
    Assert-True (-not [string]::IsNullOrWhiteSpace($layoutProbe.vsdevcmd.include)) 'metadata-only probe derives nonempty INCLUDE'
    Assert-True (-not [string]::IsNullOrWhiteSpace($layoutProbe.vsdevcmd.lib)) 'metadata-only probe derives nonempty LIB'
    Assert-True ($layoutProbe.vsdevcmd.include -notmatch 'stale-ambient' -and $layoutProbe.vsdevcmd.lib -notmatch 'stale-ambient') 'metadata-only probe never copies ambient stale VS environment'
    Assert-True (-not $layoutProbe.ableton_present) 'metadata path injection reports missing Ableton when both candidates are absent'

    $missingProductInstances = Join-Path $testTemp 'vs-missing-product'
    $missingProductStateRoot = Join-Path $missingProductInstances 'instance'
    [IO.Directory]::CreateDirectory($missingProductStateRoot) | Out-Null
    @{
        installationVersion = $lock.visual_studio.installation_version
        installationPath = $fakeVsRoot
        catalogInfo = @{}
        packages = @($lock.visual_studio.msvc_component, $lock.visual_studio.windows_sdk_component)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $missingProductStateRoot 'state.json') -Encoding UTF8
    $missingProductVs = Get-VisualStudioProbe -Lock $lock -InstancesRoot $missingProductInstances -WindowsSdkRoot $fakeSdkRoot
    Assert-Equal $missingProductVs.product_version '' 'missing VS productDisplayVersion is not replaced with the lock value'

    $dockerConfigFixture = Join-Path $testTemp 'docker-config'
    $dockerExtraFixture = Join-Path $testTemp 'docker-extra'
    [IO.Directory]::CreateDirectory($dockerConfigFixture) | Out-Null
    [IO.Directory]::CreateDirectory($dockerExtraFixture) | Out-Null
    [IO.File]::WriteAllText((Join-Path $dockerExtraFixture 'docker-compose.exe'), 'recording proxy; never execute')
    @{ auths = @{} } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dockerConfigFixture 'config.json') -Encoding UTF8
    $previousDockerConfig = $env:DOCKER_CONFIG
    try {
        $env:DOCKER_CONFIG = $dockerConfigFixture
        $composeMetadataWithoutExtras = Get-DockerComposeMetadata -Lock $lock
        @{ auths = @{}; cliPluginsExtraDirs = @($dockerExtraFixture) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dockerConfigFixture 'config.json') -Encoding UTF8
        $composeMetadata = Get-DockerComposeMetadata -Lock $lock
    }
    finally { $env:DOCKER_CONFIG = $previousDockerConfig }
    Assert-True $composeMetadataWithoutExtras.config_valid 'Docker config without cliPluginsExtraDirs remains valid'
    Assert-True $composeMetadata.config_valid 'Docker config with absolute extra paths remains valid'
    Assert-Equal $composeMetadata.winner (Join-Path $dockerExtraFixture 'docker-compose.exe') 'first configured extra plugin directory wins before config and ProgramFiles'

    $validFixture = Join-Path $fixtureRoot 'windows-native-valid.json'
    $publicProbeReport = Join-Path $testTemp 'forged-doctor.json'
    $publicProbe = Invoke-DoctorCase @('-Profile', 'HeadlessVst3', '-Json', '-ProbePath', $validFixture, '-ReportPath', $publicProbeReport)
    Assert-True ($publicProbe.ExitCode -ne 0) 'public doctor rejects fixture injection'
    Assert-True ($publicProbe.Text -match 'DBDOC_PROBE_INJECTION_FORBIDDEN') 'public doctor probe rejection has a stable code'
    Assert-True (-not (Test-Path -LiteralPath $publicProbeReport)) 'public doctor cannot mint a report from injected evidence'

    $dockerOverrideDescribe = Invoke-WrapperCase @('-Describe', '-Tool', 'docker', '-ProbePath', $validFixture, '--config=C:\shadow')
    Assert-True ($dockerOverrideDescribe.ExitCode -ne 0) 'wrapper rejects Docker provenance arguments before any launch'
    Assert-True ($dockerOverrideDescribe.Text -match 'DBDOC_DOCKER_PROVENANCE_OVERRIDE_FORBIDDEN') 'wrapper Docker argument rejection has a stable code'

    $describe = Invoke-Describe -FixturePath $validFixture
    Assert-Equal $describe.ExitCode 0 '-Describe accepts the locked native fixture'
    $description = $describe.Text | ConvertFrom-Json
    Assert-Equal $description.tool 'cmake' '-Describe reports requested tool'
    Assert-Equal $description.resolved_path (Join-Path $env:LOCALAPPDATA 'Programs\doppelbanger-devtools\cmake-4.4.2-windows-x86_64\bin\cmake.exe') '-Describe reports expanded approved path'
    Assert-Equal $description.environment.WindowsSdkDir 'C:\Program Files (x86)\Windows Kits\10\' '-Describe reports imported SDK environment'
    Assert-Equal $description.vsdevcmd_path 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat' '-Describe reports exact VsDevCmd path'
    Assert-Equal $description.vsdevcmd_import_args $lock.visual_studio.vsdevcmd_arguments '-Describe reports exact VsDevCmd import arguments'

    $injectedExecution = Invoke-InjectedExecution -FixturePath $validFixture
    Assert-True ($injectedExecution.ExitCode -ne 0) 'injected probes can never launch tools'
    Assert-True ($injectedExecution.Text -match 'DBDOC_PROBE_EXECUTION_FORBIDDEN') 'injected execution rejection has a stable code'

    $alternateLock = Join-Path $testTemp 'alternate-lock.json'
    $lock | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $alternateLock -Encoding UTF8
    $allowedOverride = Invoke-WrapperCase @('-Describe', '-Tool', 'cmake', '-ProbePath', $validFixture, '-LockPath', $alternateLock)
    Assert-Equal $allowedOverride.ExitCode 0 'alternate lock is allowed only for injected Describe'
    $liveDescribeOverride = Invoke-WrapperCase @('-Describe', '-Tool', 'cmake', '-LockPath', $alternateLock)
    Assert-True ($liveDescribeOverride.ExitCode -ne 0) 'live Describe rejects alternate lock'
    Assert-True ($liveDescribeOverride.Text -match 'DBDOC_LOCK_OVERRIDE_FORBIDDEN') 'live Describe lock rejection has stable code'
    $liveExecutionOverride = Invoke-WrapperCase @('-Tool', 'cmake', '-LockPath', $alternateLock)
    Assert-True ($liveExecutionOverride.ExitCode -ne 0) 'live execution rejects alternate lock'
    Assert-True ($liveExecutionOverride.Text -match 'DBDOC_LOCK_OVERRIDE_FORBIDDEN') 'live execution lock rejection has stable code'

    $ancestry = Invoke-Describe -FixturePath (Join-Path $fixtureRoot 'windows-wsl-parent-invalid.json')
    Assert-True ($ancestry.ExitCode -ne 0) '-Describe rejects WSL ancestry'
    Assert-True ($ancestry.Text -match 'DBDOC_WSL_FORBIDDEN') 'WSL ancestry has stable code'

    foreach ($tool in @('cmake', 'ninja', 'docker', 'cl', 'link', 'lib', 'dumpbin')) {
        $shadowPath = Write-Variant { param($p) ($p.binaries | Where-Object name -eq $tool).ambient_path = "C:\shadow\$tool.exe" }
        $shadow = Invoke-Describe -FixturePath $shadowPath -Tool $tool
        Assert-True ($shadow.ExitCode -ne 0) "$tool ambient shadow is rejected"
        Assert-True ($shadow.Text -match 'DBDOC_TOOL_PATH_SHADOW') "$tool shadow has stable code"
    }

    foreach ($requiredMsvcTool in @('cl', 'link', 'lib', 'dumpbin')) {
        $missingMsvcPath = Write-Variant { param($p) $p.binaries = @($p.binaries | Where-Object { $_.name -cne $requiredMsvcTool }) }
        $missingMsvcDescribe = Invoke-Describe -FixturePath $missingMsvcPath -Tool $requiredMsvcTool
        Assert-True ($missingMsvcDescribe.ExitCode -ne 0) "-Describe rejects missing exact $requiredMsvcTool.exe"
        Assert-True ($missingMsvcDescribe.Text -match 'DBDOC_TOOL_MISSING') "missing $requiredMsvcTool.exe has a stable code"
    }

    $compose = Invoke-Describe -FixturePath (Join-Path $fixtureRoot 'windows-compose-shadow-invalid.json') -Tool docker
    Assert-True ($compose.ExitCode -ne 0) 'Docker describe rechecks user Compose shadow'
    Assert-True ($compose.Text -match 'DBDOC_DOCKER_PLUGIN_SHADOW') 'Compose shadow has stable code'

    $extraCompose = Invoke-Describe -FixturePath (Join-Path $fixtureRoot 'windows-compose-extra-dir-shadow-invalid.json') -Tool docker
    Assert-True ($extraCompose.ExitCode -ne 0) 'Docker describe rejects configured extra-dir Compose shadow'
    Assert-True ($extraCompose.Text -match 'DBDOC_DOCKER_PLUGIN_SHADOW') 'extra-dir Compose shadow has stable code'

    foreach ($componentFixture in @('windows-cargo-missing-invalid.json', 'windows-rustfmt-missing-invalid.json', 'windows-clippy-missing-invalid.json')) {
        $componentDescribe = Invoke-Describe -FixturePath (Join-Path $fixtureRoot $componentFixture) -Tool cargo
        Assert-True ($componentDescribe.ExitCode -ne 0) "$componentFixture Describe is rejected"
        Assert-True ($componentDescribe.Text -match 'DBDOC_RUST_COMPONENT_MISSING') "$componentFixture has stable component code"
    }

    $nonPePath = Write-Variant { param($p) ($p.binaries | Where-Object name -eq 'cmake').pe_format = 'ELF64' }
    $nonPe = Invoke-Describe -FixturePath $nonPePath
    Assert-True ($nonPe.ExitCode -ne 0) '-Describe rejects non-PE tools'
    Assert-True ($nonPe.Text -match 'DBDOC_BINARY_NOT_PE') 'non-PE rejection has stable code'

    $wrongVsPath = Write-Variant { param($p) $p.vs_installation_version = '17.13.99999.0' }
    $wrongVs = Invoke-Describe -FixturePath $wrongVsPath
    Assert-True ($wrongVs.ExitCode -ne 0) '-Describe rejects wrong VS instance'
    Assert-True ($wrongVs.Text -match 'DBDOC_TOOL_VERSION_DRIFT') 'wrong VS has stable version code'

    $wrongSdkPath = Write-Variant {
        param($p)
        $p.vsdevcmd.windows_sdk_version = '10.0.22621.0\'
        $p.vsdevcmd.include = 'C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0'
        $p.vsdevcmd.lib = 'C:\Program Files (x86)\Windows Kits\10\Lib\10.0.22621.0'
    }
    $wrongSdk = Invoke-Describe -FixturePath $wrongSdkPath
    Assert-True ($wrongSdk.ExitCode -ne 0) '-Describe rejects wrong imported Windows SDK'
    Assert-True ($wrongSdk.Text -match 'DBDOC_WINDOWS_SDK_DRIFT') 'wrong SDK has stable code'

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
    Write-DoctorReport -Result $valid -Json -ReportPath $reportPath -RepoRoot $repoRoot | Out-Null
    Assert-True (Test-Path -LiteralPath $reportPath -PathType Leaf) 'explicit ReportPath is written'

    $hardlinkSource = Join-Path $testTemp 'hardlink-source.txt'
    $hardlinkReport = Join-Path $testTemp 'hardlink-report.json'
    $hardlinkSentinel = 'harmless hardlink sentinel'
    [IO.File]::WriteAllText($hardlinkSource, $hardlinkSentinel)
    New-Item -ItemType HardLink -Path $hardlinkReport -Target $hardlinkSource | Out-Null
    $hardlinkRejected = $false
    try { Write-DoctorReport -Result $valid -Json -ReportPath $hardlinkReport -RepoRoot $repoRoot | Out-Null }
    catch { $hardlinkRejected = $_.Exception.Message -match 'DBDOC_REPORT_PATH_INVALID' }
    Assert-True $hardlinkRejected 'Write-DoctorReport rejects an existing hardlink target beneath repo var'
    Assert-Equal ([IO.File]::ReadAllText($hardlinkSource)) $hardlinkSentinel 'hardlink rejection leaves the harmless source unchanged'

    $outsideReport = Join-Path $repoRoot 'doctor-outside-forbidden.json'
    $outsideRejected = $false
    try { Write-DoctorReport -Result $valid -Json -ReportPath $outsideReport -RepoRoot $repoRoot | Out-Null }
    catch { $outsideRejected = $_.Exception.Message -match 'DBDOC_REPORT_PATH_INVALID' }
    Assert-True $outsideRejected 'Write-DoctorReport rejects paths outside repo var'
    Assert-True (-not (Test-Path -LiteralPath $outsideReport)) 'outside report is never created'

    $traversalReport = Join-Path $testTemp '..\..\doctor-traversal-forbidden.json'
    $traversalRejected = $false
    try { Write-DoctorReport -Result $valid -Json -ReportPath $traversalReport -RepoRoot $repoRoot | Out-Null }
    catch { $traversalRejected = $_.Exception.Message -match 'DBDOC_REPORT_PATH_INVALID' }
    Assert-True $traversalRejected 'Write-DoctorReport rejects traversal outside repo var'

    $junctionPath = Join-Path $testTemp 'junction'
    New-Item -ItemType Junction -Path $junctionPath -Target $repoRoot | Out-Null
    $junctionReport = Join-Path $junctionPath 'doctor-junction-forbidden.json'
    $junctionRejected = $false
    try { Write-DoctorReport -Result $valid -Json -ReportPath $junctionReport -RepoRoot $repoRoot | Out-Null }
    catch { $junctionRejected = $_.Exception.Message -match 'DBDOC_REPORT_PATH_INVALID' }
    Assert-True $junctionRejected 'Write-DoctorReport rejects a reparse-point parent'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'doctor-junction-forbidden.json'))) 'junction target is never written'
}
finally {
    $resolvedTestTemp = [IO.Path]::GetFullPath($testTemp)
    if (-not $resolvedTestTemp.StartsWith($varRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'test cleanup path escaped repository var'
    }
    if ($junctionPath -and (Test-Path -LiteralPath $junctionPath)) {
        $junctionItem = Get-Item -LiteralPath $junctionPath -Force
        if (-not [bool]($junctionItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'expected test junction became a normal directory' }
        [IO.Directory]::Delete($junctionPath, $false)
    }
    if (Test-Path -LiteralPath $resolvedTestTemp) { Remove-Item -LiteralPath $resolvedTestTemp -Recurse -Force }
}

Write-Host "PASS: $script:passed Windows toolchain contract assertions"
