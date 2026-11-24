#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${SCRIPT_DIR}/build"
BIN="${OUT_DIR}/metal_host"
PID_FILE="${OUT_DIR}/metal_host.pid"
STDERR_LOG="${OUT_DIR}/metal_host.stderr.log"
mkdir -p "${OUT_DIR}"

# Building uses an atomic binary replacement and leaves receiver processes alone.
if [[ "${1:-}" == "--build-only" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "[restart_metal_host] --build-only accepts no receiver arguments" >&2
    exit 2
  fi
  "${SCRIPT_DIR}/build_metal_host.sh"
  exit 0
fi

process_state() {
  python3 - "$1" "${BIN}" <<'PYSTATE'
import ctypes
import ctypes.util
import os
from pathlib import Path
import sys

value = sys.argv[1]
if not value.isdecimal() or int(value) <= 0:
    print("invalid-pid")
    raise SystemExit(0)
pid = int(value)
try:
    os.kill(pid, 0)
except ProcessLookupError:
    print("gone")
    raise SystemExit(0)
except PermissionError:
    print("other-process")
    raise SystemExit(0)
expected = Path(sys.argv[2]).resolve()
if sys.platform == "darwin":
    library = ctypes.CDLL(ctypes.util.find_library("proc"))
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    count = library.proc_pidpath(pid, buffer, len(buffer))
    executable = buffer.value.decode() if count > 0 else ""
else:
    try:
        executable = os.readlink(Path(os.sep).joinpath("proc", str(pid), "exe"))
        executable = executable.removesuffix(" (deleted)")
    except OSError:
        executable = ""
print("project-host" if executable and Path(executable).resolve() == expected else "other-process")
PYSTATE
}

stop_project_host() {
  local target_pid="$1"
  local state
  state="$(process_state "${target_pid}")"
  case "${state}" in
    gone) return 0 ;;
    project-host) ;;
    *)
      echo "[restart_metal_host] refusing to stop an unverified receiver PID" >&2
      return 1
      ;;
  esac
  echo "[restart_metal_host] stopping verified receiver with SIGTERM" >&2
  if ! kill -TERM "${target_pid}" 2>/dev/null; then
    [[ "$(process_state "${target_pid}")" == "gone" ]] && return 0
    return 1
  fi
  for _ in {1..50}; do
    if ! kill -0 "${target_pid}" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "[restart_metal_host] receiver did not exit after SIGTERM; keeping the binary intact" >&2
  return 1
}

if [[ -f "${PID_FILE}" ]]; then
  OLD_PID="$(cat "${PID_FILE}")"
  stop_project_host "${OLD_PID}"
  rm -f "${PID_FILE}"
fi

BUILD_REPORT="$("${SCRIPT_DIR}/build_metal_host.sh")"
SRC_SHA="$(awk -F= '$1 == "source_sha256" {print $2}' <<<"${BUILD_REPORT}")"
BIN_SHA="$(awk -F= '$1 == "binary_sha256" {print $2}' <<<"${BUILD_REPORT}")"

cd "${WORKSPACE_ROOT}"
: > "${STDERR_LOG}"
nohup "${BIN}" "$@" >/dev/null 2>"${STDERR_LOG}" &
NEW_PID=$!
printf '%s\n' "${NEW_PID}" > "${PID_FILE}"

READY_LINE=""
for _ in {1..50}; do
  if ! kill -0 "${NEW_PID}" 2>/dev/null; then
    echo "[restart_metal_host] receiver exited before becoming ready" >&2
    cat "${STDERR_LOG}" >&2
    rm -f "${PID_FILE}"
    exit 1
  fi
  READY_LINE="$(python3 - "${STDERR_LOG}" <<'PYREADY'
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text(errors="replace").splitlines():
    if line.startswith("ready "):
        print(line)
        break
PYREADY
)"
  if [[ -n "${READY_LINE}" ]]; then
    break
  fi
  sleep 0.1
 done

if [[ -z "${READY_LINE}" ]]; then
  echo "[restart_metal_host] timed out waiting for ready marker" >&2
  cat "${STDERR_LOG}" >&2
  if stop_project_host "${NEW_PID}"; then
    rm -f "${PID_FILE}"
  fi
  exit 1
fi

cat <<EOF
status=running
pid=${NEW_PID}
source_sha256=${SRC_SHA}
binary_sha256=${BIN_SHA}
${READY_LINE}
EOF
