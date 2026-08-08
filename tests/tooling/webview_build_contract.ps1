[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$lockPath = Join-Path $repoRoot 'tools\editor-dependencies.lock.json'
$preparePath = Join-Path $repoRoot 'cmake\PrepareWebView.cmake'
$prepareIPlug2Path = Join-Path $repoRoot 'cmake\PrepareIPlug2.cmake'
$webViewHeaderPath = Join-Path $repoRoot 'third_party\iPlug2\IPlug\Extras\WebView\IPlugWebView.h'
$cmakePath = Join-Path $repoRoot 'CMakeLists.txt'
$configPath = Join-Path $repoRoot 'plugin\config.h'
$workflowPath = Join-Path $repoRoot '.github\workflows\windows-vst3.yml'

$script:passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:passed++
}

function Assert-Matches {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    Assert-True ([regex]::IsMatch($Actual, $Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) $Message
}

Assert-True (Test-Path -LiteralPath $lockPath -PathType Leaf) 'the editor dependency lock exists'
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
Assert-True ($lock.wil.commit -ceq 'f0c6a81c0c9a4b23b6801f40554b8bec425a83b4') 'the WIL lock uses the approved immutable commit'
Assert-True ($lock.webview2.version -ceq '1.0.2903.40') 'the WebView2 lock uses the approved SDK version'
Assert-True ($lock.webview2.sha256 -ceq 'ef128016dd1e51c59178c827ed5b8aa3322c57afa8675d930f8109505542ad74') 'the WebView2 lock uses the approved NuGet SHA-256'

Assert-True (Test-Path -LiteralPath $preparePath -PathType Leaf) 'the dedicated WebView preparation module exists'
$prepare = Get-Content -LiteralPath $preparePath -Raw
Assert-Matches $prepare 'GIT_REPOSITORY\s+https://github\.com/microsoft/wil\.git' 'WIL comes from its official repository'
Assert-Matches $prepare 'GIT_TAG\s+f0c6a81c0c9a4b23b6801f40554b8bec425a83b4' 'WIL uses the approved full commit'
Assert-Matches $prepare 'https://www\.nuget\.org/api/v2/package/Microsoft\.Web\.WebView2/1\.0\.2903\.40' 'WebView2 comes from the exact official NuGet URL'
Assert-Matches $prepare 'EXPECTED_HASH\s+"?SHA256=ef128016dd1e51c59178c827ed5b8aa3322c57afa8675d930f8109505542ad74"?' 'the downloaded NuGet archive is hash verified'
Assert-Matches $prepare 'file\s*\(\s*SHA256\s+"?\$\{[^}]*PACKAGE' 'an existing NuGet archive is re-hashed before use'
Assert-Matches $prepare 'WebView2LoaderStatic\.lib' 'the static WebView2 loader is required'
Assert-True ($prepare -notmatch '(?i)(GIT_TAG\s+(main|master|latest)|/latest\b)') 'the WebView preparation contains no floating dependency reference'

$prepareIPlug2 = Get-Content -LiteralPath $prepareIPlug2Path -Raw
Assert-Matches $prepareIPlug2 'iplug2_paths[\s\S]*?Dependencies/Extras/nlohmann' 'the prepared iPlug2 composite stages the exact WebView nlohmann leaf'
Assert-True ($prepareIPlug2 -notmatch 'Dependencies/Extras\s*(?:\r?\n|\))') 'the prepared iPlug2 composite does not stage the broad Extras tree'
$webViewHeader = Get-Content -LiteralPath $webViewHeaderPath -Raw
Assert-Matches $webViewHeader 'IWebView\s*\(\s*bool opaque = true,\s*bool enableDevTools = false' 'the Release WebView delegate defaults devtools to false'

$cmake = Get-Content -LiteralPath $cmakePath -Raw
Assert-Matches $cmake 'include\s*\(cmake/PrepareWebView\.cmake\)' 'the product includes the WebView preparation module'
Assert-Matches $cmake 'doppelbanger_prepare_webview\s*\(' 'the product prepares exact WebView inputs before use'
Assert-Matches $cmake 'include\s*\("?\$\{IPLUG2_DIR\}/Scripts/cmake/WebView\.cmake"?\)' 'the product enables iPlug2 WebView after preparation'
Assert-Matches $cmake 'target_link_libraries\s*\(Doppelbanger-vst3\s+PRIVATE[\s\S]*?iPlug2::WebView' 'only the VST3 target links the WebView integration'
Assert-Matches $cmake 'target_compile_definitions\s*\(Doppelbanger-vst3\s+PRIVATE[\s\S]*?WEBVIEW_EDITOR_DELEGATE[\s\S]*?NO_IGRAPHICS[\s\S]*?IDLE_TIMER_RATE=50[\s\S]*?SAMPLE_TYPE_FLOAT' 'the VST3 target has the required WebView editor compile shape'
Assert-Matches $cmake 'target_compile_definitions\s*\(PluginLifecycleTests\s+PRIVATE[\s\S]*?NO_IGRAPHICS[\s\S]*?PLUG_HAS_UI=0[\s\S]*?SAMPLE_TYPE_FLOAT' 'the lifecycle fixture retains its NO_IGRAPHICS headless editor topology'
Assert-Matches $cmake 'target_compile_options\s*\(Doppelbanger-vst3\s+PRIVATE[\s\S]*?/W4[\s\S]*?/WX[\s\S]*?/EHsc[\s\S]*?/wd4458' 'the VST3 target preserves warnings-as-errors while narrowly suppressing the VS 2026 upstream C4458 warning'
Assert-Matches $cmake 'find_program\s*\(\s*DOPPELBANGER_NODE_EXECUTABLE\s+NAMES\s+node\.exe\s+REQUIRED\s*\)' 'the frontend build resolves only the native node.exe executable'
Assert-Matches $cmake 'find_program\s*\(\s*DOPPELBANGER_NPM_EXECUTABLE\s+NAMES\s+npm\.cmd\s+REQUIRED\s*\)' 'the frontend build resolves only the native npm.cmd command'
Assert-True ($cmake -notmatch 'find_program\s*\(\s*DOPPELBANGER_(?:NODE|NPM)_EXECUTABLE\s+NAMES\s+(?:node\.exe\s+node|npm\.cmd\s+npm)\b') 'the frontend build has no PATH-shim fallback for node or npm'
Assert-True ($cmake -notmatch 'add_custom_command\s*\(\s*TARGET\s+Doppelbanger-vst3\s+POST_BUILD') 'web resources are not packaged only when the module relinks'
Assert-Matches $cmake 'set\s*\(\s*DOPPELBANGER_VST3_WEB_STAMP\s+"?\$\{CMAKE_BINARY_DIR\}/[^"\)]+\.stamp"?\s*\)' 'the web package uses a build-tree stamp outside the bundle'
Assert-Matches $cmake 'add_custom_command\s*\(\s*OUTPUT\s+"?\$\{DOPPELBANGER_VST3_WEB_STAMP\}"?[\s\S]*?rm\s+-rf\s+"?\$\{DOPPELBANGER_VST3_WEB_DIR\}"?[\s\S]*?copy_directory\s+"?\$\{DOPPELBANGER_UI_DIST_DIR\}"?\s+"?\$\{DOPPELBANGER_VST3_WEB_DIR\}"?[\s\S]*?touch\s+"?\$\{DOPPELBANGER_VST3_WEB_STAMP\}"?[\s\S]*?DEPENDS\s+"?\$\{DOPPELBANGER_UI_INDEX\}"?' 'the stamped web package copy depends on the frontend production output and cleans only its resource directory'
$resourceCleanups = [regex]::Matches($cmake, 'rm\s+-rf\s+"?([^"\s]+)"?')
Assert-True ($resourceCleanups.Count -eq 1 -and $resourceCleanups[0].Groups[1].Value -ceq '${DOPPELBANGER_VST3_WEB_DIR}') 'the only recursive package cleanup is the build-tree web resource directory'
Assert-Matches $cmake 'add_custom_target\s*\(\s*doppelbanger_vst3_web_resources\s+DEPENDS\s+"?\$\{DOPPELBANGER_VST3_WEB_STAMP\}"?\s*\)' 'the stamped web package has an explicit build target'
Assert-Matches $cmake 'add_dependencies\s*\(\s*Doppelbanger-vst3\s+doppelbanger_rust\s+doppelbanger_vst3_web_resources\s*\)' 'building the VST3 requires refreshed stamped web resources even without a relink'
Assert-Matches $cmake 'copy_directory\s+"?\$\{DOPPELBANGER_UI_DIST_DIR\}"?\s+"?\$\{DOPPELBANGER_VST3_WEB_DIR\}"?' 'only the frontend dist tree is copied into the VST3 resource root'
Assert-Matches $cmake 'file\s*\(GLOB_RECURSE\s+DOPPELBANGER_UI_SOURCES\s+CONFIGURE_DEPENDS\s+"\$\{DOPPELBANGER_UI_DIR\}/src/\*"\s*\)' 'the frontend source glob is restricted to plugin/ui/src'
Assert-True ($cmake -notmatch 'GLOB_RECURSE[^)]*\$\{DOPPELBANGER_UI_DIR\}/(?:index\.html|package\.json|package-lock\.json|vite\.config\.ts)') 'the frontend dependency scan cannot recurse through dist or node_modules'
Assert-True ($cmake -notmatch '(?i)(BinaryData|AddCustomServer|http://|localhost|dev-server|zip)') 'the native package path contains no resource server, archive, or dev fallback'

Assert-True (Test-Path -LiteralPath $workflowPath -PathType Leaf) 'the Windows VST3 workflow exists'
$workflow = Get-Content -LiteralPath $workflowPath -Raw
$evidenceStepMatch = [regex]::Match(
    $workflow,
    '(?ms)^[ ]{6}- name:\s*Prepare sanitized CI evidence\s*\r?\n.*?(?=^[ ]{6}- name:|\z)')
Assert-True $evidenceStepMatch.Success 'the workflow retains the dedicated sanitized-evidence step'
$evidenceStep = $evidenceStepMatch.Value
Assert-True ($evidenceStep -notmatch '\$bundleFiles\.Count\s+-ne\s+1|bundle must contain only the exact x86_64-win module') 'the CI evidence gate does not retain the stale one-file-only bundle assumption'
Assert-Matches $evidenceStep '\$module\s*=\s*Join-Path\s+\$bundle\s+''Contents\\x86_64-win\\Doppelbanger\.vst3''' 'the CI evidence gate identifies the exact x64 VST3 module'
Assert-Matches $evidenceStep '\$webRoot\s*=\s*Join-Path\s+\$bundle\s+''Contents\\Resources\\web''' 'the CI evidence gate identifies the exact packaged web root'
Assert-Matches $evidenceStep 'Test-Path\s+-LiteralPath\s+\$module\s+-PathType\s+Leaf' 'the CI evidence gate requires the exact VST3 module'
Assert-Matches $evidenceStep 'Test-Path\s+-LiteralPath\s+\$webRoot\s+-PathType\s+Container' 'the CI evidence gate requires the exact packaged web root'
Assert-Matches $evidenceStep '\$webAssetContract\s*=\s*Join-Path\s+\$repo\s+''tests\\tooling\\web_asset_contract\.ps1''' 'the CI evidence gate resolves the existing closed-world WebAssetContract'
Assert-Matches $evidenceStep 'powershell\.exe\s+-NoProfile\s+-File\s+\$webAssetContract\s+-WebRoot\s+\$webRoot\s*\r?\n\s*if\s*\(\$LASTEXITCODE\s+-ne\s+0\)\s*\{\s*exit\s+\$LASTEXITCODE\s*\}' 'the CI evidence gate runs WebAssetContract against the exact web root and propagates failure'
Assert-Matches $evidenceStep '\$moduleFullPath\s*=\s*\[System\.IO\.Path\]::GetFullPath\(\$module\)' 'the CI evidence allowlist normalizes the exact module path'
Assert-Matches $evidenceStep '\$webRootFullPath\s*=\s*\[System\.IO\.Path\]::GetFullPath\(\$webRoot\)\.TrimEnd\(' 'the CI evidence allowlist normalizes and trims the exact web root'
Assert-Matches $evidenceStep '\$webRootPrefix\s*=\s*\$webRootFullPath\s*\+\s*\[System\.IO\.Path\]::DirectorySeparatorChar' 'the CI evidence allowlist adds a trailing separator to prevent sibling-prefix bypasses'
Assert-Matches $evidenceStep '\$bundleFiles\s*=\s*@\(Get-ChildItem\s+-LiteralPath\s+\$bundle\s+-Recurse\s+-File\)' 'the CI evidence allowlist enumerates every bundle file'
Assert-Matches $evidenceStep '\[string\]::Equals\(\$fileFullPath,\s*\$moduleFullPath,\s*\[StringComparison\]::OrdinalIgnoreCase\)' 'the CI evidence allowlist admits only the exact module using Windows-safe comparison'
Assert-Matches $evidenceStep '\$fileFullPath\.StartsWith\(\$webRootPrefix,\s*\[StringComparison\]::OrdinalIgnoreCase\)' 'the CI evidence allowlist admits descendants only beneath the separator-terminated web root'
Assert-Matches $evidenceStep '\$webFileCount\s*=\s*0[\s\S]*?\$webFileCount\+\+[\s\S]*?if\s*\(\$webFileCount\s+-eq\s+0\)\s*\{[\s\S]*?throw' 'the CI evidence gate explicitly rejects a bundle with no web files'
Assert-Matches $evidenceStep 'throw\s+"unexpected VST3 bundle file:' 'the CI evidence allowlist rejects every file outside the exact module and validated web root'

$config = Get-Content -LiteralPath $configPath -Raw
foreach ($requiredDefinition in @(
    '#define PLUG_HAS_UI 1',
    '#define PLUG_WIDTH 760',
    '#define PLUG_HEIGHT 500',
    '#define PLUG_FPS 30',
    '#define PLUG_HOST_RESIZE 0'
)) {
    Assert-True ($config.Contains($requiredDefinition)) "plugin config enables the reviewed editor setting '$requiredDefinition'"
}
Assert-Matches $config '#ifndef\s+PLUG_HAS_UI\s+#define\s+PLUG_HAS_UI\s+1\s+#endif' 'the product UI setting permits the headless lifecycle fixture to override only its UI flag'

Write-Host "webview build contract passed ($script:passed assertions)."
