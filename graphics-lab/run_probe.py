#!/usr/bin/env python3
"""Measure end-to-end process-start-to-D3D-ready time without storing command lines."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path, help="optional run-timing JSON output")
    parser.add_argument("command", nargs=argparse.REMAINDER,
                        help="executable and arguments after --; no shell expansion is used")
    args = parser.parse_args()
    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        parser.error("provide a command after --")

    launched = time.perf_counter()
    try:
        child = subprocess.Popen(command, stderr=subprocess.PIPE, text=True, bufsize=1)
    except OSError as exc:
        parser.exit(2, f"run_probe: unable to start benchmark process: {exc}\n")

    internal_ready_ms: float | None = None
    ready_elapsed_ms: float | None = None
    assert child.stderr is not None
    for line in child.stderr:
        if line.startswith("probe_ready_ms="):
            try:
                internal_ready_ms = float(line.partition("=")[2].strip())
                ready_elapsed_ms = (time.perf_counter() - launched) * 1000
            except ValueError:
                pass
        else:
            sys.stderr.write(line)
            sys.stderr.flush()
    exit_code = child.wait()
    record = {
        "schema_version": 1,
        "ready": ready_elapsed_ms is not None,
        "process_start_to_d3d_ready_ms": ready_elapsed_ms,
        "probe_internal_initialization_ms": internal_ready_ms,
        "exit_code": exit_code,
    }
    encoded = json.dumps(record, indent=2, sort_keys=True) + "\n"
    if args.json:
        args.json.write_text(encoded, encoding="utf-8")
    sys.stdout.write(encoded)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
