cmake_minimum_required(VERSION 3.19)

project(Doppelbanger LANGUAGES C CXX)

if(NOT MSVC)
  message(FATAL_ERROR "Doppelbanger native builds require MSVC")
endif()

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "Doppelbanger native builds require x64")
endif()

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded" CACHE STRING
  "MSVC runtime library" FORCE)
option(DOPPELBANGER_DEPLOY_PLUGIN "Deploy a built plugin to a system location" OFF)
if(DOPPELBANGER_DEPLOY_PLUGIN)
  message(FATAL_ERROR "Plugin deployment is not available in the native foundation")
endif()

include(cmake/PrepareIPlug2.cmake)
include(cmake/PrepareWebView.cmake)
include(cmake/BuildRust.cmake)

doppelbanger_prepare_iplug2(DOPPELBANGER_IPLUG2_DIR)
doppelbanger_add_rust_target()

set(IPLUG2_DIR "${DOPPELBANGER_IPLUG2_DIR}")
set(IPLUG_DEPLOY_PLUGINS OFF CACHE BOOL
  "Never copy Doppelbanger plugins outside the build tree" FORCE)
include("${IPLUG2_DIR}/iPlug2.cmake")

doppelbanger_prepare_webview()
include("${IPLUG2_DIR}/Scripts/cmake/WebView.cmake")
include("${IPLUG2_DIR}/Scripts/cmake/VST3.cmake")

include(CTest)

add_executable(StateCodecTests
  tests/plugin/StateCodecTests.cpp
  plugin/StateCodec.cpp)
target_include_directories(StateCodecTests PRIVATE
  "${CMAKE_SOURCE_DIR}/include"
  "${CMAKE_SOURCE_DIR}/plugin")
target_compile_features(StateCodecTests PRIVATE cxx_std_17)
target_compile_options(StateCodecTests PRIVATE /W4 /WX /EHsc)
add_test(NAME StateCodecTests COMMAND StateCodecTests)

add_executable(EditorBridgeTests
  tests/plugin/EditorBridgeTests.cpp
  plugin/EditorBridge.cpp)
target_include_directories(EditorBridgeTests PRIVATE
  "${CMAKE_SOURCE_DIR}/plugin"
  "${CMAKE_SOURCE_DIR}/third_party/iPlug2/Dependencies/Extras")
target_compile_definitions(EditorBridgeTests PRIVATE
  EDITOR_BRIDGE_FIXTURE_PATH="${CMAKE_SOURCE_DIR}/plugin/contracts/fixtures/editor_bridge_v1_cases.json")
target_compile_features(EditorBridgeTests PRIVATE cxx_std_17)
target_compile_options(EditorBridgeTests PRIVATE /W4 /WX /EHsc)
add_test(NAME EditorBridgeTests COMMAND EditorBridgeTests)

add_executable(EditorSnapshotTests
  tests/plugin/EditorSnapshotTests.cpp
  plugin/Doppelbanger.cpp
  plugin/EditorBridge.cpp
  plugin/StateCodec.cpp
  "${IPLUG2_DIR}/Dependencies/IPlug/VST3_SDK/public.sdk/source/common/memorystream.cpp"
  "${IPLUG2_DIR}/Dependencies/IPlug/VST3_SDK/public.sdk/source/vst/hosting/parameterchanges.cpp")
target_include_directories(EditorSnapshotTests PRIVATE
  "${CMAKE_SOURCE_DIR}/include"
  "${CMAKE_SOURCE_DIR}/plugin"
  "${CMAKE_SOURCE_DIR}/third_party/iPlug2/Dependencies/Extras")
target_compile_definitions(EditorSnapshotTests PRIVATE
  NO_IGRAPHICS
  PLUG_HAS_UI=0
  SAMPLE_TYPE_FLOAT)
