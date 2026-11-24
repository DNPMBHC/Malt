"""Read-only Wine rendering evidence with numeric, allowlisted output. @DNPMBHC."""
from __future__ import annotations

import collections
import hashlib
import re

GRAPHICS_DLLS = (
    "d3d11.dll", "d3d9.dll", "dxgi.dll", "wined3d.dll", "opengl32.dll",
    "dwrite.dll", "dcomp.dll", "libegl.dll", "libglesv2.dll", "winevulkan.dll",
)


def summarize_log(text: str) -> dict:
    """Never export raw lines, URLs, command arguments, addresses or identities."""
    contexts: dict[str, str] = {}
    loads = []
    gpu_exits = []
    exceptions: collections.Counter[str] = collections.Counter()
    for line in text.splitlines():
        for code in re.findall(r"(?i)\bcode=(?:0x)?([0-9a-f]{8})\b", line):
            exceptions[code.lower()] += 1
        match = re.search(r"(?i)GPU process exited unexpectedly:\s*exit_code=(-?\d+)", line)
        if match:
            gpu_exits.append(int(match.group(1)))
        if "loaddll:" not in line.lower():
            continue
        module = next((name for name in GRAPHICS_DLLS
                       if re.search(r"(?i)[\\/]" + re.escape(name) + r"[\"']", line)), None)
        if module is None:
            continue
        prefix = re.match(r"^([0-9a-fA-F]+):", line)
        key = prefix.group(1).lower() if prefix else "unbound"
        if key not in contexts:
            contexts[key] = f"context-{len(contexts):03d}"
        lower = line.lower()
        role = "syswow64" if "\\syswow64\\" in lower else (
            "system32" if "\\system32\\" in lower else "other")
        loads.append({
            "log_context_alias": contexts[key], "library": module,
            "directory_role": role,
            "loader_mode": "builtin" if ": builtin" in lower else (
                "native" if ": native" in lower else "unknown"),
        })
    return {
        "owner": "@DNPMBHC", "line_count": len(text.splitlines()),
        "input_text_sha256": hashlib.sha256(text.encode()).hexdigest(),
        "graphics_module_loads": loads,
        "wine_debug_prefix_pid_binding": False,
        "loader_tag_establishes_backend_byte_identity": False,
        "exception_code_counts": dict(exceptions),
        "chromium_gpu_process_exit_codes": gpu_exits,
        "unhandled_exception_markers": len(re.findall(r"Unhandled exception", text, re.I)),
        "import_dll_error_markers": len(re.findall(r"err:module:import_dll", text, re.I)),
        "disable_gpu_argument_honored": "not_established_by_log_metadata",
        "raw_content_exported": False,
        "limitation": "Wine debug prefixes are not bound to process IDs. Builtin/native "
                      "tags and first-chance exceptions do not prove renderer identity, "
                      "a crash, or vendor rejection. No backend absence claim is made.",
    }


def bind_launcher_architectures(expected_hashes: dict[str, str], files: list[dict]) -> list[dict]:
    """Bind historical launcher bytes to inspected PE headers, not directory names."""
    result = []
    for role, digest in expected_hashes.items():
        candidates = [item for item in files if item.get("sha256") == digest]
        machines = {item.get("pe_machine") for item in candidates if item.get("pe_valid")}
        complete = bool(candidates) and all(item.get("pe_valid") for item in candidates)
        complete = complete and len(machines) == 1 and None not in machines
        result.append({
            "launcher_role_alias": role, "sha256": digest,
            "hash_match_count": len(candidates), "pe_binding_complete": complete,
            "pe_machine": next(iter(machines)) if complete else None,
            "actual_runtime_process_machine_verified": False,
        })
    return result
