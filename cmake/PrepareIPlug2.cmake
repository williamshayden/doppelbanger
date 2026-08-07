include_guard(GLOBAL)

set(DOPPELBANGER_IPLUG2_SHA "5c2df9dce3f5258acfeff3846a6a9563f382212c")
set(DOPPELBANGER_VST3SDK_SHA "58f8da7936800732561402d7936584ca4505de07")
set(DOPPELBANGER_PREPARE_IPLUG2_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(doppelbanger_find_native_git output_variable)
  if(NOT WIN32)
    message(FATAL_ERROR "Pinned plugin dependencies require native Windows CMake")
  endif()

  set(program_files_git "$ENV{ProgramFiles}/Git/cmd/git.exe")
  if(EXISTS "${program_files_git}")
    set(native_git "${program_files_git}")
  else()
    find_program(native_git NAMES git.exe git REQUIRED)
  endif()
  set(${output_variable} "${native_git}" PARENT_SCOPE)
endfunction()

function(doppelbanger_require_pinned_checkout checkout_path expected_sha)
  if(NOT EXISTS "${checkout_path}")
    message(FATAL_ERROR "Pinned plugin dependency is missing: ${checkout_path}")
  endif()
  file(REAL_PATH "${checkout_path}" canonical_checkout_path)
  doppelbanger_find_native_git(native_git)

  execute_process(
    COMMAND "${native_git}" -C "${canonical_checkout_path}" rev-parse HEAD
    RESULT_VARIABLE revision_result
    OUTPUT_VARIABLE actual_sha
    ERROR_VARIABLE revision_error)
  string(STRIP "${actual_sha}" actual_sha)
  if(NOT revision_result EQUAL 0)
    message(FATAL_ERROR
      "Cannot read pinned plugin dependency revision: ${canonical_checkout_path}: "
      "${revision_error}")
  endif()
  if(NOT actual_sha STREQUAL expected_sha)
    message(FATAL_ERROR
      "Pinned plugin dependency revision mismatch: ${canonical_checkout_path}: "
      "expected ${expected_sha}, got ${actual_sha}")
  endif()

  execute_process(
    COMMAND "${native_git}" -C "${canonical_checkout_path}"
      status --porcelain --untracked-files=all
    RESULT_VARIABLE cleanliness_result
    OUTPUT_VARIABLE cleanliness_output
    ERROR_VARIABLE cleanliness_error)
  if(NOT cleanliness_result EQUAL 0)
    message(FATAL_ERROR
      "Cannot inspect pinned plugin dependency cleanliness: "
      "${canonical_checkout_path}: ${cleanliness_error}")
  endif()
  if(NOT cleanliness_output STREQUAL "")
    message(FATAL_ERROR
      "Pinned plugin dependency is dirty: ${canonical_checkout_path}: "
      "${cleanliness_output}")
  endif()
endfunction()

function(doppelbanger_verify_pinned_dependencies source_root)
  set(lock_file "${source_root}/tools/plugin-dependencies.lock.json")
  if(NOT EXISTS "${lock_file}")
    message(FATAL_ERROR "Pinned plugin dependency lock is missing: ${lock_file}")
  endif()
  file(READ "${lock_file}" lock_json)
  string(JSON dependency_count LENGTH "${lock_json}" dependencies)
  if(NOT dependency_count EQUAL 9)
    message(FATAL_ERROR "Pinned plugin dependency lock must contain nine entries")
  endif()

  string(JSON locked_iplug2_path GET "${lock_json}" dependencies 0 path)
  string(JSON locked_iplug2_sha GET "${lock_json}" dependencies 0 sha)
  string(JSON locked_vst3sdk_path GET "${lock_json}" dependencies 1 path)
  string(JSON locked_vst3sdk_sha GET "${lock_json}" dependencies 1 sha)
  if(NOT locked_iplug2_path STREQUAL "third_party/iPlug2" OR
     NOT locked_iplug2_sha STREQUAL DOPPELBANGER_IPLUG2_SHA OR
     NOT locked_vst3sdk_path STREQUAL "third_party/vst3sdk" OR
     NOT locked_vst3sdk_sha STREQUAL DOPPELBANGER_VST3SDK_SHA)
    message(FATAL_ERROR "Pinned plugin dependency lock has unexpected top-level pins")
  endif()

  math(EXPR dependency_last_index "${dependency_count} - 1")
  foreach(dependency_index RANGE 0 ${dependency_last_index})
    string(JSON relative_path GET
      "${lock_json}" dependencies ${dependency_index} path)
    string(JSON expected_sha GET
      "${lock_json}" dependencies ${dependency_index} sha)
    doppelbanger_require_pinned_checkout(
      "${source_root}/${relative_path}" "${expected_sha}")
  endforeach()
endfunction()

function(doppelbanger_copy_pinned_path source_root relative_path destination_root)
  set(source_path "${source_root}/${relative_path}")
  if(NOT EXISTS "${source_path}")
    message(FATAL_ERROR "Pinned plugin dependency path is missing: ${source_path}")
  endif()

  get_filename_component(relative_parent "${relative_path}" DIRECTORY)
  set(destination_parent "${destination_root}/${relative_parent}")
  file(MAKE_DIRECTORY "${destination_parent}")
  if(IS_DIRECTORY "${source_path}")
    find_program(DOPPELBANGER_ROBOCOPY_EXECUTABLE NAMES robocopy REQUIRED)
    set(destination_path "${destination_root}/${relative_path}")
    file(MAKE_DIRECTORY "${destination_path}")
    execute_process(
      COMMAND "${DOPPELBANGER_ROBOCOPY_EXECUTABLE}"
        "${source_path}" "${destination_path}"
        /E /COPY:DAT /DCOPY:DAT /R:1 /W:1
        /XD .git /XF .git /NFL /NDL /NJH /NJS /NP
      RESULT_VARIABLE robocopy_result
      OUTPUT_VARIABLE robocopy_output
      ERROR_VARIABLE robocopy_error)
    if(robocopy_result GREATER_EQUAL 8)
      message(FATAL_ERROR
        "Cannot stage ${source_path}: robocopy exit ${robocopy_result}: "
        "${robocopy_output}${robocopy_error}")
    endif()
  else()
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${source_path}" "${destination_parent}"
      RESULT_VARIABLE copy_result
      OUTPUT_VARIABLE copy_output
      ERROR_VARIABLE copy_error)
    if(NOT copy_result EQUAL 0)
      message(FATAL_ERROR
        "Cannot stage ${source_path}: ${copy_output}${copy_error}")
    endif()
  endif()
