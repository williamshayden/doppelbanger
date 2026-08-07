[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$wrapperPath = Join-Path $repoRoot 'tests\plugin\validate_vst3.ps1'

if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
    throw 'RED: tests/plugin/validate_vst3.ps1 is missing'
}

. $wrapperPath

$script:passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
    $script:passed++
}

function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Message)

    Assert-True ($Actual -ceq $Expected) "$Message (expected '$Expected', got '$Actual')"
}

function New-ValidationFixture {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("doppelbanger-validation-contract-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $root -Force

    $validatorPath = Join-Path $root 'validator.exe'
    [System.IO.File]::WriteAllText($validatorPath, 'fixture')
    $pluginPath = Join-Path $root 'Doppelbanger.vst3'
    $null = New-Item -ItemType Directory -Path $pluginPath -Force

    return [pscustomobject]@{
        Root = $root
        ValidatorPath = $validatorPath
        PluginPath = $pluginPath
        EvidencePath = Join-Path $root 'evidence'
    }
}

function New-ProcessLauncher {
    param(
        [System.Collections.Generic.List[object]]$Invocations,
        [int]$ExitCode = 0,
        [bool]$TimedOut = $false,
        [string]$StdOut = 'validator stdout',
        [string]$StdErr = 'validator stderr',
        [string]$LaunchError = ''
    )

    return {
        param([string]$ValidatorPath, [string]$PluginPath, [int]$TimeoutSeconds)

        $Invocations.Add([pscustomobject]@{
            ValidatorPath = $ValidatorPath
            PluginPath = $PluginPath
            TimeoutSeconds = $TimeoutSeconds
        })
        return [pscustomobject]@{
            ExitCode = $ExitCode
            TimedOut = $TimedOut
            StdOut = $StdOut
            StdErr = $StdErr
            LaunchError = $LaunchError
        }
    }.GetNewClosure()
}

function Invoke-WrapperFixture {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [scriptblock]$ProcessLauncher,
        [Nullable[int]]$TimeoutSeconds,
        [string]$ValidatorPath = $Fixture.ValidatorPath,
        [string]$PluginPath = $Fixture.PluginPath,
        [scriptblock]$EvidenceWriter
    )

    $parameters = @{
        ValidatorPath = $ValidatorPath
        PluginPath = $PluginPath
        EvidenceDirectory = $Fixture.EvidencePath
    }
    if ($ProcessLauncher) { $parameters.ProcessLauncher = $ProcessLauncher }
    if ($PSBoundParameters.ContainsKey('TimeoutSeconds')) { $parameters.TimeoutSeconds = [int]$TimeoutSeconds }
    if ($EvidenceWriter) { $parameters.EvidenceWriter = $EvidenceWriter }

    return Invoke-DbVst3Validation @parameters
}

