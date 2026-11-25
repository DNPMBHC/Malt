#!/usr/bin/env python3
"""Preflight comparison of neptune_umd vs DXVK 2.5.3 -> WHQL vulkan_virtio (Venus) on d3d11_probe.exe.

Owner: @DNPMBHC
"""
from __future__ import annotations

import json
from pathlib import Path
import statistics
import tempfile
import time

import p7_valorant_analyzer as analyzer
import p7_valorant_session as sess
import pixel_compare

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
D3D11_PROBE = WORKSPACE_ROOT / "graphics-lab/build/d3d11_probe.exe"
WARP_REF = (
    WORKSPACE_ROOT
    / "handoff/phase-2/evidence/window-c/m0-m2-guest-final/run-20261122-140047-utc/pixel-validation/validate-legacy-0/validate-legacy-0-reference.rgba"
)
DXVK_253_X64 = Path("/tmp/p7a-dxvk/dxvk-2.5.3/x64")
OUT_JSON = WORKSPACE_ROOT / "handoff/phase-7/evidence/p7-a/venus-preflight-probe.json"


def run_probe_arm(vm_uuid: str, guest_dir: str, label: str, push_dxvk: bool) -> dict:
    sess.qga_ps(vm_uuid, f"New-Item -ItemType Directory -Force -Path '{guest_dir}' | Out-Null", timeout=30)
    sess.qga_push(vm_uuid, D3D11_PROBE, f"{guest_dir}\\d3d11_probe.exe")
    if push_dxvk:
        for dll in ("d3d11.dll", "dxgi.dll"):
            sess.qga_push(vm_uuid, DXVK_253_X64 / dll, f"{guest_dir}\\{dll}")

    ps_body = (
        "$ErrorActionPreference = 'Continue'\n"
        f"$env:DXVK_LOG_LEVEL = 'info'\n"
        f"$env:DXVK_LOG_PATH = '{guest_dir}'\n"
        "$code = 1\n"
        "try {\n"
        f"  & '{guest_dir}\\d3d11_probe.exe' --frames 1 --warmup 0 --width 1280 --height 720 --commands 16 --resource-bytes 65536 --command-every 30 --resource-every 30 --resource-pattern legacy --seed 1 --completion-mode gpu-complete --driver-type hardware --capture-rgba '{guest_dir}\\frame0.rgba' --capture-frame 0 --metadata-json '{guest_dir}\\meta.json' > '{guest_dir}\\out.log' 2> '{guest_dir}\\err.log'\n"
        "  $code = $LASTEXITCODE\n"
        "  if ($code -eq 0) {\n"
        f"    & '{guest_dir}\\d3d11_probe.exe' --frames 300 --warmup 60 --width 1280 --height 720 --commands 16 --resource-bytes 65536 --command-every 30 --resource-every 30 --resource-pattern legacy --seed 1 --completion-mode gpu-complete --driver-type hardware --csv '{guest_dir}\\perf.csv' >> '{guest_dir}\\out.log' 2>> '{guest_dir}\\err.log'\n"
        "    $code = $LASTEXITCODE\n"
        "  }\n"
        "} finally {\n"
        f"  Set-Content -LiteralPath '{guest_dir}\\done' -Value ([string]$code)\n"
        "}\n"
    )
    with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False, encoding="utf-8") as f:
        f.write(ps_body)
        tmp_ps = Path(f.name)
    try:
        sess.qga_push(vm_uuid, tmp_ps, f"{guest_dir}\\run.ps1")
    finally:
        tmp_ps.unlink(missing_ok=True)

    task_name = f"p7a-vk-{label}"
    launch = (
        "$user=(Get-CimInstance Win32_ComputerSystem).UserName;"
        "if(!$user){throw 'No interactive desktop user'};"
        f"Remove-Item -LiteralPath '{guest_dir}\\done','{guest_dir}\\meta.json','{guest_dir}\\perf.csv','{guest_dir}\\frame0.rgba' -ErrorAction SilentlyContinue;"
        f"$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File {guest_dir}\\run.ps1';"
        "$p=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited;"
        f"Register-ScheduledTask -TaskName '{task_name}' -Action $a -Principal $p -Force | Out-Null;"
        f"Start-ScheduledTask -TaskName '{task_name}'; 'ok'"
    )
    sess.qga_ps(vm_uuid, launch, timeout=30)

    deadline = time.monotonic() + 120
    exit_code = None
    while time.monotonic() < deadline:
        val = sess.qga_ps(
            vm_uuid,
            f"if(Test-Path '{guest_dir}\\done'){{(Get-Content '{guest_dir}\\done').Trim()}}else{{'pending'}}",
            timeout=15,
        ).strip()
        if val != "pending":
            exit_code = int(val)
            break
        time.sleep(1.5)
    sess.qga_ps(vm_uuid, f"Unregister-ScheduledTask -TaskName '{task_name}' -Confirm:$false -ErrorAction SilentlyContinue", timeout=20)
    if exit_code is None:
        raise TimeoutError(f"{label} probe timed out")

    result: dict = {"label": label, "push_dxvk": push_dxvk, "exit_code": exit_code}
    try:
        meta = json.loads(sess.decode_guest_text(sess.qga_pull(vm_uuid, f"{guest_dir}\\meta.json")))
        result["meta"] = meta
    except Exception as exc:
        result["meta_error"] = str(exc)

    try:
        frame = sess.qga_pull(vm_uuid, f"{guest_dir}\\frame0.rgba")
        cmp_res = pixel_compare.compare_rgba(WARP_REF.read_bytes(), frame, 1280, 720, tolerance=0)
        result["pixel_compare"] = {
            "max_channel_error_lsb": cmp_res["max_channel_error"],
            "over_threshold_pixels": cmp_res["over_threshold_pixels"],
            "byte_exact_match": cmp_res["passed"],
        }
    except Exception as exc:
        result["pixel_error"] = str(exc)

    try:
        perf_csv = sess.decode_guest_text(sess.qga_pull(vm_uuid, f"{guest_dir}\\perf.csv"))
        lines = [ln.strip() for ln in perf_csv.splitlines() if ln.strip()]
        hdr = lines[0].split(",")
        idx = hdr.index("cpu_frame_ms")
        durs = [float(r.split(",")[idx]) for r in lines[1:] if float(r.split(",")[idx]) > 0]
        if durs:
            mean_ms = round(statistics.mean(durs), 3)
            sd = sorted(durs)
            p95 = round(sd[min(len(sd) - 1, int(0.95 * len(sd)))], 3)
            result["fps"] = round(1000.0 / mean_ms, 3)
            result["mean_frame_ms"] = mean_ms
            result["p95_frame_ms"] = p95
    except Exception as exc:
        result["perf_error"] = str(exc)

    if push_dxvk:
        dxvk_logs = {}
        for log_name in ("d3d11_probe_d3d11.log", "d3d11_probe_dxgi.log"):
            try:
                txt = sess.decode_guest_text(sess.qga_pull(vm_uuid, f"{guest_dir}\\{log_name}"))
                dxvk_logs[log_name] = analyzer.redact_p7_text("\n".join(txt.splitlines()[:60]))
            except Exception:
                pass
        result["dxvk_logs"] = dxvk_logs
    try:
        result["stderr_head"] = analyzer.redact_p7_text(
            "\n".join(sess.decode_guest_text(sess.qga_pull(vm_uuid, f"{guest_dir}\\err.log")).splitlines()[:30])
        )
    except Exception:
        pass
    return result


def main() -> int:
    uid = sess.load_session_state()["clone_uuid"]
    neptune_res = run_probe_arm(uid, r"C:\p7a-probe-neptune", "neptune", push_dxvk=False)
    dxvk_res = run_probe_arm(uid, r"C:\p7a-probe-dxvk", "dxvk", push_dxvk=True)
    payload = analyzer.redact_p7_value(
        {
            "schema_version": 1,
            "owner": "@DNPMBHC",
            "captured_at_utc": analyzer.utc_now_iso(),
            "dxvk_version": "2.5.3",
            "neptune_umd": neptune_res,
            "dxvk_venus": dxvk_res,
        }
    )
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
