#!/usr/bin/env python3
"""Phase 9A-1 automated unlock of UTM native DXMT backend + D3DMetal vs DXMT d3d11_probe comparison.

Owner: @DNPMBHC
"""
from __future__ import annotations

import json
from pathlib import Path
import time
import uuid

import golden_guest_manager as ggm
import p8_valorant_session as p8s
import p9_valorant_analyzer as analyzer
import p9_valorant_session as p9s

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
EVIDENCE_P9A = WORKSPACE_ROOT / "handoff/phase-9/evidence/p9-a"


def wait_for_qga_and_user(vm_uuid: str, timeout: float = 180.0) -> float:
    t0 = time.monotonic()
    deadline = t0 + timeout
    while time.monotonic() < deadline:
        try:
            if p9s.qga_ps(vm_uuid, "'p9a-ready'", timeout=15).strip() == "p9a-ready":
                ready_s = round(time.monotonic() - t0, 3)
                # Wait briefly for interactive user logon
                u_dl = time.monotonic() + 45
                while time.monotonic() < u_dl:
                    if p9s.qga_ps(vm_uuid, "(Get-CimInstance Win32_ComputerSystem).UserName", timeout=15).strip():
                        break
                    time.sleep(1.5)
                return ready_s
        except Exception:
            pass
        time.sleep(1.5)
    raise TimeoutError("Timed out waiting for QGA readiness")


def stop_vm_clean(vm_uuid: str) -> None:
    st = ggm.utmctl_status(vm_uuid, p9s.UTMCTL)
    if st not in ("stopped", "unregistered"):
        p9s.run_cmd([str(p9s.UTMCTL), "stop", vm_uuid, "--request"], timeout=30)
        for _ in range(25):
            if ggm.utmctl_status(vm_uuid, p9s.UTMCTL) in ("stopped", "unregistered"):
                return
            time.sleep(1.0)
        p9s.run_cmd([str(p9s.UTMCTL), "stop", vm_uuid, "--kill"], timeout=30)
        time.sleep(3.0)


