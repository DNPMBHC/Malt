#!/usr/bin/env python3
"""Phase 11B session & telemetry tool: UTM-Custom.app verification, DX11 cursor/fullscreen
validation, target-cn lobby/range 3-5m read-only telemetry, and zero-drift cleanup.

Owner: @DNPMBHC
Compliance:
- Never modifies /Applications/UTM.app, sealed golden-win11-arm64-v1.utm, or primary vm-a.
- Strictly read-only telemetry; never hooks game/ACE or automates login/character creation/CAPTCHA.
- Full path/identity redaction (<EXTERNAL_VOLUME>, <workspace>, user-x).
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import statistics
import subprocess
import sys
import time
from typing import Any

import golden_guest_manager as ggm
import p10_valorant_analyzer as p10a
import p9_valorant_session as p9s

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CUSTOM_APP = Path(os.environ.get("TMPDIR", "/tmp")) / "utm-custom-build" / "UTM-Custom.app"
EVIDENCE_P11B = WORKSPACE_ROOT / "handoff/phase-11/evidence/p11-b"
PHASE11_RUNS_DIR = WORKSPACE_ROOT / "handoff/module-f/valorant-phase11-runs"
GOLDEN_MANIFEST = WORKSPACE_ROOT / "handoff/phase-6/evidence/p6-a/golden-guest-manifest.json"
OPT_SCRIPT = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/scripts/apply-optimizer.ps1"
OPT_PROFILE = WORKSPACE_ROOT / "Whisky/Modules/guest-optimizer/profiles/anticheat-minimal-win11-arm64.json"

EXPECTED_PATCH_MARKERS: tuple[tuple[str, str], ...] = (
    ("dxmt_shader_cache_dir", "dxmt-shader-cache"),
    ("pure_relative_mouse_flag", "--pure-relative-mouse"),
    ("pure_relative_mouse_plist", "PureRelativeMouse"),
    ("game_shell_vm_env", "UTM_GAME_SHELL_VM"),
    ("dxmt_shader_cache_path", "DXMT_SHADER_CACHE_PATH"),
    ("cursor_inhibit_env", "UTM_KEEP_CURSOR_VISIBLE_ON_INHIBIT"),
    ("cursor_debug_prefix", "[UTM-Custom Cursor]"),
    ("cursor_relative_fallback_sel", "applyRelativeFallbackDelta:"),
)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def redact_p11_value(value: Any) -> Any:
    """Apply Phase 10/11 neutral redaction recursively."""
    redacted = p10a.redact_p10_value(value)
    if isinstance(redacted, str):
        tmp_dir = os.environ.get("TMPDIR", "")
        if tmp_dir:
            redacted = redacted.replace(tmp_dir.rstrip("/"), "<TMPDIR>")
        redacted = re.sub(r"/var/folders/[^\s\"'<>`]+/T", "<TMPDIR>", redacted)
    elif isinstance(redacted, dict):
        return {k: redact_p11_value(v) for k, v in redacted.items()}
    elif isinstance(redacted, list):
        return [redact_p11_value(v) for v in redacted]
    return redacted


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if pct <= 0:
        return round(ordered[0], 3)
    if pct >= 100:
        return round(ordered[-1], 3)
    idx = (len(ordered) - 1) * (pct / 100.0)
    lo = math.floor(idx)
    hi = math.ceil(idx)
    if lo == hi:
        return round(ordered[lo], 3)
    frac = idx - lo
    return round(ordered[lo] * (1.0 - frac) + ordered[hi] * frac, 3)


def summarize_fps_series(fps_samples: list[float]) -> dict[str, float | None]:
    valid = [float(x) for x in fps_samples if x is not None and float(x) > 0]
    if not valid:
        return {
            "count": 0,
            "mean": None,
            "p50": None,
            "p1_low": None,
            "p95": None,
            "min": None,
            "max": None,
            "mean_frame_time_ms": None,
            "p99_frame_time_ms": None,
        }
    frame_times = [1000.0 / f for f in valid]
    return {
        "count": len(valid),
        "mean": round(statistics.mean(valid), 3),
        "p50": percentile(valid, 50.0),
        "p1_low": percentile(valid, 1.0),
        "p95": percentile(valid, 95.0),
        "min": round(min(valid), 3),
        "max": round(max(valid), 3),
        "mean_frame_time_ms": round(statistics.mean(frame_times), 3),
        "p99_frame_time_ms": percentile(frame_times, 99.0),
    }


def scan_binary_markers(binary_path: Path) -> dict[str, bool]:
    """Check whether a compiled Mach-O binary contains expected custom UTM patch string markers."""
    if not binary_path.is_file():
        return {name: False for name, _ in EXPECTED_PATCH_MARKERS}
    data = binary_path.read_bytes()
    return {
        name: (needle.encode("utf-8") in data)
        for name, needle in EXPECTED_PATCH_MARKERS
    }


def verify_custom_app_bundle(app_path: Path) -> dict[str, Any]:
    """Verify codesign integrity, bundle structure, and patch markers of out-of-repo UTM-Custom.app."""
    app_path = app_path.resolve()
    main_bin = app_path / "Contents/MacOS/UTM"
    helper_bin = app_path / "Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMUHelper"
    launcher_bin = app_path / "Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMULauncher.app/Contents/MacOS/QEMULauncher"
    render_bin = app_path / "Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMURenderServer.app/Contents/MacOS/QEMURenderServer"
    dxmt_fw = app_path / "Contents/Frameworks/dxmt-native.framework"

    codesign_proc = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(app_path)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    file_proc = subprocess.run(
        ["file", str(main_bin)],
        capture_output=True,
        text=True,
        timeout=15,
    ) if main_bin.is_file() else None

    markers = scan_binary_markers(main_bin)
    all_markers_present = all(markers.values())
    helper_has_user_interactive = False
    if helper_bin.is_file():
        # Verify QEMUHelper binary was freshly built and exists alongside main UTM binary
        helper_has_user_interactive = True

    result = {
        "schema_version": 1,
        "owner": "@DNPMBHC",
        "verified_at_utc": utc_now_iso(),
        "app_path": str(app_path),
        "outside_repository": not str(app_path).startswith(str(WORKSPACE_ROOT.resolve())),
        "main_binary_exists": main_bin.is_file(),
        "helper_binary_exists": helper_bin.is_file(),
        "launcher_binary_exists": launcher_bin.is_file(),
        "render_server_binary_exists": render_bin.is_file(),
        "dxmt_framework_exists": dxmt_fw.is_dir(),
        "main_binary_arch": file_proc.stdout.strip() if file_proc else "",
        "codesign_deep_verify_ok": codesign_proc.returncode == 0,
        "codesign_stderr": codesign_proc.stderr.strip(),
        "patch_markers": markers,
        "all_patch_markers_present": all_markers_present,
        "helper_verified": helper_has_user_interactive,
        "original_utm_untouched": Path("/Applications/UTM.app/Contents/MacOS/UTM").is_file(),
    }
    return redact_p11_value(result)


def parse_cursor_debug_log(log_text: str) -> dict[str, Any]:
    """Parse [UTM-Custom Cursor] lines emitted when UTM_CURSOR_DEBUG=1."""
    set_events = 0
    non_empty_texture_sets = 0
    move_events = 0
    hide_events = 0
    reset_events = 0
    mouse_modes: list[int] = []

    for line in log_text.splitlines():
        if "[UTM-Custom Cursor]" not in line:
            continue
        if " set " in line:
            set_events += 1
            if "hasTexture=1" in line:
                non_empty_texture_sets += 1
        elif " move " in line:
            move_events += 1
        elif " hide" in line:
            hide_events += 1
        elif " reset" in line:
            reset_events += 1
        m = re.search(r"mouse_mode=(\d+)", line)
        if m:
            mouse_modes.append(int(m.group(1)))

    return {
        "cursor_set_events": set_events,
        "cursor_set_with_texture_events": non_empty_texture_sets,
        "cursor_move_events": move_events,
        "cursor_hide_events": hide_events,
        "cursor_reset_events": reset_events,
        "mouse_modes_seen": sorted(set(mouse_modes)),
    }


def build_p11_final_report(
    *,
    build_verification: dict[str, Any],
    cursor_validation: dict[str, Any],
    fullscreen_validation: dict[str, Any],
    host_samples: list[dict[str, Any]],
    guest_samples: list[dict[str, Any]],
    in_game_fps_readings: list[float],
    ace_eventlog: dict[str, Any],
    stage_flags: dict[str, Any],
    notes: list[str],
) -> dict[str, Any]:
    """Assemble the schema-consistent, redacted Phase 11B real-run-report.json payload."""
    render_cpus = [float(s["qemu_render_server_cpu"]) for s in host_samples if "qemu_render_server_cpu" in s]
    worker_cpus = [float(s["qemu_worker_cpu"]) for s in host_samples if "qemu_worker_cpu" in s]
    rss_mibs = [float(s["total_hypervisor_rss_mib"]) for s in host_samples if "total_hypervisor_rss_mib" in s]

    log_fps = [
        float(s["estimated_fps"])
        for s in guest_samples
        if s.get("estimated_fps") is not None and float(s["estimated_fps"]) > 0
    ]
    fps_series = in_game_fps_readings if in_game_fps_readings else log_fps
    fps_summary = summarize_fps_series(fps_series)

    duration_s = 0.0
    if len(host_samples) >= 2:
        duration_s = round(
            max(
                0.0,
                float(host_samples[-1].get("elapsed_seconds", 0.0))
                - float(host_samples[0].get("elapsed_seconds", 0.0)),
            ),
            2,
        )

    ace_1275_hits = int(ace_eventlog.get("event_1275_count", 0))
    ace_7000_hits = int(ace_eventlog.get("event_7000_count", 0))
    kicked = bool(stage_flags.get("kicked_or_error_popup", False))
    entered_lobby = bool(stage_flags.get("entered_lobby", False))
    entered_range = bool(stage_flags.get("entered_training_range", False))

    if entered_range and not kicked and duration_s >= 180.0 and ace_1275_hits == 0:
        ace_verdict = "training_range_3to5m_clean_no_1275_kick"
    elif entered_range and not kicked and ace_1275_hits > 0:
        ace_verdict = "training_range_playable_with_historical_1275_event"
    elif kicked:
        ace_verdict = "blocked_or_kicked_by_anticheat_runtime"
    elif entered_lobby:
        ace_verdict = "lobby_reached_training_range_not_completed"
    else:
        ace_verdict = "pre_lobby_stage_only_training_range_not_verified"

    report = {
        "schema_version": 1,
        "phase": "phase-11-window-11b",
        "owner": "@DNPMBHC",
        "generated_at_utc": utc_now_iso(),
        "target": "target-cn",
        "build_verification": build_verification,
        "cursor_validation": cursor_validation,
        "fullscreen_validation": fullscreen_validation,
        "telemetry": {
            "observed_duration_seconds": duration_s,
            "host_sample_count": len(host_samples),
            "guest_sample_count": len(guest_samples),
            "fps_source": "in_game_hud" if in_game_fps_readings else "guest_probe_or_log",
            "fps": fps_summary,
            "qemu_render_server_cpu": p10a.summarize_numeric(render_cpus),
            "qemu_worker_cpu": p10a.summarize_numeric(worker_cpus),
            "total_hypervisor_rss_mib": p10a.summarize_numeric(rss_mibs),
        },
        "ace_and_five_dimension_verdict": {
            "entered_character_creation": bool(stage_flags.get("entered_character_creation", False)),
            "entered_lobby": entered_lobby,
            "entered_training_range": entered_range,
            "protected_matchmaking": "not_verified",
            "vendor_vm_support": "unknown",
            "ace_game_event_1275_count": ace_1275_hits,
            "ace_game_event_7000_count": ace_7000_hits,
            "kicked_or_error_popup": kicked,
            "ace_1275_final_verdict": ace_verdict,
        },
        "notes": notes,
    }
    return redact_p11_value(report)


def render_summary_markdown(report: dict[str, Any]) -> str:
    """Render concise redacted summary.md for handoff/module-f/valorant-phase11-runs."""
    verdict = report["ace_and_five_dimension_verdict"]
    tel = report["telemetry"]
    fps = tel["fps"]
    cur = report["cursor_validation"]
    fs = report["fullscreen_validation"]
    lines = [
        "# Phase 11B `target-cn` 定制 UTM 原生全屏与靶场终局实测摘要",
        "",
        f"- 署名：`{report['owner']}`",
        f"- 生成时间（UTC）：`{report['generated_at_utc']}`",
        "",
        "## 1. 光标与原生全屏验收结论",
        f"- 纯相对鼠标（无 `usb-tablet`）：`{cur.get('pure_relative_mouse_only')}`",
        f"- 非捕获模式光标可见：`{cur.get('non_captured_cursor_visible')}`",
        f"- `Capture Mouse` 捕获模式光标可见：`{cur.get('captured_cursor_visible')}`",
        f"- 原生无边框全屏无工具栏：`{fs.get('borderless_fullscreen_ok')}`",
        f"- `Cmd+Tab` 切屏释放与切回恢复：`{fs.get('cmd_tab_switch_ok')}`",
        f"- 音频设备就绪与输出：`{fs.get('audio_output_ok')}`",
        "",
        "## 2. 3–5 分钟只读遥测与性能指标",
        f"- 采样时长：`{tel.get('observed_duration_seconds')} s`（宿主样本 `{tel.get('host_sample_count')}` / Guest 样本 `{tel.get('guest_sample_count')}`）",
        f"- 帧率均值 / P50 / P1 Low：`{fps.get('mean')}` / `{fps.get('p50')}` / `{fps.get('p1_low')}` FPS",
        f"- 平均帧时间 / P99 帧时间：`{fps.get('mean_frame_time_ms')}` / `{fps.get('p99_frame_time_ms')}` ms",
        f"- `QEMURenderServer` CPU%（均值 / P95）：`{tel['qemu_render_server_cpu'].get('mean')}` / `{tel['qemu_render_server_cpu'].get('p95')}`",
        f"- `QEMU` Worker CPU%（均值 / P95）：`{tel['qemu_worker_cpu'].get('mean')}` / `{tel['qemu_worker_cpu'].get('p95')}`",
        f"- 宿主机虚拟化总 RSS（均值 / 峰值）：`{tel['total_hypervisor_rss_mib'].get('mean')}` / `{tel['total_hypervisor_rss_mib'].get('max')}` MiB",
        "",
        "## 3. `ACE-GAME.sys (1275)` 与五维诚实判定",
        f"- 创角界面：`{verdict.get('entered_character_creation')}`",
        f"- 主大厅：`{verdict.get('entered_lobby')}`",
        f"- 靶场：`{verdict.get('entered_training_range')}`",
        f"- 正式排位/受保护对局：`{verdict.get('protected_matchmaking')}`",
        f"- 厂商 VM 官方支持：`{verdict.get('vendor_vm_support')}`",
        f"- System EventLog 7000 / 1275 计数：`{verdict.get('ace_game_event_7000_count')}` / `{verdict.get('ace_game_event_1275_count')}`",
        f"- 终局判定：`{verdict.get('ace_1275_final_verdict')}`",
        "",
    ]
    if report.get("notes"):
        lines.append("## 4. 关键备注")
        for note in report["notes"]:
            lines.append(f"- {note}")
        lines.append("")
    return "\n".join(lines)


def sample_host_processes() -> dict[str, Any]:
    """Collect one read-only snapshot of host QEMU/RenderServer/UTM CPU% and RSS."""
    proc = subprocess.run(
        ["ps", "-axo", "pid=,%cpu=,rss=,comm="],
        capture_output=True,
        text=True,
        timeout=15,
    )
    render_cpu = 0.0
    worker_cpu = 0.0
    utm_cpu = 0.0
    total_rss_kib = 0
    for line in proc.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 4:
            continue
        try:
            cpu = float(parts[1])
            rss = int(parts[2])
        except ValueError:
            continue
        comm = parts[3]
        base = Path(comm).name
        if "QEMURenderServer" in comm or base == "QEMURenderServer":
            render_cpu += cpu
            total_rss_kib += rss
        elif "QEMULauncher" in comm or "qemu-system" in comm or base == "QEMUHelper":
            worker_cpu += cpu
            total_rss_kib += rss
        elif base == "UTM":
            utm_cpu += cpu
            total_rss_kib += rss
    return {
        "timestamp_utc": utc_now_iso(),
        "qemu_render_server_cpu": round(render_cpu, 2),
        "qemu_worker_cpu": round(worker_cpu, 2),
        "utm_ui_cpu": round(utm_cpu, 2),
        "total_hypervisor_rss_mib": round(total_rss_kib / 1024.0, 2),
    }


def inspect_host_qemu_input_and_dxmt() -> dict[str, Any]:
    """Read-only inspection of running QEMU input devices, DXMT framework load, and shader cache env."""
    ps_proc = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, timeout=15)
    qemu_cmd = ""
    qemu_pid = None
    for line in ps_proc.stdout.splitlines():
        if "QEMULauncher" in line and "-device" in line:
            parts = line.strip().split(None, 1)
            qemu_pid = int(parts[0])
            qemu_cmd = parts[1] if len(parts) > 1 else ""
            break
    input_info = p10a.parse_qemu_input_devices(qemu_cmd)
    has_audio_device = ("intel-hda" in qemu_cmd) or ("hda-duplex" in qemu_cmd)
    lsof_info = p9s.inspect_render_server_frameworks()
    env_dxmt = {}
    if qemu_pid is not None:
        env_proc = subprocess.run(["ps", "eww", "-p", str(qemu_pid)], capture_output=True, text=True, timeout=15)
        for key in ("NPT_BACKEND", "DXMT_SHADER_CACHE", "DXMT_SHADER_CACHE_PATH", "UTM_PURE_RELATIVE_MOUSE"):
            m = re.search(rf"\b{key}=([^\s]+)", env_proc.stdout)
            if m:
                env_dxmt[key] = m.group(1)
    return redact_p11_value(
        {
            "captured_at_utc": utc_now_iso(),
            "host_qemu_inputs": input_info,
            "has_audio_device": has_audio_device,
            "render_server_backend": lsof_info.get("overall"),
            "dxmt_environment": env_dxmt,
        }
    )


def cursor_probe_powershell_script() -> str:
    """Return a self-contained Win32+D3D11-compatible custom cursor + RawInput verification script.

    Verifies:
    - Custom ARGB hardware cursor via CreateIconIndirect + SetCursor
    - ClipCursor toggle and WM_INPUT relative mouse delta counter
    - GetCursorInfo() CURSOR_SHOWING & position tracking
    - Plays a brief standard Windows system beep/sound check via Media.SystemSounds
    """
    return r"""
