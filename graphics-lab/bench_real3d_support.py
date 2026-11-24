"""Isolated runtime and redacted evidence support. Owner: @DNPMBHC."""
from __future__ import annotations
import base64
import ctypes
import hashlib
import fcntl
from contextlib import contextmanager
import json
import os
import plistlib
import re
import shutil
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / "handoff/phase-5/evidence/p5-a"
CTL = Path(Path.home().anchor) / "Applications/UTM.app/Contents/MacOS/utmctl"


def redact(text: str) -> str:
    for task in (ROOT / "handoff/phase-5").glob("window-5a-*.md"):
        heading = task.read_text().splitlines()[0]
        if "任务书：" in heading and "双端" in heading:
            label = heading.split("任务书：", 1)[1].split("双端", 1)[0].strip()
            if label:
                text = text.replace(label, "target-cn")
    download = EVIDENCE / "official-download-center.json"
    if download.is_file():
        try:
            label = json.loads(download.read_text())["payload"]["aclos_download_center"]["verName"]
            if label and label != "target-cn":
                text = text.replace(label, "target-cn")
        except (KeyError, ValueError):
            pass
    for path, label in [(ROOT, "<workspace>"), (Path.home(), "<home>")]:
        text = text.replace(str(path), label).replace(str(path).replace("/", "\\"), label)
    for folder in ROOT.iterdir():
        if folder.is_dir() and folder.name not in ("graphics-lab", "handoff", ".git"):
            text = text.replace(folder.name, "module-x")
    text = text.replace(ROOT.name, "my-project")
    # Resolve the display name dynamically; never embed private labels in code.
    for installer in ROOT.glob("*_CN_installer_*.exe"):
        label = installer.name.split("_CN_installer_")[0]
        text = re.sub(re.escape(label), "target-cn", text, flags=re.I)
    text = re.sub(r"(?:[A-Z]:)?[/\\]Users[/\\][^\s\"'<>]+", "<local-path>", text, flags=re.I)
    text = re.sub(r"(?:[A-Z]:)?[/\\]Volumes[/\\][^\s\"'<>]+", "<EXTERNAL_VOLUME>", text)
    text = re.sub(r"(?:[A-Z]:)?[/\\](?:private[/\\])?var[/\\]folders[/\\][^\s\"'<>]+", "<tmp>", text)
    text = re.sub(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "<email>", text)
    text = re.sub(r"(?<![\w@])" + re.escape(Path.home().name) + r"(?!\w)", "user-x", text, flags=re.I)
    return text


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(redact(json.dumps(value, indent=2, ensure_ascii=False)) + "\n")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(4 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def utc() -> str:
    return datetime.now(timezone.utc).isoformat()


def run(args: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, timeout=kw.pop("timeout", 60), **kw)


def vm_packages() -> list[Path]:
    found = []
    volumes = Path(Path.home().anchor) / "Volumes"
    for vol in volumes.iterdir():
        if not vol.is_dir() or vol.is_symlink():
            continue
        for dp, dirs, _files in os.walk(vol):
            base = Path(dp)
            found.extend(base / name for name in dirs if name.endswith(".utm"))
            dirs[:] = [name for name in dirs if not name.startswith(".") and
                       not name.endswith(".utm") and name not in ("node_modules", "build", "Caches")]
            if len(base.relative_to(vol).parts) >= 3:
                dirs[:] = []
    return found


def source_vm() -> Path:
    candidates = [p for p in vm_packages() if p.name != "test-vm-p5a.utm"]
    if len(candidates) > 1:
        baseline = EVIDENCE / "vm-source-before.json"
        if baseline.is_file():
            records = json.loads(baseline.read_text()).get("files", [])
            digests = {item["sha256"] for item in records
                       if item["artifact_alias"].endswith(".plist")}
            candidates = [p for p in candidates
                          if (p / "config.plist").is_file()
                          and sha256(p / "config.plist") in digests]
    if len(candidates) != 1:
        raise RuntimeError("Expected exactly one clean source VM; refusing ambiguous selection")
    return candidates[0]


def runtime_dir() -> Path:
    return source_vm().parent / "p5-a-runtime"


def clone_path() -> Path:
    return runtime_dir() / "test-vm-p5a.utm"


def vm_id(package: Path) -> str:
    return str(plistlib.loads((package / "config.plist").read_bytes())["Information"]["UUID"])


def status(package: Path) -> str:
    r = run([str(CTL), "status", vm_id(package)], text=True)
    if r.returncode:
        return "unregistered"
    return r.stdout.strip().lower()


def runtime_isolation() -> dict:
    """Bind live UTM workers to the owned package without registering the source."""
    source, target = source_vm(), clone_path()
    source_state = status(source)
    if source_state not in ("stopped", "unregistered"):
        raise RuntimeError("Clean source may be active; refusing measurement")
    owner = json.loads((runtime_dir() / "ownership.json").read_text())
    if owner.get("phase") != "p5-a" or source == target:
        raise RuntimeError("Runtime ownership mismatch")
    inventory = run(["ps", "-axo", "pid=,ppid=,comm="], text=True)
    arguments = run(["ps", "-axo", "pid=,command="], text=True)
    if inventory.returncode or arguments.returncode:
        raise RuntimeError("Live runtime inventory unavailable")
    table = {}
    commands = {}
    for line in inventory.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            table[int(fields[0])] = (int(fields[1]), Path(fields[2]).name)
    for line in arguments.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2:
            commands[int(fields[0])] = fields[1]
    workers = {pid for pid, (_parent, name) in table.items()
               if name in ("QEMULauncher", "QEMURenderServer", "swtpm.0")
               or name.startswith("qemu-system-")}
    roots = {pid for pid in workers if table[pid][1] != "QEMURenderServer"}
    source_uuid, target_uuid = vm_id(source), vm_id(target)
    for pid in roots:
        command = commands.get(pid, "")
        if str(source) in command or source_uuid in command:
            raise RuntimeError("Clean source runtime detected")
        if str(target) not in command or target_uuid not in command:
            raise RuntimeError("Unowned or unbound hypervisor worker detected")
    family = set(roots)
    while True:
        expanded = family | {pid for pid, (parent, _name) in table.items() if parent in family}
        if expanded == family:
            break
        family = expanded
    if workers - family:
        raise RuntimeError("Unowned render worker detected")
    return {"source_registration_state": source_state,
            "source_runtime_absent_verified": True,
            "all_hypervisor_workers_bound_to_owned_clone": True,
            "root_pids": sorted(roots), "worker_count": len(workers),
            "captured_at_utc": utc(),
            "method": "live executable inventory, package and UUID arguments, descendant binding"}


def fingerprint(package: Path) -> dict:
    records = []
    for i, p in enumerate(sorted(x for x in package.rglob("*") if x.is_file())):
        if p.is_symlink():
            raise RuntimeError("Source package contains a symlink")
        s = p.stat()
        records.append({"artifact_alias": f"vm-file-{i}{p.suffix}", "size_bytes": s.st_size,
                        "mtime_ns": s.st_mtime_ns, "sha256": sha256(p)})
    return {"files": records, "total_bytes": sum(x["size_bytes"] for x in records)}


def create_clone() -> dict:
    source = source_vm()
    if status(source) != "stopped":
        raise RuntimeError("Clean VM must be stopped; refusing to touch it")
    target = clone_path()
    runtime = runtime_dir()
    if target.exists() or (runtime / "ownership.json").exists():
        raise RuntimeError("An isolated runtime already exists; inspect ownership before continuing")
    disk = run(["diskutil", "info", "-plist", str(source)], text=False)
    if disk.returncode:
        disk = run(["diskutil", "info", "-plist", str(next(p for p in source.parents if p.parent.name == "Volumes"))], text=False)
    info = plistlib.loads(disk.stdout)
    if info.get("FilesystemType") != "apfs":
        raise RuntimeError("APFS clone is required")
    before = fingerprint(source)
    write_json(EVIDENCE / "vm-source-before.json", before)
    runtime.mkdir(parents=True, exist_ok=False)
    write_json(runtime / "ownership.json", {"owner": "@DNPMBHC", "phase": "p5-a", "created_at": utc()})
    libc = ctypes.CDLL(None, use_errno=True)
    clone = libc.clonefile
    clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    clone.restype = ctypes.c_int
    target.mkdir()
    for p in source.rglob("*"):
        dest = target / p.relative_to(source)
        if p.is_symlink():
            raise RuntimeError("Clone source contains a symlink")
        if p.is_dir():
            dest.mkdir(exist_ok=True)
        elif p.is_file():
            if clone(os.fsencode(p), os.fsencode(dest), 0):
                raise OSError(ctypes.get_errno(), "APFS clonefile failed")
    meta = plistlib.loads((target / "config.plist").read_bytes())
    meta["Information"]["UUID"] = str(uuid.uuid4()).upper()
    meta["Information"]["Name"] = "test-vm-p5a"
    meta["Display"][0]["Hardware"] = "virtio-ramfb-gl"
    meta["Sharing"] = {"ClipboardSharing": False, "DirectoryShareMode": "None", "DirectoryShareReadOnly": True}
    for drive in meta["Drive"]:
        image = drive.get("ImageName")
        if drive.get("ImageType") == "Disk":
            if not image or Path(image).name != image or not (target / "Data" / image).is_file():
                raise RuntimeError("Writable drive is not contained in isolated clone")
        else:
            drive.pop("ImageName", None)
    if not meta["QEMU"].get("UEFIBoot") or not meta["QEMU"].get("TPMDevice"):
        raise RuntimeError("UEFI and TPM are required")
    if meta["QEMU"].get("AdditionalArguments"):
        raise RuntimeError("Unexpected QEMU overrides; inspect before boot")
    (target / "config.plist").write_bytes(plistlib.dumps(meta))
    if fingerprint(source) != before:
        raise RuntimeError("Source fingerprint changed during clone creation")
    proof = {"owner": "@DNPMBHC", "status": "held", "vm_alias": "test-vm-p5a", "created_at": utc(),
             "clone_method": "APFS clonefile per artifact", "source_stopped": True,
             "source_fingerprint_unchanged": True, "writable_disks_contained": True,
             "shared_directory_disabled": True, "next_window": "5C"}
    write_json(EVIDENCE / "vm-lease.json", proof)
    return proof


def start_clone() -> dict:
    target = clone_path()
    if not target.is_dir() or target == source_vm():
        raise RuntimeError("Owned clone is missing")
    r = run(["open", "-a", "UTM", str(target)], text=True)
    if r.returncode:
        raise RuntimeError("Unable to register owned clone")
    for _ in range(20):
        if status(target) != "unregistered":
            break
        time.sleep(0.5)
    r = run([str(CTL), "start", vm_id(target)], text=True, timeout=120)
    if r.returncode:
        raise RuntimeError("Owned clone start failed: " + redact(r.stderr))
    return {"clone_started": True, "source_status": status(source_vm())}


@contextmanager
def guest_transaction():
    with (runtime_dir() / "qga.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def ps(source: str, timeout: float = 60) -> str:
    target = clone_path()
    if not target.is_dir() or target == source_vm():
        raise RuntimeError("Guest command requires owned clone")
    token = uuid.uuid4().hex
    wrapped = "$ProgressPreference='SilentlyContinue'; $result = & { " + source + " }; " + "@{query_token='" + token + "';output=($result|Out-String).Trim()}|ConvertTo-Json -Depth 4 -Compress"
    encoded = base64.b64encode(wrapped.encode("utf-16-le")).decode()
    with guest_transaction():
        try:
            r = run([str(CTL), "exec", vm_id(target), "--cmd", "powershell.exe", "-NoProfile", "-EncodedCommand", encoded], text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError("Guest control timeout; native completion remains unknown") from None
    if r.returncode:
        raise RuntimeError("Guest command failed: " + redact(r.stderr))
    try:
        envelope = json.loads(r.stdout.strip().lstrip("\ufeff"))
    except ValueError:
        raise RuntimeError("Guest control response is not a bound JSON envelope") from None
    if envelope.get("query_token") != token:
        write_json(EVIDENCE / "guest-control-response-mismatch.json", {"captured_at":utc(), "status":"rejected stale response", "query_sha256":hashlib.sha256(source.encode()).hexdigest(), "response_sha256":hashlib.sha256(r.stdout.encode()).hexdigest()})
        raise RuntimeError("Guest control response belongs to a different query; refusing to infer success")
    return str(envelope.get("output", ""))


def push(local: Path, guest: str) -> None:
    with local.open("rb") as f:
        with guest_transaction():
            r = run([str(CTL), "file", "push", vm_id(clone_path()), guest], stdin=f, text=False, timeout=180)
    if r.returncode:
        raise RuntimeError("Owned clone upload failed")


def pull(guest: str) -> bytes:
    with guest_transaction():
        r = run([str(CTL), "file", "pull", vm_id(clone_path()), guest], text=False, timeout=180)
    if r.returncode:
        raise RuntimeError("Owned clone artifact retrieval failed")
    return r.stdout


def cleanup_clone(preserve_host_runtime: bool = False) -> dict:
    runtime = runtime_dir()
    target = clone_path()
    owner = json.loads((runtime / "ownership.json").read_text())
    if owner.get("phase") != "p5-a" or target == source_vm():
        raise RuntimeError("Runtime ownership mismatch")
    prior = json.loads((EVIDENCE / "vm-lease.json").read_text())
    isolation = None
    sharing_disabled = prior.get("shared_directory_disabled", False)
    disks_contained = prior.get("writable_disks_contained", False)
    if target.exists():
        state = status(target)
        if state not in ("stopped", "unregistered"):
            run([str(CTL), "stop", vm_id(target), "--request"], text=True)
            for _ in range(30):
                if status(target) == "stopped":
                    break
                time.sleep(1)
            if status(target) != "stopped":
                raise RuntimeError("Guest has not stopped; refusing removal")
        isolation = runtime_isolation()
        if isolation["worker_count"]:
            raise RuntimeError("Owned VM workers remain alive; refusing removal")
        config = plistlib.loads((target / "config.plist").read_bytes())
        sharing = config.get("Sharing", {})
        sharing_disabled = (sharing.get("DirectoryShareMode") == "None"
                            and not sharing.get("ClipboardSharing"))
        disks_contained = all(
            drive.get("ImageName")
            and Path(drive["ImageName"]).name == drive["ImageName"]
            and (target / "Data" / drive["ImageName"]).is_file()
            and not (target / "Data" / drive["ImageName"]).is_symlink()
            for drive in config.get("Drive", []) if drive.get("ImageType") == "Disk")
        if not sharing_disabled or not disks_contained:
            raise RuntimeError("Clone isolation proof failed before removal")
        if status(target) != "unregistered":
            r = run([str(CTL), "delete", vm_id(target)], text=True)
            if r.returncode:
                raise RuntimeError("Owned clone unregister/delete failed")
        if target.exists():
            shutil.rmtree(target)
    before = json.loads((EVIDENCE / "vm-source-before.json").read_text())
    after = fingerprint(source_vm())
    write_json(EVIDENCE / "vm-source-after.json", after)
    if after != before:
        raise RuntimeError("Clean VM fingerprint mismatch")
    if not preserve_host_runtime:
        shutil.rmtree(runtime)
    proof = {"owner": "@DNPMBHC", "status": "released",
             "released_at": prior.get("released_at") or utc(), "verified_at": utc(), "next_window": "5C",
             "isolated_clone_deleted": not target.exists(), "owned_runtime_deleted": not runtime.exists(),
             "host_only_runtime_cleanup_pending": preserve_host_runtime,
             "shared_directory_disabled": sharing_disabled, "writable_disks_contained": disks_contained,
             "source_sha256_and_mtime_unchanged": True, "source_status": status(source_vm()),
             "pre_delete_runtime_isolation": isolation or prior.get("pre_delete_runtime_isolation"),
             "evidence_refs": ["vm-source-before.json", "vm-source-after.json", "vm-cleanup-proof.json"]}
    write_json(EVIDENCE / "vm-cleanup-proof.json", proof)
    write_json(EVIDENCE / "vm-lease.json", proof)
    return proof
