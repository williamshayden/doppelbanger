cmake_minimum_required(VERSION 3.19)

# Task 2 owns both pinned provenance and an offline CMake build graph.  This
# contract is deliberately static: it can run before an MSVC environment is
# imported, while configure/build are covered by the native green gates.
get_filename_component(PROJECT_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." REALPATH)
set(LOCK_FILE "${PROJECT_ROOT}/tools/plugin-dependencies.lock.json")
set(GITMODULES_FILE "${PROJECT_ROOT}/.gitmodules")
set(PROJECT_CMAKE_FILE "${PROJECT_ROOT}/CMakeLists.txt")
set(PRESETS_FILE "${PROJECT_ROOT}/CMakePresets.json")
set(BUILD_RUST_FILE "${PROJECT_ROOT}/cmake/BuildRust.cmake")
set(PREPARE_IPLUG2_FILE "${PROJECT_ROOT}/cmake/PrepareIPlug2.cmake")

function(require_file path description)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "dependency contract: missing ${description}: ${path}")
  endif()
endfunction()

function(require_match source description pattern)
  string(TOLOWER "${pattern}" pattern_lower)
  string(REGEX MATCH "${pattern_lower}" matched "${source}")
  if(matched STREQUAL "")
    message(FATAL_ERROR "dependency contract: ${description}")
  endif()
endfunction()

function(reject_match source description pattern)
  string(TOLOWER "${pattern}" pattern_lower)
  string(REGEX MATCH "${pattern_lower}" matched "${source}")
  if(NOT matched STREQUAL "")
    message(FATAL_ERROR "dependency contract: ${description}")
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

require_file("${PROJECT_CMAKE_FILE}" "top-level CMakeLists.txt")
require_file("${PRESETS_FILE}" "CMakePresets.json")
require_file("${BUILD_RUST_FILE}" "cmake/BuildRust.cmake")
require_file("${PREPARE_IPLUG2_FILE}" "cmake/PrepareIPlug2.cmake")

file(READ "${PROJECT_CMAKE_FILE}" project_cmake)
file(READ "${PRESETS_FILE}" presets_json)
file(READ "${BUILD_RUST_FILE}" build_rust)
file(READ "${PREPARE_IPLUG2_FILE}" prepare_iplug2)
string(TOLOWER "${project_cmake}" project_cmake)
string(TOLOWER "${build_rust}" build_rust)
string(TOLOWER "${prepare_iplug2}" prepare_iplug2)
set(project_cmake_files "${PROJECT_CMAKE_FILE}" "${BUILD_RUST_FILE}" "${PREPARE_IPLUG2_FILE}")

foreach(cmake_file IN LISTS project_cmake_files)
  file(READ "${cmake_file}" cmake_source)
  string(TOLOWER "${cmake_source}" cmake_source_lower)
  reject_match("${cmake_source_lower}" "project CMake must not use FetchContent: ${cmake_file}" "fetchcontent")
  reject_match("${cmake_source_lower}" "project CMake must not download dependencies: ${cmake_file}" "file[ \t\r\n]*\\([ \t\r\n]*download")
  reject_match("${cmake_source_lower}" "project CMake must not clone dependencies: ${cmake_file}" "git[ \t]+clone")
endforeach()

require_match("${project_cmake}" "top-level CMake must require MSVC" "if[ \t\r\n]*\\([ \t\r\n]*not[ \t\r\n]+msvc")
require_match("${project_cmake}" "top-level CMake must require x64" "cmake_sizeof_void_p[ \t\r\n]+equal[ \t\r\n]+8")
require_match("${project_cmake}" "top-level CMake must use the static MSVC runtime" "cmake_msvc_runtime_library[ \t\r\n]+\\\"multithreaded")
require_match("${project_cmake}" "top-level CMake must disable plugin deployment by default" "doppelbanger_deploy_plugin[ \t\r\n]+.*off")
require_match("${project_cmake}" "top-level CMake must prepare the build-tree iPlug2 composite" "doppelbanger_prepare_iplug2")
require_match("${project_cmake}" "top-level CMake must create the Rust target" "doppelbanger_add_rust_target")

string(JSON preset_count LENGTH "${presets_json}" configurePresets)
set(release_preset_index -1)
math(EXPR preset_last_index "${preset_count} - 1")
foreach(preset_index RANGE 0 ${preset_last_index})
  string(JSON preset_name GET "${presets_json}" configurePresets ${preset_index} name)
  if(preset_name STREQUAL "windows-msvc-x64-release")
    set(release_preset_index ${preset_index})
  endif()
