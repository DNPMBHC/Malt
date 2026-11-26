#!/usr/bin/env python3
"""Check updater removal and observe a real packaged process before distribution."""

import argparse
import json
import pathlib
import os
import tempfile
import re
import subprocess
import time


SMOKE_ENV_KEY = "RUNTIME_DYLD_SMOKE_ONLY"
SMOKE_MARKER = "runtime-dyld-smoke:foundation-only"


DYLD_ERROR = re.compile(
    r"\bdyld\s*(?:\[\d+\]|:)|Library not loaded:|Library missing|"
    r"code signature[^\n]*(?:invalid|not valid)|different Team IDs",
    re.IGNORECASE,
)


def verify_updater_removed(app, executable):
    result = subprocess.run(
        ["otool", "-L", str(executable)], capture_output=True, text=True, check=True
    )
    linked = "sparkle.framework/" in result.stdout.lower()
    bundled = any(app.rglob("Sparkle.framework"))
    return {
        "loadCommandsChecked": True,
        "sparkleLinked": linked,
        "sparkleBundled": bundled,
        "passed": not linked and not bundled,
    }


def verify_smoke_entrypoint(executable):
    """Never start an older binary that could instantiate its normal application."""
    data = executable.read_bytes()
    present = SMOKE_ENV_KEY.encode() in data and SMOKE_MARKER.encode() in data
    return {"foundationEntryPointEmbedded": present, "passed": present}


def observe_launch(executable, log_path, seconds=4, environment=None, required_marker=None):
    process = None
    survived = False
    exit_code = None
    try:
        with log_path.open("wb") as log:
            process = subprocess.Popen([str(executable)], stdout=log, stderr=subprocess.STDOUT, env=environment)
            started = time.monotonic()
            deadline = started + seconds
            while time.monotonic() < deadline:
                exit_code = process.poll()
                if exit_code is not None:
                    break
                time.sleep(min(0.05, max(0, deadline - time.monotonic())))
            survived = process.poll() is None and time.monotonic() >= deadline
            exit_code = process.poll()
        observed = time.monotonic() - started
    finally:
        if process is not None:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            else:
                process.wait()
    log_text = log_path.read_text(errors="replace")
    dyld_errors = len(DYLD_ERROR.findall(log_text))
    marker_observed = required_marker is None or required_marker in log_text
    return {
        "requiredSurvivalSeconds": seconds,
        "observedSeconds": round(observed, 3),
        "survived": survived,
        "exitCodeDuringObservation": exit_code,
        "dyldErrorCount": dyld_errors,
        "requiredMarkerObserved": marker_observed,
        "passed": survived and dyld_errors == 0 and marker_observed,
    }


def isolated_launch_environment(user_data):
    """Select the Foundation-only entry point with disposable filesystem locations."""
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": str(user_data),
        "HOME": str(user_data),
        SMOKE_ENV_KEY: "1",
        "LANG": os.environ.get("LANG", "en_US.UTF-8"),
        "CFFIXED_USER_HOME": str(user_data),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--executable-name", required=True)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--isolated-user-data", action="store_true")
    args = parser.parse_args()
    executable = args.app / "Contents" / "MacOS" / args.executable_name
    args.output.parent.mkdir(parents=True, exist_ok=True)
    updater = verify_updater_removed(args.app, executable)
    entrypoint = verify_smoke_entrypoint(executable)
    report = {"updaterRemoval": updater, "entryPoint": entrypoint, "launch": None, "passed": False}
    if updater["passed"] and entrypoint["passed"]:
        with tempfile.TemporaryDirectory(prefix="dyld-smoke-user-") as directory:
            report["launch"] = observe_launch(
                executable, args.output.with_suffix(".log"),
                environment=isolated_launch_environment(directory), required_marker=SMOKE_MARKER,
            )
        report["temporaryFoundationHome"] = True
        report["foundationOnlySmoke"] = True
        report["scope"] = "Foundation entry point and dyld survival only; no SwiftUI, guest or game execution"
        report["passed"] = report["launch"]["passed"]
    args.output.write_text(json.dumps(report, indent=2) + chr(10))
    print(json.dumps(report))
    if not report["passed"]:
        raise SystemExit("error: packaged application failed updater removal, smoke entry point, or launch verification")


if __name__ == "__main__":
    main()