target_compile_features(EditorSnapshotTests PRIVATE cxx_std_17)
target_compile_options(EditorSnapshotTests PRIVATE
  /W4 /WX /EHsc /wd4100 /wd4456 /wd4701)
target_link_libraries(EditorSnapshotTests PRIVATE
  iPlug2::VST3
  doppelbanger_rust)
add_dependencies(EditorSnapshotTests doppelbanger_rust)
add_test(NAME EditorSnapshotTests COMMAND EditorSnapshotTests)

add_executable(PluginLifecycleTests
  tests/plugin/PluginLifecycleTests.cpp
  plugin/Doppelbanger.cpp
  plugin/StateCodec.cpp
  "${IPLUG2_DIR}/Dependencies/IPlug/VST3_SDK/public.sdk/source/common/memorystream.cpp"
  "${IPLUG2_DIR}/Dependencies/IPlug/VST3_SDK/public.sdk/source/vst/hosting/parameterchanges.cpp")
target_include_directories(PluginLifecycleTests PRIVATE
  "${CMAKE_SOURCE_DIR}/include"
  "${CMAKE_SOURCE_DIR}/plugin"
  "${CMAKE_SOURCE_DIR}/third_party/iPlug2/Dependencies/Extras")
target_compile_definitions(PluginLifecycleTests PRIVATE
  NO_IGRAPHICS
  PLUG_HAS_UI=0
  SAMPLE_TYPE_FLOAT)
target_compile_features(PluginLifecycleTests PRIVATE cxx_std_17)
target_compile_options(PluginLifecycleTests PRIVATE
  /W4 /EHsc /wd4100 /wd4456 /wd4701)
target_link_libraries(PluginLifecycleTests PRIVATE
  iPlug2::VST3
  doppelbanger_rust)
add_dependencies(PluginLifecycleTests doppelbanger_rust)
add_test(NAME PluginLifecycleTests COMMAND PluginLifecycleTests)

set(DOPPELBANGER_VST3_BUNDLE
  "${CMAKE_BINARY_DIR}/artefacts/Release/VST3/Doppelbanger.vst3")
set(DOPPELBANGER_VST3_BINARY_DIR
  "${DOPPELBANGER_VST3_BUNDLE}/Contents/x86_64-win")
set(DOPPELBANGER_VST3_WEB_DIR
  "${DOPPELBANGER_VST3_BUNDLE}/Contents/Resources/web")
set(DOPPELBANGER_UI_DIR "${CMAKE_SOURCE_DIR}/plugin/ui")
set(DOPPELBANGER_UI_DIST_DIR "${DOPPELBANGER_UI_DIR}/dist")
set(DOPPELBANGER_UI_INDEX "${DOPPELBANGER_UI_DIST_DIR}/index.html")
find_program(DOPPELBANGER_NODE_EXECUTABLE NAMES node.exe REQUIRED)
find_program(DOPPELBANGER_NPM_EXECUTABLE NAMES npm.cmd REQUIRED)
file(GLOB_RECURSE DOPPELBANGER_UI_SOURCES CONFIGURE_DEPENDS
  "${DOPPELBANGER_UI_DIR}/src/*")
set(DOPPELBANGER_UI_INPUTS
  ${DOPPELBANGER_UI_SOURCES}
  "${DOPPELBANGER_UI_DIR}/index.html"
  "${DOPPELBANGER_UI_DIR}/package.json"
  "${DOPPELBANGER_UI_DIR}/package-lock.json"
  "${DOPPELBANGER_UI_DIR}/vite.config.ts")
add_custom_command(
  OUTPUT "${DOPPELBANGER_UI_INDEX}"
  COMMAND "${CMAKE_COMMAND}" -E env "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1"
    "${DOPPELBANGER_NPM_EXECUTABLE}" ci --no-audit --no-fund
  COMMAND "${DOPPELBANGER_NPM_EXECUTABLE}" run build
  WORKING_DIRECTORY "${DOPPELBANGER_UI_DIR}"
  DEPENDS ${DOPPELBANGER_UI_INPUTS}
  VERBATIM)
