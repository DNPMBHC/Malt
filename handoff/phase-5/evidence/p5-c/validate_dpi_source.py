#!/usr/bin/env python3
"""Parse the exact embedded script without calling Windows APIs. Owner: @DNPMBHC."""
import ast
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent
ROOT = EVIDENCE.parents[3]
PACKAGE = next(ROOT.glob("*/*/Package.swift")).parent
RUNTIME = next(PACKAGE.glob("Sources/*/Runtime"))
VERSION = "7.4.6"
ARCHIVE = "powershell-" + VERSION + "-osx-arm64.tar.gz"
BASE = "https://github.com/PowerShell/PowerShell/releases/download/v" + VERSION + "/"


def optimizer_parser_sources(directory):
    spec = importlib.util.spec_from_file_location("minimal_source_parser", EVIDENCE / "prepare_minimal_guest.py")
    minimal = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(minimal)
    captured = []
    token = None

    def capture_only(identifier, script, **kwargs):
        nonlocal token
        captured.append(script)
        if "Register-ScheduledTask" in script:
            token = re.search(r"guest-shell-minimal-([0-9a-f]{32})", script).group(1)
            return {"started": True}
        if "Get-Content -Raw" in script:
            return {"owner": "@DNPMBHC", "request_id": token, "session_id": 1, "exit_code": 0,
                    "report": {"owner": "@DNPMBHC", "security_invariants_passed": True,
                     "profile_sha256": minimal.PINNED["anticheat-minimal-win11-arm64.json"],
                     "script_sha256": minimal.PINNED["apply-optimizer.ps1"]}}
        return {"cleaned": True}

    minimal.bootstrap.powershell = capture_only
    minimal.clone.save = lambda *_: None
    minimal.run_interactive("parser-only", r"C:\guest-shell-lab\minimal", "apply")
    encoded = re.search(r"FromBase64String\('([A-Za-z0-9+/=]+)'\)", captured[0]).group(1)
    body = __import__("base64").b64decode(encoded).decode()
    assert "-ExecutionPolicy RemoteSigned" in captured[0] and "Set-ExecutionPolicy" not in captured[0]
    assert "Bypass" not in captured[0] and "ExecutionPolicy" not in body
    scripts = [*captured, body]
    paths = []
    for index, source in enumerate(scripts):
        path = directory / ("minimal-" + str(index) + ".ps1")
        path.write_text(source)
        paths.append(path)
    return paths


def bridge_parser_sources(directory):
    template = (RUNTIME / "UTMGuestCommandBridge.swift").read_text().split('let script = """', 1)[1].split('"""', 1)[0]
    fingerprint_body = (RUNTIME / "UTMInteractiveHelperVerification.swift").read_text().split('body: """', 1)[1].split('"""', 1)[0]
    bodies = ["& $values[0] $values[1] $values[2]|ConvertFrom-Json", fingerprint_body]
    paths = []
    for index, body in enumerate(bodies):
        args = __import__("base64").b64encode(json.dumps([r"C:\guest-shell-lab\desktop-helper.exe", "status", "00000000-0000-0000-0000-000000000001"]).encode()).decode()
        source = template.replace(r"\(encodedArguments)", args).replace(r"\(body)", body).replace(r"\(nonce)", "00000000-0000-0000-0000-000000000002")
        if r"\(" in source: raise RuntimeError("bridge_parser_unexpanded_interpolation")
        path = directory / ("bridge-" + str(index) + ".ps1")
        path.write_text(source)
        paths.append(path)
    paths.append(EVIDENCE / "dpi-topology-probe.ps1")
    return paths