endforeach()
if(release_preset_index EQUAL -1)
  message(FATAL_ERROR "dependency contract: missing windows-msvc-x64-release preset")
endif()
string(JSON preset_generator GET "${presets_json}" configurePresets ${release_preset_index} generator)
string(JSON preset_binary_dir GET "${presets_json}" configurePresets ${release_preset_index} binaryDir)
string(JSON preset_build_type GET "${presets_json}" configurePresets ${release_preset_index} cacheVariables CMAKE_BUILD_TYPE)
string(JSON preset_runtime GET "${presets_json}" configurePresets ${release_preset_index} cacheVariables CMAKE_MSVC_RUNTIME_LIBRARY)
string(JSON preset_deployment GET "${presets_json}" configurePresets ${release_preset_index} cacheVariables DOPPELBANGER_DEPLOY_PLUGIN)
if(NOT preset_generator STREQUAL "Ninja" OR
   NOT preset_binary_dir STREQUAL "\${sourceDir}/build/windows-msvc-x64-release" OR
   NOT preset_build_type STREQUAL "Release" OR
   NOT preset_runtime STREQUAL "MultiThreaded" OR
   NOT preset_deployment STREQUAL "OFF")
  message(FATAL_ERROR "dependency contract: windows-msvc-x64-release preset is not deterministic")
endif()

string(JSON build_preset_count LENGTH "${presets_json}" buildPresets)
set(rust_build_preset_index -1)
math(EXPR build_preset_last_index "${build_preset_count} - 1")
foreach(build_preset_index RANGE 0 ${build_preset_last_index})
  string(JSON build_configure_preset GET "${presets_json}" buildPresets ${build_preset_index} configurePreset)
  if(build_configure_preset STREQUAL "windows-msvc-x64-release")
    set(rust_build_preset_index ${build_preset_index})
  endif()
endforeach()
if(rust_build_preset_index EQUAL -1)
  message(FATAL_ERROR "dependency contract: missing Rust build preset")
endif()
string(JSON rust_build_target GET "${presets_json}" buildPresets ${rust_build_preset_index} targets 0)
if(NOT rust_build_target STREQUAL "doppelbanger_rust")
  message(FATAL_ERROR "dependency contract: Rust build preset must build doppelbanger_rust")
endif()

require_match("${build_rust}" "Rust build must use the MSVC target" "--target[ \t\r\n]+x86_64-pc-windows-msvc")
require_match("${build_rust}" "Rust build must use cargo rustc --locked --offline --release --lib" "rustc[ \t\r\n]+--locked[ \t\r\n]+--offline[ \t\r\n]+--release[ \t\r\n]+--lib")
require_match("${build_rust}" "Rust build must print native static libraries" "--print[ \t\r\n]+native-static-libs")
require_match("${build_rust}" "Rust archive must be an imported library" "add_library[ \t\r\n]*\\([ \t\r\n]*doppelbanger_rust_archive[ \t\r\n]+static[ \t\r\n]+imported")
require_match("${build_rust}" "Rust build must expose a buildable doppelbanger_rust interface" "add_library[ \t\r\n]*\\([ \t\r\n]*doppelbanger_rust[ \t\r\n]+interface")
require_match("${build_rust}" "Rust target must import the MSVC static library" "target/x86_64-pc-windows-msvc/release/doppelbanger\\.lib")
require_match("${build_rust}" "Rust target must expose parsed native libraries" "interface_link_libraries")
require_match("${build_rust}" "Rust target must parse MSVC native-static-libs output" "native_static_libs_line")
require_match("${build_rust}" "Rust interface must link the imported archive" "target_link_libraries[ \t\r\n]*\\([ \t\r\n]*doppelbanger_rust[ \t\r\n]+interface[ \t\r\n]+doppelbanger_rust_archive")
reject_match("${build_rust}" "Rust build must not use a differently named proxy target" "doppelbanger_rust_build")

