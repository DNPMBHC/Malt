#!/usr/bin/env python3
"""Derive acceptance from current own-window observations. Owner: @DNPMBHC."""
import json
from datetime import datetime, timezone
from pathlib import Path

EVIDENCE = Path(__file__).resolve().parent


def read(name):
    path = EVIDENCE / name
    return json.loads(path.read_text()) if path.exists() else {}


def write(name, value):
    (EVIDENCE / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def main():
    selected = read("production-validation-selection.json")
    name = selected.get("manifest", "production-interface-version.json")
    if Path(name).name != name: raise RuntimeError("invalid_manifest_selection")
    version = read(name)
    local = read("local-validation.json")
    binary = read("runtime-binary-roundtrip.json")
    native = read("native-fullscreen-probe.json")
    display = read("guest-runtime-real-display-lifecycle.json")
    supported = read("guest-supported-display-lifecycle.json")
    dpi = read("guest-dpi-real-roundtrip.json")
    discovery = read("guest-dpi-controls.json")
    hardware = read("guest-d3d-hardware-probe.json")
    minimal = read("guest-minimal-apply.json")
    game = read("target-game-real-validation.json")
    own = read("vm-lease.json")
    cleanup = read("own-cleanup-proof.json")
    closeout = read("phase-closeout.json")
    deferred = closeout.get("real_validation_deferred_by_user") is True
    now = datetime.now(timezone.utc).isoformat()
    revision = version.get("snapshot_revision")
    fingerprint = version.get("production_fingerprint")

    def bound(report):
        return report.get("production_snapshot_revision") == revision and report.get("production_fingerprint") == fingerprint

    def synthetic_bound(report):
        return (report.get("passed") is True and report.get("production_snapshot_revision") == revision
                and report.get("source_fingerprint_after") == local.get("input_fingerprint_after")
                and report.get("inputs_stable") is True)

    runs = {x["preset"]:x for x in display.get("runs", [])} if bound(display) else {}
    failures = {x["preset"]:x for x in display.get("failures", [])} if bound(display) else {}
    rows = []

    def add(requirement, status, evidence):
        row = {"requirement":requirement, "status":status, "evidence":evidence}
        if deferred and status != "passed" and requirement != "自有克隆删除 / 主源与原备份独立复核":
            row.update(status="deferred", last_observed_status=status, deferred_to="next_phase",
                       deferral_reason="user_directed_phase_closeout")
        rows.append(row)

    add("本地 Swift、Strict SwiftLint、格式和安全门禁", "passed" if local.get("all_local_gates_passed") else "pending", "local-validation.json")
    add("极简优化 / Session 1 / 安全不变量", "passed" if minimal.get("security_invariants_passed") and minimal.get("session_id") == 1 else "pending", "guest-minimal-apply.json")
    add("WHQL 3D / 硬件适配器 / FL 11_1 / 根退出码", "passed" if hardware.get("passed") and bound(hardware) else "pending", "guest-d3d-hardware-probe.json")
    add("真实标准缩放控件发现及设置窗口关闭", "passed" if discovery.get("passed") and bound(discovery) else "pending", "guest-dpi-controls.json")
    for preset, label in (("native_retina_point_to_point", "原生点对点"), ("high_performance", "高性能"), ("follow_window", "窗口跟随及动态切换")):
        chosen = supported if preset == "follow_window" and bound(supported) else display
        chosen_runs = {x["preset"]:x for x in chosen.get("runs", [])} if bound(chosen) else {}
        run = chosen_runs.get(preset, {})
        passed = run.get("displayRestored") is True and run.get("exitCode") == 0
        status = "passed" if passed else ("failed" if preset in failures or chosen.get("errorCode") else "pending")
        add("真实 Guest " + label + " / 退出恢复", status, "guest-supported-display-lifecycle.json" if chosen is supported else "guest-runtime-real-display-lifecycle.json")
    add("真实 DPI Apply 150% / Restore 基线", "passed" if dpi.get("passed") and bound(dpi) else ("failed_prior_snapshot" if dpi.get("errorCode") else "pending"), "guest-dpi-real-roundtrip.json")
    add("真实冷后台启动 / 挂起归位", "passed" if display.get("coldHeadlessStartVerified") and display.get("passed") else "pending", "guest-runtime-real-display-lifecycle.json")
    add("完整运行时 IOSurface GPU 逐像素互操作", "passed" if synthetic_bound(binary) else "pending", "runtime-binary-roundtrip.json")
    add("宿主合成帧原生全屏窗口 / 关闭 / 无 HID 拒绝捕获", "passed" if synthetic_bound(native) else "pending", "native-fullscreen-probe.json")
    add("真实 Windows scanout / 合法虚拟 HID", "pending_upstream_capability", "interface-proposal.md")
    add("target-cn DX11 / 大厅或训练场 / 精确退出取证", "passed" if game.get("requirements_evaluated") else "pending", "target-game-real-validation.json")
    add("自有克隆删除 / 主源与原备份独立复核", "passed" if own.get("status") == "released" and own.get("clone_deleted") is True and cleanup.get("passed") else "pending", "own-cleanup-proof.json")
    complete = all(x["status"] == "passed" for x in rows)
    matrix = {"owner":"@DNPMBHC", "captured_at_utc":now, "snapshot_revision":revision,
              "production_fingerprint":fingerprint, "acceptance_complete":complete, "current_phase_closeout_complete":closeout.get("current_phase_closeout_complete") is True,
              "real_validation_deferred_by_user":deferred, "items":rows}
    write("acceptance-matrix.json", matrix)
    write("display-sync-evidence.json", {"owner":"@DNPMBHC", "schema_version":3, "captured_at_utc":now,
          "production_snapshot_revision":revision, "production_fingerprint":fingerprint,
          "acceptance_complete":complete, "current_phase_closeout_complete":closeout.get("current_phase_closeout_complete") is True,
          "real_validation_deferred_by_user":deferred, "host_measurement":display.get("hostDisplay",read("host-display-sample.json")),
          "display_api":"ChangeDisplaySettingsExW", "dpi_api":"GetDpiForWindow and scoped signed SystemSettings UIA",
          "real_display_lifecycle":display, "supported_display_lifecycle":supported, "real_dpi_roundtrip":dpi, "real_control_discovery":discovery,
          "hardware_probe":hardware, "local_gates":local.get("gates"), "clone_lease_status":own.get("status"),
          "real_windows_scanout_verified":False, "virtual_hid_verified":False})
    tests = local.get("gates", {}).get("swift_test", {})
    table = "\n".join("| " + " | ".join(str(x[k]) for k in ("requirement", "status", "evidence")) + " |" for x in rows)
    text = f"""# 窗口 5C 原生游戏壳验收报告

署名：@DNPMBHC  
证据时间（UTC）：{now}

按用户最新指示，本轮收尾={closeout.get("current_phase_closeout_complete")}；未完成的真实联调延期到下一阶段，任务书完整验收仍为 {complete}。当前验证为 snapshot {revision}，契约 revision {version.get('contract_revision')}；生产指纹 `{fingerprint}`。历史 snapshot 3 发行证据单独保留，当前候选不冒充已封版产物。

| 验收要求 | 状态 | 证据 |
| --- | --- | --- |
{table}

本地 SwiftPM {tests.get('total')} 项：{tests.get('passed_tests')} 通过、{tests.get('skipped')} 项既有显式跳过、{tests.get('failed')} 失败。Strict SwiftLint、严格格式、format_check、防外挂审计和租约反例门禁见 local-validation.json。完整运行时互操作和原生窗口以本轮源码指纹绑定，宿主合成帧不作为 Guest 游戏帧。

C1 原型已实现，但当前真实生命周期验收未通过，不能作为后台启动到退游归位的完整实证。Headless 编排使用 Session 1 helper 监控真实根及子进程树。退游先释放光标和关闭窗口，再恢复显示，恢复成功后才按策略挂起；失败与取消路径有独立行为测试。窗口捕获只接受聚焦窗口相对位移，缺少合法 HID sink 时拒绝捕获。热键、失焦、Cmd+Tab、关闭和退游释放均有状态机测试；系统调用失败保留 releasePending，自动重试不伪造成功回执。

宿主读取 NSScreen 逻辑尺寸、Backing Scale Factor 与刷新上限。Guest 分辨率采用标准枚举和 ChangeDisplaySettingsExW，DPI 通过已验证签名的系统设置窗口、限定 UIA 控件和新建 Per-Monitor V2 窗口回读。改变前保留恢复基线，DPI 恢复失败仍尝试分辨率恢复。默认 Restricted 的失败记录保留；当前仅使用脚本进程 RemoteSigned，持久与组织策略不被覆盖。

C 自有克隆已独立验证硬件适配器、FL 11_1、Session 1、根退出码 0；AdapterRAM=0。游戏是否检查该值仍须由未修改日志或对应进程的实际证据证明，未取得时为 unknown。最新 supported-lifecycle 在取消树时失败，baselineRestored=false；恢复日志早于该次失败，不能据此认定本次已恢复。原生点对点首次返回 -2 并恢复基线；后续系统盘被更新下载缓存占满，引发传输失败。失败、空间诊断及清理后回读均保留，未隐藏或计作成功。

真实 Windows scanout 与合法 HID 的完整链路仍未实证。本轮没有完成 target-cn 官方客户端安装或本窗口登录，也没有运行游戏，因此缺少显卡/DX11 弹窗、大厅/训练场、AdapterRAM 检查行为、精确弹窗截图和实际游戏退出码均未取得。先前登录等待已撤销，不要求本阶段再登录。

下一阶段须重新创建独立克隆，并先检查租约与源保护，再继续三档分辨率、DPI 150% 往返、进程取消及退游归位。游戏登录、协议、实名或验证码仍须本人完成；自然退出时记录精确弹窗文本、完整脱敏截图与根/子进程退出码。主动终止安装器或停机不作为游戏自然退出证据。

当前 C 租约={own.get('status')}，清理通过={cleanup.get('passed')}。自有克隆、内部游戏盘副本与安装光盘的删除，以及主源八份文件与原游戏备份的独立 SHA/size/mtime、进程和句柄复核，见 own-cleanup-proof.json。优化回滚验证={cleanup.get('minimal_rollback_verified')}；安装器终态回执={cleanup.get('installer_terminal_receipt')}。未取得回执不填造成功，最新失败的显示恢复仍为未验证；测试环境删除与显示恢复分开记录。原备份仅用于创建独立副本。没有跨窗口汇报、修改主 UI、Git commit/push/reset 或全局 Git 配置改动。最小主 App 接线见 interface-proposal.md。

五维口径：代码=implemented_prototype；本机验证={local.get('all_local_gates_passed')}；真实 Guest=见逐项实证；厂商支持=unknown；真实游戏=见单独取证。未完成项保持明确状态。
"""
    (EVIDENCE / "headless-shell-report.md").write_text(text)
    print(json.dumps({"owner":"@DNPMBHC", "reports_written":3, "acceptance_complete":complete}))


if __name__ == "__main__":
    main()