endfunction()

function(doppelbanger_prepare_iplug2 output_variable)
  file(REAL_PATH "${DOPPELBANGER_PREPARE_IPLUG2_MODULE_DIR}/.." source_root)
  file(REAL_PATH "${source_root}/third_party/iPlug2" iplug2_source)
  file(REAL_PATH "${source_root}/third_party/vst3sdk" vst3sdk_source)
  file(REAL_PATH "${CMAKE_BINARY_DIR}" binary_root)

  doppelbanger_verify_pinned_dependencies("${source_root}")

  foreach(required_path IN ITEMS "${iplug2_source}" "${vst3sdk_source}")
    if(NOT EXISTS "${required_path}")
      message(FATAL_ERROR "Pinned plugin dependency is missing: ${required_path}")
    endif()
  endforeach()

  file(MAKE_DIRECTORY "${binary_root}/_deps/iPlug2")
  file(REAL_PATH "${binary_root}/_deps/iPlug2" prepared_iplug2_dir)
  file(RELATIVE_PATH prepared_relative_path "${binary_root}" "${prepared_iplug2_dir}")
  if(NOT prepared_relative_path STREQUAL "_deps/iPlug2")
    message(FATAL_ERROR "iPlug2 composite must stay in ${binary_root}/_deps/iPlug2")
  endif()
  set(prepared_vst3sdk_dir
    "${prepared_iplug2_dir}/Dependencies/IPlug/VST3_SDK")

  set(iplug2_paths
    iPlug2.cmake
    Scripts/cmake
    IPlug
    IGraphics
    WDL
    Dependencies/IPlug
    Dependencies/IGraphics)
  set(vst3sdk_paths
    base
    cmake
    pluginterfaces
    public.sdk)

  set(composite_complete TRUE)
  foreach(relative_path IN LISTS iplug2_paths)
    if(NOT EXISTS "${prepared_iplug2_dir}/${relative_path}")
      set(composite_complete FALSE)
    endif()
  endforeach()
  foreach(relative_path IN LISTS vst3sdk_paths)
    if(NOT EXISTS "${prepared_vst3sdk_dir}/${relative_path}")
      set(composite_complete FALSE)
    endif()
  endforeach()

  set(stamps_match FALSE)
  if(EXISTS "${prepared_iplug2_dir}/.doppelbanger-iplug2.sha" AND
     EXISTS "${prepared_iplug2_dir}/.doppelbanger-vst3sdk.sha")
    file(READ "${prepared_iplug2_dir}/.doppelbanger-iplug2.sha"
      prepared_iplug2_sha)
    file(READ "${prepared_iplug2_dir}/.doppelbanger-vst3sdk.sha"
      prepared_vst3sdk_sha)
    string(STRIP "${prepared_iplug2_sha}" prepared_iplug2_sha)
    string(STRIP "${prepared_vst3sdk_sha}" prepared_vst3sdk_sha)
    if(prepared_iplug2_sha STREQUAL DOPPELBANGER_IPLUG2_SHA AND
       prepared_vst3sdk_sha STREQUAL DOPPELBANGER_VST3SDK_SHA)
      set(stamps_match TRUE)
    endif()
  endif()

  if(stamps_match AND composite_complete)
    set(${output_variable} "${prepared_iplug2_dir}" PARENT_SCOPE)
    message(STATUS "iPlug2 composite: matching pinned SHA stamps; skipping restage")
    return()
  endif()

  file(REMOVE_RECURSE "${prepared_iplug2_dir}")
  file(MAKE_DIRECTORY "${prepared_iplug2_dir}")
  foreach(relative_path IN LISTS iplug2_paths)
    doppelbanger_copy_pinned_path(
      "${iplug2_source}" "${relative_path}" "${prepared_iplug2_dir}")
  endforeach()

  file(MAKE_DIRECTORY "${prepared_vst3sdk_dir}")
  foreach(relative_path IN LISTS vst3sdk_paths)
    doppelbanger_copy_pinned_path(
      "${vst3sdk_source}" "${relative_path}" "${prepared_vst3sdk_dir}")
  endforeach()

  file(WRITE "${prepared_iplug2_dir}/.doppelbanger-iplug2.sha"
    "${DOPPELBANGER_IPLUG2_SHA}\n")
  file(WRITE "${prepared_iplug2_dir}/.doppelbanger-vst3sdk.sha"
    "${DOPPELBANGER_VST3SDK_SHA}\n")

  set(${output_variable} "${prepared_iplug2_dir}" PARENT_SCOPE)
endfunction()