def main() -> int:
    EVIDENCE_P9A.mkdir(parents=True, exist_ok=True)
    guest_root = p9s._external_guest_root()
    vms_dir = guest_root / "vms"
    primary = vms_dir / "Windows11-ARM64.utm"
    golden = vms_dir / "golden-win11-arm64-v1.utm"
    state_path = p9s._session_state_path()
    if state_path.exists():
        state = json.loads(state_path.read_text(encoding="utf-8"))
        eph_path = Path(state["ephemeral_path"])
        eph_uuid = state["clone_uuid"]
        print("[1/5] Reusing existing ephemeral-p9a-valorant...", flush=True)
    else:
        print("[1/5] Spawning ephemeral-p9a-valorant with DynamicResolution=False + CoW data disk...", flush=True)
        spawn_res = ggm.spawn_ephemeral(
            golden=golden,
            dest_dir=vms_dir,
            name="ephemeral-p9a-valorant",
            primary=primary,
            register_utm=False,
            fast_disk_hash=True,
        )
        eph_path = Path(spawn_res["ephemeral_path"])
        eph_uuid = spawn_res["clone_uuid"]

        cfg = ggm.read_config_plist(eph_path)
        cfg.setdefault("Display", [{}])
        cfg["Display"][0]["DynamicResolution"] = False

        cache_disk = guest_root / "game-cache" / "valorant-cn-data.qcow2"
        cache_before_stat = None
        if cache_disk.is_file():
            st = cache_disk.stat()
            cache_before_stat = {"size_bytes": st.st_size, "mtime_ns": st.st_mtime_ns}
            clone_data_name = f"p9a-data-{uuid.uuid4().hex[:8]}.qcow2"
            cp_res = p9s.run_cmd(["cp", "-c", str(cache_disk), str(eph_path / "Data" / clone_data_name)], timeout=60)
            if cp_res.returncode != 0:
                raise RuntimeError(f"CoW clone of data disk failed: {cp_res.stderr}")
            cfg.setdefault("Drive", []).append(
                {
                    "Identifier": str(uuid.uuid4()).upper(),
                    "ImageName": clone_data_name,
                    "ImageType": "Disk",
                    "Interface": "NVMe",
                    "InterfaceVersion": 1,
                    "ReadOnly": False,
                }
            )
        ggm.write_config_plist(eph_path, cfg)

        state = {
            "owner": "@DNPMBHC",
            "created_at_utc": analyzer.utc_now_iso(),
            "clone_name": "ephemeral-p9a-valorant",
            "clone_uuid": eph_uuid,
            "ephemeral_path": str(eph_path),
            "primary_path": str(primary),
            "golden_path": str(golden),
            "clone_seconds": spawn_res["clone_seconds"],
            "cache_disk_path": str(cache_disk) if cache_before_stat else None,
            "cache_before_stat": cache_before_stat,
        }
        state_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")

        p9s.run_cmd(["open", "-a", "UTM", str(eph_path)], timeout=30)
        for _ in range(30):
            if ggm.utmctl_status(eph_uuid, p9s.UTMCTL) != "unregistered":
                break
            time.sleep(0.5)

    print("[2/5] Running d3d11_probe baseline under default D3DMetal backend...", flush=True)
    if ggm.utmctl_status(eph_uuid, p9s.UTMCTL) != "started":
        p9s.run_cmd([str(p9s.UTMCTL), "start", eph_uuid], timeout=120)
    wait_for_qga_and_user(eph_uuid)
    d3dmetal_res = p9s.run_d3d11_probe_check(eph_uuid, "d3dmetal")
    print(
        f"  D3DMetal probe: fps={d3dmetal_res['fps']}, gpu_ms={d3dmetal_res['gpu_ms_mean']}, "
        f"backend={d3dmetal_res['render_server_lsof']['overall']['active_backend']}",
        flush=True,
    )

    # Try switching QEMUDirectXDriver to unlock dxmt-native.framework
    dxmt_res = None
    winning_setting = None
    for candidate_val in ("dxmt", 1, 2):
        print(f"[3/5] Switching QEMUDirectXDriver={candidate_val!r} and restarting VM...", flush=True)
        stop_vm_clean(eph_uuid)
        set_info = p9s.set_utm_directx_driver(candidate_val, restart_utm=True)
        p9s.run_cmd([str(p9s.UTMCTL), "start", eph_uuid], timeout=120)
        wait_for_qga_and_user(eph_uuid)
        probe_res = p9s.run_d3d11_probe_check(eph_uuid, f"dxmt-{candidate_val}")
        active = probe_res["render_server_lsof"]["overall"]["active_backend"]
        print(
            f"  Candidate {candidate_val!r}: fps={probe_res['fps']}, gpu_ms={probe_res['gpu_ms_mean']}, active_backend={active}",
            flush=True,
        )
        if probe_res["render_server_lsof"]["overall"]["dxmt_native_loaded"]:
            dxmt_res = probe_res
            winning_setting = {"key": "QEMUDirectXDriver", "value": candidate_val, "type": type(candidate_val).__name__, **set_info}
            break

    if dxmt_res is None:
        raise RuntimeError("Failed to activate dxmt-native.framework via QEMUDirectXDriver candidates ('dxmt', 1, 2)")

    cmp_summary = analyzer.compare_probe_backends(d3dmetal_res, dxmt_res)
    probe_bundle = analyzer.redact_p9_value(
        {
            "owner": "@DNPMBHC",
            "captured_at_utc": analyzer.utc_now_iso(),
            "winning_utm_setting": winning_setting,
            "d3dmetal_probe": d3dmetal_res,
            "dxmt_probe": dxmt_res,
            "comparison": cmp_summary,
        }
    )
    (EVIDENCE_P9A / "dxmt-vs-d3dmetal-probe.json").write_text(
        json.dumps(probe_bundle, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print("[4/5] Locking static 1280x720 + software cursor + pre-seeding GameUserSettings.ini...", flush=True)
    # Pre-seed GameUserSettings.ini before configure_guest_display_and_pointer
    seed_ps = r"""
$dir = 'F:\VALORANT_CN\Tencent Games\VALORANT\live\ShooterGame\Saved\Config\WindowsClient'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$ini = @"
[/Script/ShooterGame.ShooterGameUserSettings]
bShouldLetterbox=True
bLastConfirmedShouldLetterbox=True
bUseVSync=False
bUseDynamicResolution=False
ResolutionSizeX=1280
ResolutionSizeY=720
LastUserConfirmedResolutionSizeX=1280
LastUserConfirmedResolutionSizeY=720
WindowPosX=0
WindowPosY=0
FullscreenMode=2
LastConfirmedFullscreenMode=2
PreferredFullscreenMode=2
FrameRateLimit=0.000000
DesiredScreenWidth=1280
DesiredScreenHeight=720
LastUserConfirmedDesiredScreenWidth=1280
LastUserConfirmedDesiredScreenHeight=720

[/Script/Engine.GameUserSettings]
bUseDesiredScreenHeight=False
"@
Set-Content -LiteralPath (Join-Path $dir 'GameUserSettings.ini') -Value $ini -Encoding ASCII
'ok'
"""
    p9s.qga_ps(eph_uuid, seed_ps, timeout=25)
    disp_res = p8s.configure_guest_display_and_pointer(eph_uuid, width=1280, height=720, mouse_trails=2, fullscreen_mode=2)

    print("[5/5] Transferring and visibly launching official target-cn installer...", flush=True)
    installer_sha = p8s.transfer_and_launch_installer(eph_uuid)
    state["winning_utm_setting"] = winning_setting
    state["display_and_pointer"] = disp_res
    state["installer_sha256"] = installer_sha
    state_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    print("READY FOR T4! DXMT active:", winning_setting, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
