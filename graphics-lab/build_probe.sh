#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/d3d11_probe.cpp"
OUT_DIR="${SCRIPT_DIR}/build"
OUT="${OUT_DIR}/d3d11_probe.exe"

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

CXX="${MINGW_CXX:-$(command -v x86_64-w64-mingw32-g++ || true)}"
if [[ -z "${CXX}" ]]; then
  echo "build_probe: x86_64-w64-mingw32-g++ not found (install via 'brew install mingw-w64')" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

"${CXX}" -std=c++17 -O2 -Wall -Wextra -Wno-unknown-pragmas \
  "${SRC}" \
  -o "${OUT}" \
  -static -static-libgcc -static-libstdc++ \
  -ld3d11 -ldxgi -ld3dcompiler -lpsapi -lws2_32 -lpthread

SRC_SHA="$(shasum -a 256 "${SRC}" | awk '{print $1}')"
BIN_SHA="$(shasum -a 256 "${OUT}" | awk '{print $1}')"
CXX_VER="$("${CXX}" --version | head -n 1)"

cat <<EOF
built=build/d3d11_probe.exe
compiler=${CXX_VER}
source_sha256=${SRC_SHA}
binary_sha256=${BIN_SHA}
EOF
