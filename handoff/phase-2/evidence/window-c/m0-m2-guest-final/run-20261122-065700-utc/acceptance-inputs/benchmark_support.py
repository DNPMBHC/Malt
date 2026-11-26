#!/usr/bin/env python3
"""Scoped process, digest, Guest-session, and privacy helpers for module-c."""
from __future__ import annotations
import base64
import hashlib
import json
import os
import platform
import re
import secrets
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent
EVIDENCE_DIR = WORKSPACE_ROOT / "handoff" / "phase-2" / "evidence" / "window-c"
GUEST_DIR = r"C:\graphics-lab\module-c"
FINGERPRINT_FIELDS = ("adapter_description", "vendor_id", "device_id", "adapter_flags",
                      "selected_feature_level", "windows_session_id")


def writable_path(path: Path | str) -> Path:
    resolved = Path(path).resolve()
    if not any(resolved == p or p in resolved.parents for p in (SCRIPT_DIR, EVIDENCE_DIR)):
        raise ValueError("output must be inside graphics-lab or window-c evidence")
    return resolved


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def redact_text(text: str) -> str:
    redacted = str(text)
    for path, label in ((WORKSPACE_ROOT, "my-project"), (Path.home(), "<home>")):
        redacted = redacted.replace(str(path), label)
    for token in (WORKSPACE_ROOT.name, os.environ.get("USER", ""), platform.node()):
        if token:
            redacted = redacted.replace(token, "<private-id>")
    redacted = re.sub(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", "vm-a", redacted)
    redacted = re.sub(r"(?<![\w.])(?:[A-Za-z]:[\\/]|/(?:Users|Volumes|private|tmp|Applications|Library)/)[^\s\"'<>\x60]+", "<path>", redacted)
    redacted = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "<email>", redacted)
    return redacted


def clean_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): clean_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [clean_value(v) for v in value]
    return redact_text(value) if isinstance(value, str) else value


def write_json(path: Path, data: Any) -> None:
    path = writable_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(clean_value(data), indent=2, sort_keys=True) + "\n", encoding="utf-8")


def runtime_environment(work_dir: Path) -> dict[str, str]:
    work_dir = writable_path(work_dir)
    scratch = work_dir / "tmp"
    cache = work_dir / "cache"
    scratch.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for key in ("TMPDIR", "TMP", "TEMP"):
        env[key] = str(scratch.resolve()) + "/"
    env["XDG_CACHE_HOME"] = str(cache)
    env["CLANG_MODULE_CACHE_PATH"] = str(cache / "clang")
    env["SWIFT_MODULECACHE_PATH"] = str(cache / "swift")
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONPYCACHEPREFIX"] = str(cache / "python")
    return env


def checked(command: list[str], *, env: dict[str, str] | None = None,
            timeout: float = 120) -> subprocess.CompletedProcess:
    result = subprocess.run(command, cwd=SCRIPT_DIR, env=env, capture_output=True,
                            text=True, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f"process failed ({result.returncode}): {redact_text(result.stderr[-1500:])}")
    return result


def source_digests(probe: Path | None = None) -> dict[str, str]:
    paths = {"d3d11_probe_cpp": SCRIPT_DIR / "d3d11_probe.cpp",
             "d3d11_probe_exe": probe or SCRIPT_DIR / "build" / "d3d11_probe.exe",
             "metal_host_swift": SCRIPT_DIR / "metal_host.swift",
             "metal_host_binary": SCRIPT_DIR / "build" / "metal_host",
             "analyze_py": SCRIPT_DIR / "analyze.py",
             "benchmark_support_py": SCRIPT_DIR / "benchmark_support.py"}
    return {name: sha256_file(path) for name, path in paths.items() if path.is_file()}


def discover_utmctl() -> Path:
    found = shutil.which("utmctl")
    if found:
        return Path(found)
    candidate = Path(Path.home().anchor) / "Applications" / "UTM.app" / "Contents" / "MacOS" / "utmctl"
    if not candidate.is_file():
        raise RuntimeError("Guest control utility is unavailable")
    return candidate