require_match("${prepare_iplug2}" "iPlug2 preparation must canonicalize paths" "file[ \t\r\n]*\\([ \t\r\n]*real_path")
require_match("${prepare_iplug2}" "iPlug2 preparation must use the build-tree composite" "binary_root[^\r\n]*_deps/iPlug2")
require_match("${prepare_iplug2}" "iPlug2 destination must exist before canonicalization" "make_directory[ \t\r\n]+\\\"\\$\\{binary_root\\}/_deps/iPlug2\\\"[ \t\r\n]*\\)[ \t\r\n]*file[ \t\r\n]*\\([ \t\r\n]*real_path")
require_match("${prepare_iplug2}" "iPlug2 preparation must use Windows-native bulk directory staging" "robocopy")
require_match("${prepare_iplug2}" "iPlug2 preparation must reject robocopy failure exit codes" "greater_equal[ \t\r\n]+8")
reject_match("${prepare_iplug2}" "iPlug2 preparation must not use CMake's slow per-file directory copy" "file[ \t\r\n]*\\([ \t\r\n]*copy[ \t\r\n]+")
reject_match("${prepare_iplug2}" "iPlug2 preparation must not copy the full iPlug2 checkout" "\\$\\{iplug2_source\\}/\\\"[ \t\r\n]+destination")
reject_match("${prepare_iplug2}" "iPlug2 preparation must not copy the full VST3 SDK checkout" "\\$\\{vst3sdk_source\\}/\\\"[ \t\r\n]+destination")
foreach(required_iplug2_path IN ITEMS
    "iplug2.cmake"
    "scripts/cmake"
    "iplug"
    "igraphics"
    "wdl"
    "dependencies/iplug"
    "dependencies/igraphics")
  require_match("${prepare_iplug2}"
    "iPlug2 preparation must stage ${required_iplug2_path}"
    "${required_iplug2_path}")
endforeach()
foreach(required_vst3sdk_path IN ITEMS base cmake pluginterfaces public.sdk)
  require_match("${prepare_iplug2}"
    "iPlug2 preparation must stage VST3 SDK ${required_vst3sdk_path}"
    "${required_vst3sdk_path}")
endforeach()
foreach(rejected_vst3sdk_path IN ITEMS doc tutorials vstgui4)
  reject_match("${prepare_iplug2}"
    "iPlug2 preparation must not stage VST3 SDK ${rejected_vst3sdk_path}"
    "${rejected_vst3sdk_path}")
endforeach()
require_match("${prepare_iplug2}" "iPlug2 preparation must stamp the iPlug2 SHA" "5c2df9dce3f5258acfeff3846a6a9563f382212c")
require_match("${prepare_iplug2}" "iPlug2 preparation must stamp the VST3 SDK SHA" "58f8da7936800732561402d7936584ca4505de07")
require_match("${prepare_iplug2}" "matching SHA stamps must be read before deciding to restage" "file[ \t\r\n]*\\([ \t\r\n]*read[^)]*doppelbanger-iplug2\\.sha")
require_match("${prepare_iplug2}" "matching SHA stamps must skip restaging" "matching pinned sha stamps; skipping restage")
require_match("${prepare_iplug2}" "matching SHA stamps must return before restaging" "matching pinned sha stamps; skipping restage[^}]*return[ \t\r\n]*\\(")
reject_match("${prepare_iplug2}" "iPlug2 preparation must not write into source submodules" "third_party[/\\]iPlug2[^\r\n]*(write|remove|copy|make_directory)")
reject_match("${prepare_iplug2}" "VST3 SDK preparation must not write into source submodules" "third_party[/\\]vst3sdk[^\r\n]*(write|remove|copy|make_directory)")

include("${PREPARE_IPLUG2_FILE}")
set(copy_probe_root "${PROJECT_ROOT}/build/dependency-contract-copy-probe")
file(REMOVE_RECURSE "${copy_probe_root}")
file(MAKE_DIRECTORY "${copy_probe_root}/source/nested/deeper")
file(WRITE "${copy_probe_root}/source/nested/deeper/probe.txt" "bulk-copy-probe\n")
doppelbanger_copy_pinned_path(
  "${copy_probe_root}/source" "nested" "${copy_probe_root}/destination")
set(copy_probe_output
  "${copy_probe_root}/destination/nested/deeper/probe.txt")
if(NOT EXISTS "${copy_probe_output}")
  message(FATAL_ERROR "dependency contract: bulk directory staging omitted a nested file")
endif()
file(READ "${copy_probe_output}" copy_probe_contents)
if(NOT copy_probe_contents STREQUAL "bulk-copy-probe\n")
  message(FATAL_ERROR "dependency contract: bulk directory staging changed file contents")
endif()
file(REMOVE_RECURSE "${copy_probe_root}")

message(STATUS "dependency contract: pinned recursive provenance is valid")
