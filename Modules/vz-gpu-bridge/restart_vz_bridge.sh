#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Owner: @DNPMBHC
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
action="restart"
case "${1:-}" in
    --build-only) action="build" ;;
    --stop-only) action="stop" ;;
    --clean-build) action="clean" ;;
esac
exec python3 -B "${WORKSPACE}/graphics-lab/vz_gpu_bench_runner.py" "${action}"
