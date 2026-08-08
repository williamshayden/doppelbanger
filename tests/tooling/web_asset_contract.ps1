[CmdletBinding()]
param(
    [string]$WebRoot = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($WebRoot)) {
    $WebRoot = Join-Path $repoRoot 'build\windows-msvc-x64-release\artefacts\Release\VST3\Doppelbanger.vst3\Contents\Resources\web'
}
$expectedCsp = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'none'; object-src 'none'; frame-src 'none'; media-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:passed++
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch { $script:passed++; return }
    throw "ASSERTION FAILED: $Message"
}

function Get-NormalizedAssetReference {
    param([string]$Reference)
    if ($Reference -match '^(?:https?:|ws:|wss:|//|/|[A-Za-z]:|\\\\)') {
        throw "asset reference is not relative: $Reference"
    }
    $normalized = $Reference -replace '^\./', ''
    if ($normalized -match '(^|/)\.\.(/|$)' -or [string]::IsNullOrWhiteSpace($normalized)) {
        throw "asset reference escapes its bundle: $Reference"
    }
    return $normalized
}

function Get-RelativeWebPath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Path)
    return $Path.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
}

function Assert-WebAssetBundle {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "web asset root is missing: $Root" }
    $indexPath = Join-Path $Root 'index.html'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw 'web asset bundle must contain one index.html' }
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName)
    $relativeFiles = @{}
    foreach ($file in $files) {
        $relative = Get-RelativeWebPath -Root $Root -Path $file.FullName
        if ($relative -notmatch '^(?:index\.html|assets/[A-Za-z0-9_-]+-[A-Za-z0-9_-]{8,}\.(?:js|css))$') {
            throw "unexpected packaged web file: $relative"
        }
        if ($relative -match '(?i)(\.map$|(?:^|/)(?:src|test|tests|node_modules)(?:/|$))') {
            throw "development artifact is packaged: $relative"
        }
        $relativeFiles[$relative] = $file.FullName
    }
    if (@($relativeFiles.Keys | Where-Object { $_ -match '^assets/.+-[A-Za-z0-9_-]{8,}\.js$' }).Count -lt 1) { throw 'web asset bundle must contain a content-hashed JavaScript asset' }
    if (@($relativeFiles.Keys | Where-Object { $_ -match '^assets/.+-[A-Za-z0-9_-]{8,}\.css$' }).Count -lt 1) { throw 'web asset bundle must contain a content-hashed CSS asset' }

    $index = Get-Content -LiteralPath $indexPath -Raw
    $cspMatch = [regex]::Match($index, '<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]+)"\s*/?>', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $cspMatch.Success -or $cspMatch.Groups[1].Value -cne $expectedCsp) { throw 'index.html must retain the exact production CSP' }

    $referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $files) {
        $relative = Get-RelativeWebPath -Root $Root -Path $file.FullName
        $content = Get-Content -LiteralPath $file.FullName -Raw
        if ($content -match '(?i)(?:localhost|127\.0\.0\.1|node_modules|password\s*=|api[_-]?key|vite dev|(?:fetch|importScripts)\s*\(\s*["'']https?:|new\s+(?:WebSocket|EventSource)\s*\(\s*(?:["'']|`)(?:https?|wss?):|(?:location(?:\.href)?\s*=|window\.open\s*\()\s*["'']https?:)') {
            throw "forbidden development, remote, path, or credential marker in $(Get-RelativeWebPath -Root $Root -Path $file.FullName)"
        }
        if ($relative -ceq 'index.html') {
            foreach ($match in [regex]::Matches($content, '(?:src|href)\s*=\s*["'']([^"'']+)["'']', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $reference = $match.Groups[1].Value
                if ($reference -notmatch '^(?:#|data:)') { $null = $referenced.Add((Get-NormalizedAssetReference $reference)) }
            }
        }
        if ($relative -match '\.css$') {
            foreach ($match in [regex]::Matches($content, 'url\(\s*["'']?([^"'')\s]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $reference = $match.Groups[1].Value
                if ($reference -notmatch '^(?:#|data:)') { $null = $referenced.Add((Get-NormalizedAssetReference $reference)) }
            }
        }
    }
    foreach ($asset in @($relativeFiles.Keys | Where-Object { $_ -ne 'index.html' })) {
        if (-not $referenced.Contains($asset)) { throw "packaged asset is not referenced: $asset" }
    }
    foreach ($reference in $referenced) {
        if (-not $relativeFiles.ContainsKey($reference)) { throw "referenced asset is missing: $reference" }
    }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("doppelbanger-web-assets-" + [guid]::NewGuid().ToString('N'))
try {
    $assets = Join-Path $fixtureRoot 'assets'
    $null = New-Item -ItemType Directory -Path $assets -Force
    [IO.File]::WriteAllText((Join-Path $assets 'index-CCl-7ZKT.js'), 'console.log("ready")')
    [IO.File]::WriteAllText((Join-Path $assets 'index-D1yEFCXt.css'), 'body{color:#fff}')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'index.html'), "<meta http-equiv=`"Content-Security-Policy`" content=`"$expectedCsp`"><script src=`"./assets/index-CCl-7ZKT.js`"></script><link href=`"./assets/index-D1yEFCXt.css`" rel=`"stylesheet`">")
    Assert-WebAssetBundle -Root $fixtureRoot
    Assert-True $true 'a closed-world production fixture is accepted'
    [IO.File]::WriteAllText((Join-Path $assets 'orphan-11223344.js'), 'console.log("orphan")')
    Assert-Throws { Assert-WebAssetBundle -Root $fixtureRoot } 'an unreferenced packaged asset is rejected'
    Remove-Item -LiteralPath (Join-Path $assets 'orphan-11223344.js') -Force
    $hiddenUnexpectedPath = Join-Path $fixtureRoot 'hidden-bypass.txt'
    $hiddenOriginalAttributes = $null
    try {
        [IO.File]::WriteAllText($hiddenUnexpectedPath, 'hidden files remain inside the closed world')
        $hiddenOriginalAttributes = [IO.File]::GetAttributes($hiddenUnexpectedPath)
        [IO.File]::SetAttributes($hiddenUnexpectedPath, ($hiddenOriginalAttributes -bor [IO.FileAttributes]::Hidden))
        $hiddenAttributes = [IO.File]::GetAttributes($hiddenUnexpectedPath)
        Assert-True (($hiddenAttributes -band [IO.FileAttributes]::Hidden) -ne 0) 'the hidden-file fixture has the native Windows Hidden attribute'
        Assert-Throws { Assert-WebAssetBundle -Root $fixtureRoot } 'a hidden unexpected packaged file is rejected'
    }
    finally {
        if (Test-Path -LiteralPath $hiddenUnexpectedPath) {
            if ($null -ne $hiddenOriginalAttributes) {
                [IO.File]::SetAttributes($hiddenUnexpectedPath, $hiddenOriginalAttributes)
            }
            Remove-Item -LiteralPath $hiddenUnexpectedPath -Force
        }
    }
    $webSocketFixtures = @(
        [pscustomobject]@{ Name = 'ws single literal'; Content = "new WebSocket('ws://editor.example/socket')" },
        [pscustomobject]@{ Name = 'wss single literal'; Content = "new WebSocket('wss://editor.example/socket')" },
        [pscustomobject]@{ Name = 'ws double literal'; Content = 'new WebSocket("ws://editor.example/socket")' },
        [pscustomobject]@{ Name = 'wss double literal'; Content = 'new WebSocket("wss://editor.example/socket")' },
        [pscustomobject]@{ Name = 'ws template literal'; Content = 'new WebSocket(`ws://editor.example/socket`)' },
        [pscustomobject]@{ Name = 'wss template literal'; Content = 'new WebSocket(`wss://editor.example/socket`)' }
    )
    foreach ($webSocketFixture in $webSocketFixtures) {
        [IO.File]::WriteAllText((Join-Path $assets 'index-CCl-7ZKT.js'), $webSocketFixture.Content)
        Assert-Throws { Assert-WebAssetBundle -Root $fixtureRoot } "$($webSocketFixture.Name) is rejected"
    }
    [IO.File]::WriteAllText((Join-Path $assets 'index-CCl-7ZKT.js'), 'console.log("ready")')
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

Assert-WebAssetBundle -Root $WebRoot
Write-Host "web asset contract passed ($script:passed assertions): $WebRoot"