def discover_started_vm(utmctl: Path) -> str:
    result = checked([str(utmctl), "list"])
    started = []
    for line in result.stdout.splitlines():
        identifier = re.search(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", line)
        if identifier and re.search(r"\bstarted\b", line, re.IGNORECASE):
            started.append(identifier.group())
    if len(started) != 1:
        raise RuntimeError("exactly one running vm-a is required")
    return started[0]


def ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


class GuestSession:
    def __init__(self, utmctl: Path, vm_id: str):
        self.utmctl = utmctl
        self.vm_id = vm_id

    def powershell(self, source: str, timeout: float = 60) -> str:
        encoded = base64.b64encode(source.encode("utf-16-le")).decode("ascii")
        try:
            return checked([str(self.utmctl), "exec", self.vm_id, "--cmd", "powershell.exe",
                            "-NoProfile", "-EncodedCommand", encoded], timeout=timeout).stdout.strip()
        except RuntimeError:
            raise RuntimeError("vm-a PowerShell control action failed") from None

    def prepare_probe(self, probe: Path) -> str:
        self.powershell("New-Item -ItemType Directory -Force -Path " + ps_quote(GUEST_DIR) + " | Out-Null")
        guest_probe = GUEST_DIR + r"\d3d11_probe.exe"
        with probe.open("rb") as handle:
            result = subprocess.run([str(self.utmctl), "file", "push", self.vm_id, guest_probe],
                                    stdin=handle, capture_output=True, check=False, timeout=120)
        if result.returncode:
            raise RuntimeError("probe upload to vm-a failed")
        actual = self.powershell("(Get-FileHash -Algorithm SHA256 " + ps_quote(guest_probe) + ").Hash.ToLower()")
        expected = sha256_file(probe)
        if actual.lower() != expected:
            raise RuntimeError("vm-a probe binary SHA-256 mismatch")
        return actual

    def pull(self, guest_name: str, local: Path) -> None:
        local = writable_path(local)
        result = subprocess.run([str(self.utmctl), "file", "pull", self.vm_id,
                                 GUEST_DIR + "\\" + guest_name], capture_output=True,
                                check=False, timeout=120)
        if result.returncode or not result.stdout:
            raise RuntimeError(f"unable to retrieve vm-a artifact {Path(guest_name).name}")
        local.parent.mkdir(parents=True, exist_ok=True)
        local.write_bytes(result.stdout)

    def metadata(self) -> dict:
        source = (
            "$os=Get-CimInstance Win32_OperatingSystem; "
            "$cpu=Get-CimInstance Win32_Processor|Select-Object -First 1; "
            "$cv=Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion'; "
            "$controllers=@(Get-CimInstance Win32_VideoController); "
            "$gpu=$controllers|Select-Object -First 1; "
            "$architecture=if($cpu.Architecture -eq 12){'ARM64'}else{$os.OSArchitecture}; "
            "@{vm='vm-a';os_product=$os.Caption;version=$os.Version;build=$os.BuildNumber;"
            "display_version=$cv.DisplayVersion;architecture=$architecture;"
            "os_architecture=$os.OSArchitecture;cpu_architecture_code=$cpu.Architecture;"
            "display_adapter=$gpu.Name;display_driver_version=$gpu.DriverVersion;"
            "display_adapters=@($controllers|ForEach-Object {@{description=$_.Name;driver_version=$_.DriverVersion}})}|ConvertTo-Json -Depth 4 -Compress")
        return json.loads(self.powershell(source))

    def run_interactive(self, stem: str, args: list[str], output: Path,
                        artifacts: list[str], timeout: float = 900) -> dict:
        if not re.fullmatch(r"[a-z0-9-]+", stem):
            raise ValueError("run name must use neutral lowercase tokens")
        if any(not isinstance(name, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", name)
               or name in (".", "..") for name in artifacts):
            raise ValueError("Guest artifact names must be neutral basenames")
        output = writable_path(output)
        output.mkdir(parents=True, exist_ok=True)
        script_name = stem + ".ps1"
        done_name = stem + ".done"
        stderr_name = stem + ".stderr.log"
        stdout_name = stem + ".stdout.log"
        pid_name = stem + ".pid"
        run_token = secrets.token_hex(16)
        task_name = "module-c-" + stem + "-" + run_token[:8]
        source = ("$ErrorActionPreference='Stop'; $probeArgs=@(" + ",".join(ps_quote(a) for a in args) + "); "
                  "$p=Start-Process -FilePath " + ps_quote(GUEST_DIR + r"\d3d11_probe.exe")
                  + " -ArgumentList $probeArgs -PassThru -RedirectStandardOutput "
                  + ps_quote(GUEST_DIR + "\\" + stdout_name) + " -RedirectStandardError "
                  + ps_quote(GUEST_DIR + "\\" + stderr_name) + "; "
                  "$handle=$p.Handle; "
                  "$identity=@{run_token=" + ps_quote(run_token)
                  + ";process_id=$p.Id;creation_time_utc_ticks=[string]$p.StartTime.ToUniversalTime().Ticks}; "
                  "$identity|ConvertTo-Json -Compress|Set-Content -Encoding ASCII "
                  + ps_quote(GUEST_DIR + "\\" + pid_name) + "; "
                  "$p.WaitForExit(); $code=$p.ExitCode; if ($null -eq $code) {$code=1}; "
                  "$code|Set-Content -Encoding ASCII " + ps_quote(GUEST_DIR + "\\" + done_name))
        source = ("try {" + source + "} catch { $_ | Out-File -Encoding utf8 "
                  + ps_quote(GUEST_DIR + "\\" + stderr_name) + "; "
                  + "1|Set-Content -Encoding ASCII " + ps_quote(GUEST_DIR + "\\" + done_name) + " }")
        encoded_script = base64.b64encode(source.encode("utf-8")).decode("ascii")
        old_names = list(dict.fromkeys([pid_name, done_name, stdout_name, stderr_name] + artifacts))
        old_paths = ",".join(ps_quote(GUEST_DIR + "\\" + name) for name in old_names)
        launch = (
            "$ErrorActionPreference='Stop'; "
            "$user=(Get-CimInstance Win32_ComputerSystem).UserName; if (!$user) {throw 'interactive desktop required'}; "
            "Remove-Item -LiteralPath @(" + old_paths + ") -ErrorAction SilentlyContinue; "
            "$bytes=[Convert]::FromBase64String(" + ps_quote(encoded_script) + "); "
            "[IO.File]::WriteAllBytes(" + ps_quote(GUEST_DIR + "\\" + script_name) + ",$bytes); "
            "$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "
            + ps_quote('-NoProfile -ExecutionPolicy Bypass -File "' + GUEST_DIR + "\\" + script_name + '"') + "; "
            "$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited; "
            "Register-ScheduledTask -TaskName " + ps_quote(task_name) + " -Action $action -Principal $principal -Force|Out-Null; "
            "Start-ScheduledTask -TaskName " + ps_quote(task_name) + "; 'started'")
        cleanup = (
            "$ErrorActionPreference='Stop'; "
            "Stop-ScheduledTask -TaskName " + ps_quote(task_name) + " -ErrorAction SilentlyContinue; "
            "Unregister-ScheduledTask -TaskName " + ps_quote(task_name) + " -Confirm:$false -ErrorAction SilentlyContinue; "
            "$pidFile=" + ps_quote(GUEST_DIR + "\\" + pid_name) + "; "
            "if(Test-Path -LiteralPath $pidFile){"
            "$binding=Get-Content -Raw -LiteralPath $pidFile|ConvertFrom-Json; "
            "if($binding.run_token -ne " + ps_quote(run_token) + "){throw 'probe cleanup run identity mismatch'}; "
            "$probePid=[int]$binding.process_id; if($probePid -le 0){throw 'invalid probe process identity'}; "
            "$live=Get-Process -Id $probePid -ErrorAction SilentlyContinue; "
            "if($live){$processHandle=$live.Handle; "
            "$created=[string]$live.StartTime.ToUniversalTime().Ticks; "
            "if($created -ne [string]$binding.creation_time_utc_ticks){throw 'probe PID was reused; refusing cleanup'}; "
            "$proc=Get-CimInstance Win32_Process -Filter ('ProcessId='+$probePid); "
            "if(!$proc -or $proc.ExecutablePath -ne " + ps_quote(GUEST_DIR + r"\d3d11_probe.exe")
            + "){throw 'probe executable identity mismatch; refusing cleanup'}; "
            "if(-not $live.HasExited){$live.Kill()}; "
            "if(-not $live.WaitForExit(5000)){throw 'owned probe did not stop'}}; "
            "Remove-Item -LiteralPath $pidFile -ErrorAction Stop}; "
            "$remainingTasks=@(Get-ScheduledTask -ErrorAction Stop|Where-Object {$_.TaskName -eq "
            + ps_quote(task_name) + "}); "
            "if($remainingTasks.Count -ne 0){throw 'owned scheduled task remains after cleanup'}; "
            "'cleanup-verified'")
        start = time.perf_counter()
        body_failed = False
        try:
            self.powershell(launch)
            while True:
                state = self.powershell("if(Test-Path " + ps_quote(GUEST_DIR + "\\" + done_name)
                                        + "){(Get-Content " + ps_quote(GUEST_DIR + "\\" + done_name) + ").Trim()}else{'pending'}")
                if state != "pending":
                    if state != "0":
                        self.pull(stderr_name, output / stderr_name)
                        raw = (output / stderr_name).read_bytes()
                        text = raw.decode("utf-16") if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else raw.decode("utf-8", errors="replace")
                        (output / stderr_name).write_text(redact_text(text), encoding="utf-8")
                        raise RuntimeError("vm-a interactive probe failed; see neutral run stderr")
                    break
                if time.perf_counter() - start > timeout:
                    raise RuntimeError("vm-a interactive probe timed out")
                time.sleep(0.5)
            for artifact in artifacts:
                self.pull(artifact, output / artifact)
            self.pull(stderr_name, output / stderr_name)
            raw = (output / stderr_name).read_bytes()
            text = raw.decode("utf-16") if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else raw.decode("utf-8", errors="replace")
            cleaned = redact_text(text)
            (output / stderr_name).write_text(cleaned, encoding="utf-8")
            return {"wall_ms": (time.perf_counter() - start) * 1000,
                    "launch": "interactive-scheduled-task", "vm": "vm-a"}
        except Exception:
            body_failed = True
            raise
        finally:
            try:
                verified = self.powershell(cleanup)
                if verified != "cleanup-verified":
                    raise RuntimeError("vm-a cleanup did not confirm owned process identity")
                write_json(output / "guest-cleanup.json", {"verified": True, "instance_bound": True,
                           "owned_task_absent_verified": True})
            except Exception as error:
                write_json(output / "guest-cleanup.json", {"verified": False, "instance_bound": True,
                           "error": redact_text(str(error))})
                if not body_failed:
                    raise RuntimeError("vm-a owned task cleanup could not be verified") from None


def validate_guest_environment(metadata: dict) -> None:
    if not isinstance(metadata, dict):
        raise RuntimeError("Guest environment metadata must be an object")
    product = metadata.get("os_product")
    version = metadata.get("display_version")
    build = metadata.get("build")
    architecture = metadata.get("architecture")
    if not isinstance(product, str) or not re.search(r"\bWindows\s+11\b", product, re.IGNORECASE):
        raise RuntimeError("paired benchmark requires Windows 11")
    if not isinstance(version, str) or version.upper() != "24H2":
        raise RuntimeError("paired benchmark requires Windows 11 24H2")
    if isinstance(build, bool) or not isinstance(build, (str, int)) or str(build).split(".")[0] != "26100":
        raise RuntimeError("paired benchmark requires Windows build 26100")
    if not isinstance(architecture, str) or re.sub(r"[^a-z0-9]", "", architecture.lower()) not in (
            "arm64", "arm64bit", "arm64basedpc"):
        raise RuntimeError("paired benchmark requires the native ARM64 Guest architecture")
    if "cpu_architecture_code" in metadata and (type(metadata["cpu_architecture_code"]) is not int
                                              or metadata["cpu_architecture_code"] != 12):
        raise RuntimeError("native Guest processor architecture is not ARM64")


def validate_probe_metadata(metadata: dict, expected: dict) -> None:
    if not isinstance(metadata, dict) or not isinstance(expected, dict):
        raise RuntimeError("probe metadata and workload expectations must be objects")
    for field, wanted in expected.items():
        if field not in metadata or type(metadata[field]) is not type(wanted) or metadata[field] != wanted:
            raise RuntimeError(f"probe metadata disagrees with expected {field}")


def fingerprint(metadata: dict) -> dict:
    if any(metadata.get(key) is None for key in FINGERPRINT_FIELDS):
        raise RuntimeError("actual DXGI adapter/session fingerprint is incomplete")
    for key in ("vendor_id", "device_id", "adapter_flags", "windows_session_id"):
        value = metadata[key]
        if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF:
            raise RuntimeError("DXGI adapter and session identifiers must be uint32")
    for key in ("device_create_hresult", "adapter_get_desc1_hresult"):
        if key in metadata and metadata[key] not in ("0x00000000", 0):
            raise RuntimeError("adapter fingerprint API did not succeed")
    if metadata.get("session_api_success", True) is not True:
        raise RuntimeError("ProcessIdToSessionId did not succeed")
    if not isinstance(metadata["adapter_description"], str) or not metadata["adapter_description"]:
        raise RuntimeError("actual adapter description is missing")
    flags = metadata["adapter_flags"]
    result = {key: metadata[key] for key in FINGERPRINT_FIELDS}
    result["adapter_software_flag"] = bool(flags & 2)
    result["requested_driver_type"] = metadata.get("requested_driver_type", metadata.get("driver_type"))
    return result


def start_metal_host(output: Path, mode: str, host_ip: str, port: int,
                     *, capture_frames: list[int] | None = None) -> dict:
    output = writable_path(output)
    output.mkdir(parents=True, exist_ok=True)
    command = [str(SCRIPT_DIR / "restart_metal_host.sh"), "--bind", host_ip, "--port", str(port),
               "--jsonl", str(output / "host.jsonl"), "--resource-policy", "off", "--metalfx", "off",
               "--offload-mode", mode, "--display-sync", "off"]
    if capture_frames:
        command += ["--capture-dir", str((output / "host-captures").relative_to(WORKSPACE_ROOT)), "--capture-frame", ",".join(map(str, capture_frames))]
    result = checked(command, env=runtime_environment(SCRIPT_DIR / "build" / "runtime"), timeout=120)
    markers = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    if markers.get("status") != "running" or not any(line.startswith("ready ") for line in result.stdout.splitlines()):
        raise RuntimeError("receiver was not restarted and confirmed ready")
    source = markers.get("source_sha256")
    binary = markers.get("binary_sha256")
    if source != sha256_file(SCRIPT_DIR / "metal_host.swift") or binary != sha256_file(SCRIPT_DIR / "build" / "metal_host"):
        raise RuntimeError("restarted receiver digest verification failed")
    write_json(output / "receiver-start.json", {"status": markers.get("status"),
               "metal_host_swift": source, "metal_host_binary": binary, "offload_mode": mode,
               "restarted_from_source": True, "display_sync_enabled": False})
    return {"metal_host_swift": source, "metal_host_binary": binary}


def receiver_pid_matches(pid: int) -> bool:
    import ctypes
    library = ctypes.CDLL(str(Path(Path.home().anchor) / "usr" / "lib" / "libproc.dylib"))
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        return False
    return Path(os.fsdecode(buffer.value)).resolve() == (SCRIPT_DIR / "build" / "metal_host").resolve()


def stop_metal_host() -> None:
    pid_file = SCRIPT_DIR / "build" / "metal_host.pid"
    if not pid_file.is_file():
        return
    try:
        pid = int(pid_file.read_text().strip())
    except ValueError:
        raise RuntimeError("receiver PID marker is invalid")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pid_file.unlink(missing_ok=True)
        return
    if not receiver_pid_matches(pid):
        raise RuntimeError("receiver PID does not identify the expected executable")
    os.kill(pid, 15)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pid_file.unlink(missing_ok=True)
            return
        time.sleep(0.05)
    raise RuntimeError("receiver did not stop after SIGTERM")
