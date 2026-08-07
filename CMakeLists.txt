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
include(cmake/BuildRust.cmake)

doppelbanger_prepare_iplug2(DOPPELBANGER_IPLUG2_DIR)
doppelbanger_add_rust_target()

set(IPLUG2_DIR "${DOPPELBANGER_IPLUG2_DIR}")
set(IPLUG_DEPLOY_PLUGINS OFF CACHE BOOL
  "Never copy Doppelbanger plugins outside the build tree" FORCE)
include("${IPLUG2_DIR}/iPlug2.cmake")

# The pinned upstream core declares this optional WebView target by downloading
# dependencies at configure time. This headless target never consumes it, so a
# closed placeholder keeps the dependency graph offline without patching iPlug2.
if(NOT TARGET iPlug2::Extras::IWebViewControl)
  add_library(iPlug2::Extras::IWebViewControl INTERFACE IMPORTED GLOBAL)
endif()
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

add_executable(PluginLifecycleTests
  tests/plugin/PluginLifecycleTests.cpp
  plugin/Doppelbanger.cpp
  plugin/StateCodec.cpp
  "${IPLUG2_DIR}/Dependencies/IPlug/VST3_SDK/public.sdk/source/common/memorystream.cpp"
  "${IPLUG2_DIR}/Dependencies/IPlug/VST3_SDK/public.sdk/source/vst/hosting/parameterchanges.cpp")
target_include_directories(PluginLifecycleTests PRIVATE
  "${CMAKE_SOURCE_DIR}/include"
  "${CMAKE_SOURCE_DIR}/plugin")
target_compile_definitions(PluginLifecycleTests PRIVATE
  NO_IGRAPHICS
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
file(MAKE_DIRECTORY
  "${DOPPELBANGER_VST3_BUNDLE}/Contents/Resources")

add_library(Doppelbanger-vst3 MODULE
  plugin/Doppelbanger.cpp
  plugin/Doppelbanger.h
  plugin/config.h
  plugin/StateCodec.cpp
  plugin/StateCodec.h)
target_include_directories(Doppelbanger-vst3 PRIVATE
  "${CMAKE_SOURCE_DIR}/include"
  "${CMAKE_SOURCE_DIR}/plugin")
target_compile_definitions(Doppelbanger-vst3 PRIVATE
  NO_IGRAPHICS
  SAMPLE_TYPE_FLOAT)
target_compile_features(Doppelbanger-vst3 PRIVATE cxx_std_17)
target_compile_options(Doppelbanger-vst3 PRIVATE
  /W4 /EHsc /wd4100 /wd4456 /wd4701)
target_link_libraries(Doppelbanger-vst3 PRIVATE
  iPlug2::VST3
  doppelbanger_rust)
add_dependencies(Doppelbanger-vst3 doppelbanger_rust)
set_target_properties(Doppelbanger-vst3 PROPERTIES
  OUTPUT_NAME "Doppelbanger"
  PREFIX ""
  SUFFIX ".vst3"
  LIBRARY_OUTPUT_DIRECTORY "${DOPPELBANGER_VST3_BINARY_DIR}"
  RUNTIME_OUTPUT_DIRECTORY "${DOPPELBANGER_VST3_BINARY_DIR}")
