# Windows React Editor Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Windows x64 Doppelbanger VST3 whose packaged React editor opens in Ableton, controls the existing processor through host automation, preserves saved-state and class-ID compatibility, and is installable from `Doppelbanger-Setup.exe`.

**Architecture:** Keep the validated Rust processor and iPlug2 VST3 component intact. Add a pure React/Vite surface and a separately testable bounded C++ bridge, then connect them through iPlug2's `WebViewEditorDelegate` using local WebView2 resources only. Build a conventional Inno Setup installer from the already validated bundle; WebView2 is the only end-user editor prerequisite and is installed through Microsoft's signed Evergreen bootstrapper only when missing and approved by the user.

**Tech Stack:** Rust 1.97.1 MSVC, C++17/MSVC 14.44, CMake 4.4.2, Ninja 1.13.2, iPlug2 at `5c2df9dce3f5258acfeff3846a6a9563f382212c`, WebView2 SDK `1.0.2903.40`, WIL at `f0c6a81c0c9a4b23b6801f40554b8bec425a83b4`, Node.js `24.18.1` x64, npm `11.15.0`, React `19.2.8`, Vite `8.2.1`, TypeScript `7.0.2`, Vitest `4.1.10`, Playwright `1.62.1`, Inno Setup `6.7.1`.

## Global Constraints

- Build and test through native Windows x64 processes. WSL may orchestrate files but may not appear in the ancestry of Rust, MSVC, CMake, Ninja, Node, npm, validator, or installer-compiler processes.
- Use native Git at `C:\Program Files\Git\cmd\git.exe`; never use WSL Git.
- Run RTK before every repository shell command.
- Preserve `PLUG_MFR_ID 'WHyd'`, `PLUG_UNIQUE_ID 'DBng'`, processor/controller UIDs, parameter IDs `0..3`, VST3 host-bypass ID, state encoding, and the current class ID `F2AEE70D00DE4F4E5748796444426E67`.
- Public manufacturer/distributor text is exactly `Goblin City Records`.
- Windows 10/11 x64 VST3 is the only target. Do not add a macOS gate or promise.
- React, Node, npm, CMake, Rust, PowerShell, WSL, Inno Setup, and developer dependencies are absent from the installed product.
- The editor loads only bundled resources. No remote script, font, image, analytics, WebSocket, development server, arbitrary navigation, source map, or machine-specific path may enter the Release bundle.
- WebView/JSON/UI work stays off the audio callback. Existing audio-thread safety and processor tests remain binding.
- Do not add Postgres, PostgREST, Docker, capture, reference analysis, reports, cloud services, accounts, licensing, or telemetry in this plan.
- Do not modify, launch, remove, scan, or configure Ableton from automated implementation tasks. Manual smoke uses the user's disposable Set and never deletes Ableton content.
- Do not push without explicit user authorization.
- Visual implementation must match `docs/superpowers/specs/assets/2026-08-07-windows-react-editor-shell-concept.png` at a 760 by 500 viewport.

---

### Task 1: Build the final React surface and browser-side bridge

**Files:**

- Modify: `.gitignore`
- Create: `.node-version`
- Create: `tools/editor-dependencies.lock.json`
- Create: `plugin/contracts/editor_bridge_v1.schema.json`
- Create: `plugin/contracts/fixtures/editor_bridge_v1_cases.json`
- Create: `plugin/ui/package.json`
- Create: `plugin/ui/package-lock.json`
- Create: `plugin/ui/tsconfig.json`
- Create: `plugin/ui/vite.config.ts`
- Create: `plugin/ui/vitest.setup.ts`
- Create: `plugin/ui/playwright.config.ts`
- Create: `plugin/ui/index.html`
- Create: `plugin/ui/src/main.tsx`
- Create: `plugin/ui/src/App.tsx`
- Create: `plugin/ui/src/editor.css`
- Create: `plugin/ui/src/bridge/EditorBridge.ts`
- Create: `plugin/ui/src/bridge/editor_bridge_v1.generated.ts`
- Create: `plugin/ui/src/bridge/EditorBridge.test.ts`
- Create: `plugin/ui/src/components/DbKnob.tsx`
- Create: `plugin/ui/src/components/DbKnob.test.tsx`
- Create: `plugin/ui/src/components/ResponseCurve.tsx`
- Create: `plugin/ui/src/App.test.tsx`
- Create: `plugin/ui/e2e/editor.spec.ts`
- Modify: `scripts/dev.ps1`
- Modify: `tests/tooling/dev_entrypoint_contract.ps1`