add_custom_target(doppelbanger_ui_dist DEPENDS "${DOPPELBANGER_UI_INDEX}")
set(DOPPELBANGER_VST3_WEB_STAMP
  "${CMAKE_BINARY_DIR}/doppelbanger-vst3-web-resources.stamp")
add_custom_command(
  OUTPUT "${DOPPELBANGER_VST3_WEB_STAMP}"
  COMMAND "${CMAKE_COMMAND}" -E rm -rf "${DOPPELBANGER_VST3_WEB_DIR}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${DOPPELBANGER_VST3_WEB_DIR}"
  COMMAND "${CMAKE_COMMAND}" -E copy_directory
    "${DOPPELBANGER_UI_DIST_DIR}" "${DOPPELBANGER_VST3_WEB_DIR}"
  COMMAND "${CMAKE_COMMAND}" -E touch "${DOPPELBANGER_VST3_WEB_STAMP}"
  DEPENDS "${DOPPELBANGER_UI_INDEX}"
  VERBATIM)
add_custom_target(doppelbanger_vst3_web_resources
  DEPENDS "${DOPPELBANGER_VST3_WEB_STAMP}")
add_dependencies(doppelbanger_vst3_web_resources doppelbanger_ui_dist)

add_library(Doppelbanger-vst3 MODULE
  plugin/Doppelbanger.cpp
  plugin/Doppelbanger.h
  plugin/config.h
  plugin/EditorBridge.cpp
  plugin/EditorBridge.h
  plugin/StateCodec.cpp
  plugin/StateCodec.h)
target_include_directories(Doppelbanger-vst3 PRIVATE
  "${CMAKE_SOURCE_DIR}/include"
  "${CMAKE_SOURCE_DIR}/plugin"
  "${CMAKE_SOURCE_DIR}/third_party/iPlug2/Dependencies/Extras")
target_compile_definitions(Doppelbanger-vst3 PRIVATE
  WEBVIEW_EDITOR_DELEGATE
  NO_IGRAPHICS
  IDLE_TIMER_RATE=50
  SAMPLE_TYPE_FLOAT)
target_compile_features(Doppelbanger-vst3 PRIVATE cxx_std_17)
target_compile_options(Doppelbanger-vst3 PRIVATE
  /W4 /WX /EHsc /wd4100 /wd4456 /wd4458 /wd4701)
target_link_libraries(Doppelbanger-vst3 PRIVATE
  iPlug2::VST3
  iPlug2::WebView
  doppelbanger_rust)
add_dependencies(Doppelbanger-vst3 doppelbanger_rust doppelbanger_vst3_web_resources)
set_target_properties(Doppelbanger-vst3 PROPERTIES
  OUTPUT_NAME "Doppelbanger"
  PREFIX ""
  SUFFIX ".vst3"
  LIBRARY_OUTPUT_DIRECTORY "${DOPPELBANGER_VST3_BINARY_DIR}"
  RUNTIME_OUTPUT_DIRECTORY "${DOPPELBANGER_VST3_BINARY_DIR}")
find_program(DOPPELBANGER_POWERSHELL_EXECUTABLE NAMES powershell.exe powershell REQUIRED)
add_test(NAME WebViewBuildContract
  COMMAND "${DOPPELBANGER_POWERSHELL_EXECUTABLE}" -NoProfile -File
    "${CMAKE_SOURCE_DIR}/tests/tooling/webview_build_contract.ps1")
add_test(NAME WebAssetContract
  COMMAND "${DOPPELBANGER_POWERSHELL_EXECUTABLE}" -NoProfile -File
    "${CMAKE_SOURCE_DIR}/tests/tooling/web_asset_contract.ps1"
    -WebRoot "${DOPPELBANGER_VST3_WEB_DIR}")
