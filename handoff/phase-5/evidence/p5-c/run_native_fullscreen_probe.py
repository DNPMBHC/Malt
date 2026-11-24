#!/usr/bin/env python3
"""Actual native window/Metal diagnostics; no Guest or pointer capture. Owner: @DNPMBHC."""
import importlib.util
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("runtime_binary_tools", EVIDENCE / "run_runtime_binary_roundtrip.py")
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)

if __name__ == "__main__":
    raise SystemExit(tools.main(client_name="native-fullscreen-probe.swift", result_name="native-fullscreen-probe",
                               visible_window=True))