**Interfaces:**

- Consumes: the approved 760 by 500 visual concept and existing parameter IDs `0=low`, `1=mid`, `2=high`, `3=output`.
- Produces: `EditorBridge.subscribe(listener)`, `EditorBridge.ready()`, `EditorBridge.beginParameter(id)`, `EditorBridge.setParameter(id, normalizedValue)`, `EditorBridge.endParameter(id)`, `EditorBridge.beginBypass()`, `EditorBridge.setBypass(value)`, and `EditorBridge.endBypass()`.
- Produces: `window.__doppelbangerReceive(message)` for native-to-React envelopes and consumes iPlug2's injected `window.IPlugSendMsg(message)` transport.
- Produces: a deterministic `plugin/ui/dist` tree with relative URLs and no source maps.

- [ ] **Step 1: Provision exact native Node without changing the product runtime.** Install the official `node-v24.18.1-win-x64.zip` beneath `C:\Users\William\AppData\Local\Programs\doppelbanger-devtools\node-v24.18.1-win-x64`, verify SHA-256 `ec56b84a7551893ab2324ebdfdc4ab974a63b4781162600b68a1293cc3e53765`, and add that directory only to the ignored native task runner's PATH. Confirm native `node.exe --version` prints `v24.18.1` and native `npm.cmd --version` prints `11.15.0`.

- [ ] **Step 2: Extend the dispatcher contract red.** Add `node` and `npm` to the injected tool fixture, require the doctor to resolve both native executables, require Node `v24.18.1` and npm `11.15.0`, and add `ui-test` to the accepted task set. Assert `ui-test` invokes only checked `npm.cmd` with this exact vector:

```powershell
@('run', 'check')
```

Run `tests/tooling/dev_entrypoint_contract.ps1`. Expected: FAIL because `scripts/dev.ps1` neither verifies the editor toolchain nor implements `ui-test`.

- [ ] **Step 3: Implement the minimal native editor-tool routing.** Resolve `node` and `npm` in `Assert-DbDevNativeEnvironment`, execute their version commands through `Invoke-DbDevTool`, enforce the exact versions from `tools/editor-dependencies.lock.json`, and route `ui-test` to `npm.cmd run check` with working directory `plugin/ui`. Keep all download/install logic outside `scripts/dev.ps1`.

- [ ] **Step 4: Commit the dependency contract and package graph.** Record these exact values in `tools/editor-dependencies.lock.json` and `plugin/ui/package.json`:

```json
{
  "node": "24.18.1",
  "npm": "11.15.0",
  "react": "19.2.8",
  "react-dom": "19.2.8",
  "vite": "8.2.1",
  "typescript": "7.0.2",
  "vitest": "4.1.10",
  "jsdom": "30.0.1",
  "@vitejs/plugin-react": "6.0.5",
  "@testing-library/react": "16.3.2",
  "@testing-library/jest-dom": "7.0.0",
  "@testing-library/user-event": "14.6.3",
  "@types/react": "19.2.18",
  "@types/react-dom": "19.2.4",
  "@types/node": "26.2.0",
  "json-schema-to-typescript": "15.0.4",
  "@playwright/test": "1.62.1"
}
```

Use exact versions rather than caret/tilde ranges, set `packageManager` to `npm@11.15.0`, generate `package-lock.json` with the native npm, and expose these scripts: `generate:bridge`, `test`, `build`, `test:visual`, and `check` (`generate:bridge`, clean generated-type diff, Vitest, production build, and Playwright in that order). Set `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`; Playwright uses installed Microsoft Edge through `channel: 'msedge'`.

