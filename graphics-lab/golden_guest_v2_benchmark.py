#!/usr/bin/env python3
"""Ephemeral clone before/after benchmark for UTM hardware trim + Optimizer v2.

Owner: @DNPMBHC
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import sys
import tempfile
import time
from typing import Any

import golden_guest_build_and_smoke as ggs
import golden_guest_manager as ggm

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
ROLLBACK_OPTIMIZER_PS1 = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/scripts/rollback-optimizer.ps1"
DEFAULT_OUTPUT = WORKSPACE_ROOT / "handoff/phase-9/evidence/p9-b/utm-trim-and-optimizer-v2-benchmark.json"
DEFAULT_ZERO_DRIFT = WORKSPACE_ROOT / "handoff/phase-9/evidence/p9-b/zero-drift-proof.json"


def sample_host_idle_rss_and_cpu(samples: int = 5, interval: float = 2.0) -> dict[str, float]:
    rss_totals: list[float] = []
    qemu_cpus: list[float] = []
    for _ in range(samples):
        res = ggs.run_cmd(["ps", "-axo", "rss=,%cpu=,comm="], timeout=15)
        rss_kb = 0
        qemu_cpu = 0.0
        for line in res.stdout.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) == 3:
                rss_val, cpu_val, comm = parts
                name = Path(comm).name
                if name in ("QEMULauncher", "QEMURenderServer", "swtpm.0") or name.startswith("qemu-system-"):
                    rss_kb += int(rss_val)
                if name == "QEMULauncher" or name.startswith("qemu-system-"):
                    qemu_cpu += float(cpu_val)
        rss_totals.append(rss_kb / 1024.0)
        qemu_cpus.append(qemu_cpu)
        time.sleep(interval)
    return {
        "samples": samples,
        "interval_seconds": interval,
        "total_host_rss_mib_mean": round(statistics.mean(rss_totals), 2),
        "qemu_cpu_percent_mean": round(statistics.mean(qemu_cpus), 2),
    }


def wait_vm_started_and_qga(vm_uuid: str, timeout_s: float = 240.0) -> tuple[float, float]:
    t0 = time.monotonic()
    res = ggs.run_cmd([str(ggs.UTMCTL), "start", vm_uuid], timeout=60)
    if res.returncode != 0:
        raise RuntimeError(f"utmctl start failed: {ggm.redact_text(res.stderr)}")
    vm_started_s = round(time.monotonic() - t0, 3)

    deadline = t0 + timeout_s
    while time.monotonic() < deadline:
        try:
            out = ggs.qga_ps(vm_uuid, "'ready'", timeout=15).strip()
            if out == "ready":
                return vm_started_s, round(time.monotonic() - t0, 3)
        except Exception:
            pass
        time.sleep(2.0)
    raise TimeoutError(f"QGA not ready within {timeout_s}s")


def wait_for_desktop_ready(vm_uuid: str, timeout_s: float = 120.0) -> None:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            out = ggs.qga_ps(
                vm_uuid,
                "if((Get-Process -Name explorer -ErrorAction SilentlyContinue).Count -gt 0 -and "
                "(Get-CimInstance Win32_ComputerSystem).UserName){'desktop_ready'}else{'waiting'}",
                timeout=15,
            ).strip()
            if out == "desktop_ready":
                return
        except Exception:
            pass
        time.sleep(2.0)
    raise TimeoutError(f"Interactive desktop (explorer.exe) not ready within {timeout_s}s")


def stop_vm_clean(vm_uuid: str, timeout_s: float = 120.0) -> None:
    try:
        ggs.qga_ps(vm_uuid, "Stop-Computer -Force", timeout=15)
    except Exception:
        pass
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if ggm.utmctl_status(vm_uuid) == "stopped":
            return
        time.sleep(2.0)
    ggs.run_cmd([str(ggs.UTMCTL), "stop", vm_uuid], timeout=30)


def run_smoke_with_retry(vm_uuid: str, work_dir: Path, attempts: int = 3) -> dict[str, Any]:
    last_err: Exception | None = None
    for idx in range(attempts):
        try:
            return ggs.run_guest_3d_smoke(vm_uuid, work_dir)
        except Exception as exc:
            last_err = exc
            if idx + 1 < attempts:
                time.sleep(5.0)
    assert last_err is not None
    raise last_err


def read_guest_counts(vm_uuid: str) -> dict[str, Any]:
    raw = ggs.qga_ps(
        vm_uuid,
        "$p=@(Get-Process -ErrorAction SilentlyContinue).Count;"
        "$s=@(Get-Service -ErrorAction SilentlyContinue|Where-Object{$_.Status -eq 'Running'}).Count;"
        "@{process_count=$p;running_service_count=$s}|ConvertTo-Json -Compress",
        timeout=30,
    )
    return json.loads(raw)


def run_benchmark(
    golden: Path,
    primary: Path,
    output_path: Path,
    zero_drift_path: Path,
) -> dict[str, Any]:
    lease = ggm.check_lease_and_processes()
    if not lease["ready"]:
        raise ggm.SafetyError(f"VM lease or active QEMU workers block benchmark: {lease}")

    with tempfile.TemporaryDirectory(prefix="p9b-bench-") as tmp_str:
        work_dir = Path(tmp_str)
        baseline_res: dict[str, Any] = {}
        trimmed_v2_res: dict[str, Any] = {}
        destroy_proofs: list[dict[str, Any]] = []

        # Phase 1: Baseline (untrimmed golden clone, optimizer v1 state)
        spawn1 = ggm.spawn_ephemeral(
            golden=golden,
            name="ephemeral-p9b-baseline",
            primary=primary,
            register_utm=True,
            fast_disk_hash=True,
            trim_hardware=False,
        )
        ep1 = Path(spawn1["ephemeral_path"])
        uuid1 = spawn1["clone_uuid"]
        try:
            vm_s1, qga_s1 = wait_vm_started_and_qga(uuid1)
            wait_for_desktop_ready(uuid1)
            time.sleep(10.0)
            host1 = sample_host_idle_rss_and_cpu()
            counts1 = read_guest_counts(uuid1)
            smoke1 = run_smoke_with_retry(uuid1, work_dir)
            baseline_res = {
                "clone_seconds": spawn1["clone_seconds"],
                "vm_started_seconds": vm_s1,
                "qga_ready_seconds": qga_s1,
                "host_idle": host1,
                "guest_counts": counts1,
                "d3d11_smoke": {
                    "fps": smoke1["d3d11_probe_fps"],
                    "mean_frame_ms": smoke1["mean_frame_ms"],
                    "p95_frame_ms": smoke1["p95_frame_ms"],
                    "max_channel_error_lsb": smoke1["max_channel_error_lsb"],
                    "byte_exact_match": smoke1["byte_exact_match"],
                },
            }
            stop_vm_clean(uuid1)
        finally:
            d1 = ggm.destroy_ephemeral(ep1, golden=golden, primary=primary, fast_disk_hash=True)
            destroy_proofs.append(d1)

        # Phase 2: UTM hardware trim + Optimizer v2 + Rollback verification
        spawn2 = ggm.spawn_ephemeral(
            golden=golden,
            name="ephemeral-p9b-v2",
            primary=primary,
            register_utm=True,
            fast_disk_hash=True,
            trim_hardware=True,
            fps_limit=120,
        )
        ep2 = Path(spawn2["ephemeral_path"])
        uuid2 = spawn2["clone_uuid"]
        try:
            wait_vm_started_and_qga(uuid2)
            ggs.qga_ps(uuid2, "New-Item -ItemType Directory -Force -Path 'C:\\p9b-opt' | Out-Null")
            ggs.qga_push(uuid2, ggs.APPLY_OPTIMIZER_PS1, r"C:\p9b-opt\apply-optimizer.ps1")
            ggs.qga_push(uuid2, ROLLBACK_OPTIMIZER_PS1, r"C:\p9b-opt\rollback-optimizer.ps1")
            ggs.qga_push(uuid2, ggs.OPTIMIZER_PROFILE, r"C:\p9b-opt\profile.json")
            ggs.qga_ps(
                uuid2,
                "Remove-Item -LiteralPath 'C:\\graphics-lab\\guest-optimizer\\last-apply-report.json' -ErrorAction SilentlyContinue",
                timeout=30,
            )
            apply_res = ggs.run_cmd(
                [
                    str(ggs.UTMCTL),
                    "exec",
                    uuid2,
                    "--cmd",
                    "powershell.exe",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    r"C:\p9b-opt\apply-optimizer.ps1",
                    "-ProfilePath",
                    r"C:\p9b-opt\profile.json",
                ],
                timeout=120,
            )
            if apply_res.returncode != 0:
                raise RuntimeError(f"apply-optimizer.ps1 failed: {ggm.redact_text(apply_res.stderr)}")
            apply_raw = ggs.decode_guest_text(
                ggs.qga_pull(uuid2, r"C:\graphics-lab\guest-optimizer\last-apply-report.json")
            )
            apply_report = json.loads(apply_raw)

            # Reboot clone to measure clean cold boot & idle RSS under trimmed hardware + v2 optimizer
            stop_vm_clean(uuid2)
            vm_s2, qga_s2 = wait_vm_started_and_qga(uuid2)
            wait_for_desktop_ready(uuid2)
            time.sleep(10.0)
            host2 = sample_host_idle_rss_and_cpu()
            counts2 = read_guest_counts(uuid2)
            smoke2 = run_smoke_with_retry(uuid2, work_dir)

            ggs.qga_ps(
                uuid2,
                "Remove-Item -LiteralPath 'C:\\graphics-lab\\guest-optimizer\\last-rollback-report.json' -ErrorAction SilentlyContinue",
                timeout=30,
            )
            rb_res = ggs.run_cmd(
                [
                    str(ggs.UTMCTL),
                    "exec",
                    uuid2,
                    "--cmd",
                    "powershell.exe",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    r"C:\p9b-opt\rollback-optimizer.ps1",
                    "-ProfilePath",
                    r"C:\p9b-opt\profile.json",
                ],
                timeout=120,
            )
            if rb_res.returncode != 0:
                raise RuntimeError(f"rollback-optimizer.ps1 failed: {ggm.redact_text(rb_res.stderr)}")
            rollback_raw = ggs.decode_guest_text(
                ggs.qga_pull(uuid2, r"C:\graphics-lab\guest-optimizer\last-rollback-report.json")
            )
            rollback_report = json.loads(rollback_raw)

            trimmed_v2_res = {
                "clone_seconds": spawn2["clone_seconds"],
                "trim_summary": spawn2["trim_summary"],
                "vm_started_seconds": vm_s2,
                "qga_ready_seconds": qga_s2,
                "host_idle": host2,
                "guest_counts": counts2,
                "d3d11_smoke": {
                    "fps": smoke2["d3d11_probe_fps"],
                    "mean_frame_ms": smoke2["mean_frame_ms"],
                    "p95_frame_ms": smoke2["p95_frame_ms"],
                    "max_channel_error_lsb": smoke2["max_channel_error_lsb"],
                    "byte_exact_match": smoke2["byte_exact_match"],
                },
                "optimizer_v2_apply": {
                    "profile_revision": 2,
                    "whitelist_guard_passed": apply_report.get("whitelist_guard_passed"),
                    "security_invariants_passed": apply_report.get("security_invariants_passed"),
                    "snapshot_reused": apply_report.get("snapshot_reused"),
                },
                "rollback_verification": {
                    "mismatch_count": rollback_report.get("mismatch_count"),
                    "rollback_consistent": rollback_report.get("mismatch_count") == 0,
                    "security_invariants_passed": rollback_report.get("security_invariants_passed"),
                },
            }
            stop_vm_clean(uuid2)
        finally:
            d2 = ggm.destroy_ephemeral(ep2, golden=golden, primary=primary, fast_disk_hash=True)
            destroy_proofs.append(d2)

    comparison = {
        "total_host_rss_mib_delta": round(
            trimmed_v2_res["host_idle"]["total_host_rss_mib_mean"]
            - baseline_res["host_idle"]["total_host_rss_mib_mean"],
            2,
        ),
        "qemu_cpu_percent_delta": round(
            trimmed_v2_res["host_idle"]["qemu_cpu_percent_mean"]
            - baseline_res["host_idle"]["qemu_cpu_percent_mean"],
            2,
        ),
        "guest_process_count_delta": (
            trimmed_v2_res["guest_counts"]["process_count"]
            - baseline_res["guest_counts"]["process_count"]
        ),
        "guest_running_service_count_delta": (
            trimmed_v2_res["guest_counts"]["running_service_count"]
            - baseline_res["guest_counts"]["running_service_count"]
        ),
        "qga_ready_seconds_delta": round(
            trimmed_v2_res["qga_ready_seconds"] - baseline_res["qga_ready_seconds"], 3
        ),
        "d3d11_probe_fps_delta": round(
            trimmed_v2_res["d3d11_smoke"]["fps"] - baseline_res["d3d11_smoke"]["fps"], 3
        ),
    }

    payload = {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "captured_at_utc": ggm.utc_now_iso(),
        "baseline_v1": baseline_res,
        "trimmed_v2": trimmed_v2_res,
        "comparison": comparison,
    }
    ggm.write_redacted_json(output_path, payload)

    zero_drift = {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "captured_at_utc": ggm.utc_now_iso(),
        "ephemeral_runs_destroyed": len(destroy_proofs),
        "all_ephemeral_deleted": all(bool(d.get("ephemeral_deleted")) for d in destroy_proofs),
        "golden_zero_drift": all(bool(d.get("golden_zero_drift")) for d in destroy_proofs),
        "primary_zero_drift": all(bool(d.get("primary_zero_drift")) for d in destroy_proofs),
        "destroy_proofs": destroy_proofs,
    }
    ggm.write_redacted_json(zero_drift_path, zero_drift)
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description="Phase 9B ephemeral clone benchmark (@DNPMBHC)")
    parser.add_argument("--golden", type=Path, default=ggs.DEFAULT_GOLDEN)
    parser.add_argument("--primary", type=Path, default=ggs.DEFAULT_PRIMARY)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--zero-drift-output", type=Path, default=DEFAULT_ZERO_DRIFT)
    args = parser.parse_args()
    result = run_benchmark(args.golden, args.primary, args.output, args.zero_drift_output)
    print(json.dumps(ggm.redact_value(result), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
