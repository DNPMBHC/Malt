#!/usr/bin/env python3
"""Static anti-cheat abuse hardening and zero-cheat-primitive gate for Phase 3-B."""

import argparse
import copy
import hashlib
import json
import pathlib
import plistlib
import re
import sys


FORBIDDEN_ENTITLEMENTS = (
    "com.apple.security.get-task-allow",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.allow-jit",
)

FORBIDDEN_PRIMITIVE_RULES = {
    "memory_tampering_or_injection": (
        r"\btask_for_pid\b",
        r"\bmach_vm_read\b",
        r"\bmach_vm_write\b",
        r"\bmach_vm_remap\b",
        r"\bptrace\s*\(",
        r"\bPROCESS_VM_WRITE\b",
        r"\bPROCESS_VM_OPERATION\b",
        r"\bWriteProcessMemory\b",
        r"\bReadProcessMemory\b",
        r"\bCreateRemoteThread\b",
        r"\bNtWriteVirtualMemory\b",
        r"\bNtReadVirtualMemory\b",
        r"\bSetWindowsHookEx[AW]?\b",
        r"\bDYLD_INSERT_LIBRARIES\b",
    ),
    "virtualization_or_hwid_spoofing": (
        r"kvm\s*=\s*off",
        r"\bhv_vendor_id\b",
        r"hypervisor\.cpuid\.v0",
        r"\bsmbios_spoof\b",
        r"\bhwid_spoof\b",
    ),
    "debug_port_or_macro_injection": (
        r"(?<![A-Za-z0-9_])-qmp(?![A-Za-z0-9_])",
        r"(?<![A-Za-z0-9_])-gdb(?![A-Za-z0-9_])",
        r"\bCGEventCreateKeyboardEvent\b",
        r"\bCGEventCreateMouseEvent\b",
        r"\bCGEventPost\b",
        r"\bSendInput\s*\(",
        r"\bmouse_event\s*\(",
        r"\bkeybd_event\s*\(",
    ),
}

EXPECTED_TARGETS = ("Whisky", "WhiskyCmd", "WhiskyThumbnail")


def collect_workspace_snapshot(root: pathlib.Path) -> dict:
    pbxproj_path = root / "Whisky/Whisky.xcodeproj/project.pbxproj"
    entitlement_paths = sorted((root / "Whisky").rglob("*.entitlements"))

    prod_roots = [
        root / "Whisky/Whisky",
        root / "Whisky/WhiskyCmd",
        root / "Whisky/WhiskyThumbnail",
        root / "Whisky/WhiskyKit/Sources",
        root / "Whisky/Modules/module-a/WindowsProbe/client",
        root / "Whisky/Modules/module-a/WindowsProbe/driver",
        root / "Whisky/Modules/module-a/WindowsProbe/shared",
        root / "graphics-lab",
    ]
    source_files = {}
    for base in prod_roots:
        if not base.exists():
            continue
        for f in sorted(base.rglob("*")):
            if not f.is_file():
                continue
            if any(part in {".build", "build", "DerivedData", "__pycache__"} for part in f.parts):
                continue
            if f.suffix not in {".swift", ".c", ".h", ".m", ".mm"}:
                continue
            if f.name.startswith("test_") or "Tests" in f.parts:
                continue
            rel = "<workspace>/" + str(f.relative_to(root))
            source_files[rel] = f.read_text(encoding="utf-8")

    entitlements = {}
    for ep in entitlement_paths:
        rel = "<workspace>/" + str(ep.relative_to(root))
        entitlements[rel] = plistlib.loads(ep.read_bytes())

    return {
        "pbxproj_path": "<workspace>/Whisky/Whisky.xcodeproj/project.pbxproj",
        "pbxproj_text": pbxproj_path.read_text(encoding="utf-8"),
        "entitlements": entitlements,
        "sources": source_files,
    }


