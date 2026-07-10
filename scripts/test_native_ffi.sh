#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_dir="${CARGO_TARGET_DIR:-${repo_root}/target}"
if [[ "${target_dir}" != /* ]]; then
  target_dir="${repo_root}/${target_dir}"
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/doppelbanger-native-ffi.XXXXXX")"
trap 'rm -rf "${temp_dir}"' EXIT HUP INT TERM

cc="${CC:-cc}"
cxx="${CXX:-c++}"
host_os="$(uname -s)"

case "${host_os}" in
  Darwin)
    native_link_flags=(-framework Security -framework CoreFoundation -liconv -lm)
    ;;
  Linux)
    native_link_flags=(-ldl -lpthread -lm -lrt -lutil)
    ;;
  *)
    echo "error: native FFI smoke supports macOS and Linux, found ${host_os}" >&2
    exit 2
    ;;
esac

cd "${repo_root}"
CARGO_TARGET_DIR="${target_dir}" cargo build --release --lib

static_lib="${target_dir}/release/libdoppelbanger.a"
if [[ ! -f "${static_lib}" ]]; then
  echo "error: cargo did not produce ${static_lib}" >&2
  exit 1
fi

common_compile_flags=(
  -Wall
  -Wextra
  -Werror
  -pedantic
  -fshort-enums
  -I"${repo_root}/include"
  -I"${repo_root}/tests/native"
)

"${cc}" "${common_compile_flags[@]}" -std=c11 \
  -c "${repo_root}/tests/native/c11_smoke.c" \
  -o "${temp_dir}/c11_smoke.o"
"${cc}" "${temp_dir}/c11_smoke.o" "${static_lib}" \
  "${native_link_flags[@]}" -o "${temp_dir}/c11_smoke"

"${cxx}" "${common_compile_flags[@]}" -std=c++17 \
  -c "${repo_root}/tests/native/cpp17_smoke.cpp" \
  -o "${temp_dir}/cpp17_smoke.o"
"${cxx}" "${temp_dir}/cpp17_smoke.o" "${static_lib}" \
  "${native_link_flags[@]}" -o "${temp_dir}/cpp17_smoke"

"${temp_dir}/c11_smoke"
"${temp_dir}/cpp17_smoke"
printf 'native FFI smoke: ok (%s %s)\n' "${host_os}" "$(uname -m)"
