#!/usr/bin/env python3
"""Validate isolated B2 observations and reject privacy leaks in exported text.

Examples, from the evidence directory:
  python3 b2-evidence-tools.py validate --self-test
  python3 b2-evidence-tools.py scan report.json notes.md --recursive

Private comparison tokens are discovered at runtime. Additional comparison
tokens can be supplied as a JSON string array in B2_PRIVATE_TOKENS. Values,
original filenames and host paths are never printed by this program.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


HERE = Path(__file__).resolve().parent
TEXT_SUFFIXES = {".json", ".md", ".txt", ".log", ".csv", ".yaml", ".yml", ".xml", ".ps1", ".py"}
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
UUID = re.compile(r"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b", re.I)
UNIX_PRIVATE_PATH = re.compile(r"(?<![A-Za-z0-9])/(?:Users|home|Volumes|mnt|media)/(?:[^\s\"'<>`]+)", re.I)
WINDOWS_PATH = re.compile(r"(?<![A-Za-z0-9])[A-Za-z]:[\\/](?:[^\s\"'<>`]+)")
UNC_PATH = re.compile(r"\\\\[\w.-]+\\[\w .-]+", re.UNICODE)
IPV4 = re.compile(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])")
IPV6 = re.compile(r"(?<![A-Za-z0-9:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?:%[A-Za-z0-9_.-]+)?(?![A-Za-z0-9:])", re.I)
MAC = re.compile(r"\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b", re.I)
PRODUCT_KEY = re.compile(r"\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b")
URL_CREDENTIALS = re.compile(r"https?://[^\s/@]+(:[^\s/@]*)?@", re.I)
URL_SECRET = re.compile(r"[?&](?:access_token|token|api_key|apikey|auth|password|secret|client_secret)=[^\s&#]+", re.I)
FORBIDDEN_KEYS = {
    "username", "user_name", "real_name", "personal_name", "hostname", "host_name",
    "computer_name", "machine_name", "serial", "serial_number", "hardware_id",
    "device_id", "uuid", "vm_uuid", "machine_guid", "vm_id", "account", "account_id",
    "email", "email_address", "password", "access_token", "api_key", "client_secret",
    "private_key", "private_key_pem", "certificate_subject", "certificate_thumbprint",
    "certificate_serial", "smbios", "tpm_ek", "endorsement_key", "nonce",
    "local_path", "absolute_path", "host_path", "guest_path", "volume_name",
}
PID_BOOLEAN_KEYS = {
    "child_pid_matched", "requestor_pid_matched", "dispatch_pid_matched",
    "pid_consistency_verified", "pid_evidence_policy",
}


class EvidenceError(ValueError):
    """An error whose public message is safe to print."""


def normalize_key(value):
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", value).replace("-", "_").lower()


def runtime_private_tokens():
    tokens = {Path.home().name}
    try:
        project = HERE.parents[3]
        tokens.add(project.name)
        for item in project.iterdir():
            if item.is_dir() and (item / ".git").exists():
                tokens.add(item.name)
        for pattern in ("Modules/*", "*/Modules/*", "*/*Kit"):
            tokens.update(item.name for item in project.glob(pattern) if item.is_dir())
    except OSError:
        raise EvidenceError("Could not discover private comparison tokens.") from None
    try:
        configured = json.loads(os.environ.get("B2_PRIVATE_TOKENS", "[]"))
    except json.JSONDecodeError:
        raise EvidenceError("Private token configuration is invalid JSON.") from None
    if not isinstance(configured, list) or any(not isinstance(item, str) for item in configured):
        raise EvidenceError("Private token configuration must be a string array.")
    tokens.update(configured)
    tokens.difference_update({"", "my-project", "module-x", "feature-y", "root"})
    expanded = set()
    for token in tokens:
        if len(token) >= 3:
            expanded.add(token.casefold())
            collapsed = re.sub(r"[-_ ]", "", token).casefold()
            if len(collapsed) >= 4:
                expanded.add(collapsed)
    return expanded


def text_privacy_categories(content, private_tokens):
    categories = set()
    patterns = {
        "email": EMAIL, "uuid": UUID, "private_path": UNIX_PRIVATE_PATH,
        "guest_path": WINDOWS_PATH, "unc_path": UNC_PATH, "hardware_address": MAC,
        "product_key": PRODUCT_KEY, "url_credentials": URL_CREDENTIALS,
        "url_secret": URL_SECRET,
    }
    for category, pattern in patterns.items():
        if pattern.search(content):
            categories.add(category)
    for match in IPV4.finditer(content):
        try:
            ipaddress.IPv4Address(match.group())
        except ipaddress.AddressValueError:
            continue
        categories.add("ipv4")
    for match in IPV6.finditer(content):
        try:
            ipaddress.IPv6Address(match.group())
        except ipaddress.AddressValueError:
            continue
        categories.add("ipv6")
    folded = content.casefold()
    if any(token in folded for token in private_tokens):
        categories.add("private_token")
    return categories


def json_privacy_categories(value, private_tokens):
    categories = set()
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str):
                categories.add("invalid_json_key")
                continue
            normalized = normalize_key(key)
            if normalized in FORBIDDEN_KEYS:
                categories.add("sensitive_field")
            if re.search(r"(?:^|_)(?:pid|pids|process_id|thread_id)(?:$|_)", normalized):
                if normalized not in PID_BOOLEAN_KEYS:
                    categories.add("process_identifier")
            categories.update(text_privacy_categories(key, private_tokens))
            categories.update(json_privacy_categories(child, private_tokens))
    elif isinstance(value, list):
        for child in value:
            categories.update(json_privacy_categories(child, private_tokens))
    elif isinstance(value, str):
        categories.update(text_privacy_categories(value, private_tokens))
    return categories


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise EvidenceError("Could not read a required UTF-8 JSON artifact.") from None


def check(condition, message):
    if not condition:
        raise EvidenceError(message)


def native_schema_validate(instance, schema, document):
    """Validate the schema vocabulary used by the accompanying artifact."""
    if "$ref" in schema:
        prefix = "#/$defs/"
        check(schema["$ref"].startswith(prefix), "Unsupported schema reference.")
        return native_schema_validate(instance, document["$defs"][schema["$ref"][len(prefix):]], document)
    if "anyOf" in schema:
        for candidate in schema["anyOf"]:
            try:
                native_schema_validate(instance, candidate, document)
                break
            except EvidenceError:
                pass
        else:
            raise EvidenceError("An observation has an invalid nullable value.")
    if "const" in schema:
        check(instance == schema["const"] and type(instance) is type(schema["const"]), "An observation violates a fixed schema value.")
    if "enum" in schema:
        check(any(instance == item and type(instance) is type(item) for item in schema["enum"]), "An observation uses an unsupported state.")
    expected = schema.get("type")
    types = {
        "object": lambda x: isinstance(x, dict), "array": lambda x: isinstance(x, list),
        "string": lambda x: isinstance(x, str), "boolean": lambda x: type(x) is bool,
        "integer": lambda x: type(x) is int, "number": lambda x: type(x) in (int, float),
        "null": lambda x: x is None,
    }
    if expected:
        check(expected in types and types[expected](instance), "An observation has an invalid field type.")
    if isinstance(instance, dict):
        properties = schema.get("properties", {})
        check(all(key in instance for key in schema.get("required", [])), "An observation is missing a required field.")
        if schema.get("additionalProperties") is False:
            check(set(instance) <= set(properties), "An observation contains an undeclared field.")
        for key, child in instance.items():
            if key in properties:
                native_schema_validate(child, properties[key], document)
    if isinstance(instance, list):
        if "minItems" in schema:
            check(len(instance) >= schema["minItems"], "An observation has too few records.")
        if "maxItems" in schema:
            check(len(instance) <= schema["maxItems"], "An observation has too many records.")
        for child in instance:
            native_schema_validate(child, schema.get("items", {}), document)
    if isinstance(instance, str):
        if "minLength" in schema:
            check(len(instance) >= schema["minLength"], "An observation string is empty.")
        if "pattern" in schema:
            check(re.search(schema["pattern"], instance) is not None, "An observation string has invalid syntax.")
        if schema.get("format") == "date":
            check(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", instance) is not None, "An observation date is invalid.")
            try:
                dt.date.fromisoformat(instance)
            except ValueError:
                raise EvidenceError("An observation date is invalid.") from None
        if schema.get("format") == "date-time":
            check(re.match(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T", instance) is not None, "An observation timestamp is invalid.")
            try:
                parsed = dt.datetime.fromisoformat(instance.replace("Z", "+00:00"))
            except ValueError:
                raise EvidenceError("An observation timestamp is invalid.") from None
            check(parsed.tzinfo is not None, "Observation timestamps must include a time zone.")
    if type(instance) in (int, float):
        if "minimum" in schema:
            check(instance >= schema["minimum"], "An observation number is below its minimum.")


def evidence_references(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "evidence_refs":
                yield from child
            else:
                yield from evidence_references(child)
    elif isinstance(value, list):
        for child in value:
            yield from evidence_references(child)


def validate_semantics(data):
    attachments = data["attachments"]
    ids = [item["evidence_id"] for item in attachments]
    check(len(ids) == len(set(ids)), "Evidence IDs must be unique.")
    aliases = [item["artifact_alias"] for item in attachments]
    check(len(aliases) == len(set(aliases)), "Evidence artifact aliases must be unique.")
    check(set(evidence_references(data)) <= set(ids), "An observation references missing evidence.")
    binary_ids = []
    for binary in data["self_probe"]["binaries"] + data["commercial_sample"]["driver_binaries"]:
        binary_ids.append(binary["binary_id"])
        machine = (binary["pe_machine"] or "").lower()
        expected = {"0xaa64": "ARM64", "0x8664": "AMD64", "0x014c": "I386", "0xa641": "ARM64EC"}.get(machine)
        if expected:
            check(binary["architecture"] == expected, "A binary architecture conflicts with its PE Machine.")
        if binary["pe_valid"] is True:
            check(binary["pe_machine"] is not None and binary["sha256"] is not None, "A parsed PE binary needs a Machine value and file hash.")
        load = binary["kernel_load"]
        if load["status"] == "loaded":
            check(binary["role"] != "self_probe_collector", "A user-mode collector cannot be a loaded kernel driver.")
            check(load["kernel_driver_running"] is True and load["image_identity_verified"] is True,
                  "A loaded-driver claim needs kernel state and binary identity confirmation.")
            check(load["source"] != "not_sampled" and bool(load["evidence_refs"]), "A loaded-driver claim needs actual load evidence.")
            if any(item["guest_cpu_architecture"] == "ARM64" for item in data["security_environments"].values()):
                check(binary["architecture"] == "ARM64", "An ARM64 Guest load claim requires a native ARM64 kernel binary.")
        for name in ("embedded_signature", "catalog_signature"):
            signature = binary[name]
            if signature["status"] == "valid":
                check(signature["verification_method"] != "not_sampled" and bool(signature["evidence_refs"]), "A valid signature needs verification evidence.")
    check(len(binary_ids) == len(set(binary_ids)), "Binary IDs must be unique across the report.")
    check(all(item["role"] in {"self_probe_driver", "self_probe_collector"} for item in data["self_probe"]["binaries"]), "Self-probe binary roles are invalid.")
    check(all(item["role"] == "vendor_driver" for item in data["commercial_sample"]["driver_binaries"]), "Commercial binary roles are invalid.")
    if data["self_probe"]["build_status"] == "passed":
        binaries = data["self_probe"]["binaries"]
        check({item["role"] for item in binaries} >= {"self_probe_driver", "self_probe_collector"}, "A passed build needs both owned binaries.")
        check(all(item["architecture"] == "ARM64" and item["pe_valid"] is True for item in binaries), "A passed ARM64 build needs parsed native binaries.")
    base = {"device_control_succeeded", "same_process_object", "requestor_matches_current_context", "child_pid_matched", "create_observed", "exit_observed", "child_cleanup_complete", "unload_verified"}
    for name, phase in data["self_probe"]["lifecycle"].items():
        if phase["status"] == "passed":
            required = set(base)
            if name in {"cycle", "after_reboot"}:
                required.add("expected_missing_image_failure")
            if name in {"before_reboot", "after_reboot"}:
                required.add("demand_start_preserved")
            if name == "after_reboot":
                required.add("real_reboot_verified")
            check(all(phase["assertions"][key] is True for key in required), "A passed lifecycle phase is missing positive assertions.")
            check(bool(phase["stages"]) and bool(phase["evidence_refs"]), "A passed lifecycle phase needs stage evidence.")
            check(phase["started_at"] is not None and phase["ended_at"] is not None, "A passed lifecycle phase needs measured timestamps.")
    sample = data["commercial_sample"]
    if sample["started_at"] is not None:
        check(sample["restored_baseline_verified"] is True, "Commercial sampling requires a verified restored security baseline.")
        restored = data["security_environments"]["restored"]
        check(restored["status"] == "observed" and restored["test_signing"] == "disabled", "Commercial sampling cannot use the owned probe test-signing environment.")
        check(restored["reboot_verified"] is True and bool(restored["evidence_refs"]), "Commercial baseline restoration needs a verified reboot and evidence.")
        before = data["security_environments"]["before"]
        for key in ("secure_boot", "tpm", "vbs", "hvci", "hypervisor"):
            if before[key] != "unknown":
                check(restored[key] == before[key], "Commercial sampling changed an original security or virtualization state.")
    axis1 = data["attribution"]["axis_1_native_driver_distribution"]
    vendor_binaries = sample["driver_binaries"]
    if axis1 == "observed_arm64_in_sample":
        check(any(item["architecture"] == "ARM64" and item["pe_valid"] is True for item in vendor_binaries), "An ARM64 distribution finding needs an observed native vendor driver.")
    if axis1 == "observed_amd64_only_in_sample":
        check(bool(vendor_binaries) and all(item["architecture"] == "AMD64" and item["pe_valid"] is True for item in vendor_binaries), "An AMD64-only finding needs actual sampled drivers.")
    if axis1 == "no_driver_released_in_sample":
        check(not vendor_binaries and bool(sample["evidence_refs"]), "A no-release finding needs sampled-stage evidence and no observed driver.")
    if data["attribution"]["axis_2_guest_policy"] == "explicit_rejection_observed":
        check(any(item["category"] == "axis_2_guest_policy" and bool(item["evidence_refs"]) for item in data["attribution"]["findings"]), "An explicit policy rejection needs an evidence-backed finding.")
    allowed = {
        "actual_driver_load": {"unknown", "not_tested", "loaded", "not_loaded", "rejected"},
        "actual_game_start": {"unknown", "not_tested", "started", "rejected"},
        "actual_protected_online_session": {"unknown", "not_tested", "established", "rejected"},
    }
    for key, values in allowed.items():
        state = data["commercial_states"][key]
        check(state["value"] in values, "A commercial state uses a result from another execution stage.")
        if state["value"] not in {"unknown", "not_tested"}:
            check(bool(state["evidence_refs"]), "A commercial observation needs stage-specific evidence.")
    if data["commercial_states"]["actual_driver_load"]["value"] == "loaded":
        check(any(item["kernel_load"]["status"] == "loaded" for item in vendor_binaries), "A commercial load claim cannot be inferred from the owned probe.")
    if data["commercial_states"]["actual_protected_online_session"]["value"] == "established":
        scope = data["authorization_scope"]
        check(scope["accounts_used"] is True and scope["protected_online_session_attempted"] is True, "An online-session claim requires an actual authorized account/session observation.")
        check(data["commercial_states"]["actual_game_start"]["value"] == "started", "An online-session claim requires an independently observed game start.")
    publisher = data["commercial_states"]["publisher_stance"]
    if publisher["support"] != "unknown" or publisher["permission"] != "unknown":
        check(bool(publisher["official_claim_refs"]), "Publisher policy cannot be inferred from local observations.")
        official_claims = {}
        for source in HERE.parents[2].glob("*/evidence.json"):
            document = read_json(source)
            if document.get("snapshot", {}).get("method") == "current_official_public_document_review":
                official_claims.update({claim["claim_id"]: claim for claim in document.get("claims", [])})
        refs = publisher["official_claim_refs"]
        relevant = [official_claims[ref] for ref in refs if ref in official_claims
                    and official_claims[ref].get("scope_id") == "a-cn-win"]
        if publisher["support"] != "unknown":
            expected_status = "conflict" if publisher["support"] == "conflict" else "confirmed"
            check(any(claim.get("status") == expected_status
                      and claim.get("topic") == "vm_publisher_support"
                      and claim.get("value") == publisher["support"] for claim in relevant),
                  "Publisher support needs an official claim for the sampled product and region.")
        if publisher["permission"] != "unknown":
            check(any(claim.get("status") == "confirmed"
                      and claim.get("topic") == "vm_publisher_permission"
                      and claim.get("value") == publisher["permission"] for claim in relevant),
                  "Publisher permission needs an official claim for the sampled product and region.")
    dimensions = data["five_dimension_status"]
    if dimensions["real_guest_verification"] == "passed":
        check(data["self_probe"]["build_status"] == "passed"
              and all(phase["status"] == "passed" for phase in data["self_probe"]["lifecycle"].values()),
              "Guest verification cannot pass before all owned-probe lifecycle phases pass.")
    if dimensions["vendor_support"] == "supported":
        check(data["commercial_states"]["publisher_stance"]["support"] == "supported",
              "Vendor summary cannot exceed the independently verified publisher support state.")
    if dimensions["real_game_verification"] == "passed":
        check(data["commercial_states"]["actual_game_start"]["value"] == "started"
              and data["commercial_states"]["actual_protected_online_session"]["value"] == "established",
              "Game verification cannot pass without independent start and protected-session evidence.")
    terminal = {"passed", "failed", "blocked", "not_tested"}
    if data["status"] in {"passed", "completed_with_blockers"}:
        check(data["self_probe"]["build_status"] in terminal, "A completed report still has a pending build.")
        check(all(item["status"] in terminal for item in data["self_probe"]["lifecycle"].values()), "A completed report still has a pending lifecycle phase.")
        check(sample["installation_status"] in terminal, "A completed report still has pending installer sampling.")
    if data["status"] == "passed":
        check(data["self_probe"]["build_status"] == "passed" and all(item["status"] == "passed" for item in data["self_probe"]["lifecycle"].values()), "A passed B2 report requires actual owned-probe build and lifecycle success.")
        check(sample["started_at"] is not None and bool(sample["evidence_refs"]), "A passed B2 report requires real official-installer sampling.")


def validate_report(data, schema, private_tokens):
    categories = json_privacy_categories(data, private_tokens)
    check(not categories, "Privacy rejection: " + ", ".join(sorted(categories)) + ".")
    native_schema_validate(data, schema, schema)
    validate_semantics(data)


def self_test(data, schema, private_tokens):
    tests = []
    fixtures = [
        ("private_path", {"note": "/" + "Users" + "/sample-user/report.txt"}),
        ("guest_path", {"note": "X:" + chr(92) + "private-folder" + chr(92) + "report.txt"}),
        ("email", {"note": "sample-user" + "@" + "example.invalid"}),
        ("uuid", {"note": "12345678" + "-1234-1234-1234-123456789012"}),
        ("ipv4", {"note": "192." + "0.2.12"}),
        ("ipv6", {"note": "2001" + chr(58) + "db8" + chr(58) * 2 + "12"}),
        ("process_identifier", {"boundChildPID": 123}),
        ("sensitive_field", {"hostname": None}),
        ("private_token", {"note": "private-example-token"}),
    ]
    for category, fixture in fixtures:
        tokens = private_tokens | {"private-example-token"}
        check(category in json_privacy_categories(fixture, tokens), "A privacy regression check failed.")
        tests.append(category)
    check(not json_privacy_categories({"child_pid_matched": True, "guest_os_build": "10.0.26100.1", "signer_alias": "test-signer-x"}, private_tokens), "A derived evidence privacy check failed.")
    cases = []
    case = copy.deepcopy(data)
    case["status"] = "passed"
    cases.append(case)
    case = copy.deepcopy(data)
    case["commercial_states"]["actual_driver_load"] = {"value": "loaded", "evidence_refs": []}
    cases.append(case)
    case = copy.deepcopy(data)
    case["attribution"]["axis_1_native_driver_distribution"] = "observed_arm64_in_sample"
    case["commercial_sample"]["driver_binaries"] = []
    cases.append(case)
    case = copy.deepcopy(data)
    case["commercial_sample"]["started_at"] = "2026-11-22T12:00:00+08:00"
    case["commercial_sample"]["restored_baseline_verified"] = False
    cases.append(case)
    for key, value in (("real_guest_verification", "passed"), ("real_game_verification", "passed"), ("vendor_support", "supported")):
        case = copy.deepcopy(data)
        case["five_dimension_status"][key] = value
        if key == "real_guest_verification":
            case["self_probe"]["build_status"] = "pending"
            case["self_probe"]["lifecycle"]["cycle"]["status"] = "pending"
        elif key == "real_game_verification":
            case["commercial_states"]["actual_game_start"]["value"] = "not_tested"
            case["commercial_states"]["actual_protected_online_session"]["value"] = "not_tested"
        else:
            case["commercial_states"]["publisher_stance"]["support"] = "unknown"
        cases.append(case)
    case = copy.deepcopy(data)
    case["commercial_states"]["publisher_stance"] = {"permission": "prohibited", "support": "unknown", "official_claim_refs": ["A-VM"]}
    cases.append(case)
    for case in cases:
        try:
            validate_report(case, schema, private_tokens)
        except EvidenceError:
            tests.append("semantic_rejection")
        else:
            raise EvidenceError("A semantic regression check failed.")
    original_reader = globals()["read_json"]
    policy_case = copy.deepcopy(data)
    policy_case["status"] = "in_progress"
    policy_case["five_dimension_status"]["real_guest_verification"] = "partial"
    policy_case["five_dimension_status"]["vendor_support"] = "unknown"
    policy_case["five_dimension_status"]["real_game_verification"] = "not_tested"
    policy_case["commercial_states"]["publisher_stance"] = {"permission": "unknown", "support": "supported", "official_claim_refs": ["fixture-support"]}
    claim = {"claim_id": "fixture-support", "scope_id": "b-cn-win", "status": "confirmed", "topic": "vm_publisher_support", "value": "supported"}
    try:
        globals()["read_json"] = lambda path: {"snapshot": {"method": "current_official_public_document_review"}, "claims": [claim]}
        try:
            validate_report(policy_case, schema, private_tokens)
        except EvidenceError:
            tests.append("cross_region_policy_rejection")
        else:
            raise EvidenceError("A publisher scope regression check failed.")
        claim["scope_id"] = "a-cn-win"
        validate_report(policy_case, schema, private_tokens)
        tests.append("same_region_policy_acceptance")
    finally:
        globals()["read_json"] = original_reader
    with tempfile.TemporaryDirectory(prefix="b2-neutral-check-") as temporary:
        directory = Path(temporary) / "export"
        directory.mkdir()
        outside = Path(temporary) / "outside.json"
        raw = b'{"sample":"neutral"}'
        outside.write_bytes(raw)
        attachment = {"artifact_alias": "sample.json", "sha256": hashlib.sha256(raw).hexdigest(), "privacy_review": "automated_text_review"}
        (directory / "sample.json").symlink_to(outside)
        try:
            verify_attachment_files({"attachments": [attachment]}, directory, private_tokens)
        except EvidenceError:
            tests.append("attachment_symlink_rejection")
        else:
            raise EvidenceError("An attachment symlink regression check failed.")
        (directory / "sample.json").unlink()
        (directory / "sample.json").write_bytes(raw + b' ')
        try:
            verify_attachment_files({"attachments": [attachment]}, directory, private_tokens)
        except EvidenceError:
            tests.append("attachment_hash_rejection")
        else:
            raise EvidenceError("An attachment integrity regression check failed.")
    return len(tests) + 1


def scan_artifacts(paths, recursive, private_tokens):
    files = []
    for path in paths:
        if path.is_file():
            files.append(path)
        elif path.is_dir():
            iterator = path.rglob("*") if recursive else path.iterdir()
            files.extend(item for item in iterator if item.is_file() and item.suffix.lower() in TEXT_SUFFIXES)
        else:
            raise EvidenceError("A scan input is missing or is not a file/directory.")
    findings = []
    for index, path in enumerate(sorted(set(files)), 1):
        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            raise EvidenceError("A scan artifact is unreadable UTF-8; the scan cannot pass.") from None
        categories = text_privacy_categories(content, private_tokens)
        if path.suffix.lower() == ".json":
            try:
                data = json.loads(content)
            except json.JSONDecodeError:
                raise EvidenceError("A scanned JSON artifact is invalid; the scan cannot pass.") from None
            categories.update(json_privacy_categories(data, private_tokens))
        if categories:
            findings.append({"artifact_alias": f"file-{index:03d}", "categories": sorted(categories)})
    return {"result": "failed" if findings else "passed", "files_scanned": len(files), "findings": findings}


def verify_attachment_files(data, directory, private_tokens):
    checked = 0
    check(hasattr(os, "O_NOFOLLOW") and os.open in os.supports_dir_fd,
          "This platform cannot securely open evidence attachments without following symlinks.")
    for item in data["attachments"]:
        alias = item["artifact_alias"]
        check(Path(alias).name == alias, "An evidence alias escapes its directory.")
        directory_fd = None
        descriptor = None
        try:
            directory_fd = os.open(directory.resolve(), os.O_RDONLY | os.O_DIRECTORY)
            descriptor = os.open(alias, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
            check(stat.S_ISREG(os.fstat(descriptor).st_mode), "An attached evidence artifact must be a regular file.")
            with os.fdopen(descriptor, "rb") as stream:
                descriptor = None
                raw = stream.read()
        except OSError:
            raise EvidenceError("An attached evidence artifact is missing, unreadable or a symlink.") from None
        finally:
            if descriptor is not None:
                os.close(descriptor)
            if directory_fd is not None:
                os.close(directory_fd)
        check(hashlib.sha256(raw).hexdigest() == item["sha256"], "An attached evidence artifact hash does not match.")
        suffix = Path(alias).suffix.lower()
        if suffix == ".png":
            check(item["privacy_review"] == "manual_visual_review_completed", "Image attachments require a documented visual privacy review.")
        else:
            check(item["privacy_review"] == "automated_text_review", "Text evidence requires an automated privacy review.")
            try:
                content = raw.decode("utf-8")
            except UnicodeError:
                raise EvidenceError("An attached text artifact is not readable UTF-8.") from None
            categories = text_privacy_categories(content, private_tokens)
            if suffix == ".json":
                try:
                    categories.update(json_privacy_categories(json.loads(content), private_tokens))
                except json.JSONDecodeError:
                    raise EvidenceError("An attached JSON artifact is invalid.") from None
            check(not categories, "An attached evidence artifact failed its privacy scan.")
        checked += 1
    return checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate", help="Validate local observations and privacy.")
    validate.add_argument("report", nargs="?", type=Path, default=HERE / "b2-local-observations.json")
    validate.add_argument("--schema", type=Path, default=HERE / "b2-local-observations.schema.json")
    validate.add_argument("--self-test", action="store_true")
    validate.add_argument("--verify-files", action="store_true")
    scan = commands.add_parser("scan", help="Reject sensitive content in arbitrary export artifacts.")
    scan.add_argument("paths", nargs="+", type=Path)
    scan.add_argument("--recursive", action="store_true")
    args = parser.parse_args()
    try:
        private_tokens = runtime_private_tokens()
        if args.command == "scan":
            result = scan_artifacts(args.paths, args.recursive, private_tokens)
        else:
            data = read_json(args.report)
            schema = read_json(args.schema)
            validate_report(data, schema, private_tokens)
            result = {"result": "passed", "report_status": data["status"], "attachments": len(data["attachments"])}
            if args.self_test:
                fixture = read_json(HERE / "b2-local-observations.json")
                if fixture["status"] != "pending":
                    fixture = copy.deepcopy(fixture)
                    fixture["status"] = "pending"
                    fixture["self_probe"]["build_status"] = "pending"
                result["regression_checks"] = self_test(fixture, schema, private_tokens)
            if args.verify_files:
                result["attachment_files_verified"] = verify_attachment_files(data, args.report.parent, private_tokens)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0 if result["result"] == "passed" else 1
    except EvidenceError as error:
        print(json.dumps({"result": "failed", "reason": str(error)}, ensure_ascii=False, sort_keys=True))
        return 1
    except Exception:
        print(json.dumps({"result": "failed", "reason": "Unexpected validation failure; details withheld to protect private identifiers."}, sort_keys=True))
        return 1


if __name__ == "__main__":
    sys.exit(main())
