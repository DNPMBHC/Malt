#!/usr/bin/env python3
"""Reproducible local gates; never starts a VM. Owner: @DNPMBHC."""
import hashlib
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
ROOT = EVIDENCE.parents[3]
PACKAGES = list(ROOT.glob("*/*/Package.swift"))
if len(PACKAGES) != 1:
    raise SystemExit("runtime_package_discovery_failed")
PACKAGE = PACKAGES[0].parent
REPO = PACKAGE.parent
RUNTIME = next(PACKAGE.glob("Sources/*/Runtime"))
TESTS = next(PACKAGE.glob("Tests/*"))
OWNED = sorted([p for base in (RUNTIME, TESTS) for pattern in ("GuestSurface*.swift", "UTMHeadless*.swift", "UTMGuestCommandBridge.swift",
                                                                   "UTMInteractiveHelperVerification*.swift", "UTMWindowsGuestProvider*.swift")
                for p in base.glob(pattern)])
REPLACEMENTS = sorted(((str(ROOT), "<workspace>"), (str(Path.home()), "<user-home>"),
                       (ROOT.name, "my-project"), (PACKAGE.name, "module-x"), (REPO.name, "demo-app")),
                      key=lambda item: len(item[0]), reverse=True)


def clean(text):
    for original, alias in REPLACEMENTS:
        text = re.sub(re.escape(original), lambda match: alias, text, flags=re.IGNORECASE)
    text = re.sub(r"/Users/[^\s`\"'<>]+", "<local-path>", text)
    text = re.sub(r"/Volumes/[^\s`\"'<>]+", "<EXTERNAL_VOLUME>", text)
    text = re.sub(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "<private-email>", text)
    return text


def fingerprint():
    result = subprocess.run(["rg", "--files", "--hidden", "-g", "*.swift", "-g", "!**/.build/**",
                             "-g", "!**/.git/**", "-g", "!**/build/**"],
                            cwd=REPO, capture_output=True, text=True, check=True)
    digest = hashlib.sha256()
    for relative in sorted(result.stdout.splitlines()):
        content = (REPO / relative).read_bytes()
        digest.update(relative.encode() + b"\0" + hashlib.sha256(content).digest())
    return digest.hexdigest()


def run(name, args, cwd=ROOT, timeout=600):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("DEMO_", "HOST_", "P5C_")) and "REAL_GUEST" not in key}
    start = time.monotonic()
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, timeout=timeout)
    output = clean(result.stdout + result.stderr)
    log = "Owner: @DNPMBHC\n" + output
    (EVIDENCE / (name + ".log")).write_text(log)
    record = {"exit_code": result.returncode, "passed": result.returncode == 0,
              "duration_seconds": round(time.monotonic() - start, 3), "log": name + ".log"}
    if name == "swift-test-final":
        matches = re.findall(r"Executed (\d+) tests, with (?:(\d+) tests skipped and )?(\d+) failures?", output)
        if matches:
            total, skipped, failed = matches[-1]
            record.update(total=int(total), skipped=int(skipped or 0), failed=int(failed),
                          passed_tests=int(total) - int(skipped or 0) - int(failed))
    print(json.dumps({"stage": name, **record}), flush=True)
    return record


def main():
    before = fingerprint()
    gates = {}
    gates["swift_test"] = run("swift-test-final", ["swift", "test", "--package-path", str(PACKAGE),
        "--scratch-path", "/tmp/guest-shell-p5c-build", "--disable-automatic-resolution"])
    gates["swiftlint"] = run("swiftlint-final", [str(ROOT / "handoff/task-07/.tools/swiftlint"),
        "lint", "--strict", "--quiet"], cwd=REPO)
    gates["format_owned"] = run("format-owned-final", ["xcrun", "swift-format", "lint", "--strict",
        "--configuration", str(EVIDENCE / "swift-format-configuration.json"), *map(str, OWNED)])
    gates["format_required"] = run("format-required-final", ["python3", "-B",
        str(ROOT / "handoff/task-07/format_check.py"), "--output", str(EVIDENCE / "format-contract")])
    gates["anticheat"] = run("anticheat-final", ["python3", "-B",
        str(ROOT / "handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py"), "--self-test",
        "--output", str(EVIDENCE / "anticheat-hardening.json")])
    gates["lease_self_test"] = run("lease-self-test", ["python3", "-B", str(EVIDENCE / "verify_vm_lease.py"), "--self-test"])
    after = fingerprint()
    report = {"owner": "@DNPMBHC", "captured_at_utc": datetime.now(timezone.utc).isoformat(),
              "schema_version": 1, "gates": gates, "inputs_stable": before == after,
              "input_fingerprint_before": before, "input_fingerprint_after": after,
              "input_fingerprint_scope": "all_repository_swift_inputs",
              "owned_swift_files_checked": len(OWNED), "real_guest_executed": False,
              "all_local_gates_passed": before == after and all(gate["passed"] for gate in gates.values())}
    (EVIDENCE / "local-validation.json").write_text(json.dumps(report, indent=2) + "\n")
    for path in EVIDENCE.rglob("*"):
        if path.is_file() and path.suffix in (".json", ".md", ".log"):
            content = clean(path.read_text())
            if path.suffix == ".json":
                try:
                    data = json.loads(content)
                    if isinstance(data, dict):
                        data["owner"] = "@DNPMBHC"
                        content = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
                except ValueError:
                    pass
            if path.suffix == ".log" and "@DNPMBHC" not in content:
                content = "Owner: @DNPMBHC\n" + content
            path.write_text(content)
    print(json.dumps({"all_local_gates_passed": report["all_local_gates_passed"], "inputs_stable": before == after}))
    return 0 if report["all_local_gates_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
