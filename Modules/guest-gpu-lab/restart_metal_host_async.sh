#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/build"
SRC="${SCRIPT_DIR}/metal_host_async.swift"
BIN="${OUT_DIR}/metal_host_async"
PID_FILE="${OUT_DIR}/metal_host_async.pid"
STDERR_LOG="${OUT_DIR}/metal_host_async.stderr.log"
CACHE_DIR="${OUT_DIR}/swift-module-cache"
TMP_DIR="${OUT_DIR}/tmp"

mkdir -p "${OUT_DIR}" "${CACHE_DIR}" "${TMP_DIR}"
chmod 700 "${TMP_DIR}"

verify_and_stop_old() {
  if [[ ! -f "${PID_FILE}" ]]; then
    return 0
  fi
  local old_pid
  old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ -z "${old_pid}" || ! "${old_pid}" =~ ^[0-9]+$ ]]; then
    rm -f "${PID_FILE}"
    return 0
  fi
  local state
  state="$(python3 - "${old_pid}" "${BIN}" <<'PYSTATE'
import ctypes, ctypes.util, os, pathlib, sys
pid = int(sys.argv[1])
expected = pathlib.Path(sys.argv[2]).resolve()
try:
    os.kill(pid, 0)
except ProcessLookupError:
    print("gone")
    raise SystemExit(0)
except PermissionError:
    print("other")
    raise SystemExit(0)
lib = ctypes.CDLL(ctypes.util.find_library("proc"))
lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
lib.proc_pidpath.restype = ctypes.c_int
buf = ctypes.create_string_buffer(4096)
n = lib.proc_pidpath(pid, buf, len(buf))
exe = buf.value.decode() if n > 0 else ""
print("match" if exe and pathlib.Path(exe).resolve() == expected else "other")
PYSTATE
)"
  if [[ "${state}" == "match" ]]; then
    kill -TERM "${old_pid}" 2>/dev/null || true
    for _ in {1..50}; do
      if ! kill -0 "${old_pid}" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "${old_pid}" 2>/dev/null; then
      kill -KILL "${old_pid}" 2>/dev/null || true
    fi
  fi
  rm -f "${PID_FILE}"
}

build_binary() {
  local src_sha frontend sdk staging obj candidate runtime
  src_sha="$(shasum -a 256 "${SRC}" | awk '{print $1}')"
  frontend="$(xcrun --find swift-frontend)"
  sdk="$(xcrun --show-sdk-path)"
  staging="$(mktemp -d "${TMP_DIR}/build-XXXXXX")"
  trap 'rm -rf "${staging}"' RETURN
  obj="${staging}/metal_host_async.o"
  candidate="${staging}/metal_host_async"
  runtime="$(cd "$(dirname "${frontend}")/.." && pwd)/lib/swift/macosx"

  TMPDIR="${TMP_DIR}/" CLANG_MODULE_CACHE_PATH="${CACHE_DIR}" \
    "${frontend}" -c -O -module-name metal_host_async \
    -sdk "${sdk}" -module-cache-path "${CACHE_DIR}" \
    -primary-file "${SRC}" -o "${obj}"

  xcrun clang "${obj}" -o "${candidate}" -isysroot "${sdk}" \
    -L"${runtime}" -L"${sdk}/usr/lib/swift" \
    -Wl,-rpath,/usr/lib/swift -lswiftCore \
    -framework AppKit -framework Foundation -framework Metal \
    -framework QuartzCore -framework CryptoKit

  chmod 755 "${candidate}"
  mv -f "${candidate}" "${BIN}"
  local bin_sha
  bin_sha="$(shasum -a 256 "${BIN}" | awk '{print $1}')"
  echo "source_sha256=${src_sha}"
  echo "binary_sha256=${bin_sha}"
}

if [[ "${1:-}" == "--stop-only" ]]; then
  verify_and_stop_old
  echo "status=stopped"
  exit 0
fi

if [[ "${1:-}" == "--build-only" ]]; then
  build_binary
  echo "status=built"
  exit 0
fi

verify_and_stop_old
BUILD_INFO="$(build_binary)"
SRC_SHA="$(awk -F= '$1=="source_sha256"{print $2}' <<<"${BUILD_INFO}")"
BIN_SHA="$(awk -F= '$1=="binary_sha256"{print $2}' <<<"${BUILD_INFO}")"

: > "${STDERR_LOG}"
nohup "${BIN}" "$@" >/dev/null 2>"${STDERR_LOG}" &
NEW_PID=$!
printf '%s\n' "${NEW_PID}" > "${PID_FILE}"

READY_LINE=""
for _ in {1..50}; do
  if ! kill -0 "${NEW_PID}" 2>/dev/null; then
    echo "[restart_metal_host_async] receiver exited before ready" >&2
    cat "${STDERR_LOG}" >&2
    rm -f "${PID_FILE}"
    exit 1
  fi
  READY_LINE="$(grep -m1 '^ready ' "${STDERR_LOG}" || true)"
  if [[ -n "${READY_LINE}" ]]; then
    break
  fi
  sleep 0.1
done

if [[ -z "${READY_LINE}" ]]; then
  echo "[restart_metal_host_async] timed out waiting for ready line" >&2
  cat "${STDERR_LOG}" >&2
  verify_and_stop_old
  exit 1
fi

echo "status=running"
echo "pid=${NEW_PID}"
echo "source_sha256=${SRC_SHA}"
echo "binary_sha256=${BIN_SHA}"
echo "ready_line=${READY_LINE}"