- [ ] **Step 5: Define the closed bridge schema and cross-language cases.** Set `additionalProperties: false` at the envelope and payload levels. Accept only bridge version `1`, request IDs matching `^[A-Za-z0-9._-]{1,64}$`, parameter IDs `0..3`, normalized values `0..1`, and the message families from the design. Structure the fixture as `parse_cases` (one JSON string plus expected parse result/error per case) and `session_cases` (an ordered command array plus expected host calls/error). Include every valid family plus cases for overlong input, malformed JSON, unsupported version, unknown type, unknown key, missing key, wrong scalar type, parameter `-1`, parameter `4`, value below `0`, value above `1`, string `"NaN"`, and out-of-order gesture sequences.

- [ ] **Step 6: Write frontend tests before the bridge client.** Tests must prove: `ui.ready` is sent after subscription; all seven command families use version `1`; normalized values are finite and clamped before transport; missing `IPlugSendMsg` produces a visible `DBUI_TRANSPORT_UNAVAILABLE` state; unknown native envelopes become `DBUI_BRIDGE_MESSAGE`; subscription cleanup removes the callback; and editor recreation requests a fresh snapshot. Run native `npm.cmd test`. Expected: FAIL because the bridge client is absent.

- [ ] **Step 7: Implement the bridge client and generated types.** Generate TypeScript from the schema, validate native messages with closed hand-written type guards at runtime, install exactly one `window.__doppelbangerReceive` function, and keep authoritative values in the latest native snapshot. Do not use `postMessage`, `fetch`, storage APIs, timers that poll native state, or a second transport.

- [ ] **Step 8: Write component tests before the visual surface.** Cover exact visible copy, four control labels/ranges, signed two-decimal dB formatting, snapshot hydration, host parameter updates, bypass updates, compatibility errors, pointer begin/set/end order, keyboard begin/set/end order, blur/pointer-cancel gesture termination, ARIA slider metadata, and response-curve point changes when low/mid/high values change. Run Vitest and confirm the new tests fail for missing components.

- [ ] **Step 9: Implement the approved screen.** Use these locked visual tokens:

```css
:root {
  --db-bg: #0b0f10;
  --db-surface: #101415;
  --db-text: #e7e1d5;
  --db-muted: #8b8c84;
  --db-line: #4a4e4b;
  --db-accent: #c7ff3d;
  --db-font-display: "Bahnschrift Condensed", "Arial Narrow", "Segoe UI", sans-serif;
  --db-font-control: "Bahnschrift", "Segoe UI", sans-serif;
}
```

Build one edge-to-edge 760 by 500 surface: brand and distributor header, bypass switch, restrained 20/100/1K/10K/20K response curve, four 136-pixel rotary controls, exact signed value readouts, and four-part footer. No additional visible copy or controls. Use a native range input for keyboard/accessibility semantics and an inline SVG for the rotary face/curve; do not ship raster UI elements.

- [ ] **Step 10: Lock production resource behavior.** Configure Vite with `base: './'`, `sourcemap: false`, `assetsInlineLimit: 0`, and `outDir: 'dist'`. Put this policy in `index.html`:

```html
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'none'; object-src 'none'; frame-src 'none'; media-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'">
```

- [ ] **Step 11: Run the full frontend gate and capture fidelity evidence.** Run native `npm.cmd run check`. The Playwright test starts Vite on loopback, blocks non-loopback requests, opens 760 by 500 and 1520 by 1000 Edge viewports, exercises all controls, and writes the 760 by 500 screenshot to `var/validation/react-editor/editor-760x500.png`. Compare that screenshot and the approved concept with `view_image`; record at least copy, composition, type hierarchy, palette, control geometry, response curve, separators, and footer in `var/validation/react-editor/fidelity.md`. Fix every material mismatch before review.

- [ ] **Step 12: Commit Task 1.** Stage only the listed Task 1 files and commit `feat: add React editor surface` after the dispatcher contract, `npm run check`, and `git diff --check` pass.

---

### Task 2: Add the bounded native bridge and gesture session

**Files:**

- Create: `plugin/EditorBridge.h`
- Create: `plugin/EditorBridge.cpp`
- Create: `tests/plugin/EditorBridgeTests.cpp`
- Modify: `CMakeLists.txt`

**Interfaces:**

