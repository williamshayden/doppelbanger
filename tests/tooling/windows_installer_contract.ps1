[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$installerPath = Join-Path $repoRoot 'scripts\install_windows_toolchain.ps1'
$installerLockPath = Join-Path $repoRoot 'tools\windows-toolchain.lock.json'
$workstationDocPath = Join-Path $repoRoot 'docs\WINDOWS_WORKSTATION.md'
$powerShellHost = (Get-Process -Id $PID).Path

if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "RED: missing installer script: $installerPath"
}

. $installerPath -NoRun

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

function Assert-ThrowsCode {
    param([scriptblock]$Operation, [string]$Code, [string]$Message)
    $caught = $false
    try { & $Operation }
    catch { $caught = $_.Exception.Message -match ('^' + [regex]::Escape($Code) + ':') }
    Assert-True $caught $Message
}

function Get-FakeAmd64PeBytes {
    $bytes = New-Object byte[] 512
    $bytes[0] = 0x4D; $bytes[1] = 0x5A
    [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C)
    $bytes[0x80] = 0x50; $bytes[0x81] = 0x45
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($bytes, 0x84)
    [BitConverter]::GetBytes([uint16]0x020B).CopyTo($bytes, 0x98)
    return ,$bytes
}

function Write-FakeAmd64Pe {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = Get-FakeAmd64PeBytes
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function New-SyntheticZip {
    param([string]$Path, [object[]]$Entries)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($spec in $Entries) {
            $entry = $archive.CreateEntry([string]$spec.name, [IO.Compression.CompressionLevel]::NoCompression)
            if ($spec.PSObject.Properties.Name -contains 'external_attributes') { $entry.ExternalAttributes = [int]$spec.external_attributes }
            if (-not ([string]$spec.name).EndsWith('/') -or ($spec.PSObject.Properties.Name -contains 'write_directory_content' -and [bool]$spec.write_directory_content)) {
                [byte[]]$content = @()
                if ($null -ne $spec.content) {
                    $content = if ($spec.content -is [byte[]]) { [byte[]]$spec.content } else { [Text.Encoding]::UTF8.GetBytes([string]$spec.content) }
                }
                $entryStream = $entry.Open()
                try { if ($null -ne $content -and $content.Length -gt 0) { $entryStream.Write($content, 0, $content.Length) } }
                finally { $entryStream.Dispose() }
            }
        }
    }
    finally { $archive.Dispose(); $stream.Dispose() }
    return $Path
}

function New-ExactVisualStudioFixture {
    param($Lock, [string]$Root)
    $instancesRoot = Join-Path $Root 'instances'
    $instanceStateRoot = Join-Path $instancesRoot 'exact-instance'
    $installRoot = Join-Path $Root 'Microsoft Visual Studio\2022\BuildTools'
    $sdkRoot = Join-Path $Root 'Windows Kits\10'
    $vswherePath = Join-Path $Root 'Microsoft Visual Studio\Installer\vswhere.exe'
    $toolsetVersion = '14.44.35207'
    $toolsetRoot = Join-Path $installRoot "VC\Tools\MSVC\$toolsetVersion"
    foreach ($directory in @(
        $instanceStateRoot,
        (Split-Path -Parent $vswherePath),
        (Join-Path $installRoot 'Common7\Tools'),
        (Join-Path $installRoot 'VC\Auxiliary\Build'),
        (Join-Path $toolsetRoot 'bin\Hostx64\x64'),
        (Join-Path $toolsetRoot 'include'),
        (Join-Path $toolsetRoot 'lib\x64'),
        (Join-Path $sdkRoot "Include\$($Lock.visual_studio.windows_sdk_target)\ucrt"),
        (Join-Path $sdkRoot "Include\$($Lock.visual_studio.windows_sdk_target)\shared"),
        (Join-Path $sdkRoot "Include\$($Lock.visual_studio.windows_sdk_target)\um"),
        (Join-Path $sdkRoot "Include\$($Lock.visual_studio.windows_sdk_target)\winrt"),
        (Join-Path $sdkRoot "Include\$($Lock.visual_studio.windows_sdk_target)\cppwinrt"),
        (Join-Path $sdkRoot "Lib\$($Lock.visual_studio.windows_sdk_target)\ucrt\x64"),
        (Join-Path $sdkRoot "Lib\$($Lock.visual_studio.windows_sdk_target)\um\x64")
    )) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $statePath = Join-Path $instanceStateRoot 'state.json'
    $state = [pscustomobject][ordered]@{
        installationVersion = [string]$Lock.visual_studio.installation_version
        installationPath = $installRoot
        catalogInfo = [pscustomobject]@{ productDisplayVersion = [string]$Lock.visual_studio.product_version }
    }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $versionPath = Join-Path $installRoot 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
    [IO.File]::WriteAllText($versionPath, $toolsetVersion, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $installRoot 'Common7\Tools\VsDevCmd.bat'), '@rem physical fixture', (New-Object Text.UTF8Encoding($false)))
    Write-FakeAmd64Pe $vswherePath
    foreach ($binaryName in @('cl.exe', 'link.exe', 'lib.exe', 'dumpbin.exe')) { Write-FakeAmd64Pe (Join-Path $toolsetRoot "bin\Hostx64\x64\$binaryName") }
    [IO.File]::WriteAllText((Join-Path $sdkRoot "Include\$($Lock.visual_studio.windows_sdk_target)\um\Windows.h"), '// fixture')
    [IO.File]::WriteAllText((Join-Path $sdkRoot "Lib\$($Lock.visual_studio.windows_sdk_target)\um\x64\kernel32.lib"), 'fixture')
    [IO.File]::WriteAllText((Join-Path $sdkRoot "Lib\$($Lock.visual_studio.windows_sdk_target)\ucrt\x64\ucrt.lib"), 'fixture')
    return [pscustomobject]@{ instances_root = $instancesRoot; install_root = $installRoot; sdk_root = $sdkRoot; toolset_root = $toolsetRoot; state_path = $statePath; version_path = $versionPath; vswhere_path = $vswherePath }
}

function New-ExactRustFixture {
    param($Lock, [string]$RustupHome)
    $root = Join-Path (Join-Path $RustupHome 'toolchains') $Lock.rust.toolchain_directory
    $rustlib = Join-Path $root 'lib\rustlib'
    [IO.Directory]::CreateDirectory((Join-Path $root 'bin')) | Out-Null
    [IO.Directory]::CreateDirectory($rustlib) | Out-Null
    [IO.File]::WriteAllText((Join-Path $rustlib 'rust-installer-version'), '3')
    [IO.File]::WriteAllText((Join-Path $rustlib 'multirust-channel-manifest.toml'), "manifest-version = '2'`n[pkg.rustc]`nversion = '$($Lock.rust.toolchain) (fixture)'`n")
    [IO.File]::WriteAllText((Join-Path $rustlib 'multirust-config.toml'), "config_version = '1'`n")
    $componentFiles = [ordered]@{
        "rustc-$($Lock.rust.target)" = @('rustc.exe')
        "cargo-$($Lock.rust.target)" = @('cargo.exe')
        "rustfmt-preview-$($Lock.rust.target)" = @('rustfmt.exe')
        "clippy-preview-$($Lock.rust.target)" = @('clippy-driver.exe', 'cargo-clippy.exe')
    }
    [IO.File]::WriteAllLines((Join-Path $rustlib 'components'), @($componentFiles.Keys))
    foreach ($component in $componentFiles.Keys) {
        [IO.File]::WriteAllLines((Join-Path $rustlib "manifest-$component"), @($componentFiles[$component] | ForEach-Object { "file:bin/$_" }))
        foreach ($binary in $componentFiles[$component]) { Write-FakeAmd64Pe (Join-Path $root "bin\$binary") }
    }
    return [pscustomobject]@{ rustup_home = $RustupHome; root = $root; rustlib = $rustlib }
}

function Invoke-InstallerProcess {
    param([string[]]$Arguments, [Collections.IDictionary]$Environment)
    $saved = @{}
    if ($Environment) {
        foreach ($name in $Environment.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable([string]$name, 'Process')
            [Environment]::SetEnvironmentVariable([string]$name, [string]$Environment[$name], 'Process')
        }
    }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $powerShellHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installerPath @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
    return [pscustomobject]@{ ExitCode = $code; Text = ($lines -join [Environment]::NewLine) }
}

$varRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'var')).TrimEnd('\')
$testId = [Guid]::NewGuid().ToString('D')
$testRoot = Join-Path $varRoot $testId
if ([IO.Path]::GetFileName($testRoot) -cne $testId) { throw 'test root is not a direct GUID child of repository var' }
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    $lock = Read-InstallerLock -Path $installerLockPath
    $installerSource = Get-Content -LiteralPath $installerPath -Raw
    Assert-True ($installerSource -notmatch 'VersionRunner') 'installer contains no portable-tool execution or version-runner seam'
    Assert-True ($installerSource -match '(?s)Get-VersionedToolInstalledState.+?-ArchivePath\s+\$artifact') 'portable installed-state probes receive the verified cached archive'
    $workstationDoc = Get-Content -LiteralPath $workstationDocPath -Raw
    $installerSectionMatch = [regex]::Match($workstationDoc, '(?ms)^## Pinned developer-workstation toolchain installer\r?\n(?<body>.*?)(?=^## |\z)')
    Assert-True $installerSectionMatch.Success 'workstation documentation has the exact developer-workstation installer section'
    $installerSection = $installerSectionMatch.Groups['body'].Value
    Assert-True $installerSection.Contains('This script provisions a Doppelbanger developer workstation; it is not a musician-facing product installer.') 'installer section distinguishes developer provisioning from the musician-facing product installer'
    Assert-True $installerSection.Contains('Its ordinary invocation may install the pinned Rust, MSVC, CMake, Ninja, and Node developer tools, but Node remains outside the `HeadlessVst3` profile and Docker/WSL remain outside the ordinary installer path.') 'installer section keeps Node outside HeadlessVst3 and Docker/WSL outside the ordinary path'
    Assert-True ($workstationDoc -match 'source_size_bytes.*source_sha256' -and $workstationDoc -match 'byte-identical') 'workstation documentation requires source and backup byte-identity evidence'
    Assert-True ($workstationDoc -match 'same native Windows boot session' -and $workstationDoc -match 'action topology') 'workstation documentation explains reboot checkpoint boot and topology binding'
    Assert-True ($workstationDoc -match [regex]::Escape([string]$lock.docker.desktop_build) -and $workstationDoc -match 'exact version and build') 'workstation documentation names the exact Docker version/build postcondition'
    Assert-True $installerSection.Contains('Every bootstrap artifact is opened from a physical, non-reparse ancestry with exactly one link, hashed from the same read-only leaf handle, and kept under read-only ancestor and leaf leases through awaited process completion.') 'installer documentation states the bootstrap provenance and lease boundary'
    Assert-True $installerSection.Contains('The Rust receipt detects later drift; it is not a cryptographic defense against a malicious process running as the same Windows user that forges both the tree and receipt.') 'installer documentation states the Rust receipt threat boundary'
    Assert-True $installerSection.Contains('Visual Studio trust stops at the pinned bootstrap SHA-256 plus Microsoft Visual Studio installer/package registration and physical installed metadata/layout; it is not a full installed-byte manifest or an Authenticode proof.') 'installer documentation states the Visual Studio trust boundary'
    Assert-True $installerSection.Contains('The default live topology is exactly Visual Studio, Rust, CMake, Ninja, Node, then user PATH; Docker appears only in the explicit Docker opt-in topology immediately before user PATH.') 'installer documentation states the independently testable default and Docker topologies'
    Assert-True $installerSection.Contains('A live user PATH append expands environment variables for comparison only, then re-proves exact Visual Studio, Rust, CMake, Ninja, and Node state, rejects a concurrent baseline change, and verifies the exact stored readback.') 'installer documentation states the guarded PATH mutation contract'
    Assert-True $installerSection.Contains('If Docker returns 3010 but checkpoint persistence fails, the installer removes any partial checkpoint and restores the exact moved Compose shadow from its rollback receipt before failing.') 'installer documentation states the Docker 3010 checkpoint-compensation contract'
    Assert-Equal (Assert-NoReparsePath -Path $installerPath -Root ([IO.Path]::GetPathRoot($installerPath)) -AllowMissingLeaf) ([IO.Path]::GetFullPath($installerPath).TrimEnd('\')) 'destination ancestry validation traverses correctly from a drive root'
    $plan = New-WindowsToolchainInstallPlan -Lock $lock -LocalAppData (Join-Path $testRoot 'local-app-data')
    $actions = @($plan.actions)

    Assert-Equal $plan.schema_version 1 'plan schema is versioned'
    Assert-Equal $plan.platform 'windows-x86_64-native' 'plan platform is native Windows x64'
    Assert-Equal $plan.cache_root (Join-Path $testRoot 'local-app-data\doppelbanger\downloads') 'plan uses the per-user download cache'
    Assert-Equal $plan.toolchain_root (Join-Path $testRoot 'local-app-data\Programs\doppelbanger-devtools') 'plan uses the per-user devtools root'

    foreach ($name in @('visual_studio', 'rustup', 'cmake', 'ninja', 'node', 'docker')) {
        Assert-Equal @($actions | Where-Object name -eq $name).Count 1 "plan contains exactly one $name action"
    }
    foreach ($pair in @(
        @('visual_studio', $lock.visual_studio.url, $lock.visual_studio.sha256),
        @('rustup', $lock.rust.rustup_url, $lock.rust.rustup_sha256),
        @('cmake', $lock.cmake.url, $lock.cmake.sha256),
        @('ninja', $lock.ninja.url, $lock.ninja.sha256),
        @('node', $lock.node.url, $lock.node.sha256),
        @('docker', $lock.docker.url, $lock.docker.sha256)
    )) {
        $action = @($actions | Where-Object name -eq $pair[0])[0]
        Assert-Equal $action.url $pair[1] "$($pair[0]) emits the exact locked URL"
        Assert-Equal $action.sha256 $pair[2] "$($pair[0]) emits the exact locked SHA-256"
    }

    $vs = @($actions | Where-Object name -eq 'visual_studio')[0]
    Assert-Equal ($vs.arguments -join ' ') '--quiet --wait --norestart --installPath C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.26100' 'VS payload is exact and fully pinned'
    Assert-True (($vs.arguments -join ' ') -notmatch '(?i)includeRecommended|latest|17\.14\*') 'VS payload has no recommended or floating component selection'

    $rust = @($actions | Where-Object name -eq 'rustup')[0]
    Assert-Equal ($rust.arguments -join ' ') '-y --no-modify-path --default-host x86_64-pc-windows-msvc --default-toolchain 1.97.1-x86_64-pc-windows-msvc --profile minimal --component rustfmt,clippy' 'Rust payload pins toolchain, host, profile, and components'

    $docker = @($actions | Where-Object name -eq 'docker')[0]
    Assert-True (-not $docker.enabled) 'ordinary default developer-workstation plan keeps Docker upgrade disabled'
    Assert-Equal $docker.install_mode 'all-users' 'Docker plan preserves all-users mode'
    Assert-Equal $docker.install_path 'C:\Program Files\Docker\Docker' 'Docker plan preserves the locked install path'
    Assert-Equal ($docker.arguments -join ' ') 'install --quiet --backend=wsl-2' 'Docker payload preserves the WSL2 backend without migration'
    Assert-True (($docker.arguments -join ' ') -notmatch '(?i)(?:^|\s)--user(?:\s|$)|installation-dir|data-root|windows-containers|linux-containers') 'Docker payload contains no user, root migration, or mode switch'

    # Fix Round 1: the actual non-PlanOnly live topology is pure, stable, and injectable.
    $script:liveTopologyCalls = New-Object 'Collections.Generic.List[string]'
    $script:defaultDockerSentinelCalls = 0
    $liveVisualStudioPlanPayload = [pscustomobject]@{ name = 'visual_studio'; token = 'exact-definition-payload' }
    $liveDefinitions = @{
        visual_studio = [pscustomobject]@{ plan = $liveVisualStudioPlanPayload; checkpoint_on_3010 = $false; invoke = { param($SequenceAction); Assert-True ([object]::ReferenceEquals($SequenceAction.plan, $liveVisualStudioPlanPayload)) 'injected live closure receives its exact definition payload'; $script:liveTopologyCalls.Add('visual_studio'); return 0 }; postcondition = $null }
        rustup = [pscustomobject]@{ checkpoint_on_3010 = $false; invoke = { $script:liveTopologyCalls.Add('rustup'); return 0 }; postcondition = $null }
        cmake = [pscustomobject]@{ checkpoint_on_3010 = $false; invoke = { $script:liveTopologyCalls.Add('cmake'); return 0 }; postcondition = $null }
        ninja = [pscustomobject]@{ checkpoint_on_3010 = $false; invoke = { $script:liveTopologyCalls.Add('ninja'); return 0 }; postcondition = $null }
        node = [pscustomobject]@{ checkpoint_on_3010 = $false; invoke = { $script:liveTopologyCalls.Add('node'); return 0 }; postcondition = $null }
        docker = [pscustomobject]@{ checkpoint_on_3010 = $true; invoke = { $script:defaultDockerSentinelCalls++; $script:liveTopologyCalls.Add('docker'); return 0 }; postcondition = $null }
        user_path = [pscustomobject]@{ checkpoint_on_3010 = $false; invoke = { $script:liveTopologyCalls.Add('user_path'); return 0 }; postcondition = $null }
    }
    $topologyBefore = @(Get-ChildItem -LiteralPath $testRoot -Force | Select-Object -ExpandProperty FullName)
    $defaultLiveActions = @(New-WindowsToolchainLiveActions -ActionDefinitions $liveDefinitions)
    Assert-Equal (@($defaultLiveActions | Select-Object -ExpandProperty topology_id -Unique) -join ',') 'windows-dev-v1-default' 'default live topology has one stable identifier'
    Assert-Equal (@($defaultLiveActions | Select-Object -ExpandProperty name) -join ',') 'visual_studio,rustup,cmake,ninja,node,user_path' 'default live topology is exactly VS, Rust, CMake, Ninja, Node, PATH'
    Assert-True ([object]::ReferenceEquals($defaultLiveActions[0].plan, $liveVisualStudioPlanPayload)) 'live action descriptor carries the exact definition payload consumed by real invoke and postcondition closures'
    Invoke-WindowsToolchainLiveActions -Actions $defaultLiveActions -CheckpointPath (Join-Path $testRoot 'default-live-topology-checkpoint.json') -CheckpointRoot $testRoot -LockSha256 (Get-FileSha256 -Path $installerLockPath) -PreconditionCheck { } -EnvironmentCheck { } | Out-Null
    Assert-Equal ($script:liveTopologyCalls -join ',') 'visual_studio,rustup,cmake,ninja,node,user_path' 'default non-PlanOnly orchestration invokes only the six developer-workstation actions'
    Assert-Equal $script:defaultDockerSentinelCalls 0 'default non-PlanOnly orchestration never calls the Docker action sentinel'

    $script:liveTopologyCalls.Clear()
    $dockerLiveActions = @(New-WindowsToolchainLiveActions -ActionDefinitions $liveDefinitions -UpgradeDocker)
    Assert-Equal (@($dockerLiveActions | Select-Object -ExpandProperty topology_id -Unique) -join ',') 'windows-dev-v1-docker-opt-in' 'Docker opt-in live topology has a separate stable identifier'
    Assert-Equal (@($dockerLiveActions | Select-Object -ExpandProperty name) -join ',') 'visual_studio,rustup,cmake,ninja,node,docker,user_path' 'Docker opt-in topology is explicit and ordered before PATH'
    Invoke-WindowsToolchainLiveActions -Actions $dockerLiveActions -CheckpointPath (Join-Path $testRoot 'docker-live-topology-checkpoint.json') -CheckpointRoot $testRoot -LockSha256 (Get-FileSha256 -Path $installerLockPath) -PreconditionCheck { } -EnvironmentCheck { } | Out-Null
    Assert-Equal ($script:liveTopologyCalls -join ',') 'visual_studio,rustup,cmake,ninja,node,docker,user_path' 'opted non-PlanOnly orchestration invokes Docker only in its explicit topology'
    $topologyAfter = @(Get-ChildItem -LiteralPath $testRoot -Force | Select-Object -ExpandProperty FullName)
    Assert-Equal ($topologyBefore -join '|') ($topologyAfter -join '|') 'sentinel-backed live topology orchestration creates no filesystem state'
    Assert-True ($installerSource -notmatch '(?im)\b(?:Start|Set|Restart)-Service\b|&\s*[^\r\n]*\bwsl(?:\.exe)?\b') 'installer contains no WSL invocation or service-start seam'

    # Fix Round 2: invoke the actual non-PlanOnly main preparation path through production-wiring seams.
    $mainTokens = $null
    $mainParseErrors = $null
    $installerAst = [Management.Automation.Language.Parser]::ParseInput($installerSource, [ref]$mainTokens, [ref]$mainParseErrors)
    Assert-Equal $mainParseErrors.Count 0 'installer source parses before the main-path safety guard runs'
    $mainDefinitions = @($installerAst.FindAll({
        param($Node)
        return $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Invoke-WindowsToolchainInstallerMain'
    }, $true))
    Assert-Equal $mainDefinitions.Count 1 'installer contains exactly one actual main function for safe injected execution'
    $mainDefinition = $mainDefinitions[0]
    $mainParameterNames = if ($mainDefinition.Body.ParamBlock) { @($mainDefinition.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) } else { @() }
    Assert-True ('PlanOnly' -in $mainParameterNames -and 'UpgradeDockerDesktop' -in $mainParameterNames -and 'MainSeams' -in $mainParameterNames) 'actual main exposes explicit invocation options and side-effect seam injection before any safe test execution'

    $forbiddenMainCommands = @(
        'Start-Process', 'Start-Service', 'Stop-Service', 'Restart-Service', 'Get-Service', 'Get-Process',
        'Set-Service', 'Suspend-Service', 'Resume-Service', 'New-Service', 'Remove-Service', 'sc', 'sc.exe', 'net', 'net.exe',
        'wsl', 'wsl.exe', 'docker', 'docker.exe', 'Invoke-BootstrapProcess', 'Invoke-WindowsToolchainLiveActions',
        'Upgrade-DockerDesktop', 'Get-DockerDesktopInstalledMetadata', 'Get-InstallerDockerComposeMetadata',
        'Get-DockerDataCandidatePaths', 'Resolve-DockerDataPath', 'Invoke-Expression', 'Start-Job'
    )
    foreach ($qualifiedServiceLauncher in @('C:\Windows\System32\sc.exe', 'C:\Windows\System32\net.exe')) {
        $serviceLauncherLeaf = $qualifiedServiceLauncher -replace '^.*[\\/]', ''
        Assert-True ($serviceLauncherLeaf -in $forbiddenMainCommands) "main guard rejects path-qualified native service launcher: $qualifiedServiceLauncher"
    }
    $allowedDynamicMainTargets = @(
        '$mainSeams.environment_probe', '$mainSeams.environment_check', '$mainSeams.boot_session_probe',
        '$mainSeams.preflight_check', '$mainSeams.precondition_check', '$mainSeams.live_execute',
        '$mainSeams.completion_writer', '$mainSeams.docker_prepare', '$mainSeams.docker_execute'
    )
    $mainCommands = @($mainDefinition.Body.FindAll({ param($Node) return $Node -is [Management.Automation.Language.CommandAst] }, $true))
    $unsafeMainCommands = New-Object 'Collections.Generic.List[string]'
    foreach ($mainCommand in $mainCommands) {
        $commandName = [string]$mainCommand.GetCommandName()
        $commandLeaf = if ($commandName) { $commandName -replace '^.*[\\/]', '' } else { '' }
        if ($commandLeaf -and ($commandLeaf -in $forbiddenMainCommands -or $commandLeaf -match '^(?:wsl|docker|docker desktop|dockercli|com\.docker\.[^\\/]+)(?:\.exe)?$')) {
            $unsafeMainCommands.Add($commandName)
            continue
        }
        if (-not $commandName -and $mainCommand.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand) {
            $dynamicTarget = [string]$mainCommand.CommandElements[0].Extent.Text
            if ($dynamicTarget -notin $allowedDynamicMainTargets) { $unsafeMainCommands.Add("dynamic:$dynamicTarget") }
        }
    }
    Assert-Equal $unsafeMainCommands.Count 0 'main AST contains no direct process, service, WSL, Docker, live-execution, or unnamed dynamic side-effect command'
    Assert-True ($mainDefinition.Extent.Text -notmatch '(?is)\[(?:System\.)?(?:Diagnostics\.)?Process\]\s*::\s*Start|ServiceController[^\r\n]*\.\s*(?:Start|Stop)\s*\(') 'main source contains no static process launch or service-controller bypass outside a named seam'
    foreach ($bootstrapCommandName in @('Install-VsBuildTools', 'Install-RustToolchain')) {
        $bootstrapCommands = @($mainCommands | Where-Object { [string]$_.GetCommandName() -ceq $bootstrapCommandName })
        Assert-Equal $bootstrapCommands.Count 1 "main has exactly one production $bootstrapCommandName action binding"
        Assert-True ($bootstrapCommands[0].Extent.Text -match '(?s)-Runner\s+\$mainSeams\.process_runner(?:\s|$)') "$bootstrapCommandName is hard-bound to the injected process-launch seam"
    }
    $mainPathCommands = @($mainCommands | Where-Object { [string]$_.GetCommandName() -ceq 'Set-DoppelbangerUserPath' })
    Assert-Equal $mainPathCommands.Count 1 'main has exactly one production user PATH action binding'
    Assert-True ($mainPathCommands[0].Extent.Text -match '(?s)-PathReader\s+\$mainSeams\.path_reader.+?-PathWriter\s+\$mainSeams\.path_writer') 'production PATH action is hard-bound to injected reader and writer seams'

    $round2Environment = [pscustomobject]@{
        local_app_data = Join-Path $testRoot 'round2-local-app-data'
        user_profile = Join-Path $testRoot 'round2-user-profile'
        rustup_home = Join-Path $testRoot 'round2-rustup'
        cargo_home = Join-Path $testRoot 'round2-cargo'
    }
    $script:round2MainCounts = [ordered]@{
        environment_probe = 0; environment_check = 0; boot_session_probe = 0; preflight_check = 0; precondition_check = 0
        live_execute = 0; completion_writer = 0; checkpoint_writer = 0; process_runner = 0; wsl_runner = 0; service_runner = 0
        path_reader = 0; path_writer = 0; docker_prepare = 0; docker_execute = 0
    }
    $script:round2CapturedRequests = New-Object 'Collections.Generic.List[object]'
    $script:round2PreflightTargetSets = New-Object 'Collections.Generic.List[object]'
    $script:round2PathEquivalentState = 'C:\Fixture Existing PATH'
    $round2EnvironmentForClosure = $round2Environment
    $round2MainSeams = [ordered]@{
        environment_probe = { $script:round2MainCounts.environment_probe++; return $round2EnvironmentForClosure }.GetNewClosure()
        environment_check = { $script:round2MainCounts.environment_check++ }
        boot_session_probe = { $script:round2MainCounts.boot_session_probe++; return 'round2-injected-boot' }
        preflight_check = {
            param($Targets)
            $script:round2MainCounts.preflight_check++
            $script:round2PreflightTargetSets.Add([pscustomobject]@{ values = @($Targets) })
        }
        precondition_check = { param($Targets); $script:round2MainCounts.precondition_check++ }
        live_execute = {
            param($Request)
            $script:round2MainCounts.live_execute++
            $script:round2CapturedRequests.Add($Request)
            return [pscustomobject]@{ status = 'captured'; action_count = @($Request.actions).Count }
        }
        completion_writer = { param($Message); $script:round2MainCounts.completion_writer++ }
        checkpoint_writer = { $script:round2MainCounts.checkpoint_writer++; throw 'checkpoint writer must remain captured' }
        process_runner = { param($Path, $Arguments); $script:round2MainCounts.process_runner++; throw 'process launch must remain captured' }
        wsl_runner = { $script:round2MainCounts.wsl_runner++; throw 'WSL must never run from workstation installer main' }
        service_runner = { $script:round2MainCounts.service_runner++; throw 'service control must never run from workstation installer main' }
        path_reader = { $script:round2MainCounts.path_reader++; return $script:round2PathEquivalentState }
        path_writer = { param($Value); $script:round2MainCounts.path_writer++; throw 'PATH writer must remain captured' }
        docker_prepare = { param($Request); $script:round2MainCounts.docker_prepare++; throw 'ordinary main must not prepare Docker' }
        docker_execute = { param($Request); $script:round2MainCounts.docker_execute++; throw 'capturing live executor must not execute or postcondition Docker' }
    }
    $round2FilesystemSnapshot = {
        param([string]$Root)
        return @(Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object -Property FullName | ForEach-Object {
            $relative = $_.FullName.Substring($Root.Length).TrimStart('\')
            if ($_.PSIsContainer) { return "directory:$relative" }
            return "file:${relative}:$($_.Length):$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
        })
    }
    $round2FilesystemBefore = @(& $round2FilesystemSnapshot $testRoot)
    $round2UserPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
    $round2ProcessPathBefore = [string]$env:Path
    Invoke-WindowsToolchainInstallerMain -MainSeams $round2MainSeams
    Assert-Equal $script:round2CapturedRequests.Count 1 'actual ordinary main delegates live execution exactly once'
    $round2OrdinaryRequest = $script:round2CapturedRequests[0]
    Assert-Equal (@($round2OrdinaryRequest.actions | ForEach-Object { [string]$_.name }) -join ',') 'visual_studio,rustup,cmake,ninja,node,user_path' 'actual ordinary main captures exact production VS, Rust, CMake, Ninja, Node, PATH descriptors'
    Assert-Equal (@($round2OrdinaryRequest.actions | ForEach-Object { [string]$_.topology_id } | Select-Object -Unique) -join ',') 'windows-dev-v1-default' 'actual ordinary main uses the stable default production topology'
    Assert-Equal (@($round2OrdinaryRequest.action_definitions.Keys | Sort-Object) -join ',') 'cmake,ninja,node,rustup,user_path,visual_studio' 'actual ordinary main captures exactly its production action-definition set'
    $round2ExpectedOrdinaryPlan = New-WindowsToolchainInstallPlan -Lock $lock -LocalAppData ([string]$round2Environment.local_app_data)
    foreach ($round2Descriptor in @($round2OrdinaryRequest.actions)) {
        $round2Definition = $round2OrdinaryRequest.action_definitions[[string]$round2Descriptor.name]
        Assert-True ([object]::ReferenceEquals($round2Descriptor.invoke, $round2Definition.invoke)) "actual ordinary descriptor preserves the exact production invoke callback: $($round2Descriptor.name)"
        Assert-True ([object]::ReferenceEquals($round2Descriptor.postcondition, $round2Definition.postcondition)) "actual ordinary descriptor preserves the exact production postcondition callback: $($round2Descriptor.name)"
        Assert-Equal ([bool]$round2Descriptor.checkpoint_on_3010) ([bool]$round2Definition.checkpoint_on_3010) "actual ordinary descriptor preserves production checkpoint policy: $($round2Descriptor.name)"
        if ([string]$round2Descriptor.name -ceq 'user_path') {
            Assert-True ($null -eq $round2Descriptor.plan -and $null -eq $round2Descriptor.postcondition) 'actual user PATH descriptor is the production callback without a synthetic plan or postcondition'
        }
        else {
            Assert-True ([object]::ReferenceEquals($round2Descriptor.plan, $round2Definition.plan)) "actual ordinary descriptor preserves the exact production plan object: $($round2Descriptor.name)"
            $round2ExpectedAction = @($round2ExpectedOrdinaryPlan.actions | Where-Object { [string]$_.name -ceq [string]$round2Descriptor.name })[0]
            Assert-Equal ($round2Descriptor.plan | ConvertTo-Json -Depth 10 -Compress) ($round2ExpectedAction | ConvertTo-Json -Depth 10 -Compress) "actual ordinary descriptor carries the exact generated production plan: $($round2Descriptor.name)"
        }
    }
    $round2OrdinaryInvokeSource = [string]$round2OrdinaryRequest.action_definitions.visual_studio.invoke.Ast.Extent.Text
    $round2OrdinaryPostconditionSource = [string]$round2OrdinaryRequest.action_definitions.visual_studio.postcondition.Ast.Extent.Text
    foreach ($productionInvokeCommand in @('Install-VsBuildTools', 'Install-RustToolchain', 'Expand-VersionedTool')) {
        Assert-True ($round2OrdinaryInvokeSource -match [regex]::Escape($productionInvokeCommand)) "captured production invoke callback retains $productionInvokeCommand"
    }
    foreach ($productionPostconditionCommand in @('Assert-VisualStudioInstallPostcondition', 'Assert-RustToolchainPostcondition', 'Assert-VersionedToolMatchesArchive')) {
        Assert-True ($round2OrdinaryPostconditionSource -match [regex]::Escape($productionPostconditionCommand)) "captured production postcondition callback retains $productionPostconditionCommand"
    }
    $round2PathInvokeSource = [string]$round2OrdinaryRequest.action_definitions.user_path.invoke.Ast.Extent.Text
    Assert-True ($round2PathInvokeSource -match '(?s)Set-DoppelbangerUserPath.+?-PathReader\s+\$MainSeams\.path_reader.+?-PathWriter\s+\$MainSeams\.path_writer') 'captured production PATH callback retains provenance and both injected PATH seams'
    Assert-True (-not [bool]$round2OrdinaryRequest.docker_context.prepared) 'actual ordinary main captures an explicitly unprepared Docker context'
    Assert-True ([object]::ReferenceEquals($round2OrdinaryRequest.checkpoint_writer, $round2MainSeams.checkpoint_writer)) 'actual main forwards the injected checkpoint seam to captured live execution'
    Assert-Equal $script:round2MainCounts.environment_probe 1 'actual ordinary main uses injected environment exactly once'
    Assert-Equal $script:round2MainCounts.environment_check 1 'actual ordinary main runs one injected initial environment check'
    Assert-Equal $script:round2MainCounts.boot_session_probe 1 'actual ordinary main reads boot provenance only through its seam'
    Assert-Equal $script:round2MainCounts.preflight_check 1 'actual ordinary main runs only the injected preflight check'
    Assert-Equal $script:round2MainCounts.docker_prepare 0 'ordinary actual main never calls Docker preparation'
    foreach ($forbiddenSentinelName in @('checkpoint_writer', 'process_runner', 'wsl_runner', 'service_runner', 'path_reader', 'path_writer', 'docker_execute')) {
        Assert-Equal ([int]$script:round2MainCounts[$forbiddenSentinelName]) 0 "captured ordinary actual main keeps $forbiddenSentinelName at zero"
    }

    $round2DockerSource = 'C:\round2-fixture\Docker\wsl\data\docker_data.vhdx'
    $round2DockerBackup = 'D:\round2-fixture\docker_data.backup.vhdx'
    $script:round2DockerManifest = [pscustomobject][ordered]@{
        schema_version = 1; source_desktop_version = '4.46.0'; install_mode = 'all-users'; install_path = [string]$lock.docker.root
        source_data_path = $round2DockerSource; source_size_bytes = 1024; source_sha256 = ('1' * 64)
        backup_path = $round2DockerBackup; backup_size_bytes = 1024; backup_sha256 = ('1' * 64)
        created_utc = '2026-08-06T12:00:00Z'; desktop_stopped = $true
    }
    $script:round2ComposeMetadata = [pscustomobject][ordered]@{
        docker_config = 'C:\round2-fixture\.docker'
        plugin_roots = @('C:\round2-fixture\.docker\cli-plugins', 'C:\Program Files\Docker\cli-plugins')
        candidates = @('C:\round2-fixture\.docker\cli-plugins\docker-compose.exe', [string]$lock.docker.compose_plugin_path)
        winner = [string]$lock.docker.compose_plugin_path
    }
    $script:round2DockerInstalledMetadata = [pscustomobject]@{ version = '4.46.0'; build = '0' }
    $round2MainSeams['docker_prepare'] = {
        param($Request)
        $script:round2MainCounts.docker_prepare++
        return [pscustomobject][ordered]@{
            installed_metadata = $script:round2DockerInstalledMetadata
            manifest_sha256 = ('2' * 64)
            manifest = $script:round2DockerManifest
            compose_metadata = $script:round2ComposeMetadata
            detected_data_path = [string]$script:round2DockerManifest.source_data_path
            data_roots = @('C:\round2-fixture\Docker\wsl\data')
            preflight_paths = @(
                [string]$Request.lock.docker.root,
                [string]$script:round2DockerManifest.source_data_path,
                [string]$script:round2DockerManifest.backup_path,
                [string]$Request.backup_manifest_path,
                [string]$script:round2ComposeMetadata.winner,
                'C:\round2-fixture\Docker\wsl\data'
            ) + @($script:round2ComposeMetadata.plugin_roots)
        }
    }
    Invoke-WindowsToolchainInstallerMain -UpgradeDockerDesktop -DockerBackupManifest 'C:\round2-fixture\docker-backup-manifest.json' -BackupShadowingComposePlugin -MainSeams $round2MainSeams
    Assert-Equal $script:round2CapturedRequests.Count 2 'actual Docker-opt-in main delegates captured live execution exactly once after ordinary main'
    $round2DockerRequest = $script:round2CapturedRequests[1]
    Assert-Equal (@($round2DockerRequest.actions | ForEach-Object { [string]$_.name }) -join ',') 'visual_studio,rustup,cmake,ninja,node,docker,user_path' 'actual Docker-opt-in main captures Docker immediately before PATH in production descriptors'
    Assert-Equal (@($round2DockerRequest.actions | ForEach-Object { [string]$_.topology_id } | Select-Object -Unique) -join ',') 'windows-dev-v1-docker-opt-in' 'actual Docker-opt-in main uses the stable explicit production topology'
    Assert-Equal (@($round2DockerRequest.action_definitions.Keys | Sort-Object) -join ',') 'cmake,docker,ninja,node,rustup,user_path,visual_studio' 'actual Docker-opt-in main captures exactly its production action-definition set'
    foreach ($round2Descriptor in @($round2DockerRequest.actions)) {
        $round2Definition = $round2DockerRequest.action_definitions[[string]$round2Descriptor.name]
        Assert-True ([object]::ReferenceEquals($round2Descriptor.invoke, $round2Definition.invoke)) "actual Docker-opt-in descriptor preserves the exact production invoke callback: $($round2Descriptor.name)"
        Assert-True ([object]::ReferenceEquals($round2Descriptor.postcondition, $round2Definition.postcondition)) "actual Docker-opt-in descriptor preserves the exact production postcondition callback: $($round2Descriptor.name)"
        Assert-Equal ([bool]$round2Descriptor.checkpoint_on_3010) ([bool]$round2Definition.checkpoint_on_3010) "actual Docker-opt-in descriptor preserves production checkpoint policy: $($round2Descriptor.name)"
        if ($round2Descriptor.plan) { Assert-True ([object]::ReferenceEquals($round2Descriptor.plan, $round2Definition.plan)) "actual Docker-opt-in descriptor preserves the exact production plan object: $($round2Descriptor.name)" }
    }
    $round2DockerInvokeSource = [string]$round2DockerRequest.action_definitions.docker.invoke.Ast.Extent.Text
    $round2DockerPostconditionSource = [string]$round2DockerRequest.action_definitions.docker.postcondition.Ast.Extent.Text
    foreach ($dockerContextBinding in @(
        'backup_manifest_path\s*=\s*\[string\]\$DockerBackupManifest',
        'detected_data_path\s*=\s*\$dockerDetectedDataPath',
        'data_roots\s*=\s*\$dockerDataRoots',
        'compose_metadata\s*=\s*\$dockerComposeMetadata',
        'backup_shadowing_compose_plugin\s*=\s*\[bool\]\$BackupShadowingComposePlugin',
        'process_runner\s*=\s*\$MainSeams\.process_runner'
    )) {
        Assert-True ($round2DockerInvokeSource -match $dockerContextBinding) "captured production Docker callback retains context binding: $dockerContextBinding"
    }
    Assert-True ($round2DockerPostconditionSource -match "phase\s*=\s*'postcondition'" -and $round2DockerPostconditionSource -match 'docker_execute') 'captured production Docker postcondition remains bound to the Docker execution seam'
    Assert-True ([bool]$round2DockerRequest.docker_context.prepared) 'actual Docker-opt-in main captures explicit preparation provenance'
    Assert-True ([object]::ReferenceEquals($round2DockerRequest.docker_context.installed_metadata, $script:round2DockerInstalledMetadata)) 'actual Docker-opt-in main captures only injected installed metadata'
    Assert-True ([object]::ReferenceEquals($round2DockerRequest.docker_context.manifest, $script:round2DockerManifest)) 'actual Docker-opt-in main captures the exact injected backup manifest'
    Assert-True ([object]::ReferenceEquals($round2DockerRequest.docker_context.compose_metadata, $script:round2ComposeMetadata)) 'actual Docker-opt-in main captures the exact injected Compose metadata'
    Assert-Equal ([string]$round2DockerRequest.docker_context.detected_data_path) $round2DockerSource 'actual Docker-opt-in main captures the injected detected data path'
    Assert-Equal (@($round2DockerRequest.docker_context.data_roots) -join ',') 'C:\round2-fixture\Docker\wsl\data' 'actual Docker-opt-in main captures only injected Docker data roots'
    Assert-True ([bool]$round2DockerRequest.install_options.upgrade_docker) 'captured Docker topology binds the explicit upgrade option'
    Assert-Equal ([string]$round2DockerRequest.install_options.docker_manifest_sha256) ('2' * 64) 'captured Docker topology binds injected manifest provenance'
    Assert-Equal $script:round2MainCounts.docker_prepare 1 'Docker-opt-in actual main calls injected metadata/manifest/Compose/data preparation exactly once'
    Assert-Equal $script:round2PreflightTargetSets.Count 2 'ordinary and Docker-opt-in actual main each expose one injected preflight target set'
    $round2DockerPreflightTargets = @($script:round2PreflightTargetSets[1].values)
    foreach ($injectedDockerTarget in @(
        $round2DockerSource,
        $round2DockerBackup,
        'C:\round2-fixture\docker-backup-manifest.json',
        [string]$script:round2ComposeMetadata.winner,
        @($script:round2ComposeMetadata.plugin_roots)[0],
        @($script:round2ComposeMetadata.plugin_roots)[1],
        'C:\round2-fixture\Docker\wsl\data'
    )) {
        Assert-True ($injectedDockerTarget -in $round2DockerPreflightTargets) "Docker-opt-in actual main uses injected preparation target: $injectedDockerTarget"
    }
    foreach ($forbiddenSentinelName in @('checkpoint_writer', 'process_runner', 'wsl_runner', 'service_runner', 'path_reader', 'path_writer', 'docker_execute')) {
        Assert-Equal ([int]$script:round2MainCounts[$forbiddenSentinelName]) 0 "captured Docker-opt-in actual main keeps $forbiddenSentinelName at zero"
    }
    Assert-Equal $script:round2MainCounts.environment_probe 2 'ordinary and Docker-opt-in actual main each use the injected environment once'
    Assert-Equal $script:round2MainCounts.environment_check 2 'ordinary and Docker-opt-in actual main each run one initial environment check'
    Assert-Equal $script:round2MainCounts.boot_session_probe 2 'ordinary and Docker-opt-in actual main each use injected boot provenance'
    Assert-Equal $script:round2MainCounts.preflight_check 2 'ordinary and Docker-opt-in actual main each use injected preflight once'
    Assert-Equal $script:round2MainCounts.live_execute 2 'ordinary and Docker-opt-in actual main each use captured live execution once'
    Assert-Equal $script:round2MainCounts.completion_writer 2 'ordinary and Docker-opt-in actual main each use the injected completion writer'
    Assert-Equal $script:round2MainCounts.precondition_check 0 'capturing live executor never runs per-action mutation preconditions'
    $round2FilesystemAfter = @(& $round2FilesystemSnapshot $testRoot)
    Assert-Equal ($round2FilesystemAfter -join '|') ($round2FilesystemBefore -join '|') 'both injected actual-main preparations leave fixture filesystem state unchanged'
    Assert-Equal ([Environment]::GetEnvironmentVariable('Path', 'User')) $round2UserPathBefore 'both injected actual-main preparations leave registry-backed user PATH unchanged'
    Assert-Equal ([string]$env:Path) $round2ProcessPathBefore 'both injected actual-main preparations leave process PATH unchanged'
    Assert-Equal $script:round2PathEquivalentState 'C:\Fixture Existing PATH' 'both injected actual-main preparations leave PATH-equivalent fixture state unchanged'

    $plannedCommands = @($actions | ForEach-Object { @($_.arguments) -join ' ' }) -join "`n"
    Assert-True ($plannedCommands -notmatch '(?im)(?:^|\s)winget(?:\.exe)?(?:\s|$)|wsl(?:\.exe)?\s+--update|git\s+config\s+--global|docker\s+(?:system\s+prune|desktop\s+(?:reset|uninstall))|Ableton') 'plan contains no forbidden package manager, WSL update, Git-global, destructive Docker, or Ableton action'

    $publicLocalAppData = Join-Path $testRoot 'public-local-app-data'
    $before = @(Get-ChildItem -LiteralPath $testRoot -Force | Select-Object -ExpandProperty FullName)
    $public = Invoke-InstallerProcess -Arguments @('-PlanOnly') -Environment @{ LOCALAPPDATA = $publicLocalAppData }
    $after = @(Get-ChildItem -LiteralPath $testRoot -Force | Select-Object -ExpandProperty FullName)
    Assert-Equal $public.ExitCode 0 'public PlanOnly exits successfully'
    $publicPlan = $public.Text | ConvertFrom-Json
    Assert-Equal $publicPlan.cache_root (Join-Path $publicLocalAppData 'doppelbanger\downloads') 'public PlanOnly reports the intended cache'
    Assert-Equal ($before -join '|') ($after -join '|') 'public PlanOnly creates no cache, tool, checkpoint, or other path'
    Assert-True (-not (Test-Path -LiteralPath $publicLocalAppData)) 'public PlanOnly does not create LOCALAPPDATA roots'
    $publicOutsideCheckpoint = Invoke-InstallerProcess -Arguments @('-PlanOnly', '-CheckpointPath', (Join-Path $testRoot 'outside-public-checkpoint.json')) -Environment @{ LOCALAPPDATA = $publicLocalAppData }
    Assert-True ($publicOutsideCheckpoint.ExitCode -ne 0 -and $publicOutsideCheckpoint.Text -match 'DBINST_CHECKPOINT_PATH_INVALID') 'public entry point rejects checkpoint overrides outside its one canonical LOCALAPPDATA path'

    $alternateLock = Join-Path $testRoot 'alternate-lock.json'
    [IO.File]::WriteAllText($alternateLock, ($lock | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    $override = Invoke-InstallerProcess -Arguments @('-PlanOnly', '-LockPath', $alternateLock)
    Assert-True ($override.ExitCode -ne 0) 'public installer rejects a live lock override'
    Assert-True ($override.Text -match 'DBINST_LOCK_OVERRIDE_FORBIDDEN') 'live lock override has a stable code'

    $downloadRoot = Join-Path $testRoot 'artifact-download'
    [IO.Directory]::CreateDirectory($downloadRoot) | Out-Null
    $artifactPath = Join-Path $downloadRoot 'artifact.bin'
    $goodBytes = [Text.Encoding]::UTF8.GetBytes('verified artifact bytes')
    $goodHash = Get-ByteArraySha256 -Bytes $goodBytes
    $script:downloads = 0
    $verified = Get-VerifiedArtifact -Url 'https://example.invalid/artifact.bin' -Sha256 $goodHash -CachePath $artifactPath -Downloader {
        param($Url, $Destination)
        $script:downloads++
        [IO.File]::WriteAllBytes($Destination, $goodBytes)
    }
    Assert-Equal $verified $artifactPath 'verified download is atomically placed in cache'
    Assert-Equal $script:downloads 1 'missing artifact downloads once'
    Get-VerifiedArtifact -Url 'https://example.invalid/artifact.bin' -Sha256 $goodHash -CachePath $artifactPath -Downloader { throw 'cached verified artifact must not download again' } | Out-Null
    Assert-True $true 'cached artifact is reverified without network'
    Assert-ThrowsCode { Assert-ArtifactHash -Path $artifactPath -Sha256 $goodHash.ToUpperInvariant() } 'DBINST_LOCK_INVALID' 'artifact verifier rejects uppercase expected SHA instead of normalizing provenance'

    # Fix Round 1: every bootstrap cache/download use is physical, and the exact verified leaf stays leased through runner completion.
    $hardlinkArtifactSource = Join-Path $downloadRoot 'hardlink-artifact-source.bin'
    $hardlinkArtifactCache = Join-Path $downloadRoot 'hardlink-artifact-cache.bin'
    [IO.File]::WriteAllBytes($hardlinkArtifactSource, $goodBytes)
    New-Item -ItemType HardLink -Path $hardlinkArtifactCache -Target $hardlinkArtifactSource | Out-Null
    Assert-ThrowsCode {
        Get-VerifiedArtifact -Url 'https://example.invalid/hardlink-cache.bin' -Sha256 $goodHash -CachePath $hardlinkArtifactCache | Out-Null
    } 'DBINST_ARTIFACT_PROVENANCE_INVALID' 'hardlinked cached bootstrap artifact is rejected on reuse'

    $hardlinkDownloadedCache = Join-Path $downloadRoot 'hardlink-downloaded-cache.bin'
    Assert-ThrowsCode {
        Get-VerifiedArtifact -Url 'https://example.invalid/hardlink-download.bin' -Sha256 $goodHash -CachePath $hardlinkDownloadedCache -Downloader {
            param($Url, $Destination)
            New-Item -ItemType HardLink -Path $Destination -Target $hardlinkArtifactSource | Out-Null
        } | Out-Null
    } 'DBINST_ARTIFACT_PROVENANCE_INVALID' 'hardlinked downloader output never enters the trusted bootstrap cache'
    Assert-True (-not (Test-Path -LiteralPath $hardlinkDownloadedCache)) 'rejected hardlinked download leaves no trusted cache path'

    $junctionArtifactBacking = Join-Path $testRoot 'junction-artifact-backing'
    $junctionArtifactRoot = Join-Path $testRoot 'junction-artifact-root'
    [IO.Directory]::CreateDirectory($junctionArtifactBacking) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $junctionArtifactBacking 'artifact.bin'), $goodBytes)
    New-Item -ItemType Junction -Path $junctionArtifactRoot -Target $junctionArtifactBacking | Out-Null
    try {
        Assert-ThrowsCode {
            Get-VerifiedArtifact -Url 'https://example.invalid/junction-cache.bin' -Sha256 $goodHash -CachePath (Join-Path $junctionArtifactRoot 'artifact.bin') | Out-Null
        } 'DBINST_ARTIFACT_PROVENANCE_INVALID' 'bootstrap artifact beneath a reparse/junction ancestor is rejected'
    }
    finally { if (Test-Path -LiteralPath $junctionArtifactRoot) { [IO.Directory]::Delete($junctionArtifactRoot, $false) } }

    $identityArtifact = Join-Path $downloadRoot 'identity-artifact.bin'
    $identityAlternate = Join-Path $downloadRoot 'identity-alternate.bin'
    [IO.File]::WriteAllBytes($identityArtifact, $goodBytes)
    [IO.File]::WriteAllBytes($identityAlternate, $goodBytes)
    Assert-ThrowsCode {
        Open-VerifiedBootstrapArtifactLease -Path $identityArtifact -Sha256 $goodHash -LeafStreamFactory {
            param($ExpectedPath)
            return New-Object IO.FileStream($identityAlternate, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        } | Out-Null
    } 'DBINST_ARTIFACT_PROVENANCE_INVALID' 'bootstrap lease rejects a same-hash leaf handle whose volume/file identity does not match the launch pathname'

    $leaseParent = Join-Path $testRoot 'bootstrap-lease-parent'
    [IO.Directory]::CreateDirectory($leaseParent) | Out-Null
    $leaseArtifact = Join-Path $leaseParent 'bootstrap.exe'
    [IO.File]::WriteAllBytes($leaseArtifact, $goodBytes)
    $leaseHash = Get-FileSha256 -Path $leaseArtifact
    $script:leaseBlocks = [ordered]@{ overwrite = $false; delete = $false; leaf_rename = $false; ancestor_rename = $false }
    $leaseExit = Invoke-VerifiedBootstrapInstaller -ArtifactPath $leaseArtifact -Sha256 $leaseHash -Arguments @('--quiet') -Runner {
        param($Path, $Arguments)
        try { [IO.File]::WriteAllText($Path, 'swap') } catch [IO.IOException] { $script:leaseBlocks.overwrite = $true }
        try { [IO.File]::Delete($Path) } catch [IO.IOException] { $script:leaseBlocks.delete = $true }
        try { [IO.File]::Move($Path, ($Path + '.swapped')) } catch [IO.IOException] { $script:leaseBlocks.leaf_rename = $true }
        try { [IO.Directory]::Move((Split-Path -Parent $Path), ((Split-Path -Parent $Path) + '-swapped')) } catch [IO.IOException] { $script:leaseBlocks.ancestor_rename = $true }
        return 0
    }
    Assert-Equal $leaseExit 0 'regular physical bootstrap artifact executes through the verified lease'
    foreach ($leaseOperation in @('overwrite', 'delete', 'leaf_rename', 'ancestor_rename')) {
        Assert-True ([bool]$script:leaseBlocks[$leaseOperation]) "bootstrap lease blocks $leaseOperation during runner completion"
    }
    $beforeLaunchHardlink = Join-Path $leaseParent 'before-launch-hardlink.exe'
    $script:runnerAfterHardlink = 0
    try {
        Assert-ThrowsCode {
            Invoke-VerifiedBootstrapInstaller -ArtifactPath $leaseArtifact -Sha256 $leaseHash -Arguments @('--quiet') -BeforeLaunch {
                New-Item -ItemType HardLink -Path $beforeLaunchHardlink -Target $leaseArtifact | Out-Null
            } -Runner { $script:runnerAfterHardlink++; return 0 } | Out-Null
        } 'DBINST_ARTIFACT_PROVENANCE_INVALID' 'new hardlink created after hashing is rejected before bootstrap launch'
        Assert-Equal $script:runnerAfterHardlink 0 'post-hash hardlink detection invokes no runner'
    }
    finally { if (Test-Path -LiteralPath $beforeLaunchHardlink) { [IO.File]::Delete($beforeLaunchHardlink) } }
    $runnerHardlink = Join-Path $leaseParent 'runner-hardlink.exe'
    $script:hardlinkRunnerCalls = 0
    try {
        Assert-ThrowsCode {
            Invoke-VerifiedBootstrapInstaller -ArtifactPath $leaseArtifact -Sha256 $leaseHash -Arguments @('--quiet') -Runner {
                $script:hardlinkRunnerCalls++
                New-Item -ItemType HardLink -Path $runnerHardlink -Target $leaseArtifact | Out-Null
                return 0
            } | Out-Null
        } 'DBINST_ARTIFACT_PROVENANCE_INVALID' 'new hardlink created during the awaited runner is detected before the lease releases'
        Assert-Equal $script:hardlinkRunnerCalls 1 'runner-time hardlink detection occurs after the awaited runner returns'
    }
    finally { if (Test-Path -LiteralPath $runnerHardlink) { [IO.File]::Delete($runnerHardlink) } }
    $releasedArtifact = $leaseArtifact + '.released'
    [IO.File]::Move($leaseArtifact, $releasedArtifact)
    [IO.File]::Move($releasedArtifact, $leaseArtifact)
    $releasedParent = $leaseParent + '-released'
    [IO.Directory]::Move($leaseParent, $releasedParent)
    [IO.Directory]::Move($releasedParent, $leaseParent)
    Assert-True (Test-Path -LiteralPath $leaseArtifact -PathType Leaf) 'bootstrap leaf and ancestor leases release after runner completion'

    Assert-True ($installerSource -match '(?s)function Install-VsBuildTools.+?Invoke-VerifiedBootstrapInstaller') 'VS bootstrap uses the verified artifact lease seam'
    Assert-True ($installerSource -match '(?s)function Install-RustToolchain.+?Invoke-VerifiedBootstrapInstaller') 'rustup-init bootstrap uses the verified artifact lease seam'
    Assert-True ($installerSource -match '(?s)function Upgrade-DockerDesktop.+?Invoke-VerifiedBootstrapInstaller') 'Docker bootstrap uses the verified artifact lease seam'

    $script:beforeLaunchCalls = 0
    Assert-ThrowsCode {
        Invoke-VerifiedBootstrapInstaller -ArtifactPath $artifactPath -Sha256 ('0' * 64) -Arguments @('--quiet') -BeforeLaunch { $script:beforeLaunchCalls++ } -Runner { throw 'invalid hash must not launch' } | Out-Null
    } 'DBINST_CHECKSUM_MISMATCH' 'invalid bootstrap hash fails before the final launch seam'
    Assert-Equal $script:beforeLaunchCalls 0 'invalid bootstrap hash never invokes BeforeLaunch'
    $script:launchOrder = New-Object 'Collections.Generic.List[string]'
    $orderedBootstrapExit = Invoke-VerifiedBootstrapInstaller -ArtifactPath $artifactPath -Sha256 $goodHash -Arguments @('--quiet') -BeforeLaunch { $script:launchOrder.Add('before-launch') } -Runner { $script:launchOrder.Add('runner'); return 0 }
    Assert-Equal $orderedBootstrapExit 0 'valid bootstrap returns its runner exit code through the final launch seam'
    Assert-Equal ($script:launchOrder -join ',') 'before-launch,runner' 'BeforeLaunch runs after final hash and immediately before runner'

    [IO.File]::WriteAllText($artifactPath, 'tampered cache')
    $script:executionCount = 0
    Assert-ThrowsCode {
        Install-VsBuildTools -Lock $lock -ArtifactPath $artifactPath -Runner { param($Path, $Arguments) $script:executionCount++; return 0 }
    } 'DBINST_CHECKSUM_MISMATCH' 'checksum mismatch fails before VS execution'
    Assert-Equal $script:executionCount 0 'checksum mismatch never executes an installer'

    $badDownload = Join-Path $downloadRoot 'bad-download.bin'
    Assert-ThrowsCode {
        Get-VerifiedArtifact -Url 'https://example.invalid/bad.bin' -Sha256 $goodHash -CachePath $badDownload -Downloader {
            param($Url, $Destination)
            [IO.File]::WriteAllText($Destination, 'wrong downloaded bytes')
        }
    } 'DBINST_CHECKSUM_MISMATCH' 'downloaded checksum mismatch fails closed'
    Assert-True (-not (Test-Path -LiteralPath $badDownload)) 'failed downloaded bytes never enter the trusted cache'

    $savedSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    $script:protocolDuringDownload = $null
    try {
        Invoke-Tls12Download -Url 'https://example.invalid/tls.bin' -Destination (Join-Path $downloadRoot 'tls.bin') -DownloadOperation {
            param($Url, $Destination)
            $script:protocolDuringDownload = [Net.ServicePointManager]::SecurityProtocol
            [IO.File]::WriteAllText($Destination, 'injected TLS download')
        }
        Assert-True (([int]$script:protocolDuringDownload -band 3072) -eq 3072) 'download adds TLS 1.2 while the transfer runs'
        Assert-Equal ([int][Net.ServicePointManager]::SecurityProtocol) ([int]$savedSecurityProtocol) 'download restores the prior process SecurityProtocol'
    }
    finally { [Net.ServicePointManager]::SecurityProtocol = $savedSecurityProtocol }

    $script:starterArguments = $null
    $bootstrapExit = Invoke-BootstrapProcess -Path $artifactPath -Arguments @('--one', 'two words') -ProcessStarter {
        param($StartArguments)
        $script:starterArguments = $StartArguments
        return [pscustomobject]@{ ExitCode = 0 }
    }
    Assert-Equal $bootstrapExit 0 'awaited bootstrap process returns the top-level exit code'
    Assert-True $script:starterArguments.Wait 'bootstrap uses Start-Process wait semantics'
    Assert-True $script:starterArguments.PassThru 'bootstrap captures the authoritative top-level process'

    $pathOne = Join-Path $testRoot 'path-one'
    $pathTwo = Join-Path $testRoot 'path-two'
    [IO.Directory]::CreateDirectory($pathOne) | Out-Null
    [IO.Directory]::CreateDirectory($pathTwo) | Out-Null
    $pathResult = Set-DoppelbangerUserPath -RequiredDirectories @($pathOne, $pathTwo, $pathOne.ToUpperInvariant()) -CurrentUserPath 'C:\Unrelated;C:\Other' -PlanOnly
    Assert-Equal $pathResult.path "C:\Unrelated;C:\Other;$pathOne;$pathTwo" 'user PATH preserves unrelated entries and adds exact directories once'
    $pathAgain = Set-DoppelbangerUserPath -RequiredDirectories @($pathOne, $pathTwo) -CurrentUserPath $pathResult.path -PlanOnly
    Assert-Equal $pathAgain.path $pathResult.path 'user PATH update is idempotent'
    Assert-True (-not $pathAgain.changed) 'idempotent PATH plan reports no change'
    $textPreservingPath = 'C:\Unrelated\; C:\Keep This Text '
    $textPreservingResult = Set-DoppelbangerUserPath -RequiredDirectories @($pathOne) -CurrentUserPath $textPreservingPath -PlanOnly
    Assert-Equal $textPreservingResult.path "$textPreservingPath;$pathOne" 'user PATH preserves unrelated order and text exactly'

    # Fix Round 1: environment expansion is comparison-only, and a live PATH write is provenance/concurrency/readback guarded.
    $savedPathEquivalentRoot = $env:DBINST_PATH_EQUIVALENT_ROOT
    try {
        $env:DBINST_PATH_EQUIVALENT_ROOT = $testRoot
        $environmentPathText = '%DBINST_PATH_EQUIVALENT_ROOT%\path-one;C:\Keep Literal Text'
        $environmentEquivalent = Set-DoppelbangerUserPath -RequiredDirectories @($pathOne) -CurrentUserPath $environmentPathText -PlanOnly
        Assert-True (-not $environmentEquivalent.changed) 'environment-variable PATH entry compares equivalent to its required absolute directory'
        Assert-Equal $environmentEquivalent.path $environmentPathText 'environment expansion never rewrites original PATH text or order'
    }
    finally { $env:DBINST_PATH_EQUIVALENT_ROOT = $savedPathEquivalentRoot }

    $script:pathState = 'C:\Existing'
    $script:pathReads = 0
    $script:pathWrites = 0
    $script:pathProvenanceChecks = 0
    $guardedPath = Set-DoppelbangerUserPath -RequiredDirectories @($pathOne) -PathReader { $script:pathReads++; return $script:pathState } -ProvenanceCheck { $script:pathProvenanceChecks++ } -PathWriter { param($Value) $script:pathWrites++; $script:pathState = $Value }
    Assert-Equal $guardedPath.path "C:\Existing;$pathOne" 'guarded PATH write computes the append-only value'
    Assert-Equal $script:pathProvenanceChecks 1 'PATH write revalidates tool provenance exactly once immediately before mutation'
    Assert-Equal $script:pathWrites 1 'stable guarded PATH baseline writes exactly once'
    Assert-True ($script:pathReads -ge 3) 'guarded PATH flow reads initial, concurrent baseline, and stored readback state'
    Assert-Equal $script:pathState $guardedPath.path 'guarded PATH readback proves exact stored text'

    $script:concurrentPathReads = 0
    $script:concurrentPathWrites = 0
    Assert-ThrowsCode {
        Set-DoppelbangerUserPath -RequiredDirectories @($pathOne) -PathReader {
            $script:concurrentPathReads++
            if ($script:concurrentPathReads -eq 1) { return 'C:\Baseline' }
            return 'C:\Changed Concurrently'
        } -ProvenanceCheck { } -PathWriter { $script:concurrentPathWrites++ } | Out-Null
    } 'DBINST_PATH_CONCURRENT_CHANGE' 'concurrent user PATH baseline change blocks the write'
    Assert-Equal $script:concurrentPathWrites 0 'concurrent PATH change invokes no writer'

    $script:driftPathWrites = 0
    Assert-ThrowsCode {
        Set-DoppelbangerUserPath -RequiredDirectories @($pathOne) -PathReader { return 'C:\Baseline' } -ProvenanceCheck { Stop-Installer 'DBINST_PATH_PROVENANCE_INVALID' 'Node drifted between install and PATH action' } -PathWriter { $script:driftPathWrites++ } | Out-Null
    } 'DBINST_PATH_PROVENANCE_INVALID' 'tool drift between install and PATH action blocks the write'
    Assert-Equal $script:driftPathWrites 0 'provenance drift invokes no PATH writer'

    $script:badReadbackState = 'C:\Baseline'
    Assert-ThrowsCode {
        Set-DoppelbangerUserPath -RequiredDirectories @($pathOne) -PathReader { return $script:badReadbackState } -ProvenanceCheck { } -PathWriter { param($Value) $script:badReadbackState = 'C:\Wrong Stored Value' } | Out-Null
    } 'DBINST_PATH_WRITE_FAILED' 'PATH writer readback mismatch fails closed'

    $script:pathStateProbeNames = New-Object 'Collections.Generic.List[string]'
    Assert-True (Assert-WindowsToolchainPathProvenance -Lock $lock -Plan $plan -RustupHome (Join-Path $testRoot 'path-rustup') -RustReceiptPath (Join-Path $testRoot 'path-receipt.json') -LockSha256 (Get-FileSha256 -Path $installerLockPath) -StateProbe {
        param($Name, $Action)
        $script:pathStateProbeNames.Add($Name)
        return 'exact'
    }) 'all five required developer tool states can be reproven immediately before PATH'
    Assert-Equal ($script:pathStateProbeNames -join ',') 'visual_studio,rustup,cmake,ninja,node' 'PATH provenance rechecks VS, Rust, CMake, Ninja, and Node in order'
    Assert-ThrowsCode {
        Assert-WindowsToolchainPathProvenance -Lock $lock -Plan $plan -RustupHome (Join-Path $testRoot 'path-rustup') -RustReceiptPath (Join-Path $testRoot 'path-receipt.json') -LockSha256 (Get-FileSha256 -Path $installerLockPath) -StateProbe { param($Name, $Action); if ($Name -eq 'node') { return 'conflict' }; return 'exact' } | Out-Null
    } 'DBINST_PATH_PROVENANCE_INVALID' 'any required tool drift fails the aggregate PATH provenance gate'

    $volumeCalls = New-Object 'Collections.Generic.List[string]'
    $preconditions = Assert-InstallPreconditions -TargetPaths @('C:\tools\one', 'D:\data\two', 'C:\tools\three') -VolumeProbe {
        param($Root)
        $volumeCalls.Add($Root)
        if ($Root -ieq 'C:\') { return 45 }
        return 41
    } -PendingRebootProbe { return $false }
    Assert-Equal $preconditions.volumes.Count 2 'preconditions check every distinct target volume'
    Assert-Equal $volumeCalls.Count 2 'each distinct target volume is probed once'
    Assert-ThrowsCode {
        Assert-InstallPreconditions -TargetPaths @('C:\tools', 'D:\data') -VolumeProbe { param($Root) if ($Root -ieq 'D:\') { return 39.9 }; return 80 } -PendingRebootProbe { return $false } | Out-Null
    } 'DBINST_LOW_DISK' 'any target volume below 40 GiB blocks mutation'
    Assert-ThrowsCode {
        Assert-InstallPreconditions -TargetPaths @('C:\tools') -VolumeProbe { return 80 } -PendingRebootProbe { return $true } | Out-Null
    } 'DBINST_PENDING_REBOOT' 'pending reboot blocks mutation'

    $checkpointPath = Join-Path $testRoot 'resume-checkpoint.json'
    $script:sequence = New-Object 'Collections.Generic.List[string]'
    $actions3010 = @(
        [pscustomobject]@{ name = 'first'; checkpoint_on_3010 = $true; invoke = { $script:sequence.Add('first'); return 3010 } },
        [pscustomobject]@{ name = 'later-installer'; invoke = { $script:sequence.Add('later-installer'); return 0 } },
        [pscustomobject]@{ name = 'later-move'; invoke = { $script:sequence.Add('later-move'); return 0 } }
    )
    Assert-ThrowsCode {
        Invoke-InstallActionSequence -Actions $actions3010 -CheckpointPath $checkpointPath -CheckpointRoot (Split-Path -Parent $checkpointPath) -LockSha256 (Get-FileSha256 -Path $installerLockPath) -BootSessionMarker 'old-boot' -PreconditionCheck { $script:sequence.Add('precondition') }
    } 'DBINST_REBOOT_REQUIRED' 'exit 3010 writes a checkpoint and halts'
    Assert-Equal ($script:sequence -join ',') 'precondition,first' 'no later installer or move runs after exit 3010'
    $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
    Assert-Equal $checkpoint.schema_version 1 'checkpoint schema is versioned'
    Assert-Equal $checkpoint.next_action_index 1 'checkpoint resumes at the first unrun action'
    Assert-True $checkpoint.requires_reboot 'checkpoint explicitly requires reboot'

    $script:sequence.Clear()
    $resumeActions = @(
        [pscustomobject]@{ name = 'first'; postcondition = { $script:sequence.Add('completed-postcondition') }; invoke = { throw 'completed action must not rerun' } },
        [pscustomobject]@{ name = 'later-installer'; postcondition = { $script:sequence.Add('resume-action-postcondition') }; invoke = { $script:sequence.Add('resume-action'); return 0 } },
        [pscustomobject]@{ name = 'later-move'; invoke = { return 0 } }
    )
    Invoke-InstallActionSequence -Actions $resumeActions -CheckpointPath $checkpointPath -CheckpointRoot (Split-Path -Parent $checkpointPath) -LockSha256 (Get-FileSha256 -Path $installerLockPath) -BootSessionMarker 'new-boot' -Resume -PreconditionCheck { $script:sequence.Add('resume-precondition') } | Out-Null
    Assert-Equal ($script:sequence -join ',') 'resume-precondition,completed-postcondition,resume-precondition,resume-action,resume-action-postcondition,resume-precondition' 'resume rechecks preconditions and completed postconditions before each remaining mutation, then validates each result'
    Assert-True (-not (Test-Path -LiteralPath $checkpointPath)) 'successful resume removes its checkpoint'

    $rustCheckpoint = Join-Path $testRoot 'rust-3010-checkpoint.json'
    Assert-ThrowsCode {
        Invoke-InstallActionSequence -Actions @([pscustomobject]@{ name = 'rustup'; checkpoint_on_3010 = $false; invoke = { return 3010 } }) -CheckpointPath $rustCheckpoint -LockSha256 (Get-FileSha256 -Path $installerLockPath) -PreconditionCheck { } | Out-Null
    } 'DBINST_ACTION_FAILED' 'rustup exit 3010 is a failure rather than a resumable success'
    Assert-True (-not (Test-Path -LiteralPath $rustCheckpoint)) 'rustup exit 3010 never writes a reboot checkpoint'

    $successfulArtifact = Join-Path $downloadRoot 'successful-bootstrap.exe'
    [IO.File]::WriteAllBytes($successfulArtifact, $goodBytes)
    $bootstrapLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $bootstrapLock.visual_studio.sha256 = $goodHash
    $bootstrapLock.rust.rustup_sha256 = $goodHash
    $script:vsPostcondition = 0
    $vsExit = Install-VsBuildTools -Lock $bootstrapLock -ArtifactPath $successfulArtifact -Runner { return 0 } -PostconditionCheck { $script:vsPostcondition++ }
    Assert-Equal $vsExit 0 'VS successful top-level exit is returned'
    Assert-Equal $script:vsPostcondition 1 'VS exact instance/component postcondition runs after exit 0'
    $savedRustupHome = $env:RUSTUP_HOME
    $savedCargoHome = $env:CARGO_HOME
    $script:rustEnvironment = ''
    $script:rustPostcondition = 0
    try {
        $rustExit = Install-RustToolchain -Lock $bootstrapLock -ArtifactPath $successfulArtifact -RustupHome (Join-Path $testRoot 'rustup-home') -CargoHome (Join-Path $testRoot 'cargo-home') -Runner {
            $script:rustEnvironment = "$env:RUSTUP_HOME|$env:CARGO_HOME"
            return 0
        } -PostconditionCheck { $script:rustPostcondition++ }
    }
    finally {
        $env:RUSTUP_HOME = $savedRustupHome
        $env:CARGO_HOME = $savedCargoHome
    }
    Assert-Equal $rustExit 0 'rustup successful top-level exit is returned'
    Assert-Equal $script:rustEnvironment "$(Join-Path $testRoot 'rustup-home')|$(Join-Path $testRoot 'cargo-home')" 'rustup uses consistent process RUSTUP_HOME and CARGO_HOME'
    Assert-Equal $script:rustPostcondition 1 'physical Rust manifests/components postcondition runs after exit 0'

    # Final precommit repair: a VS state record alone never proves exact physical installation state.
    $emptyVsRoot = Join-Path $testRoot 'empty-vs-fixture'
    $emptyVsInstall = Join-Path $emptyVsRoot 'Microsoft Visual Studio\2022\BuildTools'
    $emptyVsInstances = Join-Path $emptyVsRoot 'instances\exact-instance'
    [IO.Directory]::CreateDirectory($emptyVsInstall) | Out-Null
    [IO.Directory]::CreateDirectory($emptyVsInstances) | Out-Null
    $emptyVsState = [pscustomobject][ordered]@{
        installationVersion = [string]$lock.visual_studio.installation_version
        installationPath = $emptyVsInstall
        catalogInfo = [pscustomobject]@{ productDisplayVersion = [string]$lock.visual_studio.product_version }
    }
    [IO.File]::WriteAllText((Join-Path $emptyVsInstances 'state.json'), ($emptyVsState | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Assert-Equal (Get-VisualStudioInstalledState -Lock $lock -InstallPath $emptyVsInstall -InstancesRoot (Split-Path -Parent $emptyVsInstances) -WindowsSdkRoot (Join-Path $emptyVsRoot 'Windows Kits\10')) 'repairable' 'matching VS JSON with an empty physical root is not exact or skipped'

    $vsFixture = New-ExactVisualStudioFixture -Lock $lock -Root (Join-Path $testRoot 'exact-vs-fixture')
    $script:vswhereInvokedPath = ''
    $script:vswhereInvokedArguments = @()
    $vswhereRunner = {
        param($Path, $Arguments)
        $script:vswhereInvokedPath = [string]$Path
        $script:vswhereInvokedArguments = @($Arguments)
        return [pscustomobject]@{ exit_code = 0; output = $vsFixture.install_root }
    }
    Assert-VisualStudioInstallPostcondition -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner
    Assert-Equal $script:vswhereInvokedPath ([IO.Path]::GetFullPath($vsFixture.vswhere_path)) 'VS component proof invokes the exact absolute bundled vswhere path'
    Assert-Equal ($script:vswhereInvokedArguments -join ' ') '-products Microsoft.VisualStudio.Product.BuildTools -requires Microsoft.VisualStudio.Workload.VCTools Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64 Microsoft.VisualStudio.Component.Windows11SDK.26100 -property installationPath' 'VS component proof filters the exact Build Tools product and all pinned IDs'
    Assert-Equal (Get-VisualStudioInstalledState -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner) 'exact' 'package-less state JSON plus successful vswhere component proof is exact'
    Assert-ThrowsCode {
        Assert-VisualStudioInstallPostcondition -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner { return [pscustomobject]@{ exit_code = 1; output = $vsFixture.install_root } }
    } 'DBINST_VS_POSTCONDITION_FAILED' 'nonzero vswhere component query fails exact state'
    Assert-ThrowsCode {
        Assert-VisualStudioInstallPostcondition -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner { return [pscustomobject]@{ exit_code = 0; output = 'C:\Other\Visual Studio' } }
    } 'DBINST_VS_POSTCONDITION_FAILED' 'vswhere output missing the fixed VS path fails exact state'
    Assert-ThrowsCode {
        Assert-VisualStudioInstallPostcondition -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner {
            param($Path, $Arguments)
            $output = if (@($Arguments) -contains '*') { $vsFixture.install_root } else { 'C:\Other\Visual Studio' }
            return [pscustomobject]@{ exit_code = 0; output = $output }
        }
    } 'DBINST_VS_POSTCONDITION_FAILED' 'a wildcard-product-only vswhere result cannot prove the fixed Build Tools product'
    $script:exactVsMutation = 0
    Invoke-IdempotentInstallAction -Name 'visual_studio' -StateProbe { Get-VisualStudioInstalledState -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner } -Mutation { $script:exactVsMutation++ } | Out-Null
    Assert-Equal $script:exactVsMutation 0 'complete physical VS fixture skips downloader and installer mutation'

    $sdkAncestorBacking = Join-Path $testRoot 'sdk-ancestor-backing'
    $sdkAncestorFixture = New-ExactVisualStudioFixture -Lock $lock -Root $sdkAncestorBacking
    $sdkAncestorJunction = Join-Path $testRoot 'sdk-ancestor-junction'
    New-Item -ItemType Junction -Path $sdkAncestorJunction -Target $sdkAncestorBacking | Out-Null
    $redirectedSdkRoot = Join-Path $sdkAncestorJunction 'Windows Kits\10'
    try {
        Assert-ThrowsCode { Assert-VisualStudioInstallPostcondition -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $redirectedSdkRoot -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner } 'DBINST_VS_POSTCONDITION_FAILED' 'SDK root with an ancestor junction fails the VS postcondition'
        Assert-Equal (Get-VisualStudioInstalledState -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $redirectedSdkRoot -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner) 'conflict' 'SDK root with an ancestor junction is conflicting installed state'
        Assert-ThrowsCode { Assert-InstallPreflightTargetAncestry -TargetPaths @($redirectedSdkRoot) | Out-Null } 'DBINST_PATH_UNSAFE' 'preflight rejects an SDK target beneath an ancestor junction'
    }
    finally { if (Test-Path -LiteralPath $sdkAncestorJunction) { [IO.Directory]::Delete($sdkAncestorJunction, $false) } }

    $instancesAncestorBacking = Join-Path $testRoot 'instances-ancestor-backing'
    $instancesAncestorFixture = New-ExactVisualStudioFixture -Lock $lock -Root $instancesAncestorBacking
    $redirectedState = Get-Content -LiteralPath $instancesAncestorFixture.state_path -Raw | ConvertFrom-Json
    $redirectedState.installationPath = $vsFixture.install_root
    [IO.File]::WriteAllText($instancesAncestorFixture.state_path, ($redirectedState | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $instancesAncestorJunction = Join-Path $testRoot 'instances-ancestor-junction'
    New-Item -ItemType Junction -Path $instancesAncestorJunction -Target $instancesAncestorBacking | Out-Null
    $redirectedInstancesRoot = Join-Path $instancesAncestorJunction 'instances'
    try {
        Assert-ThrowsCode { Assert-VisualStudioInstallPostcondition -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $redirectedInstancesRoot -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner } 'DBINST_VS_POSTCONDITION_FAILED' '_Instances root with an ancestor junction fails the VS postcondition'
        Assert-Equal (Get-VisualStudioInstalledState -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $redirectedInstancesRoot -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner) 'conflict' '_Instances root with an ancestor junction is conflicting installed state'
        Assert-ThrowsCode { Assert-InstallPreflightTargetAncestry -TargetPaths @($redirectedInstancesRoot) | Out-Null } 'DBINST_PATH_UNSAFE' 'preflight rejects an _Instances target beneath an ancestor junction'
    }
    finally { if (Test-Path -LiteralPath $instancesAncestorJunction) { [IO.Directory]::Delete($instancesAncestorJunction, $false) } }

    $installerAncestorBacking = Join-Path $testRoot 'installer-ancestor-backing'
    $installerAncestorFixture = New-ExactVisualStudioFixture -Lock $lock -Root $installerAncestorBacking
    $installerAncestorJunction = Join-Path $testRoot 'installer-ancestor-junction'
    New-Item -ItemType Junction -Path $installerAncestorJunction -Target $installerAncestorBacking | Out-Null
    $redirectedVswherePath = Join-Path $installerAncestorJunction 'Microsoft Visual Studio\Installer\vswhere.exe'
    try {
        Assert-ThrowsCode { Assert-VisualStudioInstallPostcondition -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $redirectedVswherePath -VswhereRunner $vswhereRunner } 'DBINST_VS_POSTCONDITION_FAILED' 'bundled vswhere with an ancestor junction fails the VS postcondition'
        Assert-Equal (Get-VisualStudioInstalledState -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $redirectedVswherePath -VswhereRunner $vswhereRunner) 'conflict' 'bundled vswhere with an ancestor junction is conflicting installed state'
        Assert-ThrowsCode { Assert-InstallPreflightTargetAncestry -TargetPaths @((Split-Path -Parent $redirectedVswherePath)) | Out-Null } 'DBINST_PATH_UNSAFE' 'preflight rejects a VS Installer target beneath an ancestor junction'
    }
    finally { if (Test-Path -LiteralPath $installerAncestorJunction) { [IO.Directory]::Delete($installerAncestorJunction, $false) } }

    Assert-True (Assert-InstallPreflightTargetAncestry -TargetPaths @($vsFixture.install_root, $vsFixture.sdk_root, $vsFixture.instances_root, (Split-Path -Parent $vsFixture.vswhere_path))) 'preflight accepts normal physical VS mutation roots'

    $vsCl = Join-Path $vsFixture.toolset_root 'bin\Hostx64\x64\cl.exe'
    [IO.File]::WriteAllText($vsCl, 'wrong architecture')
    Assert-True ((Get-VisualStudioInstalledState -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner) -cne 'exact') 'wrong-architecture cl.exe is never exact'
    Write-FakeAmd64Pe $vsCl
    $vsClSource = Join-Path $vsFixture.toolset_root 'bin\Hostx64\x64\cl-source.exe'
    Write-FakeAmd64Pe $vsClSource
    [IO.File]::Delete($vsCl)
    New-Item -ItemType HardLink -Path $vsCl -Target $vsClSource | Out-Null
    Assert-True ((Get-VisualStudioInstalledState -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner) -cne 'exact') 'hardlinked cl.exe is never exact'
    [IO.File]::Delete($vsCl); [IO.File]::Delete($vsClSource); Write-FakeAmd64Pe $vsCl

    $vsStateSource = Join-Path (Split-Path -Parent $vsFixture.state_path) 'state-source.json'
    [IO.File]::Move($vsFixture.state_path, $vsStateSource)
    New-Item -ItemType HardLink -Path $vsFixture.state_path -Target $vsStateSource | Out-Null
    Assert-True ((Get-VisualStudioInstalledState -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner) -cne 'exact') 'hardlinked VS state metadata is never exact'
    [IO.File]::Delete($vsFixture.state_path); [IO.File]::Move($vsStateSource, $vsFixture.state_path)

    $vsBinPath = Join-Path $vsFixture.toolset_root 'bin'
    $vsBinBacking = Join-Path $testRoot 'vs-bin-backing'
    [IO.Directory]::Move($vsBinPath, $vsBinBacking)
    New-Item -ItemType Junction -Path $vsBinPath -Target $vsBinBacking | Out-Null
    Assert-True ((Get-VisualStudioInstalledState -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner) -cne 'exact') 'internal VS toolset junction is never exact'
    [IO.Directory]::Delete($vsBinPath, $false); [IO.Directory]::Move($vsBinBacking, $vsBinPath)

    $unrelatedVsBacking = Join-Path $testRoot 'unrelated-vs-backing'
    $unrelatedVsJunction = Join-Path $vsFixture.install_root 'UnrelatedThirdPartyLink'
    [IO.Directory]::CreateDirectory($unrelatedVsBacking) | Out-Null
    New-Item -ItemType Junction -Path $unrelatedVsJunction -Target $unrelatedVsBacking | Out-Null
    Assert-Equal (Get-VisualStudioInstalledState -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner) 'exact' 'an unrelated junction outside all owned VS paths does not invalidate exact state'
    $missingOwnedVsBinary = Join-Path $vsFixture.toolset_root 'bin\Hostx64\x64\dumpbin.exe'
    [IO.File]::Delete($missingOwnedVsBinary)
    Assert-Equal (Get-VisualStudioInstalledState -Lock $lock -InstallPath $vsFixture.install_root -InstancesRoot $vsFixture.instances_root -WindowsSdkRoot $vsFixture.sdk_root -VswherePath $vsFixture.vswhere_path -VswhereRunner $vswhereRunner) 'repairable' 'unrelated VS reparse content does not turn a safe same-version missing owned file into conflict'
    Write-FakeAmd64Pe $missingOwnedVsBinary
    [IO.Directory]::Delete($unrelatedVsJunction, $false)

    # Final precommit repair: Rust exact state is physical and link-free throughout the locked toolchain.
    $rustFixture = New-ExactRustFixture -Lock $lock -RustupHome (Join-Path $testRoot 'exact-rust-fixture')
    $rustLockHash = Get-FileSha256 -Path $installerLockPath
    $missingRustReceipt = Join-Path $testRoot 'rust-receipts\missing.json'
    Assert-ThrowsCode {
        Assert-RustToolchainPostcondition -Lock $lock -RustupHome $rustFixture.rustup_home -ReceiptPath $missingRustReceipt -LockSha256 $rustLockHash
    } 'DBINST_RUST_RECEIPT_MISSING' 'a structural Rust toolchain without an external clean-install receipt is never exact'
    Assert-True ((Get-RustInstalledState -Lock $lock -RustupHome $rustFixture.rustup_home -ReceiptPath $missingRustReceipt -LockSha256 $rustLockHash) -ne 'exact') 'unreceipted preexisting Rust root is not reused as exact'

    $untrustedRustSentinel = Join-Path $rustFixture.root 'bin\preexisting-untrusted.exe'
    Write-FakeAmd64Pe $untrustedRustSentinel
    $rustReceiptPath = Join-Path $testRoot 'rust-receipts\rust-toolchain-receipt-v1.json'
    $script:rustRunnerSawAbsentRoot = $false
    $enrolledRustExit = Install-RustToolchain -Lock $bootstrapLock -ArtifactPath $successfulArtifact -RustupHome $rustFixture.rustup_home -CargoHome (Join-Path $testRoot 'receipt-cargo-home') -ReceiptPath $rustReceiptPath -LockSha256 $rustLockHash -Runner {
        $script:rustRunnerSawAbsentRoot = -not (Test-Path -LiteralPath $rustFixture.root)
        New-ExactRustFixture -Lock $bootstrapLock -RustupHome $rustFixture.rustup_home | Out-Null
        return 0
    }
    Assert-Equal $enrolledRustExit 0 'locked rustup current action enrolls a clean Rust tree'
    Assert-True $script:rustRunnerSawAbsentRoot 'unreceipted preexisting Rust root is quarantined before rustup runs'
    Assert-True (Test-Path -LiteralPath $rustReceiptPath -PathType Leaf) 'successful clean rustup action writes its external integrity receipt'
    Assert-True (-not (Test-PathNested -Path $rustReceiptPath -Root $rustFixture.root -AllowRoot)) 'Rust integrity receipt remains outside the Rust toolchain tree'
    $rustQuarantines = @(Get-ChildItem -LiteralPath (Split-Path -Parent $rustFixture.root) -Directory | Where-Object { $_.Name -like ((Split-Path -Leaf $rustFixture.root) + '.dbq-*') })
    Assert-Equal $rustQuarantines.Count 1 'unreceipted preexisting Rust root is retained in one explicit quarantine'
    Assert-True (Test-Path -LiteralPath (Join-Path $rustQuarantines[0].FullName 'bin\preexisting-untrusted.exe') -PathType Leaf) 'quarantine preserves the preexisting untrusted Rust bytes'
    Assert-True (-not (Test-Path -LiteralPath $untrustedRustSentinel)) 'fresh enrolled Rust root does not bless a preexisting extra binary'

    $failedRustupHome = Join-Path $testRoot 'failed-clean-rustup'
    $failedRustRoot = Join-Path (Join-Path $failedRustupHome 'toolchains') $bootstrapLock.rust.toolchain_directory
    $failedRustReceipt = Join-Path $testRoot 'rust-receipts\failed-clean-receipt.json'
    $failedRustExit = Install-RustToolchain -Lock $bootstrapLock -ArtifactPath $successfulArtifact -RustupHome $failedRustupHome -CargoHome (Join-Path $testRoot 'failed-clean-cargo') -ReceiptPath $failedRustReceipt -LockSha256 $rustLockHash -Runner {
        New-ExactRustFixture -Lock $bootstrapLock -RustupHome $failedRustupHome | Out-Null
        return 1
    }
    Assert-Equal $failedRustExit 1 'failed clean rustup action returns its runner exit code'
    Assert-True (-not (Test-Path -LiteralPath $failedRustRoot)) 'failed clean rustup action leaves no partial tree at the canonical target'
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path -Parent $failedRustRoot) -Directory | Where-Object { $_.Name -like ((Split-Path -Leaf $failedRustRoot) + '.dbf-*') }).Count 1 'failed clean rustup tree is retained in one explicit failure quarantine'
    Assert-True (-not (Test-Path -LiteralPath $failedRustReceipt)) 'failed clean rustup action leaves no integrity receipt'

    $rollbackRustFixture = New-ExactRustFixture -Lock $bootstrapLock -RustupHome (Join-Path $testRoot 'rust-rollback')
    $rollbackRustSentinel = Join-Path $rollbackRustFixture.root 'preexisting-sentinel.txt'
    [IO.File]::WriteAllText($rollbackRustSentinel, 'preexisting Rust bytes')
    $script:rollbackRustRunnerSawAbsentRoot = $false
    $rollbackRustExit = Install-RustToolchain -Lock $bootstrapLock -ArtifactPath $successfulArtifact -RustupHome $rollbackRustFixture.rustup_home -CargoHome (Join-Path $testRoot 'rust-rollback-cargo') -ReceiptPath (Join-Path $testRoot 'rust-receipts\rollback-failure.json') -LockSha256 $rustLockHash -Runner {
        $script:rollbackRustRunnerSawAbsentRoot = -not (Test-Path -LiteralPath $rollbackRustFixture.root)
        New-ExactRustFixture -Lock $bootstrapLock -RustupHome $rollbackRustFixture.rustup_home | Out-Null
        return 1
    }
    Assert-Equal $rollbackRustExit 1 'failed rustup action with a preexisting tree returns its runner exit code'
    Assert-True $script:rollbackRustRunnerSawAbsentRoot 'preexisting Rust tree remains quarantined while failed rustup runs against absence'
    Assert-True (Test-Path -LiteralPath $rollbackRustSentinel -PathType Leaf) 'failed rustup action restores the preexisting Rust tree exactly to its canonical root'
    Assert-Equal ([IO.File]::ReadAllText($rollbackRustSentinel)) 'preexisting Rust bytes' 'restored Rust quarantine preserves its original bytes'
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path -Parent $rollbackRustFixture.root) -Directory | Where-Object { $_.Name -like ((Split-Path -Leaf $rollbackRustFixture.root) + '.dbf-*') }).Count 1 'failed replacement Rust tree is retained separately from the restored original'

    Assert-RustToolchainPostcondition -Lock $bootstrapLock -RustupHome $rustFixture.rustup_home -ReceiptPath $rustReceiptPath -LockSha256 $rustLockHash
    Assert-Equal (Get-RustInstalledState -Lock $bootstrapLock -RustupHome $rustFixture.rustup_home -ReceiptPath $rustReceiptPath -LockSha256 $rustLockHash) 'exact' 'complete receipted Rust fixture is exact'
    $rustcFixturePath = Join-Path $rustFixture.root 'bin\rustc.exe'
    $originalRustcBytes = [IO.File]::ReadAllBytes($rustcFixturePath)
    Write-FakeAmd64Pe $rustcFixturePath
    $substitutedRustcBytes = [IO.File]::ReadAllBytes($rustcFixturePath)
    $substitutedRustcBytes[511] = 0x7f
    [IO.File]::WriteAllBytes($rustcFixturePath, $substitutedRustcBytes)
    Assert-ThrowsCode {
        Assert-RustToolchainPostcondition -Lock $bootstrapLock -RustupHome $rustFixture.rustup_home -ReceiptPath $rustReceiptPath -LockSha256 $rustLockHash
    } 'DBINST_RUST_CONTENT_MISMATCH' 'structurally valid substituted AMD64 rustc.exe fails receipt authentication'
    Assert-True ((Get-RustInstalledState -Lock $bootstrapLock -RustupHome $rustFixture.rustup_home -ReceiptPath $rustReceiptPath -LockSha256 $rustLockHash) -cne 'exact') 'same-architecture rustc substitution is never exact'
    [IO.File]::WriteAllBytes($rustcFixturePath, $originalRustcBytes)

    $rustAddition = Join-Path $rustFixture.root 'bin\unexpected-extra.exe'
    Write-FakeAmd64Pe $rustAddition
    Assert-ThrowsCode {
        Assert-RustToolchainPostcondition -Lock $bootstrapLock -RustupHome $rustFixture.rustup_home -ReceiptPath $rustReceiptPath -LockSha256 $rustLockHash
    } 'DBINST_RUST_CONTENT_MISMATCH' 'Rust tree addition fails exact-set receipt authentication'
    [IO.File]::Delete($rustAddition)

    $cargoFixturePath = Join-Path $rustFixture.root 'bin\cargo.exe'
    $cargoFixtureBytes = [IO.File]::ReadAllBytes($cargoFixturePath)
    [IO.File]::Delete($cargoFixturePath)
    Assert-True ((Get-RustInstalledState -Lock $bootstrapLock -RustupHome $rustFixture.rustup_home -ReceiptPath $rustReceiptPath -LockSha256 $rustLockHash) -cne 'exact') 'Rust tree removal is never exact'
    [IO.File]::WriteAllBytes($cargoFixturePath, $cargoFixtureBytes)

    $rustReceiptJson = [IO.File]::ReadAllText($rustReceiptPath)
    $tamperedRustReceipt = $rustReceiptJson | ConvertFrom-Json
    $tamperedRustReceipt.lock_sha256 = ('0' * 64)
    [IO.File]::WriteAllText($rustReceiptPath, ($tamperedRustReceipt | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    Assert-ThrowsCode {
        Assert-RustToolchainPostcondition -Lock $bootstrapLock -RustupHome $rustFixture.rustup_home -ReceiptPath $rustReceiptPath -LockSha256 $rustLockHash
    } 'DBINST_RUST_RECEIPT_INVALID' 'tampered Rust receipt lock binding fails closed'
    [IO.File]::WriteAllText($rustReceiptPath, $rustReceiptJson, (New-Object Text.UTF8Encoding($false)))

    [IO.File]::WriteAllText($rustcFixturePath, 'wrong architecture')
    Assert-True ((Get-RustInstalledState -Lock $bootstrapLock -RustupHome $rustFixture.rustup_home -ReceiptPath $rustReceiptPath -LockSha256 $rustLockHash) -cne 'exact') 'wrong-architecture rustc is never exact'
    Write-FakeAmd64Pe $rustcFixturePath
    $rustManifestPath = Join-Path $rustFixture.rustlib 'multirust-channel-manifest.toml'
    $rustManifestSource = Join-Path $rustFixture.rustlib 'channel-source.toml'
    [IO.File]::Move($rustManifestPath, $rustManifestSource)
    New-Item -ItemType HardLink -Path $rustManifestPath -Target $rustManifestSource | Out-Null
    Assert-Equal (Get-RustInstalledState -Lock $bootstrapLock -RustupHome $rustFixture.rustup_home -ReceiptPath $rustReceiptPath -LockSha256 $rustLockHash) 'conflict' 'hardlinked Rust support manifest is unsafe conflict'
    [IO.File]::Delete($rustManifestPath); [IO.File]::Move($rustManifestSource, $rustManifestPath)
    $rustToolchainsPath = Join-Path $rustFixture.rustup_home 'toolchains'
    $rustToolchainsBacking = Join-Path $testRoot 'rust-toolchains-backing'
    [IO.Directory]::Move($rustToolchainsPath, $rustToolchainsBacking)
    New-Item -ItemType Junction -Path $rustToolchainsPath -Target $rustToolchainsBacking | Out-Null
    Assert-Equal (Get-RustInstalledState -Lock $bootstrapLock -RustupHome $rustFixture.rustup_home -ReceiptPath $rustReceiptPath -LockSha256 $rustLockHash) 'conflict' 'Rust toolchains child junction is unsafe conflict, never repairable'
    [IO.Directory]::Delete($rustToolchainsPath, $false); [IO.Directory]::Move($rustToolchainsBacking, $rustToolchainsPath)

    $dockerFixtureRoot = Join-Path $testRoot 'docker-fixture'
    [IO.Directory]::CreateDirectory($dockerFixtureRoot) | Out-Null
    $dockerSourceRoot = Join-Path $dockerFixtureRoot 'source'
    $dockerBackupRoot = Join-Path $dockerFixtureRoot 'backup'
    [IO.Directory]::CreateDirectory($dockerSourceRoot) | Out-Null
    [IO.Directory]::CreateDirectory($dockerBackupRoot) | Out-Null
    $dockerSourcePath = Join-Path $dockerSourceRoot 'docker_data.vhdx'
    [IO.File]::WriteAllText($dockerSourcePath, 'actual Docker source data')
    $backupPath = Join-Path $dockerBackupRoot 'docker-backup.bin'
    [IO.File]::Copy($dockerSourcePath, $backupPath)
    $sourceHash = Get-FileSha256 -Path $dockerSourcePath
    $backupHash = Get-FileSha256 -Path $backupPath
    $manifestPath = Join-Path $dockerFixtureRoot 'manifest.json'
    $manifest = [ordered]@{
        schema_version = 1
        source_desktop_version = '4.46.0'
        install_mode = 'all-users'
        install_path = 'C:\Program Files\Docker\Docker'
        source_data_path = $dockerSourcePath
        source_size_bytes = (Get-Item -LiteralPath $dockerSourcePath).Length
        source_sha256 = $sourceHash
        backup_path = $backupPath
        backup_size_bytes = (Get-Item -LiteralPath $backupPath).Length
        backup_sha256 = $backupHash
        created_utc = '2026-08-05T12:00:00.0000000Z'
        desktop_stopped = $true
    }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $dockerArtifact = Join-Path $dockerFixtureRoot 'Docker Desktop Installer.exe'
    $dockerBytes = [Text.Encoding]::UTF8.GetBytes('verified Docker installer')
    [IO.File]::WriteAllBytes($dockerArtifact, $dockerBytes)
    $dockerHash = Get-ByteArraySha256 -Bytes $dockerBytes
    $dockerLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $dockerLock.docker.sha256 = $dockerHash
    $unitLockedComposeRoot = Join-Path $dockerFixtureRoot 'locked-cli-plugins'
    [IO.Directory]::CreateDirectory($unitLockedComposeRoot) | Out-Null
    $dockerLock.docker.compose_plugin_path = Join-Path $unitLockedComposeRoot 'docker-compose.exe'
    Write-FakeAmd64Pe $dockerLock.docker.compose_plugin_path
    $script:dockerRuns = 0
    $dockerUpgrade = Upgrade-DockerDesktop -Lock $dockerLock -ArtifactPath $dockerArtifact -DockerBackupManifest $manifestPath -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -DesktopStoppedProbe { return $true } -PlanOnly
    Assert-Equal ($dockerUpgrade.arguments -join ' ') 'install --quiet --backend=wsl-2' 'validated Docker upgrade retains exact payload'
    Assert-Equal $script:dockerRuns 0 'Docker PlanOnly never executes the installer'

    foreach ($mutator in @(
        { param($m) $m.schema_version = 2 },
        { param($m) $m.source_desktop_version = '4.45.0' },
        { param($m) $m.install_mode = 'user' },
        { param($m) $m.install_path = 'C:\Other' },
        { param($m) $m.source_data_path = 'C:\Program Files\Docker\Docker\data\docker_data.vhdx' },
        { param($m) $m.backup_path = 'C:\Program Files\Docker\Docker\backup.bin' },
        { param($m) $m.backup_size_bytes = 1 },
        { param($m) $m.backup_sha256 = ('0' * 64) },
        { param($m) $m.created_utc = 'not-utc' },
        { param($m) $m.desktop_stopped = $false }
    )) {
        $badManifest = $manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        & $mutator $badManifest
        $badManifestPath = Join-Path $dockerFixtureRoot ("bad-{0}.json" -f [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($badManifestPath, ($badManifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        Assert-ThrowsCode {
            Upgrade-DockerDesktop -Lock $dockerLock -ArtifactPath $dockerArtifact -DockerBackupManifest $badManifestPath -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -DesktopStoppedProbe { return $true } -PlanOnly | Out-Null
        } 'DBINST_DOCKER_BACKUP_INVALID' 'invalid Docker preservation manifest fails closed'
    }
    Assert-ThrowsCode {
        Upgrade-DockerDesktop -Lock $dockerLock -ArtifactPath $dockerArtifact -DockerBackupManifest $manifestPath -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -DesktopStoppedProbe { return $false } -PlanOnly | Out-Null
    } 'DBINST_DOCKER_DESKTOP_RUNNING' 'live Desktop process confirmation is mandatory'

    $unitShadowRoot = Join-Path $dockerFixtureRoot 'unit-shadow-cli-plugins'
    [IO.Directory]::CreateDirectory($unitShadowRoot) | Out-Null
    $shadowPath = Join-Path $unitShadowRoot 'docker-compose.exe'
    [IO.File]::WriteAllText($shadowPath, 'user Compose shadow')
    Assert-ThrowsCode {
        Upgrade-DockerDesktop -Lock $dockerLock -ArtifactPath $dockerArtifact -DockerBackupManifest $manifestPath -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -DesktopStoppedProbe { return $true } -ComposeShadowPath $shadowPath -PlanOnly | Out-Null
    } 'DBINST_COMPOSE_SHADOW_OPT_IN_REQUIRED' 'Compose shadow move requires separate opt-in'
    $shadowPlan = Upgrade-DockerDesktop -Lock $dockerLock -ArtifactPath $dockerArtifact -DockerBackupManifest $manifestPath -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -DesktopStoppedProbe { return $true } -ComposeShadowPath $shadowPath -BackupShadowingComposePlugin -TimestampUtc ([DateTime]'2026-08-05T12:34:56Z') -PlanOnly
    Assert-Equal $shadowPlan.compose_shadow_source $shadowPath 'Compose shadow plan names the source'
    Assert-True ($shadowPlan.compose_shadow_backup -match 'docker-compose\.exe\.doppelbanger-backup-20260805T123456Z$') 'Compose shadow plan uses a timestamped backup path'
    Assert-True (Test-Path -LiteralPath $shadowPath -PathType Leaf) 'Compose shadow PlanOnly does not move or delete the plugin'

    Assert-Equal (Resolve-DockerDataPath -CandidatePaths @($dockerSourcePath, (Join-Path $dockerFixtureRoot 'missing.vhdx'))) $dockerSourcePath 'exactly one existing Docker data candidate is accepted'
    Assert-ThrowsCode { Resolve-DockerDataPath -CandidatePaths @((Join-Path $dockerFixtureRoot 'missing-one.vhdx'), (Join-Path $dockerFixtureRoot 'missing-two.vhdx')) | Out-Null } 'DBINST_DOCKER_DATA_AMBIGUOUS' 'zero Docker data candidates fail closed'
    $secondSource = Join-Path $dockerSourceRoot 'second-docker_data.vhdx'
    [IO.File]::WriteAllText($secondSource, 'second source')
    Assert-ThrowsCode { Resolve-DockerDataPath -CandidatePaths @($dockerSourcePath, $secondSource) | Out-Null } 'DBINST_DOCKER_DATA_AMBIGUOUS' 'multiple Docker data candidates fail closed'
    $dockerSettingsRoot = Join-Path $dockerFixtureRoot 'settings'
    [IO.Directory]::CreateDirectory($dockerSettingsRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $dockerSettingsRoot 'settings-store.json'), (@{ diskImageLocation = $dockerSourceRoot } | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $configuredCandidates = Get-DockerDataCandidatePaths -LocalAppData (Join-Path $dockerFixtureRoot 'local-app-data') -SettingsRoot $dockerSettingsRoot
    Assert-True ($configuredCandidates -contains $dockerSourcePath) 'configured Docker disk-image root contributes its actual data disk candidate'

    # Audit repair: checkpoint paths and contents are treated as hostile input.
    $checkpointSafetyRoot = Join-Path $testRoot 'checkpoint-safety'
    [IO.Directory]::CreateDirectory($checkpointSafetyRoot) | Out-Null
    $safeCheckpoint = Join-Path $checkpointSafetyRoot 'installer-checkpoint-v1.json'
    $outsideSentinel = Join-Path $testRoot 'outside-checkpoint-sentinel.json'
    [IO.File]::WriteAllText($outsideSentinel, 'outside sentinel must remain unchanged')
    Assert-ThrowsCode { Assert-InstallerCheckpointPath -Path $outsideSentinel -Root $checkpointSafetyRoot | Out-Null } 'DBINST_CHECKPOINT_PATH_INVALID' 'checkpoint outside the canonical root is rejected'
    Assert-Equal ([IO.File]::ReadAllText($outsideSentinel)) 'outside sentinel must remain unchanged' 'outside checkpoint rejection never replaces the file'
    foreach ($unsafeCheckpoint in @('\\server\share\checkpoint.json', '\\?\C:\checkpoint.json', (Join-Path $checkpointSafetyRoot 'checkpoint.json:ads'))) {
        Assert-ThrowsCode { Assert-InstallerCheckpointPath -Path $unsafeCheckpoint -Root $checkpointSafetyRoot | Out-Null } 'DBINST_CHECKPOINT_PATH_INVALID' 'UNC, device, and ADS checkpoint paths are rejected'
    }
    $hardlinkCheckpointSource = Join-Path $checkpointSafetyRoot 'hardlink-source.json'
    $hardlinkCheckpoint = Join-Path $checkpointSafetyRoot 'installer-checkpoint-v1.json'
    [IO.File]::WriteAllText($hardlinkCheckpointSource, '{}')
    New-Item -ItemType HardLink -Path $hardlinkCheckpoint -Target $hardlinkCheckpointSource | Out-Null
    Assert-ThrowsCode { Assert-InstallerCheckpointPath -Path $hardlinkCheckpoint -Root $checkpointSafetyRoot | Out-Null } 'DBINST_CHECKPOINT_PATH_INVALID' 'hardlinked checkpoint target is rejected'
    [IO.File]::Delete($hardlinkCheckpoint)
    $checkpointJunctionTarget = Join-Path $testRoot 'checkpoint-junction-target'
    $checkpointJunction = Join-Path $checkpointSafetyRoot 'junction'
    [IO.Directory]::CreateDirectory($checkpointJunctionTarget) | Out-Null
    New-Item -ItemType Junction -Path $checkpointJunction -Target $checkpointJunctionTarget | Out-Null
    Assert-ThrowsCode { Assert-InstallerCheckpointPath -Path (Join-Path $checkpointJunction 'installer-checkpoint-v1.json') -Root $checkpointSafetyRoot | Out-Null } 'DBINST_CHECKPOINT_PATH_INVALID' 'checkpoint below a reparse ancestor is rejected'

    $checkpointActions = @(
        [pscustomobject]@{ name = 'one'; checkpoint_on_3010 = $true; invoke = { return 3010 } },
        [pscustomobject]@{ name = 'two'; invoke = { $script:auditCheckpointInvokes++; return 0 } }
    )
    $checkpointOptions = [ordered]@{ upgrade_docker = $true; docker_manifest_sha256 = ('1' * 64) }
    $script:auditCheckpointInvokes = 0
    Assert-ThrowsCode {
        Invoke-InstallActionSequence -Actions $checkpointActions -CheckpointPath $safeCheckpoint -CheckpointRoot $checkpointSafetyRoot -LockSha256 (Get-FileSha256 -Path $installerLockPath) -InstallOptions $checkpointOptions -BootSessionMarker 'boot-a' -PreconditionCheck { } -EnvironmentCheck { } | Out-Null
    } 'DBINST_REBOOT_REQUIRED' 'audit checkpoint is created from exit 3010'
    $validCheckpointJson = [IO.File]::ReadAllText($safeCheckpoint)
    $validCheckpoint = $validCheckpointJson | ConvertFrom-Json
    Assert-Equal $validCheckpoint.exit_code 3010 'checkpoint records authoritative exit 3010'
    Assert-Equal $validCheckpoint.completed_action 'one' 'checkpoint records the completed action'
    Assert-Equal $validCheckpoint.next_action_name 'two' 'checkpoint binds the exact next action name'
    Assert-ThrowsCode {
        Invoke-InstallActionSequence -Actions $checkpointActions -CheckpointPath $safeCheckpoint -CheckpointRoot $checkpointSafetyRoot -LockSha256 (Get-FileSha256 -Path $installerLockPath) -InstallOptions $checkpointOptions -BootSessionMarker 'boot-a' -Resume -PreconditionCheck { } -EnvironmentCheck { } | Out-Null
    } 'DBINST_RESUME_SAME_BOOT' 'resume on the same native boot session is rejected'
    Assert-Equal $script:auditCheckpointInvokes 0 'same-boot resume executes no later action'

    foreach ($checkpointMutation in @(
        { param($c) $c.next_action_index = -1 },
        { param($c) $c.next_action_index = 99 },
        { param($c) $c.next_action_index = 1.5 },
        { param($c) $c.created_utc = 'not-utc' },
        { param($c) $c.created_utc = '2026-08-05T12:00:00.0000000+00:00' },
        { param($c) $c.next_action_name = 'changed' },
        { param($c) $c.exit_code = 0 }
    )) {
        $badCheckpoint = $validCheckpointJson | ConvertFrom-Json
        & $checkpointMutation $badCheckpoint
        [IO.File]::WriteAllText($safeCheckpoint, ($badCheckpoint | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        Assert-ThrowsCode {
            Invoke-InstallActionSequence -Actions $checkpointActions -CheckpointPath $safeCheckpoint -CheckpointRoot $checkpointSafetyRoot -LockSha256 (Get-FileSha256 -Path $installerLockPath) -InstallOptions $checkpointOptions -BootSessionMarker 'boot-b' -Resume -PreconditionCheck { } -EnvironmentCheck { } | Out-Null
        } 'DBINST_CHECKPOINT_INVALID' 'negative, oversized, fractional, stale-name, timestamp, and exit-code checkpoints fail closed'
        Assert-Equal $script:auditCheckpointInvokes 0 'invalid checkpoint executes no action'
    }
    [IO.File]::WriteAllText($safeCheckpoint, '{invalid json')
    Assert-ThrowsCode {
        Invoke-InstallActionSequence -Actions $checkpointActions -CheckpointPath $safeCheckpoint -CheckpointRoot $checkpointSafetyRoot -LockSha256 (Get-FileSha256 -Path $installerLockPath) -InstallOptions $checkpointOptions -BootSessionMarker 'boot-b' -Resume -PreconditionCheck { } -EnvironmentCheck { } | Out-Null
    } 'DBINST_CHECKPOINT_INVALID' 'malformed checkpoint JSON fails closed'
    [IO.File]::WriteAllText($safeCheckpoint, $validCheckpointJson)
    $reorderedActions = @($checkpointActions[1], $checkpointActions[0])
    Assert-ThrowsCode {
        Invoke-InstallActionSequence -Actions $reorderedActions -CheckpointPath $safeCheckpoint -CheckpointRoot $checkpointSafetyRoot -LockSha256 (Get-FileSha256 -Path $installerLockPath) -InstallOptions $checkpointOptions -BootSessionMarker 'boot-b' -Resume -PreconditionCheck { } -EnvironmentCheck { } | Out-Null
    } 'DBINST_CHECKPOINT_INVALID' 'reordered enabled actions cannot resume an older checkpoint'
    $differentDockerOptions = [ordered]@{ upgrade_docker = $false; docker_manifest_sha256 = '' }
    Assert-ThrowsCode {
        Invoke-InstallActionSequence -Actions $checkpointActions -CheckpointPath $safeCheckpoint -CheckpointRoot $checkpointSafetyRoot -LockSha256 (Get-FileSha256 -Path $installerLockPath) -InstallOptions $differentDockerOptions -BootSessionMarker 'boot-b' -Resume -PreconditionCheck { } -EnvironmentCheck { } | Out-Null
    } 'DBINST_CHECKPOINT_INVALID' 'Docker-enabled checkpoint cannot resume without the same opt-in and manifest hash'

    # Audit repair: native preflight is mandatory before any mutation.
    $nativeProbe = [pscustomobject]@{ os = 'Windows'; arch = 'x86_64'; wsl = $false; wsl_distro_name = ''; wsl_interop = ''; ancestors = @('powershell.exe', 'explorer.exe') }
    Assert-True (Assert-NativeInstallEnvironment -Probe $nativeProbe) 'native Windows x64 probe is accepted'

    # Runtime ancestry repair: a canonical Explorer whose historical parent row is gone is one narrow trusted boundary.
    $nativeLookupFactory = {
        param([Collections.IDictionary]$Rows, $Calls, [int]$ThrowOnProcessId = 0)
        $lookupRows = $Rows
        $lookupCalls = $Calls
        $lookupThrowId = $ThrowOnProcessId
        return {
            param([int]$TargetProcessId)
            $lookupCalls.Add($TargetProcessId)
            if ($TargetProcessId -eq $lookupThrowId) { throw "fixture lookup denied for PID $TargetProcessId" }
            if ($lookupRows.Contains($TargetProcessId)) { return $lookupRows[$TargetProcessId] }
            return $null
        }.GetNewClosure()
    }
    $ancestryRtkId = [int]$PID + 10001
    $ancestryPowerShellId = [int]$PID + 10002
    $ancestryCodexId = [int]$PID + 10003
    $ancestryChatGptId = [int]$PID + 10004
    $ancestryExplorerId = [int]$PID + 10005
    $ancestryMissingExplorerParentId = [int]$PID + 10006
    $canonicalExplorerRows = @{}
    $canonicalExplorerRows[[int]$PID] = [pscustomobject][ordered]@{ ProcessId = [int]$PID; ParentProcessId = $ancestryRtkId; Name = 'powershell.exe'; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    $canonicalExplorerRows[$ancestryRtkId] = [pscustomobject][ordered]@{ ProcessId = $ancestryRtkId; ParentProcessId = $ancestryPowerShellId; Name = 'rtk.exe'; ExecutablePath = 'C:\Users\fixture\AppData\Local\rtk\rtk.exe' }
    $canonicalExplorerRows[$ancestryPowerShellId] = [pscustomobject][ordered]@{ ProcessId = $ancestryPowerShellId; ParentProcessId = $ancestryCodexId; Name = 'powershell.exe'; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    $canonicalExplorerRows[$ancestryCodexId] = [pscustomobject][ordered]@{ ProcessId = $ancestryCodexId; ParentProcessId = $ancestryChatGptId; Name = 'codex.exe'; ExecutablePath = 'C:\Program Files\Codex\codex.exe' }
    $canonicalExplorerRows[$ancestryChatGptId] = [pscustomobject][ordered]@{ ProcessId = $ancestryChatGptId; ParentProcessId = $ancestryExplorerId; Name = 'ChatGPT.exe'; ExecutablePath = 'C:\Program Files\WindowsApps\OpenAI.ChatGPT_fixture\ChatGPT.exe' }
    $canonicalExplorerRows[$ancestryExplorerId] = [pscustomobject][ordered]@{ ProcessId = $ancestryExplorerId; ParentProcessId = $ancestryMissingExplorerParentId; Name = 'Explorer.EXE'; ExecutablePath = 'C:\Windows\Explorer.EXE' }
    $canonicalExplorerCalls = New-Object 'Collections.Generic.List[int]'
    $canonicalExplorerProbe = $null
    $canonicalExplorerError = ''
    try {
        $canonicalExplorerProbe = Get-NativeInstallEnvironmentProbe -ProcessLookup (& $nativeLookupFactory $canonicalExplorerRows $canonicalExplorerCalls) -WindowsDirectory 'C:\Windows'
    }
    catch { $canonicalExplorerError = $_.Exception.Message }
    Assert-Equal $canonicalExplorerError '' 'exact Codex/rtk/ChatGPT/canonical-Explorer chain accepts only the missing historical Explorer parent boundary'
    Assert-Equal ($canonicalExplorerCalls -join ',') "${PID},$ancestryRtkId,$ancestryPowerShellId,$ancestryCodexId,$ancestryChatGptId,$ancestryExplorerId,$ancestryMissingExplorerParentId" 'canonical Explorer parent PID is queried before the ancestry walk terminates'
    Assert-Equal (@($canonicalExplorerProbe.ancestors) -join ',') 'powershell.exe,rtk.exe,powershell.exe,codex.exe,ChatGPT.exe,Explorer.EXE' 'accepted ancestry retains canonical Explorer and the complete resolved Codex launch chain'
    Assert-True (Assert-NativeInstallEnvironment -Probe $canonicalExplorerProbe) 'accepted canonical Explorer boundary still passes the independent native environment validator'

    $missingBelowCodexId = [int]$PID + 10103
    $missingBelowCodexParentId = [int]$PID + 10104
    $missingBelowCodexRows = @{}
    $missingBelowCodexRows[[int]$PID] = [pscustomobject][ordered]@{ ProcessId = [int]$PID; ParentProcessId = $ancestryRtkId; Name = 'powershell.exe'; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    $missingBelowCodexRows[$ancestryRtkId] = [pscustomobject][ordered]@{ ProcessId = $ancestryRtkId; ParentProcessId = $missingBelowCodexId; Name = 'rtk.exe'; ExecutablePath = 'C:\Users\fixture\AppData\Local\rtk\rtk.exe' }
    $missingBelowCodexRows[$missingBelowCodexId] = [pscustomobject][ordered]@{ ProcessId = $missingBelowCodexId; ParentProcessId = $missingBelowCodexParentId; Name = 'codex.exe'; ExecutablePath = 'C:\Program Files\Codex\codex.exe' }
    $missingBelowCodexCalls = New-Object 'Collections.Generic.List[int]'
    Assert-ThrowsCode {
        Get-NativeInstallEnvironmentProbe -ProcessLookup (& $nativeLookupFactory $missingBelowCodexRows $missingBelowCodexCalls) -WindowsDirectory 'C:\Windows' | Out-Null
    } 'DBINST_NATIVE_WINDOWS_REQUIRED' 'missing ancestry below rtk/Codex remains fail-closed'
    Assert-Equal ($missingBelowCodexCalls -join ',') "${PID},$ancestryRtkId,$missingBelowCodexId,$missingBelowCodexParentId" 'missing non-Explorer parent is queried before failure'

    foreach ($untrustedExplorerCase in @(
        [pscustomobject]@{ label = 'pathless'; name = 'explorer.exe'; path = '' },
        [pscustomobject]@{ label = 'noncanonical path'; name = 'explorer.exe'; path = 'C:\Windows\System32\explorer.exe' },
        [pscustomobject]@{ label = 'nonexact alias path'; name = 'explorer.exe'; path = 'C:\Windows\System32\..\explorer.exe' },
        [pscustomobject]@{ label = 'wrong process name'; name = 'not-explorer.exe'; path = 'C:\Windows\explorer.exe' }
    )) {
        $untrustedExplorerRows = @{}
        $untrustedExplorerRows[[int]$PID] = [pscustomobject][ordered]@{ ProcessId = [int]$PID; ParentProcessId = $ancestryExplorerId; Name = 'powershell.exe'; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
        $untrustedExplorerRows[$ancestryExplorerId] = [pscustomobject][ordered]@{ ProcessId = $ancestryExplorerId; ParentProcessId = $ancestryMissingExplorerParentId; Name = [string]$untrustedExplorerCase.name; ExecutablePath = [string]$untrustedExplorerCase.path }
        $untrustedExplorerCalls = New-Object 'Collections.Generic.List[int]'
        Assert-ThrowsCode {
            Get-NativeInstallEnvironmentProbe -ProcessLookup (& $nativeLookupFactory $untrustedExplorerRows $untrustedExplorerCalls) -WindowsDirectory 'C:\Windows' | Out-Null
        } 'DBINST_NATIVE_WINDOWS_REQUIRED' "$($untrustedExplorerCase.label) Explorer with a missing parent remains fail-closed"
        Assert-Equal ($untrustedExplorerCalls -join ',') "${PID},$ancestryExplorerId,$ancestryMissingExplorerParentId" "$($untrustedExplorerCase.label) Explorer parent is queried before failure"
    }

    $unreadableExplorerParentCalls = New-Object 'Collections.Generic.List[int]'
    Assert-ThrowsCode {
        Get-NativeInstallEnvironmentProbe -ProcessLookup (& $nativeLookupFactory $canonicalExplorerRows $unreadableExplorerParentCalls $ancestryMissingExplorerParentId) -WindowsDirectory 'C:\Windows' | Out-Null
    } 'DBINST_NATIVE_WINDOWS_REQUIRED' 'an unreadable canonical Explorer parent remains fail-closed rather than being treated as a missing historical row'

    $ancestryCycleId = [int]$PID + 10200
    $ancestryCycleRows = @{}
    $ancestryCycleRows[[int]$PID] = [pscustomobject][ordered]@{ ProcessId = [int]$PID; ParentProcessId = $ancestryCycleId; Name = 'powershell.exe'; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    $ancestryCycleRows[$ancestryCycleId] = [pscustomobject][ordered]@{ ProcessId = $ancestryCycleId; ParentProcessId = [int]$PID; Name = 'rtk.exe'; ExecutablePath = 'C:\Users\fixture\AppData\Local\rtk\rtk.exe' }
    $ancestryCycleCalls = New-Object 'Collections.Generic.List[int]'
    Assert-ThrowsCode {
        Get-NativeInstallEnvironmentProbe -ProcessLookup (& $nativeLookupFactory $ancestryCycleRows $ancestryCycleCalls) -WindowsDirectory 'C:\Windows' | Out-Null
    } 'DBINST_NATIVE_WINDOWS_REQUIRED' 'a live process ancestry PID cycle fails closed'
    Assert-Equal ($ancestryCycleCalls -join ',') "${PID},$ancestryCycleId" 'cycle detection rejects a repeated PID before looking it up again'

    $depthRows = @{}
    $depthCurrentId = [int]$PID
    for ($depthIndex = 0; $depthIndex -lt 31; $depthIndex++) {
        $depthParentId = [int]$PID + 11000 + $depthIndex
        $depthRows[$depthCurrentId] = [pscustomobject][ordered]@{
            ProcessId = $depthCurrentId
            ParentProcessId = $depthParentId
            Name = if ($depthIndex -eq 0) { 'powershell.exe' } else { "ancestor-$depthIndex.exe" }
            ExecutablePath = "C:\fixture\ancestor-$depthIndex.exe"
        }
        $depthCurrentId = $depthParentId
    }
    $depthExplorerId = $depthCurrentId
    $depthWslId = [int]$PID + 12000
    $depthRows[$depthExplorerId] = [pscustomobject][ordered]@{ ProcessId = $depthExplorerId; ParentProcessId = $depthWslId; Name = 'explorer.exe'; ExecutablePath = 'C:\Windows\explorer.exe' }
    $depthRows[$depthWslId] = [pscustomobject][ordered]@{ ProcessId = $depthWslId; ParentProcessId = 0; Name = 'wsl.exe'; ExecutablePath = 'C:\Windows\System32\wsl.exe' }
    $depthCalls = New-Object 'Collections.Generic.List[int]'
    Assert-ThrowsCode {
        Get-NativeInstallEnvironmentProbe -ProcessLookup (& $nativeLookupFactory $depthRows $depthCalls) -WindowsDirectory 'C:\Windows' | Out-Null
    } 'DBINST_NATIVE_WINDOWS_REQUIRED' 'a live record beyond the 32-resolved-process limit fails closed'
    Assert-Equal $depthCalls.Count 33 'depth exhaustion still queries the canonical Explorer parent before failing'
    Assert-Equal $depthCalls[$depthCalls.Count - 1] $depthWslId 'depth exhaustion cannot hide a live WSL parent immediately above canonical Explorer'

    foreach ($malformedProcessCase in @(
        [pscustomobject]@{ label = 'missing ProcessId'; row = [pscustomobject][ordered]@{ ParentProcessId = 0; Name = 'powershell.exe'; ExecutablePath = 'C:\fixture\powershell.exe' } },
        [pscustomobject]@{ label = 'mismatched ProcessId'; row = [pscustomobject][ordered]@{ ProcessId = ([int]$PID + 1); ParentProcessId = 0; Name = 'powershell.exe'; ExecutablePath = 'C:\fixture\powershell.exe' } },
        [pscustomobject]@{ label = 'non-lossless ProcessId'; row = [pscustomobject][ordered]@{ ProcessId = "00$PID"; ParentProcessId = 0; Name = 'powershell.exe'; ExecutablePath = 'C:\fixture\powershell.exe' } },
        [pscustomobject]@{ label = 'missing ParentProcessId'; row = [pscustomobject][ordered]@{ ProcessId = [int]$PID; Name = 'powershell.exe'; ExecutablePath = 'C:\fixture\powershell.exe' } },
        [pscustomobject]@{ label = 'negative ParentProcessId'; row = [pscustomobject][ordered]@{ ProcessId = [int]$PID; ParentProcessId = -1; Name = 'powershell.exe'; ExecutablePath = 'C:\fixture\powershell.exe' } },
        [pscustomobject]@{ label = 'out-of-range ParentProcessId'; row = [pscustomobject][ordered]@{ ProcessId = [int]$PID; ParentProcessId = '4294967295'; Name = 'powershell.exe'; ExecutablePath = 'C:\fixture\powershell.exe' } },
        [pscustomobject]@{ label = 'blank Name'; row = [pscustomobject][ordered]@{ ProcessId = [int]$PID; ParentProcessId = 0; Name = '   '; ExecutablePath = 'C:\fixture\powershell.exe' } }
    )) {
        $malformedProcessRows = @{}
        $malformedProcessRows[[int]$PID] = $malformedProcessCase.row
        $malformedProcessCalls = New-Object 'Collections.Generic.List[int]'
        Assert-ThrowsCode {
            Get-NativeInstallEnvironmentProbe -ProcessLookup (& $nativeLookupFactory $malformedProcessRows $malformedProcessCalls) -WindowsDirectory 'C:\Windows' | Out-Null
        } 'DBINST_NATIVE_WINDOWS_REQUIRED' "$($malformedProcessCase.label) process row fails closed"
    }

    $liveWslId = [int]$PID + 10201
    $liveWslRows = @{}
    $liveWslRows[[int]$PID] = [pscustomobject][ordered]@{ ProcessId = [int]$PID; ParentProcessId = $ancestryExplorerId; Name = 'powershell.exe'; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    $liveWslRows[$ancestryExplorerId] = [pscustomobject][ordered]@{ ProcessId = $ancestryExplorerId; ParentProcessId = $liveWslId; Name = 'explorer.exe'; ExecutablePath = 'C:\Windows\explorer.exe' }
    $liveWslRows[$liveWslId] = [pscustomobject][ordered]@{ ProcessId = $liveWslId; ParentProcessId = 0; Name = 'wsl.exe'; ExecutablePath = 'C:\Windows\System32\wsl.exe' }
    $liveWslCalls = New-Object 'Collections.Generic.List[int]'
    $liveWslProbe = Get-NativeInstallEnvironmentProbe -ProcessLookup (& $nativeLookupFactory $liveWslRows $liveWslCalls) -WindowsDirectory 'C:\Windows'
    Assert-Equal ($liveWslCalls -join ',') "${PID},$ancestryExplorerId,$liveWslId" 'a live Explorer parent is traversed instead of accepting the canonical Explorer boundary early'
    Assert-ThrowsCode { Assert-NativeInstallEnvironment -Probe $liveWslProbe | Out-Null } 'DBINST_NATIVE_WINDOWS_REQUIRED' 'live WSL launcher above canonical Explorer remains detectable and rejected'

    $savedWslDistroNameForAncestry = $env:WSL_DISTRO_NAME
    $savedWslInteropForAncestry = $env:WSL_INTEROP
    try {
        $env:WSL_DISTRO_NAME = 'Ubuntu-fixture'
        $env:WSL_INTEROP = '\\wsl.localhost\fixture\interop'
        $markerExplorerCalls = New-Object 'Collections.Generic.List[int]'
        $markerExplorerProbe = Get-NativeInstallEnvironmentProbe -ProcessLookup (& $nativeLookupFactory $canonicalExplorerRows $markerExplorerCalls) -WindowsDirectory 'C:\Windows'
        Assert-Equal (@($markerExplorerProbe.ancestors) -join ',') 'powershell.exe,rtk.exe,powershell.exe,codex.exe,ChatGPT.exe,Explorer.EXE' 'WSL marker fixture still reaches the accepted canonical Explorer boundary'
        Assert-ThrowsCode { Assert-NativeInstallEnvironment -Probe $markerExplorerProbe | Out-Null } 'DBINST_NATIVE_WINDOWS_REQUIRED' 'WSL environment markers independently reject an otherwise accepted canonical Explorer chain'
    }
    finally {
        $env:WSL_DISTRO_NAME = $savedWslDistroNameForAncestry
        $env:WSL_INTEROP = $savedWslInteropForAncestry
    }

    $wslParentProbe = $nativeProbe | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $wslParentProbe.ancestors = @('powershell.exe', 'wslhost.exe')
    $script:wslBlockedInvoke = 0
    Assert-ThrowsCode {
        Invoke-InstallActionSequence -Actions @([pscustomobject]@{ name = 'blocked'; invoke = { $script:wslBlockedInvoke++; return 0 } }) -CheckpointPath (Join-Path $checkpointSafetyRoot 'blocked.json') -CheckpointRoot $checkpointSafetyRoot -LockSha256 (Get-FileSha256 -Path $installerLockPath) -InstallOptions @{} -BootSessionMarker 'boot-a' -PreconditionCheck { } -EnvironmentCheck { Assert-NativeInstallEnvironment -Probe $wslParentProbe | Out-Null } | Out-Null
    } 'DBINST_NATIVE_WINDOWS_REQUIRED' 'WSL ancestry blocks before an action invoke'
    Assert-Equal $script:wslBlockedInvoke 0 'WSL ancestry never invokes a mutation'
    Assert-ThrowsCode { Assert-InstallPreconditions -TargetPaths @('C:\tools') -VolumeProbe { return [double]::NaN } -PendingRebootProbe { return $false } | Out-Null } 'DBINST_FREE_SPACE_UNKNOWN' 'non-finite free-space state fails closed'
    Assert-ThrowsCode { Assert-InstallPreconditions -TargetPaths @('C:\tools') -VolumeProbe { return 100 } -PendingRebootProbe { return $null } | Out-Null } 'DBINST_PENDING_REBOOT_UNKNOWN' 'unknown pending-reboot state fails closed'
    Assert-ThrowsCode { Assert-InstallPreconditions -TargetPaths @('C:\tools') -VolumeProbe { return 100 } -PendingRebootProbe { throw 'registry access denied' } | Out-Null } 'DBINST_PENDING_REBOOT_UNKNOWN' 'pending-reboot registry read failure fails closed'
    $auditTargets = Get-InstallPreflightTargets -Plan $plan -Lock $lock -RustupHome 'D:\rustup' -CargoHome 'E:\cargo' -CheckpointPath 'F:\doppelbanger\installer-checkpoint-v1.json' -DockerPaths @('G:\Docker', 'H:\docker_data.vhdx', 'I:\backup.vhdx', 'J:\plugins', 'K:\plugins-backup')
    $expectedRustPreflightRoot = 'D:\rustup\toolchains\' + [string]$lock.rust.toolchain_directory
    foreach ($requiredTarget in @($plan.cache_root, $plan.actions[2].target_root, $plan.actions[3].target_root, $plan.actions[4].target_root, 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools', 'C:\Program Files (x86)\Windows Kits\10', 'C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances', 'C:\Program Files (x86)\Microsoft Visual Studio\Installer', 'D:\rustup', $expectedRustPreflightRoot, 'E:\cargo', 'E:\cargo\bin', 'F:\doppelbanger', 'G:\Docker', 'H:\docker_data.vhdx', 'I:\backup.vhdx', 'J:\plugins', 'K:\plugins-backup')) {
        Assert-True ($auditTargets -contains $requiredTarget) "preflight includes every mutation destination: $requiredTarget"
    }
    $savedProgramData = $env:ProgramData
    $savedProgramFilesX86 = ${env:ProgramFiles(x86)}
    try {
        $env:ProgramData = Join-Path $testRoot 'relocated-program-data'
        ${env:ProgramFiles(x86)} = Join-Path $testRoot 'relocated-program-files-x86'
        $relocatedAuxiliaryTargets = Get-InstallPreflightTargets -Plan $plan -Lock $lock -RustupHome 'D:\rustup' -CargoHome 'E:\cargo' -CheckpointPath 'F:\doppelbanger\installer-checkpoint-v1.json'
        foreach ($requiredTarget in @(
            (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'),
            (Join-Path $env:ProgramData 'Microsoft\VisualStudio\Packages\_Instances'),
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer')
        )) { Assert-True ($relocatedAuxiliaryTargets -contains $requiredTarget) "preflight auxiliary root follows its canonical environment location: $requiredTarget" }
    }
    finally {
        $env:ProgramData = $savedProgramData
        ${env:ProgramFiles(x86)} = $savedProgramFilesX86
    }

    # Audit repair: lock roots cannot redirect extraction and archive reuse validates payload.
    $redirectedLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $redirectedLock.ninja.root = '%LOCALAPPDATA%\Programs\elsewhere\ninja-1.13.2'
    Assert-ThrowsCode { New-WindowsToolchainInstallPlan -Lock $redirectedLock -LocalAppData (Join-Path $testRoot 'redirected-local') | Out-Null } 'DBINST_LOCK_ROOT_INVALID' 'changed lock cannot redirect an archive target outside the exact devtools descendant'
    $uppercaseLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $uppercaseLock.cmake.sha256 = $uppercaseLock.cmake.sha256.ToUpperInvariant()
    Assert-ThrowsCode { Read-InstallerLockFromObject -Lock $uppercaseLock | Out-Null } 'DBINST_LOCK_INVALID' 'uppercase lock SHA is rejected case-sensitively'
    Assert-ThrowsCode { Assert-SafeArchiveSubdirectory -ArchiveSubdirectory '..\escape' } 'DBINST_ARCHIVE_LAYOUT_INVALID' 'archive subdirectory escape is rejected before extraction'

    $authenticatedNinjaArchive = Join-Path $testRoot 'authenticated-ninja.zip'
    New-SyntheticZip -Path $authenticatedNinjaArchive -Entries @(
        [pscustomobject]@{ name = 'ninja.exe'; content = (Get-FakeAmd64PeBytes) },
        [pscustomobject]@{ name = 'README.txt'; content = [byte[]]@() },
        [pscustomobject]@{ name = 'docs/guide.txt'; content = 'guide' },
        [pscustomobject]@{ name = 'explicit/'; content = [byte[]]@() },
        [pscustomobject]@{ name = 'explicit/zero.txt'; content = [byte[]]@() }
    ) | Out-Null
    $authenticatedNinjaHash = Get-FileSha256 -Path $authenticatedNinjaArchive
    Assert-ThrowsCode {
        $unexpectedManifest = $null
        try { $unexpectedManifest = Open-AuthenticatedZipManifest -Name 'ninja' -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -Lock $lock }
        finally { if ($unexpectedManifest) { $unexpectedManifest.zip.Dispose(); $unexpectedManifest.guard.Dispose() } }
    } 'DBINST_LOCK_INVALID' 'authenticated archive SHA must be the exact SHA bound in the selected tool lock'
    $authenticatedNinjaLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $authenticatedNinjaLock.ninja.sha256 = $authenticatedNinjaHash
    $authenticatedNinjaRoot = Join-Path $testRoot 'authenticated-ninja-root'
    $authenticatedFresh = Expand-VersionedTool -Name 'ninja' -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -TargetRoot $authenticatedNinjaRoot -Lock $authenticatedNinjaLock
    Assert-Equal $authenticatedFresh.status 'installed' 'valid synthetic Ninja ZIP installs without launching a tool executable'
    Assert-Equal (Get-Item -LiteralPath (Join-Path $authenticatedNinjaRoot 'README.txt')).Length 0 'zero-byte archive files are authenticated and retained'
    $authenticatedReuse = Expand-VersionedTool -Name 'ninja' -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -TargetRoot $authenticatedNinjaRoot -Lock $authenticatedNinjaLock -Expander { throw 'exact reuse must not extract' }
    Assert-Equal $authenticatedReuse.status 'already_installed' 'exact installed files are authenticated against the same cached ZIP on reuse'
    Assert-Equal (Get-VersionedToolInstalledState -Name 'ninja' -Root $authenticatedNinjaRoot -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -Lock $authenticatedNinjaLock) 'exact' 'installed-state detection authenticates the exact Ninja payload against the cached ZIP'

    [IO.File]::WriteAllText((Join-Path $authenticatedNinjaRoot 'README.txt'), 'drift')
    Assert-ThrowsCode { Expand-VersionedTool -Name 'ninja' -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -TargetRoot $authenticatedNinjaRoot -Lock $authenticatedNinjaLock | Out-Null } 'DBINST_ARCHIVE_CONTENT_MISMATCH' 'same-version installed content drift is rejected against the locked ZIP'
    Assert-Equal (Get-VersionedToolInstalledState -Name 'ninja' -Root $authenticatedNinjaRoot -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -Lock $authenticatedNinjaLock) 'conflict' 'installed-state detection fails closed on same-version content drift'
    $emptyRestore = [IO.File]::Create((Join-Path $authenticatedNinjaRoot 'README.txt')); $emptyRestore.Dispose()
    [IO.File]::WriteAllText((Join-Path $authenticatedNinjaRoot 'extra.txt'), 'extra')
    Assert-ThrowsCode { Expand-VersionedTool -Name 'ninja' -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -TargetRoot $authenticatedNinjaRoot -Lock $authenticatedNinjaLock | Out-Null } 'DBINST_ARCHIVE_CONTENT_MISMATCH' 'extra installed files are rejected against the locked ZIP'
    [IO.File]::Delete((Join-Path $authenticatedNinjaRoot 'extra.txt'))
    [IO.File]::Delete((Join-Path $authenticatedNinjaRoot 'docs\guide.txt'))
    Assert-ThrowsCode { Expand-VersionedTool -Name 'ninja' -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -TargetRoot $authenticatedNinjaRoot -Lock $authenticatedNinjaLock | Out-Null } 'DBINST_ARCHIVE_CONTENT_MISMATCH' 'missing installed files are rejected against the locked ZIP'
    [IO.File]::WriteAllText((Join-Path $authenticatedNinjaRoot 'docs\guide.txt'), 'guide')
    $wrongHashNinjaLock = $authenticatedNinjaLock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $wrongHashNinjaLock.ninja.sha256 = ('0' * 64)
    Assert-ThrowsCode { Expand-VersionedTool -Name 'ninja' -ArchivePath $authenticatedNinjaArchive -Sha256 ('0' * 64) -TargetRoot $authenticatedNinjaRoot -Lock $wrongHashNinjaLock | Out-Null } 'DBINST_CHECKSUM_MISMATCH' 'a marker cannot authenticate reuse when the cached archive hash is wrong'

    $guardedNinjaRoot = Join-Path $testRoot 'guarded-ninja-root'
    $script:archiveWriteDenied = $false
    Expand-VersionedTool -Name 'ninja' -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -TargetRoot $guardedNinjaRoot -Lock $authenticatedNinjaLock -Expander {
        param($Archive, $Staging)
        try {
            $writeAttempt = [IO.File]::Open($Archive, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $writeAttempt.Dispose()
        }
        catch [IO.IOException] { $script:archiveWriteDenied = $true }
        Expand-Archive -LiteralPath $Archive -DestinationPath $Staging
    } | Out-Null
    Assert-True $script:archiveWriteDenied 'archive remains guarded against replacement or writes through verification and extraction'

    $badNinjaArchive = Join-Path $testRoot 'bad-ninja.zip'
    New-SyntheticZip -Path $badNinjaArchive -Entries @([pscustomobject]@{ name = 'ninja.exe'; content = 'not a PE' }) | Out-Null
    $badNinjaHash = Get-FileSha256 -Path $badNinjaArchive
    $badNinjaLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $badNinjaLock.ninja.sha256 = $badNinjaHash
    $badNinjaRoot = Join-Path $testRoot 'bad-ninja-root'
    Assert-ThrowsCode { Expand-VersionedTool -Name 'ninja' -ArchivePath $badNinjaArchive -Sha256 $badNinjaHash -TargetRoot $badNinjaRoot -Lock $badNinjaLock | Out-Null } 'DBINST_TOOL_LAYOUT_INVALID' 'fresh authenticated archive still requires a physical AMD64 executable'
    Assert-True (-not (Test-Path -LiteralPath $badNinjaRoot)) 'invalid fresh authenticated archive never becomes the managed root'
    $corruptZip = Join-Path $testRoot 'corrupt.zip'
    [IO.File]::WriteAllBytes($corruptZip, [byte[]](1, 2, 3, 4))
    $corruptZipHash = Get-FileSha256 -Path $corruptZip
    $corruptZipLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $corruptZipLock.ninja.sha256 = $corruptZipHash
    Assert-ThrowsCode { Open-AuthenticatedZipManifest -Name 'ninja' -ArchivePath $corruptZip -Sha256 $corruptZipHash -Lock $corruptZipLock | Out-Null } 'DBINST_ARCHIVE_LAYOUT_INVALID' 'malformed ZIP structure fails closed with a stable installer error'

    $symlinkAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]2717843456), 0)
    $unsafeArchiveCases = @(
        [pscustomobject]@{ label = 'rooted'; entries = @([pscustomobject]@{ name = '/absolute.txt'; content = 'x' }) },
        [pscustomobject]@{ label = 'drive'; entries = @([pscustomobject]@{ name = 'C:/escape.txt'; content = 'x' }) },
        [pscustomobject]@{ label = 'ADS'; entries = @([pscustomobject]@{ name = 'file:stream'; content = 'x' }) },
        [pscustomobject]@{ label = 'empty segment'; entries = @([pscustomobject]@{ name = 'a//b.txt'; content = 'x' }) },
        [pscustomobject]@{ label = 'dotdot'; entries = @([pscustomobject]@{ name = 'a/../b.txt'; content = 'x' }) },
        [pscustomobject]@{ label = 'trailing dot'; entries = @([pscustomobject]@{ name = 'alias./b.txt'; content = 'x' }) },
        [pscustomobject]@{ label = 'trailing space'; entries = @([pscustomobject]@{ name = 'alias /b.txt'; content = 'x' }) },
        [pscustomobject]@{ label = 'invalid Windows character'; entries = @([pscustomobject]@{ name = 'bad?.txt'; content = 'x' }) },
        [pscustomobject]@{ label = 'reserved device'; entries = @([pscustomobject]@{ name = 'CON.txt'; content = 'x' }) },
        [pscustomobject]@{ label = 'marker'; entries = @([pscustomobject]@{ name = '.doppelbanger-tool.json'; content = '{}' }) },
        [pscustomobject]@{ label = 'case duplicate'; entries = @([pscustomobject]@{ name = 'README.txt'; content = 'a' }, [pscustomobject]@{ name = 'readme.TXT'; content = 'b' }) },
        [pscustomobject]@{ label = 'file directory collision'; entries = @([pscustomobject]@{ name = 'folder/'; content = [byte[]]@() }, [pscustomobject]@{ name = 'folder'; content = 'x' }) },
        [pscustomobject]@{ label = 'symlink attribute'; entries = @([pscustomobject]@{ name = 'link'; content = 'target'; external_attributes = $symlinkAttributes }) }
    )
    $unsafeIndex = 0
    foreach ($unsafeCase in $unsafeArchiveCases) {
        $unsafeIndex++
        $unsafeArchive = Join-Path $testRoot ("unsafe-{0}.zip" -f $unsafeIndex)
        New-SyntheticZip -Path $unsafeArchive -Entries (@([pscustomobject]@{ name = 'ninja.exe'; content = (Get-FakeAmd64PeBytes) }) + @($unsafeCase.entries)) | Out-Null
        $unsafeHash = Get-FileSha256 -Path $unsafeArchive
        $unsafeLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $unsafeLock.ninja.sha256 = $unsafeHash
        $unsafeTarget = Join-Path $testRoot ("unsafe-target-{0}" -f $unsafeIndex)
        Assert-ThrowsCode { Expand-VersionedTool -Name 'ninja' -ArchivePath $unsafeArchive -Sha256 $unsafeHash -TargetRoot $unsafeTarget -Lock $unsafeLock | Out-Null } 'DBINST_ARCHIVE_LAYOUT_INVALID' ("unsafe ZIP entry is rejected: {0}" -f $unsafeCase.label)
        Assert-True (-not (Test-Path -LiteralPath $unsafeTarget)) ("unsafe ZIP creates no final root: {0}" -f $unsafeCase.label)
    }

    Assert-ThrowsCode { Get-SafeArchiveEntryPath -Name 'ninja' -RawPath ('bad' + [char]1 + '.txt') | Out-Null } 'DBINST_ARCHIVE_LAYOUT_INVALID' 'pure ZIP path validation rejects a Windows control character'

    Assert-ThrowsCode { Open-AuthenticatedZipManifest -Name 'ninja' -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -Lock $authenticatedNinjaLock -MaximumEntries 1 | Out-Null } 'DBINST_ARCHIVE_LAYOUT_INVALID' 'ZIP entry count is bounded before extraction'
    Assert-ThrowsCode { Open-AuthenticatedZipManifest -Name 'ninja' -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -Lock $authenticatedNinjaLock -MaximumUncompressedBytes 511 | Out-Null } 'DBINST_ARCHIVE_LAYOUT_INVALID' 'ZIP aggregate uncompressed size is bounded without overflow'
    $directoryPayloadArchive = Join-Path $testRoot 'directory-payload.zip'
    New-SyntheticZip -Path $directoryPayloadArchive -Entries @(
        [pscustomobject]@{ name = 'ninja.exe'; content = (Get-FakeAmd64PeBytes) },
        [pscustomobject]@{ name = 'odd-directory/'; content = 'x'; write_directory_content = $true }
    ) | Out-Null
    $directoryPayloadHash = Get-FileSha256 -Path $directoryPayloadArchive
    $directoryPayloadLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $directoryPayloadLock.ninja.sha256 = $directoryPayloadHash
    Assert-ThrowsCode { Open-AuthenticatedZipManifest -Name 'ninja' -ArchivePath $directoryPayloadArchive -Sha256 $directoryPayloadHash -Lock $directoryPayloadLock -MaximumUncompressedBytes 512 | Out-Null } 'DBINST_ARCHIVE_LAYOUT_INVALID' 'ZIP aggregate bound includes directory-entry payload bytes'

    $cmakePrefix = "cmake-$($lock.cmake.version)-windows-x86_64"
    $authenticatedCmakeArchive = Join-Path $testRoot 'authenticated-cmake.zip'
    New-SyntheticZip -Path $authenticatedCmakeArchive -Entries @(
        [pscustomobject]@{ name = "$cmakePrefix/bin/cmake.exe"; content = (Get-FakeAmd64PeBytes) },
        [pscustomobject]@{ name = "$cmakePrefix/bin/ctest.exe"; content = (Get-FakeAmd64PeBytes) }
    ) | Out-Null
    $authenticatedCmakeHash = Get-FileSha256 -Path $authenticatedCmakeArchive
    $authenticatedCmakeLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $authenticatedCmakeLock.cmake.sha256 = $authenticatedCmakeHash
    $nodePrefix = "node-v$($lock.node.version)-win-x64"
    $authenticatedNodeArchive = Join-Path $testRoot 'authenticated-node.zip'
    New-SyntheticZip -Path $authenticatedNodeArchive -Entries @(
        [pscustomobject]@{ name = "$nodePrefix/node.exe"; content = (Get-FakeAmd64PeBytes) },
        [pscustomobject]@{ name = "$nodePrefix/npm.cmd"; content = 'npm' },
        [pscustomobject]@{ name = "$nodePrefix/npx.cmd"; content = 'npx' },
        [pscustomobject]@{ name = "$nodePrefix/node_modules/npm/bin/npm-cli.js"; content = 'npm-cli' },
        [pscustomobject]@{ name = "$nodePrefix/node_modules/npm/bin/npx-cli.js"; content = 'npx-cli' },
        [pscustomobject]@{ name = "$nodePrefix/node_modules/npm/package.json"; content = ('{"version":"' + $lock.node.npm_version + '"}') }
    ) | Out-Null
    $authenticatedNodeHash = Get-FileSha256 -Path $authenticatedNodeArchive
    $authenticatedNodeLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $authenticatedNodeLock.node.sha256 = $authenticatedNodeHash
    $savedProcessPath = $env:PATH
    try {
        $env:PATH = 'Z:\definitely-not-a-tool-path'
        Expand-VersionedTool -Name 'cmake' -ArchivePath $authenticatedCmakeArchive -Sha256 $authenticatedCmakeHash -TargetRoot (Join-Path $testRoot 'authenticated-cmake-root') -ArchiveSubdirectory $cmakePrefix -Lock $authenticatedCmakeLock | Out-Null
        Expand-VersionedTool -Name 'node' -ArchivePath $authenticatedNodeArchive -Sha256 $authenticatedNodeHash -TargetRoot (Join-Path $testRoot 'authenticated-node-root') -ArchiveSubdirectory $nodePrefix -Lock $authenticatedNodeLock | Out-Null
    }
    finally { $env:PATH = $savedProcessPath }
    Assert-True (Test-Path -LiteralPath (Join-Path $testRoot 'authenticated-cmake-root\bin\ctest.exe') -PathType Leaf) 'CMake authenticates from the locked ZIP independently of ambient PATH'
    Assert-True (Test-Path -LiteralPath (Join-Path $testRoot 'authenticated-node-root\node_modules\npm\package.json') -PathType Leaf) 'Node and npm authenticate from the locked ZIP independently of ambient PATH'

    $badCmakeBinding = $authenticatedCmakeLock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $badCmakeBinding.cmake.url = ([string]$badCmakeBinding.cmake.url).Replace("/v$($lock.cmake.version)/", '/v0.0.0/')
    Assert-ThrowsCode { Open-AuthenticatedZipManifest -Name 'cmake' -ArchivePath $authenticatedCmakeArchive -Sha256 $authenticatedCmakeHash -ArchiveSubdirectory $cmakePrefix -Lock $badCmakeBinding | Out-Null } 'DBINST_LOCK_INVALID' 'CMake lock version is statically bound to its release URL and archive prefix'
    $badNinjaBinding = $authenticatedNinjaLock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $badNinjaBinding.ninja.url = ([string]$badNinjaBinding.ninja.url).Replace("/v$($lock.ninja.version)/", '/v0.0.0/')
    Assert-ThrowsCode { Open-AuthenticatedZipManifest -Name 'ninja' -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -Lock $badNinjaBinding | Out-Null } 'DBINST_LOCK_INVALID' 'Ninja lock version is statically bound to its release URL'
    Assert-ThrowsCode { Open-AuthenticatedZipManifest -Name 'node' -ArchivePath $authenticatedNodeArchive -Sha256 $authenticatedNodeHash -ArchiveSubdirectory 'wrong-prefix' -Lock $authenticatedNodeLock | Out-Null } 'DBINST_LOCK_INVALID' 'Node lock version is statically bound to its release URL and archive prefix'

    $reparseToolBacking = Join-Path $testRoot 'reparse-tool-backing'
    $reparseToolParent = Join-Path $testRoot 'reparse-tool-parent'
    [IO.Directory]::CreateDirectory($reparseToolBacking) | Out-Null
    New-Item -ItemType Junction -Path $reparseToolParent -Target $reparseToolBacking | Out-Null
    Assert-ThrowsCode {
        Expand-VersionedTool -Name 'ninja' -ArchivePath $authenticatedNinjaArchive -Sha256 $authenticatedNinjaHash -TargetRoot (Join-Path $reparseToolParent 'ninja-unsafe') -Lock $authenticatedNinjaLock | Out-Null
    } 'DBINST_TOOL_ROOT_CONFLICT' 'archive install rejects a reparse-backed managed-root ancestor'

    # Portable payload layout validation remains static; version identity comes only from the authenticated ZIP and lock binding.
    $versionedCmakeRoot = Join-Path $testRoot 'versioned-cmake-root'
    [IO.Directory]::CreateDirectory((Join-Path $versionedCmakeRoot 'bin')) | Out-Null
    Write-FakeAmd64Pe (Join-Path $versionedCmakeRoot 'bin\cmake.exe')
    Write-FakeAmd64Pe (Join-Path $versionedCmakeRoot 'bin\ctest.exe')
    Assert-True (Test-VersionedToolLayout -Name 'cmake' -Root $versionedCmakeRoot -Lock $lock) 'complete physical CMake and CTest fixture passes static layout checks'
    $cmakeBin = Join-Path $versionedCmakeRoot 'bin'
    $cmakeBinBacking = Join-Path $testRoot 'cmake-bin-backing'
    [IO.Directory]::Move($cmakeBin, $cmakeBinBacking)
    New-Item -ItemType Junction -Path $cmakeBin -Target $cmakeBinBacking | Out-Null
    Assert-ThrowsCode {
        Test-VersionedToolLayout -Name 'cmake' -Root $versionedCmakeRoot -Lock $lock | Out-Null
    } 'DBINST_TOOL_LAYOUT_INVALID' 'portable tool internal bin junction fails static physical-tree validation'
    [IO.Directory]::Delete($cmakeBin, $false); [IO.Directory]::Move($cmakeBinBacking, $cmakeBin)

    $versionedNinjaRoot = Join-Path $testRoot 'versioned-ninja-root'
    [IO.Directory]::CreateDirectory($versionedNinjaRoot) | Out-Null
    Write-FakeAmd64Pe (Join-Path $versionedNinjaRoot 'ninja.exe')
    Assert-True (Test-VersionedToolLayout -Name 'ninja' -Root $versionedNinjaRoot -Lock $lock) 'complete physical Ninja fixture passes static layout checks'

    $versionedNodeRoot = Join-Path $testRoot 'versioned-node-root'
    [IO.Directory]::CreateDirectory((Join-Path $versionedNodeRoot 'node_modules\npm\bin')) | Out-Null
    Write-FakeAmd64Pe (Join-Path $versionedNodeRoot 'node.exe')
    foreach ($relative in @('npm.cmd', 'npx.cmd', 'node_modules\npm\bin\npm-cli.js', 'node_modules\npm\bin\npx-cli.js')) { [IO.File]::WriteAllText((Join-Path $versionedNodeRoot $relative), 'fixture') }
    [IO.File]::WriteAllText((Join-Path $versionedNodeRoot 'node_modules\npm\package.json'), '{"version":"11.17.0"}')
    Assert-True (Test-VersionedToolLayout -Name 'node' -Root $versionedNodeRoot -Lock $lock) 'complete physical Node and locked npm metadata fixture passes'
    $npmCmdPath = Join-Path $versionedNodeRoot 'npm.cmd'
    $npmCmdSource = Join-Path $versionedNodeRoot 'npm-source.cmd'
    [IO.File]::Move($npmCmdPath, $npmCmdSource)
    New-Item -ItemType HardLink -Path $npmCmdPath -Target $npmCmdSource | Out-Null
    Assert-ThrowsCode { Test-VersionedToolLayout -Name 'node' -Root $versionedNodeRoot -Lock $lock | Out-Null } 'DBINST_TOOL_LAYOUT_INVALID' 'hardlinked portable support file fails closed'
    [IO.File]::Delete($npmCmdPath); [IO.File]::Move($npmCmdSource, $npmCmdPath)

    # Audit repair: PATH is append-only over the original byte sequence.
    $pathOriginal = ' C:\Quoted Path ;"C:\Already";C:\dup;C:\dup;'
    $quotedEquivalent = Join-Path $testRoot 'quoted-path'
    $missingAppend = Join-Path $testRoot 'missing-append'
    [IO.Directory]::CreateDirectory($quotedEquivalent) | Out-Null
    [IO.Directory]::CreateDirectory($missingAppend) | Out-Null
    $quotedOriginal = 'C:\unrelated;"' + $quotedEquivalent + '";C:\dup;C:\dup;'
    $appendOnly = Set-DoppelbangerUserPath -RequiredDirectories @($quotedEquivalent, $missingAppend) -CurrentUserPath $quotedOriginal -PlanOnly
    Assert-Equal $appendOnly.path ($quotedOriginal + $missingAppend) 'PATH preserves quotes, duplicates, whitespace, order, and trailing delimiter while appending minimally'
    $appendAgain = Set-DoppelbangerUserPath -RequiredDirectories @($quotedEquivalent, $missingAppend) -CurrentUserPath $appendOnly.path -PlanOnly
    Assert-Equal $appendAgain.path $appendOnly.path 'append-only PATH remains idempotent through normalized comparison'

    # Audit repair: exact installed state skips every downloader/runner path.
    foreach ($idempotentName in @('visual_studio', 'rustup', 'ninja', 'docker')) {
        $script:idempotentMutations = 0
        $skip = Invoke-IdempotentInstallAction -Name $idempotentName -StateProbe { return 'exact' } -Mutation { $script:idempotentMutations++ }
        Assert-Equal $skip.status 'already_installed' "$idempotentName exact state is skipped"
        Assert-Equal $script:idempotentMutations 0 "$idempotentName exact state invokes no downloader or runner"
    }
    $script:conflictMutation = 0
    Assert-ThrowsCode { Invoke-IdempotentInstallAction -Name 'visual_studio' -StateProbe { return 'conflict' } -Mutation { $script:conflictMutation++ } | Out-Null } 'DBINST_INSTALLED_STATE_CONFLICT' 'conflicting VS fixed-root state fails before bootstrap'
    Assert-Equal $script:conflictMutation 0 'conflicting VS state invokes no mutation'

    # Audit repair: Docker backup and Compose provenance gates precede download and restore safely.
    $composeProfile = Join-Path $dockerFixtureRoot 'compose-profile'
    $composeConfig = Join-Path $dockerFixtureRoot 'compose-config'
    $composeExtra = Join-Path $dockerFixtureRoot 'compose-extra'
    $composeProgramFiles = Join-Path $dockerFixtureRoot 'compose-program-files'
    foreach ($directory in @($composeProfile, (Join-Path $composeProfile '.docker\cli-plugins'), $composeConfig, (Join-Path $composeConfig 'cli-plugins'), $composeExtra, (Join-Path $composeProgramFiles 'Docker\cli-plugins'))) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $extraWinner = Join-Path $composeExtra 'docker-compose.exe'
    $configWinner = Join-Path $composeConfig 'cli-plugins\docker-compose.exe'
    $userWinner = Join-Path $composeProfile '.docker\cli-plugins\docker-compose.exe'
    $systemWinner = Join-Path $composeProgramFiles 'Docker\cli-plugins\docker-compose.exe'
    foreach ($plugin in @($extraWinner, $configWinner, $userWinner, $systemWinner)) { Write-FakeAmd64Pe $plugin }
    [IO.File]::WriteAllText((Join-Path $composeConfig 'config.json'), (@{ cliPluginsExtraDirs = @($composeExtra) } | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $composeMetadata = Get-InstallerDockerComposeMetadata -DockerConfig $composeConfig -UserProfile $composeProfile -ProgramFilesRoot $composeProgramFiles
    Assert-Equal $composeMetadata.winner $extraWinner 'configured extra Compose directory wins before DOCKER_CONFIG, user default, and system roots'
    Assert-True ($composeMetadata.plugin_roots -contains $composeExtra -and $composeMetadata.plugin_roots -contains (Join-Path $composeConfig 'cli-plugins') -and $composeMetadata.plugin_roots -notcontains (Join-Path $composeProfile '.docker\cli-plugins')) 'explicit DOCKER_CONFIG uses exact Task 1 precedence without inserting the user-default plugin root'
    [IO.File]::WriteAllText((Join-Path $composeConfig 'config.json'), '{}')
    $configPrecedence = Get-InstallerDockerComposeMetadata -DockerConfig $composeConfig -UserProfile $composeProfile -ProgramFilesRoot $composeProgramFiles
    Assert-Equal $configPrecedence.winner $configWinner 'effective DOCKER_CONFIG plugin wins before the user default and system plugin'

    $dockerAuditLock = $dockerLock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $dockerAuditLock.docker.compose_plugin_path = $systemWinner
    $manifest.source_size_bytes = (Get-Item -LiteralPath $dockerSourcePath).Length
    $manifest.source_sha256 = Get-FileSha256 -Path $dockerSourcePath
    $manifest.backup_size_bytes = (Get-Item -LiteralPath $backupPath).Length
    $manifest.backup_sha256 = Get-FileSha256 -Path $backupPath
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))

    $unrelatedBackupManifest = $manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    [IO.File]::WriteAllText($backupPath, 'same size maybe, different Docker bytes')
    $unrelatedBackupManifest.backup_size_bytes = (Get-Item -LiteralPath $backupPath).Length
    $unrelatedBackupManifest.backup_sha256 = Get-FileSha256 -Path $backupPath
    [IO.File]::WriteAllText((Join-Path $dockerFixtureRoot 'unrelated-backup.json'), ($unrelatedBackupManifest | ConvertTo-Json -Depth 8))
    Assert-ThrowsCode {
        Upgrade-DockerDesktop -Lock $dockerAuditLock -DockerBackupManifest (Join-Path $dockerFixtureRoot 'unrelated-backup.json') -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -ComposeMetadata $composeMetadata -DesktopStoppedProbe { return $true } -PlanOnly | Out-Null
    } 'DBINST_DOCKER_BACKUP_INVALID' 'individually hashed but byte-unrelated Docker backup is rejected'
    [IO.File]::Copy($dockerSourcePath, $backupPath, $true)
    $manifest.backup_size_bytes = (Get-Item -LiteralPath $backupPath).Length
    $manifest.backup_sha256 = Get-FileSha256 -Path $backupPath
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8))

    $sourceChangedManifest = $manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    [IO.File]::AppendAllText($dockerSourcePath, 'changed after manifest')
    [IO.File]::WriteAllText((Join-Path $dockerFixtureRoot 'source-changed.json'), ($sourceChangedManifest | ConvertTo-Json -Depth 8))
    Assert-ThrowsCode {
        Upgrade-DockerDesktop -Lock $dockerAuditLock -DockerBackupManifest (Join-Path $dockerFixtureRoot 'source-changed.json') -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -ComposeMetadata $composeMetadata -DesktopStoppedProbe { return $true } -PlanOnly | Out-Null
    } 'DBINST_DOCKER_BACKUP_INVALID' 'live source changed after manifest fails closed'
    [IO.File]::WriteAllText($dockerSourcePath, 'actual Docker source data')
    [IO.File]::Copy($dockerSourcePath, $backupPath, $true)
    $manifest.source_size_bytes = (Get-Item -LiteralPath $dockerSourcePath).Length
    $manifest.source_sha256 = Get-FileSha256 -Path $dockerSourcePath
    $manifest.backup_size_bytes = (Get-Item -LiteralPath $backupPath).Length
    $manifest.backup_sha256 = Get-FileSha256 -Path $backupPath
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8))

    $uppercaseManifest = $manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $uppercaseManifest.source_sha256 = $uppercaseManifest.source_sha256.ToUpperInvariant()
    [IO.File]::WriteAllText((Join-Path $dockerFixtureRoot 'uppercase-manifest.json'), ($uppercaseManifest | ConvertTo-Json -Depth 8))
    Assert-ThrowsCode {
        Upgrade-DockerDesktop -Lock $dockerAuditLock -DockerBackupManifest (Join-Path $dockerFixtureRoot 'uppercase-manifest.json') -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -ComposeMetadata $composeMetadata -DesktopStoppedProbe { return $true } -PlanOnly | Out-Null
    } 'DBINST_DOCKER_BACKUP_INVALID' 'uppercase manifest SHA is rejected case-sensitively'

    $hardlinkBackupSource = Join-Path $dockerBackupRoot 'hardlink-backup-source.bin'
    $hardlinkBackup = Join-Path $dockerBackupRoot 'hardlink-backup.bin'
    [IO.File]::Copy($dockerSourcePath, $hardlinkBackupSource)
    New-Item -ItemType HardLink -Path $hardlinkBackup -Target $hardlinkBackupSource | Out-Null
    $hardlinkManifest = $manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $hardlinkManifest.backup_path = $hardlinkBackup
    $hardlinkManifest.backup_size_bytes = (Get-Item -LiteralPath $hardlinkBackup).Length
    $hardlinkManifest.backup_sha256 = Get-FileSha256 -Path $hardlinkBackup
    [IO.File]::WriteAllText((Join-Path $dockerFixtureRoot 'hardlink-manifest.json'), ($hardlinkManifest | ConvertTo-Json -Depth 8))
    Assert-ThrowsCode {
        Upgrade-DockerDesktop -Lock $dockerAuditLock -DockerBackupManifest (Join-Path $dockerFixtureRoot 'hardlink-manifest.json') -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -ComposeMetadata $composeMetadata -DesktopStoppedProbe { return $true } -PlanOnly | Out-Null
    } 'DBINST_DOCKER_BACKUP_INVALID' 'hardlinked Docker backup evidence is rejected'

    $pluginRootManifest = $manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $pluginBackup = Join-Path $composeExtra 'docker-backup.bin'
    [IO.File]::Copy($dockerSourcePath, $pluginBackup)
    $pluginRootManifest.backup_path = $pluginBackup
    $pluginRootManifest.backup_size_bytes = (Get-Item -LiteralPath $pluginBackup).Length
    $pluginRootManifest.backup_sha256 = Get-FileSha256 -Path $pluginBackup
    [IO.File]::WriteAllText((Join-Path $dockerFixtureRoot 'plugin-root-manifest.json'), ($pluginRootManifest | ConvertTo-Json -Depth 8))
    Assert-ThrowsCode {
        Upgrade-DockerDesktop -Lock $dockerAuditLock -DockerBackupManifest (Join-Path $dockerFixtureRoot 'plugin-root-manifest.json') -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -ComposeMetadata $composeMetadata -DesktopStoppedProbe { return $true } -PlanOnly | Out-Null
    } 'DBINST_DOCKER_BACKUP_INVALID' 'backup inside configured Compose plugin root is rejected'

    $siblingDataRoot = Join-Path $dockerFixtureRoot 'sibling-docker-data-root'
    [IO.Directory]::CreateDirectory($siblingDataRoot) | Out-Null
    $siblingDataBackup = Join-Path $siblingDataRoot 'docker-backup.bin'
    [IO.File]::Copy($dockerSourcePath, $siblingDataBackup)
    $siblingDataManifest = $manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $siblingDataManifest.backup_path = $siblingDataBackup
    $siblingDataManifest.backup_size_bytes = (Get-Item -LiteralPath $siblingDataBackup).Length
    $siblingDataManifest.backup_sha256 = Get-FileSha256 -Path $siblingDataBackup
    $siblingDataManifestPath = Join-Path $dockerFixtureRoot 'sibling-data-root-manifest.json'
    [IO.File]::WriteAllText($siblingDataManifestPath, ($siblingDataManifest | ConvertTo-Json -Depth 8))
    Assert-ThrowsCode {
        Upgrade-DockerDesktop -Lock $dockerAuditLock -DockerBackupManifest $siblingDataManifestPath -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -DockerDataRoots @($siblingDataRoot) -ComposeMetadata $composeMetadata -DesktopStoppedProbe { return $true } -PlanOnly | Out-Null
    } 'DBINST_DOCKER_BACKUP_INVALID' 'backup inside any discovered sibling Docker data root is rejected'

    $badGateManifest = $manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $badGateManifest.backup_sha256 = ('0' * 64)
    $badGatePath = Join-Path $dockerFixtureRoot 'gate-before-download.json'
    [IO.File]::WriteAllText($badGatePath, ($badGateManifest | ConvertTo-Json -Depth 8))
    Assert-ThrowsCode {
        Upgrade-DockerDesktop -Lock $dockerAuditLock -DockerBackupManifest $badGatePath -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -ComposeMetadata $composeMetadata -DesktopStoppedProbe { return $false } -PlanOnly | Out-Null
    } 'DBINST_DOCKER_DESKTOP_RUNNING' 'live Desktop stop gate runs before source or backup hashing'
    $script:dockerArtifactRequests = 0
    Assert-ThrowsCode {
        Upgrade-DockerDesktop -Lock $dockerAuditLock -DockerBackupManifest $badGatePath -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -ComposeMetadata $composeMetadata -DesktopStoppedProbe { return $true } -ArtifactProvider { $script:dockerArtifactRequests++; return $dockerArtifact } -PlanOnly:$false | Out-Null
    } 'DBINST_DOCKER_BACKUP_INVALID' 'Docker manifest gate fails before artifact provider'
    Assert-Equal $script:dockerArtifactRequests 0 'invalid Docker gate never downloads an artifact'

    $lockedComposeMetadata = [pscustomobject]@{ winner = $systemWinner; plugin_roots = $composeMetadata.plugin_roots; candidates = $composeMetadata.candidates }

    # Fix Round 1: a Docker 3010 Compose move is compensated if durable checkpoint persistence fails.
    $checkpointShadow = Join-Path $composeExtra 'checkpoint-3010-compose.exe'
    Write-FakeAmd64Pe $checkpointShadow
    $checkpointShadowMetadata = [pscustomobject]@{ winner = $checkpointShadow; plugin_roots = $composeMetadata.plugin_roots; candidates = @($checkpointShadow, $systemWinner) }
    $checkpointFailurePath = Join-Path $testRoot 'docker-3010-checkpoint.json'
    $script:docker3010Runs = 0
    $script:docker3010LaterActions = 0
    $docker3010Actions = @(
        [pscustomobject]@{ name = 'docker'; checkpoint_on_3010 = $true; invoke = {
            Upgrade-DockerDesktop -Lock $dockerAuditLock -DockerBackupManifest $manifestPath -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -ComposeMetadata $checkpointShadowMetadata -DesktopStoppedProbe { return $true } -ArtifactProvider { return $dockerArtifact } -BackupShadowingComposePlugin -TimestampUtc ([DateTime]'2026-08-05T13:00:00Z') -Runner { $script:docker3010Runs++; return 3010 }
        } },
        [pscustomobject]@{ name = 'later'; invoke = { $script:docker3010LaterActions++; return 0 } }
    )
    Assert-ThrowsCode {
        Invoke-InstallActionSequence -Actions $docker3010Actions -CheckpointPath $checkpointFailurePath -CheckpointRoot (Split-Path -Parent $checkpointFailurePath) -LockSha256 (Get-FileSha256 -Path $installerLockPath) -BootSessionMarker 'docker-3010-boot' -PreconditionCheck { } -EnvironmentCheck { } -CheckpointWriter { [IO.File]::WriteAllText($checkpointFailurePath, 'partial checkpoint'); throw 'injected checkpoint persistence failure' } | Out-Null
    } 'DBINST_CHECKPOINT_WRITE_FAILED' 'Docker 3010 checkpoint persistence failure has a stable compensating-rollback error'
    Assert-Equal $script:docker3010Runs 1 'Docker 3010 runner executes exactly once before checkpoint failure'
    Assert-Equal $script:docker3010LaterActions 0 'checkpoint failure runs no later action'
    Assert-True (Test-Path -LiteralPath $checkpointShadow -PathType Leaf) 'checkpoint failure restores the exact moved Compose winner'
    Assert-True (-not (Test-Path -LiteralPath ($checkpointShadow + '.doppelbanger-backup-20260805T130000Z'))) 'checkpoint failure leaves no moved Compose backup after successful compensation'
    Assert-True (-not (Test-Path -LiteralPath $checkpointFailurePath)) 'failed checkpoint persistence leaves no visible checkpoint'
    $checkpointRestoredItem = Get-Item -LiteralPath $checkpointShadow
    $checkpointRollbackAgain = Restore-ComposeShadowFromReceipt -Receipt ([pscustomobject]@{
        source = $checkpointShadow
        backup = $checkpointShadow + '.doppelbanger-backup-20260805T130000Z'
        length = [long]$checkpointRestoredItem.Length
        sha256 = Get-FileSha256 -Path $checkpointShadow
    })
    Assert-True $checkpointRollbackAgain.restored 'Compose rollback receipt is idempotent after exact restoration'
    Assert-True $checkpointRollbackAgain.already_restored 'idempotent Compose rollback reports the already-restored state'

    $rollbackFailureCheckpoint = Join-Path $testRoot 'docker-rollback-failure-checkpoint.json'
    $script:checkpointRollbackFailures = 0
    Assert-ThrowsCode {
        Invoke-InstallActionSequence -Actions @([pscustomobject]@{
            name = 'docker'; checkpoint_on_3010 = $true; invoke = {
                return [pscustomobject]@{
                    exit_code = 3010
                    checkpoint_rollback = { $script:checkpointRollbackFailures++; throw 'injected Compose restore failure' }
                    rollback_receipt = [pscustomobject]@{ source = 'C:\source'; backup = 'C:\backup'; length = 1; sha256 = ('1' * 64) }
                }
            }
        }) -CheckpointPath $rollbackFailureCheckpoint -CheckpointRoot (Split-Path -Parent $rollbackFailureCheckpoint) -LockSha256 (Get-FileSha256 -Path $installerLockPath) -BootSessionMarker 'docker-rollback-failure-boot' -PreconditionCheck { } -EnvironmentCheck { } -CheckpointWriter { [IO.File]::WriteAllText($rollbackFailureCheckpoint, 'partial checkpoint'); throw 'injected checkpoint persistence failure' } | Out-Null
    } 'DBINST_COMPOSE_ROLLBACK_FAILED' 'checkpoint and Compose rollback double failure has its own stable recovery error'
    Assert-Equal $script:checkpointRollbackFailures 1 'checkpoint double-failure path attempts Compose rollback exactly once'
    Assert-True (-not (Test-Path -LiteralPath $rollbackFailureCheckpoint)) 'checkpoint double-failure path still removes its visible partial checkpoint'

    $script:lateStopChecks = 0
    $script:lateDockerRunner = 0
    Assert-ThrowsCode {
        Upgrade-DockerDesktop -Lock $dockerAuditLock -DockerBackupManifest $manifestPath -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -ComposeMetadata $lockedComposeMetadata -DesktopStoppedProbe { $script:lateStopChecks++; return $script:lateStopChecks -eq 1 } -ArtifactProvider { return $dockerArtifact } -Runner { $script:lateDockerRunner++; return 0 } | Out-Null
    } 'DBINST_DOCKER_DESKTOP_RUNNING' 'Docker processes restarting after hash gate block launch'
    Assert-Equal $script:lateDockerRunner 0 'late Docker process restart never launches installer'

    $lateRestoreShadow = Join-Path $composeExtra 'late-restart-compose.exe'
    Write-FakeAmd64Pe $lateRestoreShadow
    $lateRestoreMetadata = [pscustomobject]@{ winner = $lateRestoreShadow; plugin_roots = $composeMetadata.plugin_roots; candidates = @($lateRestoreShadow, $systemWinner) }
    $script:lateRestoreChecks = 0
    $script:lateRestoreRunner = 0
    Assert-ThrowsCode {
        Upgrade-DockerDesktop -Lock $dockerAuditLock -DockerBackupManifest $manifestPath -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -ComposeMetadata $lateRestoreMetadata -DesktopStoppedProbe { $script:lateRestoreChecks++; return $script:lateRestoreChecks -eq 1 } -ArtifactProvider { return $dockerArtifact } -BackupShadowingComposePlugin -TimestampUtc ([DateTime]'2026-08-05T12:35:56Z') -Runner { $script:lateRestoreRunner++; return 0 } | Out-Null
    } 'DBINST_DOCKER_DESKTOP_RUNNING' 'late Desktop restart at the final launch seam blocks runner'
    Assert-Equal $script:lateRestoreRunner 0 'late Desktop restart invokes no Docker installer runner'
    Assert-True (Test-Path -LiteralPath $lateRestoreShadow -PathType Leaf) 'late restart restores the exact opted-in Compose winner'
    Assert-True (-not (Test-Path -LiteralPath ($lateRestoreShadow + '.doppelbanger-backup-20260805T123556Z'))) 'late-restart restore leaves no Compose move target'

    $restoreShadow = Join-Path $composeExtra 'restore-compose.exe'
    Write-FakeAmd64Pe $restoreShadow
    $restoreMetadata = [pscustomobject]@{ winner = $restoreShadow; plugin_roots = $composeMetadata.plugin_roots; candidates = @($restoreShadow, $systemWinner) }
    $failedUpgrade = Upgrade-DockerDesktop -Lock $dockerAuditLock -DockerBackupManifest $manifestPath -CurrentDesktopVersion '4.46.0' -DetectedSourceDataPath $dockerSourcePath -ComposeMetadata $restoreMetadata -DesktopStoppedProbe { return $true } -ArtifactProvider { return $dockerArtifact } -BackupShadowingComposePlugin -TimestampUtc ([DateTime]'2026-08-05T12:34:56Z') -Runner { return 1 }
    Assert-Equal $failedUpgrade.exit_code 1 'failed Docker installer returns its authoritative nonzero exit'
    Assert-True (Test-Path -LiteralPath $restoreShadow -PathType Leaf) 'failed Docker upgrade restores the exact moved Compose winner'
    Assert-True (-not (Test-Path -LiteralPath ($restoreShadow + '.doppelbanger-backup-20260805T123456Z'))) 'restored Compose plugin leaves no orphaned move target'

    Assert-True (Test-DockerDesktopExactState -Lock $lock -Metadata ([pscustomobject]@{ version = $lock.docker.desktop_version; build = $lock.docker.desktop_build })) 'Docker exact state requires locked semantic version and build'
    Assert-True (-not (Test-DockerDesktopExactState -Lock $lock -Metadata ([pscustomobject]@{ version = $lock.docker.desktop_version; build = 'wrong' }))) 'Docker same version with wrong build is not exact state'
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    $relative = $resolvedRoot.Substring($varRoot.Length).TrimStart('\')
    $guid = [Guid]::Empty
    if (-not [Guid]::TryParseExact($relative, 'D', [ref]$guid) -or $resolvedRoot -ine (Join-Path $varRoot $guid.ToString('D'))) {
        throw 'test cleanup target is not a validated direct GUID child of repository var'
    }
    if (Test-Path -LiteralPath $resolvedRoot) {
        $pending = New-Object 'Collections.Generic.Stack[string]'
        $pending.Push($resolvedRoot)
        while ($pending.Count -gt 0) {
            $current = $pending.Pop()
            foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
                if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName, $false) } else { [IO.File]::Delete($item.FullName) }
                }
                elseif ($item.PSIsContainer) { $pending.Push($item.FullName) }
            }
        }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}

Write-Host "PASS: $script:passed Windows installer contract assertions"
