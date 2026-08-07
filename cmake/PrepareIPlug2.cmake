include_guard(GLOBAL)

set(DOPPELBANGER_IPLUG2_SHA "5c2df9dce3f5258acfeff3846a6a9563f382212c")
set(DOPPELBANGER_VST3SDK_SHA "58f8da7936800732561402d7936584ca4505de07")
set(DOPPELBANGER_PREPARE_IPLUG2_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

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