def audit_snapshot(snapshot: dict) -> dict:
    pbx = snapshot["pbxproj_text"]

    # 1. Parse target build configurations in project.pbxproj
    config_blocks = re.findall(
        r"([0-9A-F]{24})\s*/\*\s*(Debug|Release)\s*\*/\s*=\s*\{\s*isa\s*=\s*XCBuildConfiguration;\s*buildSettings\s*=\s*\{(.*?)\};\s*name\s*=\s*\2;\s*\};",
        pbx,
        flags=re.S,
    )
    target_configs = {}
    for cfg_id, cfg_name, body in config_blocks:
        bundle_match = re.search(r"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;\s]+)\s*;", body)
        if not bundle_match:
            continue
        bundle_id = bundle_match.group(1)
        target_name = bundle_id.split(".")[-1]
        hardened = bool(re.search(r"ENABLE_HARDENED_RUNTIME\s*=\s*YES\s*;", body))
        target_configs.setdefault(target_name, {})[cfg_name] = {
            "config_id": cfg_id,
            "bundle_id": bundle_id,
            "hardened_runtime_enabled": hardened,
        }

    for target in EXPECTED_TARGETS:
        if target not in target_configs:
            raise ValueError(f"missing target in pbxproj: {target}")
        for mode in ("Release", "Debug"):
            if mode not in target_configs[target]:
                raise ValueError(f"missing {mode} configuration for {target}")
            if not target_configs[target][mode]["hardened_runtime_enabled"]:
                raise ValueError(f"{target} ({mode}) must enable ENABLE_HARDENED_RUNTIME = YES")

    # 2. Audit entitlements files
    entitlement_summary = {}
    for rel_path, plist_data in snapshot["entitlements"].items():
        if not isinstance(plist_data, dict):
            raise ValueError(f"{rel_path}: entitlements root must be a dict")
        for forbidden_key in FORBIDDEN_ENTITLEMENTS:
            if plist_data.get(forbidden_key) is True:
                raise ValueError(f"{rel_path}: forbidden entitlement enabled: {forbidden_key}")
        entitlement_summary[rel_path] = {
            "allowed_keys": sorted(k for k, v in plist_data.items() if v is True),
            "forbidden_keys_present": [],
        }

    # 3. Audit production sources for forbidden cheat/spoofing/injection primitives
    violations = []
    for rel_path, content in snapshot["sources"].items():
        for category, patterns in FORBIDDEN_PRIMITIVE_RULES.items():
            for pat in patterns:
                match = re.search(pat, content)
                if match:
                    violations.append({
                        "file": rel_path,
                        "category": category,
                        "pattern": pat,
                        "matched": match.group(0),
                    })
    if violations:
        first = violations[0]
        raise ValueError(
            f"forbidden primitive in {first['file']} ({first['category']}): {first['matched']}"
        )

    source_hashes = {
        rel: hashlib.sha256(text.encode("utf-8")).hexdigest()
        for rel, text in sorted(snapshot["sources"].items())
    }

    return {
        "schema_version": "1.0.0",
        "gate_id": "phase-3-b-anticheat-abuse-hardening-audit",
        "result": "passed",
        "targets_verified": target_configs,
        "entitlements_verified": entitlement_summary,
        "production_source_count": len(snapshot["sources"]),
        "production_source_fingerprint_sha256": hashlib.sha256(
            json.dumps(source_hashes, sort_keys=True).encode("utf-8")
        ).hexdigest(),
        "forbidden_primitive_categories_checked": {
            cat: len(pats) for cat, pats in FORBIDDEN_PRIMITIVE_RULES.items()
        },
        "forbidden_entitlements_checked": list(FORBIDDEN_ENTITLEMENTS),
        "violations": [],
    }


def run_self_test(base_snapshot: dict) -> int:
    mutations = []

    # 1. Forbidden get-task-allow entitlement
    m1 = copy.deepcopy(base_snapshot)
    first_ent = next(iter(m1["entitlements"]))
    m1["entitlements"][first_ent]["com.apple.security.get-task-allow"] = True
    mutations.append(("reject_get_task_allow_entitlement", m1))

    # 2. Forbidden allow-unsigned-executable-memory entitlement
    m2 = copy.deepcopy(base_snapshot)
    m2["entitlements"][first_ent]["com.apple.security.cs.allow-unsigned-executable-memory"] = True
    mutations.append(("reject_unsigned_executable_memory_entitlement", m2))

    # 3. Disabled Hardened Runtime in Release
    m3 = copy.deepcopy(base_snapshot)
    m3["pbxproj_text"] = m3["pbxproj_text"].replace(
        "ENABLE_HARDENED_RUNTIME = YES;", "ENABLE_HARDENED_RUNTIME = NO;", 1
    )
    mutations.append(("reject_disabled_hardened_runtime", m3))

    # 4. Forbidden memory tampering API
    m4 = copy.deepcopy(base_snapshot)
    first_src = next(iter(m4["sources"]))
    m4["sources"][first_src] += "\n// injected test: WriteProcessMemory(hProc, addr, buf, sz, NULL);\n"
    mutations.append(("reject_memory_write_primitive", m4))

    # 5. Forbidden virtualization hiding parameter
    m5 = copy.deepcopy(base_snapshot)
    m5["sources"][first_src] += "\n// injected test: -cpu host,kvm=off,hv_vendor_id=GenuineIntel\n"
    mutations.append(("reject_hypervisor_hiding_primitive", m5))

    # 6. Forbidden synthetic macro injection API
    m6 = copy.deepcopy(base_snapshot)
    m6["sources"][first_src] += "\n// injected test: CGEventPost(kCGHIDEventTap, evt)\n"
    mutations.append(("reject_macro_injection_primitive", m6))

    for name, mutated in mutations:
        try:
            audit_snapshot(mutated)
        except ValueError:
            continue
        raise ValueError(f"self-test failed to reject mutation: {name}")

    return len(mutations)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--output", type=pathlib.Path, default=None)
    args = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parents[4]
    snapshot = collect_workspace_snapshot(root)
    report = audit_snapshot(snapshot)
    if args.self_test:
        report["negative_self_tests_passed"] = run_self_test(snapshot)

    serialized = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if any(tok in serialized for tok in ("/" + "Users" + "/", "/" + "home" + "/")):
        raise ValueError("private path leaked in hardening audit report")

    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(serialized, encoding="utf-8")

    print(json.dumps({
        "result": report["result"],
        "production_source_count": report["production_source_count"],
        "negative_self_tests_passed": report.get("negative_self_tests_passed", 0),
    }, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Hardening audit failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
