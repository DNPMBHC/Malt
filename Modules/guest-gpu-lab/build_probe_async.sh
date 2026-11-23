#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/d3d11_probe_async.cpp"
OUT_DIR="${SCRIPT_DIR}/build"
OUT="${OUT_DIR}/d3d11_probe_async.exe"

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
CXX="${MINGW_CXX:-$(command -v x86_64-w64-mingw32-g++ || true)}"
if [[ -z "${CXX}" ]]; then
  echo "build_probe_async: x86_64-w64-mingw32-g++ not found" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}/tmp"
TMPDIR="${OUT_DIR}/tmp/" TMP="${OUT_DIR}/tmp/" TEMP="${OUT_DIR}/tmp/" \
  "${CXX}" -std=c++17 -O2 -Wall -Wextra -Wno-unknown-pragmas \
  "${SRC}" -o "${OUT}" \
  -static -static-libgcc -static-libstdc++ \
  -lws2_32 -lpthread

SRC_SHA="$(shasum -a 256 "${SRC}" | awk '{print $1}')"
BIN_SHA="$(shasum -a 256 "${OUT}" | awk '{print $1}')"
echo "built=build/d3d11_probe_async.exe"
echo "source_sha256=${SRC_SHA}"
echo "binary_sha256=${BIN_SHA}"
