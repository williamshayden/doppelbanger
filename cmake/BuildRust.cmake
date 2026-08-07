include_guard(GLOBAL)

function(doppelbanger_add_rust_target)
  if(TARGET doppelbanger_rust)
    return()
  endif()

  find_program(DOPPELBANGER_CARGO_EXECUTABLE NAMES cargo REQUIRED)
  set(DOPPELBANGER_RUST_TARGET "x86_64-pc-windows-msvc")
  set(DOPPELBANGER_RUST_LIBRARY
    "${CMAKE_SOURCE_DIR}/target/x86_64-pc-windows-msvc/release/doppelbanger.lib")

  execute_process(
    COMMAND "${DOPPELBANGER_CARGO_EXECUTABLE}" rustc --locked --offline --release --lib
      --target x86_64-pc-windows-msvc --
      -C target-feature=+crt-static --print native-static-libs
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    RESULT_VARIABLE rustc_result
    OUTPUT_VARIABLE rustc_output
    ERROR_VARIABLE rustc_error)
  if(NOT rustc_result EQUAL 0)
    message(FATAL_ERROR "cargo rustc failed: ${rustc_output}${rustc_error}")
  endif()
  if(NOT EXISTS "${DOPPELBANGER_RUST_LIBRARY}")
    message(FATAL_ERROR "cargo rustc did not produce ${DOPPELBANGER_RUST_LIBRARY}")
  endif()

  string(REGEX MATCH "native-static-libs:[^\r\n]+" native_static_libs_line
    "${rustc_output}\n${rustc_error}")
  string(REGEX MATCHALL "[A-Za-z0-9_.-]+\\.lib" native_static_libraries
    "${native_static_libs_line}")
  if(native_static_libraries STREQUAL "")
    message(FATAL_ERROR "cargo rustc did not report MSVC native static libraries")
  endif()
  list(REMOVE_DUPLICATES native_static_libraries)

  add_library(doppelbanger_rust_archive STATIC IMPORTED GLOBAL)
  set_target_properties(doppelbanger_rust_archive PROPERTIES
    IMPORTED_LOCATION "${DOPPELBANGER_RUST_LIBRARY}"
    INTERFACE_LINK_LIBRARIES "${native_static_libraries}")

  file(GLOB_RECURSE DOPPELBANGER_RUST_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_SOURCE_DIR}/src/*.rs")
  add_custom_command(
    OUTPUT "${DOPPELBANGER_RUST_LIBRARY}"
    COMMAND "${DOPPELBANGER_CARGO_EXECUTABLE}" rustc --locked --offline --release --lib
      --target x86_64-pc-windows-msvc --
      -C target-feature=+crt-static --print native-static-libs
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    DEPENDS
      "${CMAKE_SOURCE_DIR}/Cargo.toml"
      "${CMAKE_SOURCE_DIR}/Cargo.lock"
      "${CMAKE_SOURCE_DIR}/build.rs"
      ${DOPPELBANGER_RUST_SOURCES}
    COMMENT "Building the Doppelbanger Rust static library"
    VERBATIM)
  add_library(doppelbanger_rust INTERFACE "${DOPPELBANGER_RUST_LIBRARY}")
  target_link_libraries(doppelbanger_rust INTERFACE doppelbanger_rust_archive)
endfunction()