- Consumes: `plugin/contracts/editor_bridge_v1.schema.json` and `editor_bridge_v1_cases.json`.
- Produces: `ParseEditorCommand(std::string_view) noexcept`, stable `DBUI_*` error codes, and `EditorSession::Dispatch/Close`.
- Produces: an `EditorHost` interface implemented by the plug-in in Task 4.

- [ ] **Step 1: Define the exact native types.** Use this public shape:

```cpp
namespace doppelbanger::editor {
inline constexpr std::size_t kMaxMessageBytes = 4096;
enum class CommandType {
  kUiReady,
  kParameterBeginEdit,
  kParameterSet,
  kParameterEndEdit,
  kBypassBeginEdit,
  kBypassSet,
  kBypassEndEdit,
};
struct Command {
  CommandType type = CommandType::kUiReady;
  int parameterId = -1;
  double normalizedValue = 0.0;
  bool bypassed = false;
};
struct ParseResult {
  bool ok = false;
  Command command{};
  const char* errorCode = "DBUI_BRIDGE_MALFORMED";
};
ParseResult ParseEditorCommand(std::string_view json) noexcept;
}
```

`EditorHost` has only `BeginParameter`, `SetParameter`, `EndParameter`, `BeginBypass`, `SetBypass`, `EndBypass`, and `SendSnapshot`. `EditorSession` owns four parameter-gesture flags and one bypass flag; it rejects duplicate begin, set/end without begin, and closes every open gesture exactly once.

- [ ] **Step 2: Write parser/session tests red.** Enumerate `parse_cases` for parser acceptance/error and `session_cases` for ordered host effects. Add direct tests for byte lengths `4096` and `4097`, embedded NUL, `NaN`/infinity supplied through programmatic commands, duplicate keys, all gesture state transitions, and `Close()` idempotence. Assert rejected commands invoke zero fake-host methods. Run the focused `EditorBridgeTests` target. Expected: build/test failure because the implementation is absent.

- [ ] **Step 3: Implement the parser minimally.** Check length and embedded NUL before parsing. Parse with the already pinned nlohmann JSON headers on the controller thread, catch every exception, require exact object/key sets, check finite numbers with `std::isfinite`, and map failures to `DBUI_BRIDGE_TOO_LARGE`, `DBUI_BRIDGE_MALFORMED`, `DBUI_BRIDGE_VERSION`, `DBUI_BRIDGE_TYPE`, `DBUI_BRIDGE_PAYLOAD`, or `DBUI_GESTURE_STATE`. Do not log raw input.

- [ ] **Step 4: Implement the session state machine.** Dispatch only a successfully parsed command, mutate gesture state only after the host action succeeds, and unwind every open host gesture in `Close()`. `ui.ready` is legal at any time and invokes only `SendSnapshot()`.

- [ ] **Step 5: Add the focused CMake target.** Compile C++17 with `/W4 /WX /EHsc`, include the prepared nlohmann directory, define the absolute fixture path only for the test target, and register `EditorBridgeTests` with CTest. The product target receives no fixture path.

- [ ] **Step 6: Run and commit.** Run `EditorBridgeTests`, all existing CTest targets, and `git diff --check`; commit `feat: add bounded editor bridge`.

---

### Task 3: Build WebView2 and package local React resources

**Files:**

- Create: `cmake/PrepareWebView.cmake`
- Create: `tests/tooling/webview_build_contract.ps1`
- Create: `tests/tooling/web_asset_contract.ps1`
- Modify: `CMakeLists.txt`
- Modify: `plugin/config.h`
- Modify: `scripts/dev.ps1`
- Modify: `tests/tooling/dev_entrypoint_contract.ps1`
- Modify: `tools/editor-dependencies.lock.json`

**Interfaces:**

- Consumes: Task 1's production frontend and Task 2's bridge library.
- Produces: `iPlug2::WebView` linked with static `WebView2LoaderStatic.lib` and a VST3 resource root at `Contents/Resources/web`.
- Produces: `scripts/dev.ps1 -Task build` that builds frontend assets before the module and `-Task validate` that checks packaged assets before Steinberg Validator.

