#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
albumdb_root="${1:-${repo_root}/var/albumdb}"
archive_root="${albumdb_root}/archives"
mkdir -p "${archive_root}"

verify_md5() {
  local path="$1"
  local expected="$2"
  local actual
  if command -v md5sum >/dev/null 2>&1; then
    actual="$(md5sum "${path}" | awk '{print $1}')"
  elif command -v md5 >/dev/null 2>&1; then
    actual="$(md5 -q "${path}")"
  else
    echo "error: md5 or md5sum is required" >&2
    return 1
  fi
  [[ "${actual}" == "${expected}" ]]
}

download() {
  local name="$1"
  local expected="$2"
  local url="$3"
  local path="${archive_root}/${name}"
  local partial="${path}.part"
  if [[ -f "${path}" ]] && verify_md5 "${path}" "${expected}"; then
    echo "verified ${name}"
    return
  fi
  if [[ -f "${path}" ]]; then
    mv "${path}" "${partial}"
  fi
  echo "downloading ${name}"
  if ! curl --fail --location --continue-at - --retry 3 --output "${partial}" "${url}"; then
    echo "resume failed for ${name}; retrying from byte zero"
    rm -f "${partial}"
    curl --fail --location --retry 3 --output "${partial}" "${url}"
  fi
  if ! verify_md5 "${partial}" "${expected}"; then
    echo "error: checksum mismatch for ${partial}" >&2
    exit 1
  fi
  mv "${partial}" "${path}"
}

download \
  "stems_mixed.zip" \
  "a6ddc38004047879622542f41ab691ed" \
  "https://zenodo.org/api/records/19683001/files/stems_mixed.zip/content"
download \
  "masters_stereo.zip" \
  "06ff09dfe1d03788c71071b419eb0366" \
  "https://zenodo.org/api/records/19683001/files/masters_stereo.zip/content"

if [[ ! -d "${albumdb_root}/stems_mixed" ]]; then
  unzip -q "${archive_root}/stems_mixed.zip" -d "${albumdb_root}"
fi
if [[ ! -d "${albumdb_root}/masters_stereo" ]]; then
  unzip -q "${archive_root}/masters_stereo.zip" -d "${albumdb_root}"
fi

cd "${repo_root}"
cargo run --release --bin prepare_albumdb -- --root "${albumdb_root}"
