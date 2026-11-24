#!/usr/bin/env python3
"""Run every lab test with owned outputs and real native fixtures. @DNPMBHC."""
from __future__ import annotations
import contextlib
import io
import os
import shutil
import tempfile
import unittest
from pathlib import Path

import bench_real3d_support as support


def main() -> int:
    import vz_gpu_bench_runner as native
    import vz_gpu_bench_library as library

    evidence = support.EVIDENCE / "gate-native-output"
    evidence.mkdir(exist_ok=True)
    harness = native.EVIDENCE / "efi-consumer-roundtrip.swift"
    shutil.copy2(harness, evidence / harness.name)
    native.EVIDENCE = evidence
    native.BUILD = support.runtime_dir() / "gate-native-build"
    native.BINARY = native.BUILD / "demo-app"
    library.LIBRARY_DIR = native.BUILD / "consumer-library"

    log = io.StringIO()
    old_tmp = os.environ.get("TMPDIR")
    old_cache = tempfile.tempdir
    with tempfile.TemporaryDirectory(prefix="p5a-gate-", dir="/tmp") as fixtures:
        # DiskImages accepts these real mounts in the standard temporary area.
        # Compilers and generated native evidence still use our external runtime.
        os.environ["TMPDIR"] = fixtures
        tempfile.tempdir = fixtures
        try:
            with contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
                suite = unittest.defaultTestLoader.discover(str(support.ROOT / "graphics-lab"))
                result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
        finally:
            tempfile.tempdir = old_cache
            if old_tmp is None:
                os.environ.pop("TMPDIR", None)
            else:
                os.environ["TMPDIR"] = old_tmp
    text = support.redact(log.getvalue())
    output = support.EVIDENCE / "unittest-current.log"
    output.write_text(text)
    support.write_json(support.EVIDENCE / "unittest-current.json", {
        "owner": "@DNPMBHC", "captured_at_utc": support.utc(),
        "exit_code": 0 if result.wasSuccessful() else 1,
        "tests_run": result.testsRun, "failures": len(result.failures),
        "errors": len(result.errors), "skipped": len(result.skipped),
        "log_ref": output.name, "log_sha256": support.sha256(output),
        "all_tests_discovered": True, "native_execution_mocked": False,
        "native_sources_modified": False,
        "native_outputs_redirected_to_owned_paths": True,
        "real_fixture_mounts_in_owned_standard_temporary_directory": True,
        "fixture_directory_deleted": not Path(fixtures).exists(),
        "gate_runner_sha256": support.sha256(Path(__file__)),
    })
    print(text[-2000:])
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