- [ ] **Step 1: Add build-contract tests red.** Require the editor lock to contain WIL commit `f0c6a81c0c9a4b23b6801f40554b8bec425a83b4`, WebView2 version `1.0.2903.40`, and NuGet SHA-256 `ef128016dd1e51c59178c827ed5b8aa3322c57afa8675d930f8109505542ad74`. Require CMake to use the full WIL commit and WebView2 `EXPECTED_HASH`, link the static loader, avoid floating tags/latest URLs, copy only `plugin/ui/dist`, and set Release devtools false. Run the contract and confirm red.

- [ ] **Step 2: Prepare exact build-only dependencies.** `PrepareWebView.cmake` declares WIL with the full commit and pre-populates `${CMAKE_BINARY_DIR}/_deps/webview2` from the exact NuGet URL:

```text
https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.2903.40
```

Retain the downloaded package in the build tree, verify its hash on every configure, extract only after verification, and fail closed on a mismatched existing package. Include upstream `Scripts/cmake/WebView.cmake` only after the exact inputs are ready.

- [ ] **Step 3: Enable the product editor without changing test topology.** Set:

```cpp
#define PLUG_HAS_UI 1
#define PLUG_WIDTH 760
#define PLUG_HEIGHT 500
#define PLUG_FPS 30
#define PLUG_HOST_RESIZE 0
```

Keep `PluginLifecycleTests` compiled with `NO_IGRAPHICS`. Compile only `Doppelbanger-vst3` with `WEBVIEW_EDITOR_DELEGATE`, `NO_IGRAPHICS`, `IDLE_TIMER_RATE=50`, and `SAMPLE_TYPE_FLOAT`; link it to `iPlug2::WebView` and `doppelbanger_rust`.

- [ ] **Step 4: Add the frontend build target.** Locate exact native `node.exe` and `npm.cmd`, run `npm ci --no-audit --no-fund` with `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`, run `npm run build`, and make the VST3 depend on the resulting `dist/index.html`. Before copying, remove only the build-tree `Contents/Resources/web` directory; copy the fresh `dist` tree there. Never copy `node_modules`, source files, tests, the concept PNG, or source maps.

- [ ] **Step 5: Implement the packaged-asset gate.** Require one `index.html`, one or more content-hashed `.js`/`.css` files beneath `web/assets`, relative references, the exact CSP, and no unexpected extension. Reject `.map`, source/test file names, `http:`, `https:` other than the WebView virtual origin at runtime, `localhost`, `127.0.0.1`, `ws:`, `wss:`, drive-letter paths, UNC paths, `node_modules`, credentials, and development markers. Assert every referenced asset exists and every packaged asset is referenced.

- [ ] **Step 6: Run native green gates.** Run the WebView build contract, dispatcher contract, native configure/build, full CTest, asset gate, PE/import checks, and Steinberg Validator. Confirm the VST3 bundle contains one x64 module plus only the reviewed web resource files; no WebView2 loader DLL is shipped because the loader is static.

- [ ] **Step 7: Commit Task 3.** Commit `build: package React editor in VST3` with only the listed files.

---

### Task 4: Wire editor lifecycle, host automation, and safe fallback

**Files:**

- Modify: `plugin/Doppelbanger.h`
- Modify: `plugin/Doppelbanger.cpp`
- Modify: `tests/plugin/PluginLifecycleTests.cpp`
- Create: `tests/plugin/EditorSnapshotTests.cpp`
- Modify: `CMakeLists.txt`

**Interfaces:**

- Consumes: `EditorHost`, `EditorSession`, packaged `web/index.html`, and iPlug2 WebView transport.
- Produces: strict local navigation, complete snapshots, differential parameter/bypass messages, and closed editor gestures.

- [ ] **Step 1: Write lifecycle/snapshot tests red.** Using a fake `EditorHost` and pure snapshot formatter, prove exact parameter IDs/ranges, signed dB formatting, bypass state, bridge/build/runtime fields, processor-ready atomics, host automation updates, snapshot recreation, compatibility errors, open-gesture cleanup, and no change to `StateCodec` bytes. Add a test that the bundle resource resolver rejects a path outside `Contents/Resources/web/index.html`.

- [ ] **Step 2: Add editor-only overrides under `WEBVIEW_EDITOR_DELEGATE`.** Declare and implement `OnMessageFromWebView`, `OnWebContentLoaded`, `OnCanNavigateToURL`, `OnCanDownloadMIMEType`, `OnIdle`, and `CloseWindow`. Keep all editor members and includes behind the same compile definition so headless lifecycle tests remain independent of WebView2.