$fixture = New-ValidationFixture
try {
    $successInvocations = [System.Collections.Generic.List[object]]::new()
    $successResult = Invoke-WrapperFixture -Fixture $fixture -ProcessLauncher (New-ProcessLauncher -Invocations $successInvocations)

    Assert-True $successResult.Success 'a completed zero validator exit succeeds'
    Assert-Equal $successInvocations.Count 1 'the validator is launched exactly once'
    Assert-Equal $successInvocations[0].ValidatorPath $fixture.ValidatorPath 'the direct launch receives the exact validator path'
    Assert-Equal $successInvocations[0].PluginPath $fixture.PluginPath 'the direct launch receives the exact plugin path'
    Assert-True ($successInvocations[0].TimeoutSeconds -gt 0) 'a finite positive timeout is defaulted'
    Assert-Equal $successResult.ValidatorPath $fixture.ValidatorPath 'result records the exact validator path'
    Assert-Equal $successResult.PluginPath $fixture.PluginPath 'result records the exact plugin path'
    Assert-Equal $successResult.ValidatorExitCode 0 'result records the real zero validator exit code'
    Assert-True (-not $successResult.TimedOut) 'result records a completed validator'
    Assert-True ($null -ne [datetime]::Parse($successResult.StartedUtc)) 'result records start UTC'
    Assert-True ($null -ne [datetime]::Parse($successResult.EndedUtc)) 'result records end UTC'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.EvidencePath 'validator.stdout.txt') -PathType Leaf) 'stdout is retained separately'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.EvidencePath 'validator.stderr.txt') -PathType Leaf) 'stderr is retained separately'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $fixture.EvidencePath 'validator.stdout.txt'))) 'validator stdout' 'stdout evidence preserves validator output'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $fixture.EvidencePath 'validator.stderr.txt'))) 'validator stderr' 'stderr evidence preserves validator output'
    $persistedResult = Get-Content -LiteralPath (Join-Path $fixture.EvidencePath 'validator.result.json') -Raw | ConvertFrom-Json
    Assert-Equal $persistedResult.ValidatorPath $fixture.ValidatorPath 'machine-readable evidence records the exact validator path'
    Assert-Equal $persistedResult.PluginPath $fixture.PluginPath 'machine-readable evidence records the exact plugin path'
    Assert-Equal ([int]$persistedResult.ValidatorExitCode) 0 'machine-readable evidence records the real exit code'
    Assert-True ([bool]$persistedResult.Success) 'machine-readable evidence records success only after evidence is written'

    $invalidTargets = @(
        [pscustomobject]@{ Name = 'relative validator'; Validator = 'validator.exe'; Plugin = $fixture.PluginPath },
        [pscustomobject]@{ Name = 'relative plugin'; Validator = $fixture.ValidatorPath; Plugin = 'Doppelbanger.vst3' },
        [pscustomobject]@{ Name = 'missing validator'; Validator = (Join-Path $fixture.Root 'missing.exe'); Plugin = $fixture.PluginPath },
        [pscustomobject]@{ Name = 'missing plugin'; Validator = $fixture.ValidatorPath; Plugin = (Join-Path $fixture.Root 'missing.vst3') },
        [pscustomobject]@{ Name = 'WSL validator'; Validator = '\\wsl$\Ubuntu\validator.exe'; Plugin = $fixture.PluginPath },
        [pscustomobject]@{ Name = 'UNC plugin'; Validator = $fixture.ValidatorPath; Plugin = '\\server\share\Doppelbanger.vst3' },
        [pscustomobject]@{ Name = 'quoted validator'; Validator = ('"' + $fixture.ValidatorPath + '"'); Plugin = $fixture.PluginPath },
        [pscustomobject]@{ Name = 'injected plugin'; Validator = $fixture.ValidatorPath; Plugin = ($fixture.PluginPath + '" -selftest') },
        [pscustomobject]@{ Name = 'wildcard plugin'; Validator = $fixture.ValidatorPath; Plugin = (Join-Path $fixture.Root '*.vst3') }
    )
    foreach ($target in $invalidTargets) {
        $invalidInvocations = [System.Collections.Generic.List[object]]::new()
        $invalidResult = Invoke-WrapperFixture -Fixture $fixture -ValidatorPath $target.Validator -PluginPath $target.Plugin -ProcessLauncher (New-ProcessLauncher -Invocations $invalidInvocations)
        Assert-True (-not $invalidResult.Success) "$($target.Name) fails validation"
        Assert-Equal $invalidInvocations.Count 0 "$($target.Name) fails before process launch"
    }

    $wrongValidatorExtension = Join-Path $fixture.Root 'validator.cmd'
    [System.IO.File]::WriteAllText($wrongValidatorExtension, 'fixture')
    $wrongValidatorInvocations = [System.Collections.Generic.List[object]]::new()
    $wrongValidatorResult = Invoke-WrapperFixture -Fixture $fixture -ValidatorPath $wrongValidatorExtension -ProcessLauncher (New-ProcessLauncher -Invocations $wrongValidatorInvocations)
    Assert-True (-not $wrongValidatorResult.Success) 'a validator must be an existing .exe file'
    Assert-Equal $wrongValidatorInvocations.Count 0 'a non-.exe validator fails before launch'

    $pluginFile = Join-Path $fixture.Root 'plugin-file.vst3'
    [System.IO.File]::WriteAllText($pluginFile, 'fixture')
    $pluginFileInvocations = [System.Collections.Generic.List[object]]::new()
    $pluginFileResult = Invoke-WrapperFixture -Fixture $fixture -PluginPath $pluginFile -ProcessLauncher (New-ProcessLauncher -Invocations $pluginFileInvocations)
    Assert-True (-not $pluginFileResult.Success) 'a plugin must be an existing .vst3 directory'
    Assert-Equal $pluginFileInvocations.Count 0 'a .vst3 file fails before launch'

    $zeroTimeoutInvocations = [System.Collections.Generic.List[object]]::new()
    $zeroTimeoutResult = Invoke-WrapperFixture -Fixture $fixture -TimeoutSeconds 0 -ProcessLauncher (New-ProcessLauncher -Invocations $zeroTimeoutInvocations)
    Assert-True (-not $zeroTimeoutResult.Success) 'a non-positive timeout fails'
    Assert-Equal $zeroTimeoutInvocations.Count 0 'a non-positive timeout fails before launch'

    $timeoutInvocations = [System.Collections.Generic.List[object]]::new()
    $timeoutResult = Invoke-WrapperFixture -Fixture $fixture -TimeoutSeconds 5 -ProcessLauncher (New-ProcessLauncher -Invocations $timeoutInvocations -TimedOut $true -ExitCode 137)
    Assert-True (-not $timeoutResult.Success) 'a timed-out validator fails'
    Assert-True $timeoutResult.TimedOut 'a timed-out validator is recorded'
    Assert-Equal $timeoutResult.ValidatorExitCode 137 'a timed-out validator retains its real exit code'

    foreach ($failure in @(
        [pscustomobject]@{ Name = 'launch error'; ExitCode = 0; LaunchError = 'simulated launch error' },
        [pscustomobject]@{ Name = 'crash'; ExitCode = -1073741819; LaunchError = '' },
        [pscustomobject]@{ Name = 'nonzero exit'; ExitCode = 7; LaunchError = '' }
    )) {
        $failureInvocations = [System.Collections.Generic.List[object]]::new()
        $failureResult = Invoke-WrapperFixture -Fixture $fixture -ProcessLauncher (New-ProcessLauncher -Invocations $failureInvocations -ExitCode $failure.ExitCode -LaunchError $failure.LaunchError)
        Assert-True (-not $failureResult.Success) "$($failure.Name) cannot report success"
    }

    $shortWriteInvocations = [System.Collections.Generic.List[object]]::new()
    $shortWriteResult = Invoke-WrapperFixture -Fixture $fixture -ProcessLauncher (New-ProcessLauncher -Invocations $shortWriteInvocations) -EvidenceWriter {
        param([string]$Path, [string]$Content)
        return $false
    }
    Assert-True (-not $shortWriteResult.Success) 'failed evidence writes cannot report success'
}
finally {
    if (Test-Path -LiteralPath $fixture.Root) {
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force
    }
}

Write-Host "validation wrapper contract passed ($script:passed assertions)."