def main():
    report = {"owner": "@DNPMBHC", "runtime_version": VERSION,
              "captured_at_utc": datetime.now(timezone.utc).isoformat(),
              "windows_execution_verified": False, "windows_api_called": False, "passed": False}
    directory = Path(tempfile.mkdtemp(prefix="guest-shell-dpi-parser-"))
    try:
        script = EVIDENCE / "dpi-settings-probe.ps1"
        text = script.read_text()
        embedded = (RUNTIME / "GuestSurfaceDPIScript.swift").read_text()
        body = embedded.split('let guestSurfaceDPISettingsScriptBody = #"""\n', 1)[1].rsplit('  """#', 1)[0]
        body = "\n".join(line[2:] if line.startswith("  ") else line for line in body.splitlines()) + "\n"
        assert body == text, "embedded_script_mismatch"
        report["embedded_script_byte_exact"] = True
        report["script_sha256"] = hashlib.sha256(script.read_bytes()).hexdigest()
        print(json.dumps({"stage": "official_parser_fetch"}), flush=True)
        checksums = urllib.request.urlopen(urllib.request.Request(BASE + "hashes.sha256", headers={"User-Agent": "guest-shell-source-validation"}), timeout=30).read().decode()
        line = next(line for line in checksums.splitlines() if ARCHIVE in line)
        expected = re.search(r"[0-9a-fA-F]{64}", line).group(0).lower()
        archive = directory / ARCHIVE
        with urllib.request.urlopen(urllib.request.Request(BASE + ARCHIVE, headers={"User-Agent": "guest-shell-source-validation"}), timeout=90) as source, archive.open("wb") as sink:
            shutil.copyfileobj(source, sink)
        actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        assert actual == expected, "official_archive_checksum_mismatch"
        report.update(official_checksum_verified=True, archive_sha256=actual,
                      archive_url=BASE + ARCHIVE, checksums_url=BASE + "hashes.sha256")
        print(json.dumps({"stage": "parser_archive_verified"}), flush=True)
        runtime = directory / "runtime"
        runtime.mkdir()
        with tarfile.open(archive) as package:
            package.extractall(runtime, filter="data")
        pwsh = runtime / "pwsh"
        pwsh.chmod(0o755)
        helper = re.search(r"Add-Type -TypeDefinition @'\n(.*?)\n'@ -Language CSharp", text, re.S).group(1)
        helper_file = directory / "helper.cs"
        helper_file.write_text(helper)
        tree = ast.parse((EVIDENCE / "bootstrap_guest_clone.py").read_text())
        extra = []
        for function in tree.body:
            if isinstance(function, ast.FunctionDef) and function.name in ("preflight", "install_driver"):
                value = next(node.value.value for node in function.body if isinstance(node, ast.Assign)
                             and isinstance(node.targets[0], ast.Name) and node.targets[0].id == "query")
                path = directory / (function.name + ".ps1")
                path.write_text(value)
                extra.append(path)
        extra.extend(optimizer_parser_sources(directory))
        extra.extend(bridge_parser_sources(directory))
        list_file = directory / "scripts.json"
        list_file.write_text(json.dumps([str(script), *map(str, extra)]))
        report["bootstrap_source_sha256"] = hashlib.sha256((EVIDENCE / "bootstrap_guest_clone.py").read_bytes()).hexdigest()
        report["powershell_sources_parsed"] = 1 + len(extra)
        report["minimal_optimizer_wrapper_source_sha256"] = hashlib.sha256((EVIDENCE / "prepare_minimal_guest.py").read_bytes()).hexdigest()
        validation = directory / "parse.ps1"
        validation.write_text("""param([string]$ScriptList, [string]$HelperFile)
$ErrorActionPreference = 'Stop'
foreach($ScriptFile in (Get-Content -LiteralPath $ScriptList -Raw | ConvertFrom-Json)) {
  $tokens = $null; $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($ScriptFile, [ref]$tokens, [ref]$errors)
  if ($errors.Count) {
    @{error_count=$errors.Count; errors=@($errors | ForEach-Object {$_.ErrorId})} | ConvertTo-Json -Compress
    exit 1
  }
}
Add-Type -TypeDefinition ([IO.File]::ReadAllText($HelperFile)) -Language CSharp | Out-Null
@{error_count=0; errors=@(); helper_compiled=$true; windows_api_called=$false} | ConvertTo-Json -Compress
""")
        result = subprocess.run([str(pwsh), "-NoProfile", "-NonInteractive", "-File", str(validation),
                                 str(list_file), str(helper_file)], text=True, capture_output=True, timeout=60)
        report["parser_exit"] = result.returncode
        report["result"] = json.loads(result.stdout)
        assert result.returncode == 0 and report["result"]["helper_compiled"], "parser_or_csharp_failed"
        report["passed"] = True
    except (AssertionError, OSError, ValueError, RuntimeError, SyntaxError, StopIteration, subprocess.TimeoutExpired) as error:
        report["error_code"] = "dpi_source_validation_failed"
        report["error_type"] = type(error).__name__
        if isinstance(getattr(error, "code", None), int): report["http_status"] = error.code
    finally:
        shutil.rmtree(directory)
        report["parser_runtime_cleaned_after_verification"] = not directory.exists()
    (EVIDENCE / "dpi-parser-validation-candidate4.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
