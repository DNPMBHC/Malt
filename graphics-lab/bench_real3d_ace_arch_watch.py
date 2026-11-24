#!/usr/bin/env python3
"""Deadline-bounded, read-only PE inventory. Owner: @DNPMBHC.

A certificate table is not proof of a trusted signature. Windows trust verification
is reported separately. This script does not install, register or load drivers.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import multiprocessing
import os
import re
import shutil
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PE_MACHINE_NAMES = {0x014C: "I386", 0x01C4: "ARMNT", 0x8664: "AMD64", 0xAA64: "ARM64", 0xA641: "ARM64EC", 0xA64E: "ARM64X"}
DEFAULT_EXTENSIONS = (".sys",)
ACE_NAME_HINTS = ("ace", "anti", "guard", "tesafe", "tenprotect")


def redact_path_text(text: str) -> str:
    text = text.replace(str(Path.home()), "<home>")
    text = re.sub(r"(?:[A-Z]:)?[/\\]Users[/\\][^\s\"'<>]+", "<home>", text)
    text = re.sub(r"(?:[A-Z]:)?[/\\]Volumes[/\\][^\s\"'<>]+", "<EXTERNAL_VOLUME>", text)
    return text


def _remaining(deadline: float) -> float:
    left = deadline - time.monotonic()
    if left <= 0:
        raise TimeoutError("Scan deadline reached")
    return left


def sha256_file(path: Path, deadline: float = float("inf")) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            _remaining(deadline)
            chunk = handle.read(1 << 16)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def parse_pe_header(path: Path) -> dict[str, Any]:
    result = {"pe_valid": False, "pe_machine": None, "architecture": "UNKNOWN", "pe_format": None,
              "has_embedded_signature": False, "embedded_signature_size": 0,
              "certificate_table_status": "absent", "embedded_signature_trust": "not_verified"}
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            dos = handle.read(64)
            if len(dos) < 64 or dos[:2] != b"MZ":
                return result
            offset = struct.unpack_from("<I", dos, 60)[0]
            if offset < 64 or offset + 24 > size:
                return result
            handle.seek(offset)
            coff = handle.read(24)
            if len(coff) != 24 or coff[:4] != b"PE\0\0":
                return result
            machine, _n, _ts, _syms, _count, opt_size, _chars = struct.unpack_from("<HHIIIHH", coff, 4)
            if opt_size < 2 or offset + 24 + opt_size > size:
                return result
            opt = handle.read(opt_size)
            magic = struct.unpack_from("<H", opt, 0)[0]
            if magic not in (0x10B, 0x20B):
                return result
            result.update(pe_valid=True, pe_machine=f"0x{machine:04x}",
                          architecture=PE_MACHINE_NAMES.get(machine, "UNKNOWN"),
                          pe_format="PE32+" if magic == 0x20B else "PE32")
            directories = 112 if magic == 0x20B else 96
            if len(opt) >= directories + 40 and struct.unpack_from("<I", opt, directories - 4)[0] > 4:
                cert_offset, cert_size = struct.unpack_from("<II", opt, directories + 32)
                if cert_offset or cert_size:
                    result["embedded_signature_size"] = cert_size
                    result["certificate_table_status"] = "invalid_extent"
                    if cert_offset % 8 == 0 and cert_size >= 8 and cert_offset >= offset + 24 + opt_size and cert_offset + cert_size <= size:
                        handle.seek(cert_offset)
                        length, revision, cert_type = struct.unpack("<IHH", handle.read(8))
                        if 8 <= length <= cert_size and revision == 0x0200 and cert_type == 0x0002:
                            result["has_embedded_signature"] = True
                            result["certificate_table_status"] = "present_not_verified"
    except (OSError, struct.error):
        result["read_error"] = True
    return result


def matches_ace_hint(rel_path: str) -> bool:
    return any(hint in rel_path.lower() for hint in ACE_NAME_HINTS)


def verify_windows(path: Path, deadline: float) -> dict:
    if os.name != "nt":
        return {"status": "not_verified_platform", "method": "Windows Authenticode trust", "file_version": None}
    shell = shutil.which("powershell.exe")
    if not shell:
        return {"status": "verifier_unavailable", "file_version": None}
    env = os.environ.copy()
    env["ACE_SCAN_FILE"] = str(path)
    source = "$ErrorActionPreference='Stop'; $s=Get-AuthenticodeSignature -LiteralPath $env:ACE_SCAN_FILE; $v=[Diagnostics.FileVersionInfo]::GetVersionInfo($env:ACE_SCAN_FILE); @{status=[string]$s.Status;signature_type=[string]$s.SignatureType;file_version=$v.FileVersion;signer_thumbprint=if($s.SignerCertificate){$s.SignerCertificate.Thumbprint}else{$null};signer_alias=if($s.SignerCertificate){'publisher-x'}else{$null}}|ConvertTo-Json -Compress"
    try:
        r = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-Command", source], env=env,
                           capture_output=True, text=True, timeout=_remaining(deadline))
        if r.returncode:
            return {"status": "verification_error", "native_exit_code": r.returncode, "file_version": None}
        value = json.loads(r.stdout.lstrip("\ufeff"))
        value["method"] = "Get-AuthenticodeSignature"
        return value
    except subprocess.TimeoutExpired:
        raise TimeoutError("Signature verification reached scan deadline") from None
    except (OSError, ValueError):
        return {"status": "verification_error", "file_version": None}


def scan_directory(root: Path, extensions: tuple[str, ...] = DEFAULT_EXTENSIONS,
                   only_ace_hints: bool = False, compute_sha256: bool = True,
                   max_files: int = 2000, budget_seconds: float = 30,
                   verify_signatures: bool = True) -> dict:
    if budget_seconds <= 0 or max_files < 1:
        raise ValueError("Positive deadline and file limit required")
    started = time.monotonic()
    deadline = started + budget_seconds
    root = root.resolve()
    ext_set = {e.lower() if e.startswith(".") else "." + e.lower() for e in extensions}
    records, errors = [], []
    reasons = set()
    base = root.parent if root.is_file() else root
    if not root.exists():
        reasons.add("target_missing")
    def candidates():
        if root.is_file():
            if root.suffix.lower() in ext_set:
                yield root
            return
        def walk_error(_error):
            reasons.add("enumeration_error")
        for dp, dirs, names in os.walk(root, followlinks=False, onerror=walk_error):
            _remaining(deadline)
            dirs.sort()
            for name in sorted(names):
                _remaining(deadline)
                p = Path(dp) / name
                if p.suffix.lower() in ext_set and (not only_ace_hints or matches_ace_hint(str(p.relative_to(base)))):
                    yield p
    try:
        for path in candidates():
            if len(records) >= max_files:
                reasons.add("file_limit")
                break
            alias = f"artifact-{len(records):04d}{path.suffix.lower()}"
            if path.is_symlink():
                reasons.add("symlink_skipped")
                continue
            try:
                _remaining(deadline)
                item = {"relative_path": alias, "extension": path.suffix.lower(), "size_bytes": path.stat().st_size,
                        "matches_ace_hint": matches_ace_hint(str(path.relative_to(base))), **parse_pe_header(path)}
                if compute_sha256:
                    item["sha256"] = sha256_file(path, deadline)
                item["signature"] = verify_windows(path, deadline) if verify_signatures else {"status": "not_requested", "file_version": None}
                records.append(item)
                if item.get("read_error"):
                    reasons.add("file_read_error")
                if item["extension"] == ".sys" and not item["pe_valid"]:
                    reasons.add("unparsed_sys")
            except TimeoutError:
                raise
            except OSError:
                reasons.add("file_read_error")
                errors.append({"artifact_alias": alias, "status": "unreadable"})
    except TimeoutError:
        reasons.add("deadline")
    drivers = [f for f in records if f["extension"] == ".sys" and f["pe_valid"]]
    counts = {}
    for f in drivers:
        counts[f["architecture"]] = counts.get(f["architecture"], 0) + 1
    arm64 = [f["relative_path"] for f in drivers if f["pe_machine"] == "0xaa64"]
    amd64 = [f["relative_path"] for f in drivers if f["pe_machine"] == "0x8664"]
    if arm64:
        verdict = "native_arm64_sys_detected"
    elif reasons:
        verdict = "incomplete_inventory_no_arm64_observed"
    elif amd64 and len(amd64) == len(drivers):
        verdict = "amd64_only_no_arm64_sys"
    else:
        verdict = "no_arm64_sys_observed_in_scanned_scope"
    return {"schema_version": 2, "owner": "@DNPMBHC", "captured_at_utc": datetime.now(timezone.utc).isoformat(),
            "elapsed_seconds": round(time.monotonic()-started,4), "budget_seconds": budget_seconds,
            "extensions": sorted(ext_set), "only_ace_hints": only_ace_hints, "truncated": bool(reasons),
            "inventory_complete": not reasons, "incomplete_reasons": sorted(reasons),
            "total_files_scanned": len(records), "sys_driver_count": len(drivers), "sys_architecture_counts": counts,
            "has_native_arm64_driver": bool(arm64), "arm64_driver_paths": arm64, "amd64_driver_paths": amd64,
            "verdict": verdict, "scope": "local inspected distribution only; ARM64 presence does not prove vendor support or successful load",
            "files": records, "errors": errors}


def _scan_worker(connection, kwargs):
    try:
        connection.send(scan_directory(**kwargs))
    except Exception as error:
        connection.send({"worker_error": type(error).__name__})
    finally:
        connection.close()


def bounded_scan_directory(**kwargs):
    """CLI wall-clock supervisor also covers a blocking filesystem operation."""
    budget = kwargs.get("budget_seconds", 30)
    if budget <= 0:
        raise ValueError("Positive deadline required")
    started = time.monotonic()
    context = multiprocessing.get_context("spawn")
    receiver, sender = context.Pipe(duplex=False)
    process = context.Process(target=_scan_worker, args=(sender, kwargs), daemon=True)
    process.start()
    sender.close()
    report = None
    try:
        remaining = max(0, budget - 0.2 - (time.monotonic() - started))
        if receiver.poll(remaining):
            try:
                report = receiver.recv()
            except EOFError:
                pass
    finally:
        receiver.close()
        if process.is_alive():
            process.terminate()
        process.join(timeout=0.2)
    if report is None or "worker_error" in report:
        reason = "deadline" if report is None else "worker_error"
        report = {"schema_version": 2, "owner": "@DNPMBHC",
                  "captured_at_utc": datetime.now(timezone.utc).isoformat(),
                  "inventory_complete": False, "truncated": True,
                  "incomplete_reasons": [reason], "files": [], "errors": [],
                  "total_files_scanned": 0, "sys_driver_count": 0,
                  "sys_architecture_counts": {}, "has_native_arm64_driver": False,
                  "arm64_driver_paths": [], "amd64_driver_paths": [],
                  "verdict": "incomplete_inventory_no_arm64_observed",
                  "scope": "Worker did not return a complete report; no architecture absence claim is valid"}
    report["elapsed_seconds"] = round(time.monotonic() - started, 4)
    report["budget_seconds"] = budget
    report["deadline_method"] = "parent process wall-clock supervisor; worker termination on deadline"
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Read-only ACE architecture and Windows signature watcher")
    parser.add_argument("target", type=Path)
    parser.add_argument("--extensions", default=".sys")
    parser.add_argument("--only-ace-hints", action="store_true")
    parser.add_argument("--no-sha256", action="store_true")
    parser.add_argument("--no-signature-check", action="store_true")
    parser.add_argument("--budget-seconds", type=float, default=30)
    parser.add_argument("--max-files", type=int, default=2000)
    parser.add_argument("--json-out", type=Path)
    args = parser.parse_args(argv)
    report = bounded_scan_directory(root=args.target,
                                    extensions=tuple(x.strip() for x in args.extensions.split(",") if x.strip()),
                                    only_ace_hints=args.only_ace_hints, compute_sha256=not args.no_sha256,
                                    max_files=args.max_files, budget_seconds=args.budget_seconds,
                                    verify_signatures=not args.no_signature_check)
    rendered = redact_path_text(json.dumps(report, indent=2)) + "\n"
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0 if report["inventory_complete"] else 2

if __name__ == "__main__":
    raise SystemExit(main())
