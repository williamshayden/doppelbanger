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