- [ ] **Step 3: Load only the installed resource.** In the constructor, disable devtools unconditionally for Release, resolve the VST3 module's `Contents/Resources` path with `BundleResourcePath(..., gHINSTANCE)`, append `web\\index.html`, and call `LoadFile` only after the WebView is ready. Allow navigation only to `about:blank` and `https://iplug.example/`; reject downloads and new product links.

- [ ] **Step 4: Adapt bridge actions to normal host gestures.** Parameter actions call `BeginInformHostOfParamChangeFromUI`, `SendParameterValueFromUI`, and `EndInformHostOfParamChangeFromUI` for IDs `0..3`. Bypass actions use VST3's existing `kBypassParam`, `setParamNormalized`, and begin/perform/end host edit methods; they do not add a fifth user parameter or write audio-owned fields directly.

- [ ] **Step 5: Publish authoritative state safely.** Add a lock-free atomic processor-ready flag updated wherever the processor is created/destroyed. On the editor/controller idle tick, compare atomically readable parameter values and the existing published state generation against the last sent snapshot. Send bounded JSON through:

```javascript
window.__doppelbangerReceive(<validated native envelope>)
```

Send a complete snapshot on `ui.ready` and editor recreation. Send only ASCII-controlled strings and cap every serialized outbound envelope at 4096 bytes.

- [ ] **Step 6: Close safely.** `CloseWindow()` first calls `EditorSession::Close()` to end every open host gesture, marks the editor unavailable, closes WebView2, calls the normal UI-close lifecycle, and leaves the processor/state mailboxes untouched. A missing WebView2 controller or asset causes editor-only failure; VST3 construction and audio remain successful.

- [ ] **Step 7: Run integration gates.** Run all frontend tests, native CTest, build/asset checks, Steinberg Validator, class-ID comparison against the old installed binary, and open/close the built editor in a minimal WebView2 host smoke. Confirm vendor `Goblin City Records`, CID `F2AEE70D00DE4F4E5748796444426E67`, and no audio-output change when the editor opens/closes.

- [ ] **Step 8: Commit Task 4.** Commit `feat: host React editor in Doppelbanger` after review-clean evidence.

---

### Task 5: Build the conventional Windows installer

**Files:**

- Create: `installer/windows/Doppelbanger.iss`
- Create: `scripts/package.ps1`
- Create: `tests/installer/installer_contract.ps1`
- Modify: `.gitignore`
- Modify: `scripts/dev.ps1`
- Modify: `tests/tooling/dev_entrypoint_contract.ps1`
- Modify: `README.md`
- Modify: `docs/WINDOWS_WORKSTATION.md`
- Modify: `docs/VALIDATION.md`

**Interfaces:**

- Consumes: the exact validated Release VST3 bundle and Microsoft-signed Evergreen WebView2 bootstrapper.
- Produces: `dist/Doppelbanger-Setup.exe` and `dist/Doppelbanger-Setup.release.json`.

- [ ] **Step 1: Provision exact native Inno Setup.** Install Inno Setup `6.7.1` through the official `JRSoftware.InnoSetup` winget package and require `ISCC.exe` to report `6.7.1`. Keep the compiler out of product artifacts.

- [ ] **Step 2: Write installer contract red.** Require exact product name/version/publisher, stable AppId `{4C81D2D5-33C4-4E77-9C1A-4D1F5FD9B1A7}`, x64-only elevated install, fixed `{commoncf64}\\VST3\\Doppelbanger.vst3` destination, uninstall metadata outside the VST3 directory, recursive inclusion of only the validated bundle, WebView2 detection, consent before prerequisite installation, and zero Ableton/WSL/Docker/game operations. Reject absolute developer paths, wildcard sources outside the supplied bundle root, shell scripts, source files, credentials, and uninstall patterns broader than Doppelbanger-owned paths.