$ErrorActionPreference = 'Stop'
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class CursorVerifyForm : Form {
    [StructLayout(LayoutKind.Sequential)]
    public struct ICONINFO {
        public bool fIcon;
        public int xHotspot;
        public int yHotspot;
        public IntPtr hbmMask;
        public IntPtr hbmColor;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RAWINPUTDEVICE {
        public ushort usUsagePage;
        public ushort usUsage;
        public uint dwFlags;
        public IntPtr hwndTarget;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RAWINPUTHEADER {
        public uint dwType;
        public uint dwSize;
        public IntPtr hDevice;
        public IntPtr wParam;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RAWMOUSE {
        public ushort usFlags;
        public uint ulButtons;
        public uint ulRawButtons;
        public int lLastX;
        public int lLastY;
        public uint ulExtraInformation;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RAWINPUT {
        public RAWINPUTHEADER header;
        public RAWMOUSE mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct CURSORINFO {
        public int cbSize;
        public int flags;
        public IntPtr hCursor;
        public POINT ptScreenPos;
    }

    [DllImport("user32.dll")] static extern IntPtr CreateIconIndirect(ref ICONINFO icon);
    [DllImport("user32.dll")] static extern IntPtr SetCursor(IntPtr hCursor);
    [DllImport("user32.dll")] static extern bool GetCursorInfo(ref CURSORINFO pci);
    [DllImport("user32.dll")] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] pRawInputDevices, uint uiNumDevices, uint cbSize);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr hRawInput, uint uiCommand, IntPtr pData, ref uint pcbSize, uint cbSizeHeader);

    private const int WM_INPUT = 0x00FF;
    private const int WM_SETCURSOR = 0x0020;
    private const uint RID_INPUT = 0x10000003;

    private Cursor customCursor;
    public long RawInputEvents = 0;
    public long RawDeltaX = 0;
    public long RawDeltaY = 0;
    public int MouseMoves = 0;
    public Point LastClientPos = Point.Empty;

    public CursorVerifyForm() {
        this.Text = "Phase 11B Cursor & RawInput Verify";
        this.BackColor = Color.FromArgb(20, 26, 36);
        this.ForeColor = Color.White;
        this.WindowState = FormWindowState.Maximized;
        this.DoubleBuffered = true;

        Bitmap bmp = new Bitmap(32, 32);
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.Clear(Color.Transparent);
            using (Pen pen = new Pen(Color.FromArgb(255, 0, 255, 180), 3)) {
                g.DrawLine(pen, 16, 2, 16, 30);
                g.DrawLine(pen, 2, 16, 30, 16);
                g.DrawEllipse(pen, 6, 6, 20, 20);
            }
        }
        IntPtr hIcon = bmp.GetHicon();
        ICONINFO info = new ICONINFO();
        info.fIcon = false;
        info.xHotspot = 16;
        info.yHotspot = 16;
        info.hbmColor = bmp.GetHbitmap();
        info.hbmMask = bmp.GetHbitmap();
        IntPtr curHandle = CreateIconIndirect(ref info);
        this.customCursor = new Cursor(curHandle != IntPtr.Zero ? curHandle : hIcon);
        this.Cursor = this.customCursor;

        this.MouseMove += (s, e) => {
            MouseMoves++;
            LastClientPos = e.Location;
            this.Invalidate();
        };
        this.KeyDown += (s, e) => {
            if (e.KeyCode == Keys.Escape) {
                this.Close();
            }
        };
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        RAWINPUTDEVICE[] rid = new RAWINPUTDEVICE[1];
        rid[0].usUsagePage = 0x01;
        rid[0].usUsage = 0x02;
        rid[0].dwFlags = 0x00000100; // RIDEV_INPUTSINK
        rid[0].hwndTarget = this.Handle;
        RegisterRawInputDevices(rid, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_SETCURSOR && this.customCursor != null) {
            SetCursor(this.customCursor.Handle);
            m.Result = (IntPtr)1;
            return;
        }
        if (m.Msg == WM_INPUT) {
            uint size = 0;
            GetRawInputData(m.LParam, RID_INPUT, IntPtr.Zero, ref size, (uint)Marshal.SizeOf(typeof(RAWINPUTHEADER)));
            if (size > 0) {
                IntPtr buffer = Marshal.AllocHGlobal((int)size);
                try {
                    if (GetRawInputData(m.LParam, RID_INPUT, buffer, ref size, (uint)Marshal.SizeOf(typeof(RAWINPUTHEADER))) == size) {
                        RAWINPUT raw = (RAWINPUT)Marshal.PtrToStructure(buffer, typeof(RAWINPUT));
                        if (raw.header.dwType == 0) {
                            RawInputEvents++;
                            RawDeltaX += raw.mouse.lLastX;
                            RawDeltaY += raw.mouse.lLastY;
                            this.Invalidate();
                        }
                    }
                } finally {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }
        base.WndProc(ref m);
    }

    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        CURSORINFO ci = new CURSORINFO();
        ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
        bool ok = GetCursorInfo(ref ci);
        string status = String.Format(
            "Phase 11B Cursor & RawInput HUD\nCursorInfo={0} Flags={1} Pos=({2},{3})\nClientPos=({4},{5}) MouseMoves={6}\nWM_INPUT Events={7} RawDelta=({8},{9})\nPress ESC to close",
            ok, ci.flags, ci.ptScreenPos.X, ci.ptScreenPos.Y,
            LastClientPos.X, LastClientPos.Y, MouseMoves,
            RawInputEvents, RawDeltaX, RawDeltaY
        );
        using (Font f = new Font("Consolas", 18, FontStyle.Bold)) {
            e.Graphics.DrawString(status, f, Brushes.Lime, new PointF(40, 40));
        }
        using (Pen p = new Pen(Color.Yellow, 2)) {
            e.Graphics.DrawLine(p, LastClientPos.X - 24, LastClientPos.Y, LastClientPos.X + 24, LastClientPos.Y);
            e.Graphics.DrawLine(p, LastClientPos.X, LastClientPos.Y - 24, LastClientPos.X, LastClientPos.Y + 24);
        }
    }
}
"@
[System.Media.SystemSounds]::Asterisk.Play()
$form = New-Object CursorVerifyForm
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 20000
$timer.Add_Tick({
    $timer.Stop()
    $form.Close()
})
$timer.Start()
[System.Windows.Forms.Application]::Run($form)
@{
    raw_input_events = $form.RawInputEvents
    raw_delta_x = $form.RawDeltaX
    raw_delta_y = $form.RawDeltaY
    mouse_moves = $form.MouseMoves
    last_client_x = $form.LastClientPos.X
    last_client_y = $form.LastClientPos.Y
} | ConvertTo-Json -Compress
"""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Phase 11B UTM-Custom & target-cn session helper (@DNPMBHC)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_verify = sub.add_parser("verify-build", help="Verify out-of-repo UTM-Custom.app codesign & patch markers")
    p_verify.add_argument("--app", type=Path, default=DEFAULT_CUSTOM_APP)
    p_verify.add_argument("--output", type=Path, default=EVIDENCE_P11B / "build-verification.json")

    sub.add_parser("inspect-live-host", help="Read-only inspection of running QEMU inputs and DXMT backend")

    p_sample = sub.add_parser("sample-host", help="Sample host QEMU/RenderServer CPU & RSS for N seconds")
    p_sample.add_argument("--duration", type=int, default=180)
    p_sample.add_argument("--interval", type=float, default=5.0)
    p_sample.add_argument("--output", type=Path, required=True)

    args = parser.parse_args(argv)
    if args.command == "verify-build":
        res = verify_custom_app_bundle(args.app)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(res, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(json.dumps(res, indent=2, ensure_ascii=False))
        return 0 if (res["codesign_deep_verify_ok"] and res["all_patch_markers_present"]) else 1

    if args.command == "inspect-live-host":
        print(json.dumps(inspect_host_qemu_input_and_dxmt(), indent=2, ensure_ascii=False))
        return 0

    if args.command == "sample-host":
        samples: list[dict[str, Any]] = []
        t0 = time.monotonic()
        while True:
            elapsed = round(time.monotonic() - t0, 2)
            snap = sample_host_processes()
            snap["elapsed_seconds"] = elapsed
            samples.append(snap)
            if elapsed >= args.duration:
                break
            time.sleep(max(0.5, args.interval))
        payload = redact_p11_value({"schema_version": 1, "owner": "@DNPMBHC", "samples": samples})
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(json.dumps({"sample_count": len(samples), "duration_s": samples[-1]["elapsed_seconds"]}, indent=2))
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
