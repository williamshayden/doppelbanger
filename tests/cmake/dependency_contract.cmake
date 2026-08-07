cmake_minimum_required(VERSION 3.19)

# Phase 2A owns pinned dependency provenance.  Phase 2B will add the project
# CMake files and their preparation/build behavior; their absence is not a
# failure in this provenance-only contract.
get_filename_component(PROJECT_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." REALPATH)
set(LOCK_FILE "${PROJECT_ROOT}/tools/plugin-dependencies.lock.json")
set(GITMODULES_FILE "${PROJECT_ROOT}/.gitmodules")

function(require_file path description)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "dependency contract: missing ${description}: ${path}")
  endif()
endfunction()

function(require_lock_entry index expected_path expected_url expected_sha)
  string(JSON actual_path GET "${LOCK_JSON}" dependencies ${index} path)
  string(JSON actual_url GET "${LOCK_JSON}" dependencies ${index} url)
  string(JSON actual_sha GET "${LOCK_JSON}" dependencies ${index} sha)
  if(NOT actual_path STREQUAL expected_path OR
     NOT actual_url STREQUAL expected_url OR
     NOT actual_sha STREQUAL expected_sha)
    message(FATAL_ERROR
      "dependency contract: lock entry ${index} must be ${expected_path} at ${expected_sha}")
  endif()
endfunction()

require_file("${GITMODULES_FILE}" ".gitmodules")
require_file("${LOCK_FILE}" "plugin dependency lock")

file(READ "${LOCK_FILE}" LOCK_JSON)
string(JSON dependency_count LENGTH "${LOCK_JSON}" dependencies)
if(NOT dependency_count EQUAL 9)
  message(FATAL_ERROR "dependency contract: lock must contain exactly nine dependency entries")
endif()

require_lock_entry(0 "third_party/iPlug2" "https://github.com/iPlug2/iPlug2.git" "5c2df9dce3f5258acfeff3846a6a9563f382212c")
require_lock_entry(1 "third_party/vst3sdk" "https://github.com/steinbergmedia/vst3sdk.git" "58f8da7936800732561402d7936584ca4505de07")
require_lock_entry(2 "third_party/vst3sdk/base" "https://github.com/steinbergmedia/vst3_base" "3d2e82f8e6bff59c1d8b7a27491a29c2286b5206")
require_lock_entry(3 "third_party/vst3sdk/cmake" "https://github.com/steinbergmedia/vst3_cmake" "de6e54eeaaab35b7145f5c32c279b5e892146e04")
require_lock_entry(4 "third_party/vst3sdk/doc" "https://github.com/steinbergmedia/vst3_doc" "6d4737c9e70750056e731d88d49aa06eefc8a1a4")
require_lock_entry(5 "third_party/vst3sdk/pluginterfaces" "https://github.com/steinbergmedia/vst3_pluginterfaces" "31d6eeba6daaa3e2a8bfbe3e7a90ca0b7fbfbc1c")
require_lock_entry(6 "third_party/vst3sdk/public.sdk" "https://github.com/steinbergmedia/vst3_public_sdk" "a3911a4615dabbfdfd9d181ee26b05c70c289a95")
require_lock_entry(7 "third_party/vst3sdk/tutorials" "https://github.com/steinbergmedia/vst3_tutorials" "33b73dfbb87f3fde3bce8c0a10cae934dc66ad34")
require_lock_entry(8 "third_party/vst3sdk/vstgui4" "https://github.com/steinbergmedia/vstgui" "76823bdbe286e4bdb9f79ab8986af5ce7202336c")

if(WIN32)
  set(NATIVE_GIT "$ENV{ProgramFiles}/Git/cmd/git.exe")
else()
  set(NATIVE_GIT "/mnt/c/Program Files/Git/cmd/git.exe")
endif()
if(NOT EXISTS "${NATIVE_GIT}")
  message(FATAL_ERROR "dependency contract: native Windows Git is required: ${NATIVE_GIT}")
endif()

execute_process(
  COMMAND "${NATIVE_GIT}" config --file .gitmodules --get-regexp "^submodule\\..*\\.(path|url)$"
  WORKING_DIRECTORY "${PROJECT_ROOT}"
  RESULT_VARIABLE gitmodules_result
  OUTPUT_VARIABLE gitmodules_output
  ERROR_VARIABLE gitmodules_error)
if(NOT gitmodules_result EQUAL 0)
  message(FATAL_ERROR "dependency contract: cannot read .gitmodules: ${gitmodules_error}")
endif()
string(REPLACE "\r\n" "\n" gitmodules_output "${gitmodules_output}")
string(STRIP "${gitmodules_output}" gitmodules_output)
set(expected_gitmodules
  "submodule.third_party/iPlug2.path third_party/iPlug2\nsubmodule.third_party/iPlug2.url https://github.com/iPlug2/iPlug2.git\nsubmodule.third_party/vst3sdk.path third_party/vst3sdk\nsubmodule.third_party/vst3sdk.url https://github.com/steinbergmedia/vst3sdk.git")