- [ ] **Step 3: Implement the Inno script.** Use preprocessor parameters `BundleRoot`, `BootstrapperPath`, and `OutputDir`; never hardcode a workstation path. Detect `pv` greater than `0.0.0.0` at Microsoft's documented WebView2 client key `{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` in both 64-bit machine and current-user locations. If missing, ask once whether to install the required Microsoft runtime; run the packaged bootstrapper with `/silent /install` only after consent. Declining installs the audio plug-in and displays a clear editor-repair warning.

- [ ] **Step 4: Implement the release packager.** `scripts/package.ps1` accepts exact absolute bundle/output paths, runs native build/CTest/asset/validator gates, downloads the Evergreen bootstrapper only from Microsoft's official WebView2 link, verifies a valid Authenticode signature whose signer is Microsoft Corporation, records its SHA-256, and invokes exact `ISCC.exe`. It refuses dirty/unexpected bundle contents and never deploys or launches Ableton.

- [ ] **Step 5: Emit machine-readable provenance.** `Doppelbanger-Setup.release.json` records commit, branch, UTC timestamp, VST3 module/resource hashes, VST3 CID/vendor/version, WebView2 bootstrapper hash/signer, Inno version, setup hash/size, and unsigned-signing status. It contains no username, absolute path, hostname, audio, or credential.

- [ ] **Step 6: Run installer tests.** Compile twice from the same validated inputs and compare manifests/content inventories; allow the PE wrapper's timestamp/signature region to differ only if Inno cannot produce byte-identical unsigned output, and document that exact limitation. Install manually with UAC, verify only the Doppelbanger bundle and uninstall metadata were created, run validator against the installed bundle, uninstall, and verify only Doppelbanger-owned paths were removed. Never delete Ableton content.

- [ ] **Step 7: Commit Task 5.** Commit `build: add Windows VST3 installer` with the installer source, packager, contracts, and concise public docs; keep downloaded bootstrapper and built `dist` artifacts ignored.

---

### Task 6: Complete Ableton and demo readiness evidence

**Files:**

- Modify: `README.md`
- Modify: `docs/VALIDATION.md`
- Evidence only (ignored): `var/validation/react-editor/ableton-smoke.md`
- Evidence only (ignored): `var/validation/react-editor/release-manifest.json`

**Interfaces:**

- Consumes: review-clean `Doppelbanger-Setup.exe` and installed system VST3.
- Produces: final Windows editor/automation/save-reopen evidence and a README that promises only verified behavior.

- [ ] **Step 1: Install the exact reviewed setup.** Close Ableton, run the setup manually with UAC, and verify the installed module and every web resource hash against `Doppelbanger-Setup.release.json`. Do not alter the user's existing per-user copy automatically; report duplicate locations and resolve only with explicit user direction.

- [ ] **Step 2: Run the Ableton editor smoke.** In a disposable Set: rescan, insert Doppelbanger, open/close/reopen the editor ten times, move all four knobs, automate all four values, toggle bypass from both surfaces, confirm audio with editor open/closed, save, close, reopen, and verify values/sound. Exercise 44.1/48/96 kHz and two practical buffer sizes.

- [ ] **Step 3: Record AV demo readiness.** Confirm the user's screen recorder captures the Doppelbanger editor, Ableton, and synchronized system audio. Record a short before/after automation pass without exposing development shells, private paths, or test fixtures.

- [ ] **Step 4: Run the complete automated release gate.** From native Windows run formatter, Rust tests, UI check, configure, build, CTest, asset gate, Steinberg Validator, installer contract, package, installed-bundle verification, and `git diff --check`. Preserve command, exit code, stdout/stderr, hashes, and timestamps under the ignored validation directory.

- [ ] **Step 5: Update public truth and commit.** README names Windows x64 VST3 only, Goblin City Records, one installer, WebView2's handled prerequisite, exact install path, Ableton usage, current limitations, and demo recording instructions. Commit `docs: document Windows editor release` only after every stated behavior has evidence.

- [ ] **Step 6: Request the final whole-branch review.** Review from `bab87a3` through HEAD for architecture, realtime safety, class-ID/state compatibility, bridge bounds, WebView/resource security, visual fidelity, installer ownership, documentation truth, and test coverage. Fix all Critical/Important findings through the bounded SDD loop, run one scoped re-review, then use the finishing-development-branch workflow. Do not push until the user explicitly authorizes it.
