#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/metal_host.swift"
OUT_DIR="${SCRIPT_DIR}/build"
BIN="${OUT_DIR}/metal_host"
PID_FILE="${OUT_DIR}/metal_host.pid"
STDERR_LOG="${OUT_DIR}/metal_host.stderr.log"

mkdir -p "${OUT_DIR}"

echo "[restart_metal_host] compiling metal_host.swift..." >&2
swiftc -O "${SRC}" \
  -framework AppKit -framework Metal -framework MetalFX -framework QuartzCore \
  -o "${BIN}"

SRC_SHA="$(shasum -a 256 "${SRC}" | awk '{print $1}')"
BIN_SHA="$(shasum -a 256 "${BIN}" | awk '{print $1}')"

if [[ -f "${PID_FILE}" ]]; then
  OLD_PID="$(cat "${PID_FILE}" || true)"
  if [[ -n "${OLD_PID}" ]] && kill -0 "${OLD_PID}" 2>/dev/null; then
    echo "[restart_metal_host] stopping previous pid=${OLD_PID}..." >&2
    kill "${OLD_PID}" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "${OLD_PID}" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "${OLD_PID}" 2>/dev/null || true
  fi
  rm -f "${PID_FILE}"
fi

pkill -f "${BIN}" 2>/dev/null || true
sleep 0.2

if [[ "${1:-}" == "--build-only" ]]; then
  cat <<EOF
status=built
source_sha256=${SRC_SHA}
binary_sha256=${BIN_SHA}
EOF
  exit 0
fi

: > "${STDERR_LOG}"
nohup "${BIN}" "$@" >/dev/null 2>"${STDERR_LOG}" &
NEW_PID=$!
echo "${NEW_PID}" > "${PID_FILE}"

READY_LINE=""
for _ in {1..50}; do
  if ! kill -0 "${NEW_PID}" 2>/dev/null; then
    echo "[restart_metal_host] process exited early:" >&2
    cat "${STDERR_LOG}" >&2
    exit 1
  fi
  if grep -q '^ready ' "${STDERR_LOG}" 2>/dev/null; then
    READY_LINE="$(grep '^ready ' "${STDERR_LOG}" | head -n 1)"
    break
  fi
  sleep 0.1
done

if [[ -z "${READY_LINE}" ]]; then
  echo "[restart_metal_host] timed out waiting for ready marker" >&2
  cat "${STDERR_LOG}" >&2
  kill "${NEW_PID}" 2>/dev/null || true
  exit 1
fi

cat <<EOF
status=running
pid=${NEW_PID}
source_sha256=${SRC_SHA}
binary_sha256=${BIN_SHA}
${READY_LINE}
EOF