if(NOT "${gitmodules_output}" STREQUAL "${expected_gitmodules}")
  message(FATAL_ERROR "dependency contract: .gitmodules must contain only the two pinned top-level dependencies")
endif()

execute_process(
  COMMAND "${NATIVE_GIT}" submodule status --recursive
  WORKING_DIRECTORY "${PROJECT_ROOT}"
  RESULT_VARIABLE submodule_result
  OUTPUT_VARIABLE submodule_output
  ERROR_VARIABLE submodule_error)
if(NOT submodule_result EQUAL 0)
  message(FATAL_ERROR "dependency contract: submodule status failed: ${submodule_error}")
endif()
string(REPLACE "\r\n" "\n" submodule_output "${submodule_output}")
string(REGEX REPLACE " [(][^)\r\n]*[)]" "" submodule_output "${submodule_output}")
string(STRIP "${submodule_output}" submodule_output)
set(expected_submodule_status
  " 5c2df9dce3f5258acfeff3846a6a9563f382212c third_party/iPlug2\n 58f8da7936800732561402d7936584ca4505de07 third_party/vst3sdk\n 3d2e82f8e6bff59c1d8b7a27491a29c2286b5206 third_party/vst3sdk/base\n de6e54eeaaab35b7145f5c32c279b5e892146e04 third_party/vst3sdk/cmake\n 6d4737c9e70750056e731d88d49aa06eefc8a1a4 third_party/vst3sdk/doc\n 31d6eeba6daaa3e2a8bfbe3e7a90ca0b7fbfbc1c third_party/vst3sdk/pluginterfaces\n a3911a4615dabbfdfd9d181ee26b05c70c289a95 third_party/vst3sdk/public.sdk\n 33b73dfbb87f3fde3bce8c0a10cae934dc66ad34 third_party/vst3sdk/tutorials\n 76823bdbe286e4bdb9f79ab8986af5ce7202336c third_party/vst3sdk/vstgui4")
if(NOT " ${submodule_output}" STREQUAL "${expected_submodule_status}")
  message(FATAL_ERROR "dependency contract: missing, dirty, mismatched, or extra recursive gitlink")
endif()

set(locked_paths
  third_party/iPlug2
  third_party/vst3sdk
  third_party/vst3sdk/base
  third_party/vst3sdk/cmake
  third_party/vst3sdk/doc
  third_party/vst3sdk/pluginterfaces
  third_party/vst3sdk/public.sdk
  third_party/vst3sdk/tutorials
  third_party/vst3sdk/vstgui4)
foreach(locked_path IN LISTS locked_paths)
  execute_process(
    COMMAND "${NATIVE_GIT}" -C "${locked_path}" status --porcelain --untracked-files=all
    WORKING_DIRECTORY "${PROJECT_ROOT}"
    RESULT_VARIABLE cleanliness_result
    OUTPUT_VARIABLE cleanliness_output
    ERROR_VARIABLE cleanliness_error)
  if(NOT cleanliness_result EQUAL 0 OR NOT cleanliness_output STREQUAL "")
    message(FATAL_ERROR "dependency contract: dirty recursive gitlink ${locked_path}: ${cleanliness_output}${cleanliness_error}")
  endif()
endforeach()

set(project_cmake_files)
if(EXISTS "${PROJECT_ROOT}/CMakeLists.txt")
  list(APPEND project_cmake_files "${PROJECT_ROOT}/CMakeLists.txt")
endif()
if(IS_DIRECTORY "${PROJECT_ROOT}/cmake")
  file(GLOB_RECURSE cmake_support_files LIST_DIRECTORIES false
    "${PROJECT_ROOT}/cmake/*.cmake")
  list(APPEND project_cmake_files ${cmake_support_files})
endif()
if(project_cmake_files)
  foreach(cmake_file IN LISTS project_cmake_files)
    file(READ "${cmake_file}" cmake_source)
    string(TOLOWER "${cmake_source}" cmake_source_lower)
    if(cmake_source_lower MATCHES "fetchcontent" OR
       cmake_source_lower MATCHES "file[ \t\r\n]*\\([ \t\r\n]*download" OR
       cmake_source_lower MATCHES "git[ \t]+clone")
      message(FATAL_ERROR "dependency contract: project CMake must not download or clone dependencies: ${cmake_file}")
    endif()
  endforeach()
else()
  message(STATUS "dependency contract: Phase 2B CMake files are intentionally absent; CMake behavior is not asserted in phase 2A")
endif()

message(STATUS "dependency contract: pinned recursive provenance is valid")
