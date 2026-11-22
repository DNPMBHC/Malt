#!/usr/bin/env python3
"""Run macOS 27 Game Mode bundle observation and real d3d11_probe.exe TCP offload verification."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import analyze
import run_wine_benchmark as wine_bench

SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_gamemode_plist_with_swift(app_bundle: Path) -> dict[str, Any]:
    evidence_src = WORKSPACE_ROOT / "Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/HostGameModeEvidence.swift"
    with tempfile.TemporaryDirectory(prefix="gamemode-check-") as tmp_name:
        tmp = Path(tmp_name)
        driver = tmp / "check.swift"
        driver.write_text(
            """
import Foundation

@main
struct GameModePlistCheck {
    static func main() throws {
        let path = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let evidence = HostGameModeEvidence.capture(
            infoDictionary: plist,
            platform: .current,
            subjectProcessID: ProcessInfo.processInfo.processIdentifier,
            observation: nil
        )
        let output: [String: Any] = [
            "declaration": evidence.declaration.rawValue,
            "legacy_declaration": evidence.legacyDeclaration.rawValue,
            "platform_eligible": evidence.platformEligible,
            "activation": evidence.activation.rawValue,
            "activation_evidence": evidence.activationEvidence.rawValue,
            "wine_child_benefit": evidence.wineChildBenefit.rawValue,
            "windows_guest_benefit": evidence.windowsGuestBenefit.rawValue,
            "application_category": (plist?["LSApplicationCategoryType"] as? String) ?? ""
        ]
        let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}
""",
            encoding="utf-8",
        )
        binary = tmp / "gamemode-check"
        subprocess.run(
            ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(evidence_src), str(driver), "-o", str(binary)],
            check=True,
            capture_output=True,
            text=True,
        )
        res = subprocess.run(
            [str(binary), str(app_bundle / "Contents/Info.plist")],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(res.stdout)


def main() -> int:
    out_dir = WORKSPACE_ROOT / "handoff/phase-2/evidence/window-c/gamemode-and-offload"
    out_dir.mkdir(parents=True, exist_ok=True)

    print("[c2-probe] building GraphicsLabHost.app with LSSupportsGameMode=true...", flush=True)
    build_res = subprocess.run(
        [str(SCRIPT_DIR / "build_gamemode_app.sh")],
        check=True, capture_output=True, text=True,
    )
    app_bundle = SCRIPT_DIR / "build/GraphicsLabHost.app"
    app_exec = app_bundle / "Contents/MacOS/GraphicsLabHost"

    plist_check = verify_gamemode_plist_with_swift(app_bundle)

    # Compile host-state-observer.swift into temporary binary
    observer_src = WORKSPACE_ROOT / "Whisky/WhiskyKit/Tools/host-state-observer.swift"
    components = wine_bench.resolve_wine_components(wine_bench.DEFAULT_ENGINE_ROOT)
    probe_exe = SCRIPT_DIR / "build/d3d11_probe.exe"

    host_jsonl = out_dir / "gamemode-app-offload-host.jsonl"
    offload_csv = out_dir / "wine-d3dmetal-offload-1280x720.csv"
    offload_startup_json = out_dir / "wine-d3dmetal-offload-startup.json"
    state_jsonl = out_dir / "host-state-observation.jsonl"

    with tempfile.TemporaryDirectory(prefix="c2-gamemode-offload-") as tmp_name:
        tmp = Path(tmp_name)
        observer_bin = tmp / "host-state-observer"
        subprocess.run(
            ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(observer_src), "-o", str(observer_bin)],
            check=True, capture_output=True, text=True,
        )

        # Prepare disposable D3DMetal prefix for offload verification
        print("[c2-probe] preparing disposable Wine D3DMetal prefix for real d3d11_probe.exe offload...", flush=True)
        prefix = wine_bench._prepare_prefix(components, "d3dmetal", tmp)

        # Launch GraphicsLabHost.app in native fullscreen mode with live auto policy
        port = 39014
        app_stderr = tmp / "app.stderr.log"
        print("[c2-probe] launching GraphicsLabHost.app (--fullscreen --resource-policy auto)...", flush=True)
        app_err_handle = app_stderr.open("w", encoding="utf-8")
        app_proc = subprocess.Popen(
            [
                str(app_exec),
                "--bind", "127.0.0.1",
                "--port", str(port),
                "--jsonl", str(host_jsonl),
                "--resource-policy", "auto",
                "--metalfx", "off",
                "--fullscreen",
            ],
            stdout=subprocess.DEVNULL,
            stderr=app_err_handle,
        )

        try:
            ready_line = ""
            for _ in range(60):
                if app_proc.poll() is not None:
                    raise RuntimeError("GraphicsLabHost.app exited prematurely")
                text = app_stderr.read_text(encoding="utf-8", errors="replace")
                for line in text.splitlines():
                    if line.startswith("ready "):
                        ready_line = line
                        break
                if ready_line:
                    break
                time.sleep(0.1)
            if not ready_line:
                raise RuntimeError("timed out waiting for GraphicsLabHost.app ready line")

            # Start 6s natural thermal/power/wake state observer alongside fullscreen workload
            obs_proc = subprocess.Popen(
                [
                    str(observer_bin),
                    "--duration", "6",
                    "--run-label", "sample-002",
                    "--phase", "control",
                    "--execution-domain", "wine",
                    "--game-mode-observation", "unknown",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            # Run real d3d11_probe.exe under Wine D3DMetal sending 1280x720 offload TCP frames to GraphicsLabHost.app
            print("[c2-probe] running real d3d11_probe.exe --transport-host 127.0.0.1 (1280x720, 30 warmup + 120 measured)...", flush=True)
            tmp_csv = tmp / "offload.csv"
            env = wine_bench._backend_env(components, "d3dmetal", prefix, tmp)
            wine_cmd = [
                sys.executable,
                str(SCRIPT_DIR / "run_probe.py"),
                "--json", str(offload_startup_json),
                "--",
                str(components["wine_bin"]),
                str(probe_exe),
                "--frames", "120",
                "--warmup", "30",
                "--width", "1280",
                "--height", "720",
                "--commands", "16",
                "--command-every", "30",
                "--resource-bytes", "65536",
                "--resource-every", "30",
                "--transport-host", "127.0.0.1",
                "--port", str(port),
                "--csv", wine_bench._to_wine_z_path(tmp_csv),
            ]
            wine_res = subprocess.run(wine_cmd, env=env, capture_output=True, text=True, check=False)
            wine_bench._kill_wineserver(components["wineserver_bin"], prefix)
            if wine_res.returncode != 0 or not tmp_csv.is_file():
                raise RuntimeError(f"offload probe failed (exit={wine_res.returncode}): {wine_bench.redact_text(wine_res.stderr)}")
            shutil.copy2(tmp_csv, offload_csv)

            obs_out, _ = obs_proc.communicate(timeout=15)
            state_jsonl.write_text(obs_out, encoding="utf-8")
        finally:
            if app_proc.poll() is None:
                app_proc.terminate()
                try:
                    app_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    app_proc.kill()
            app_err_handle.close()

    with offload_csv.open("r", encoding="utf-8-sig", newline="") as stream:
        offload_rows = analyze.load_rows(stream)
    offload_summary = analyze.summarize(offload_rows)
    startup_data = json.loads(offload_startup_json.read_text(encoding="utf-8"))

    # Parse host JSONL for offload session
    host_rows = [json.loads(line) for line in host_jsonl.read_text(encoding="utf-8").splitlines() if line.strip()]
    measured_host = [r for r in host_rows if not r.get("warmup", False)]

    report = {
        "schema_version": 1,
        "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": wine_bench.collect_host_metadata(),
        "game_mode_observation": {
            "app_bundle": "graphics-lab/build/GraphicsLabHost.app",
            "launch_mode": "native_fullscreen_requested_via_NSWindow_toggleFullScreen",
            "host_evidence_verifier": plist_check,
            "public_api_activation_query_available": False,
            "system_ui_manual_confirmation": False,
            "observed_activation": "unknown",
            "wine_child_benefit": "unmeasured",
            "boundary_note": (
                "Info.plist sets LSSupportsGameMode=true and LSApplicationCategoryType=public.app-category.games "
                "on an eligible macOS 27.2.1 Apple M4 host. Because macOS 27 SDK provides no public Game Mode "
                "activation query API and no manual Game Overlay UI confirmation was captured in this automated run, "
                "activation remains 'unknown' and Wine child benefit remains 'unmeasured'."
            ),
            "host_state_observer_events": len([ln for ln in state_jsonl.read_text(encoding="utf-8").splitlines() if ln.strip()]),
        },
        "wine_tcp_offload_verification": {
            "scope_note": (
                "Runs real d3d11_probe.exe (offload_tcp mode) inside a local Wine D3DMetal process over loopback TCP "
                "to GraphicsLabHost.app. Verifies D3D11 render -> CopyResource -> staging Map -> TCP -> Metal present -> ACK. "
                "This is NOT a Windows Guest boundary measurement (C3 awaits Window A's Windows Guest)."
            ),
            "workload": {
                "width": 1280,
                "height": 720,
                "warmup": 30,
                "frames": 120,
                "commands": 16,
                "command_every": 30,
                "resource_bytes": 65536,
                "resource_every": 30,
            },
            "startup": startup_data,
            "client_summary": offload_summary,
            "host_measured_frames": len(measured_host),
            "host_policy_modes_observed": sorted({str(r.get("policy_mode")) for r in measured_host}),
            "host_policy_sources_observed": sorted({str(r.get("policy_source")) for r in measured_host}),
            "host_render_paths_observed": sorted({str(r.get("render_path")) for r in measured_host}),
        },
        "immutable_digests": {
            "d3d11_probe_exe": sha256_file(probe_exe),
            "metal_host_swift": sha256_file(SCRIPT_DIR / "metal_host.swift"),
            "gamemode_app_info_plist": sha256_file(app_bundle / "Contents/Info.plist"),
            "gamemode_app_binary": sha256_file(app_exec),
            "offload_csv": sha256_file(offload_csv),
            "host_jsonl": sha256_file(host_jsonl),
            "state_jsonl": sha256_file(state_jsonl),
        },
    }
    report_path = out_dir / "observation-manifest.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"[c2-probe] completed; saved {report_path.name}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
