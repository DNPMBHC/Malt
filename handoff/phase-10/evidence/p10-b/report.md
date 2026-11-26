# Phase 10 窗口 10B 最终验收报告：开源 UTM 最小化定制架构与「纯净原生全屏游戏壳」补丁集

日期：2026-11-24  
署名：`@DNPMBHC`  
状态：**任务 10B-1、10B-2 与全套门禁全绿验收通过。**

---

## 1. 任务执行摘要（严格遵守文件写入锁与仓库纯净红线）

### 任务 10B-1：UTM 5.0.9 / `CocoaSpice` 源码审计与架构设计
- 在仓库外临时目录（`${TMPDIR}/utm-custom-src`）浅克隆 `utmapp/UTM`（`v5.0.9`，commit `305fd07781231754c32eac367fa83ea759ce374a`）与 `utmapp/CocoaSpice`（commit `e239fab0828ebafc3a5a973fa84039400d7ac703`），仓库内零外部源码树与 `>5 MiB` 产物残留。
- 撰写 `Whisky/Modules/utm-custom/ARCHITECTURE.md`，精准定位 3 处改造位置：
  1. `UTM/Services/UTMQemuVirtualMachine.swift`（`directXDriver`）与 `UTMQemuSystem.m`（`-setDirectXDriver:`）：支持 `--dxmt-native` 与默认锁定 `QEMUDirectXDriver = 2`（`dxmt-native.framework`）及 `DXMT_SHADER_CACHE=1`；
  2. `CocoaSpice/Sources/CocoaSpice/CSCursor.m`（`-isVisible`）与 `UTM/Platform/macOS/Display/VMDisplayQemuMetalWindowController.swift`：失焦/应用停用自动 `releaseMouse()` 安全释放与可选 `UTM_KEEP_CURSOR_VISIBLE_ON_INHIBIT=1` 光标合成保留；
  3. `UTM/Platform/macOS/AppDelegate.swift` 与 `VMDisplayQemuMetalWindowController.swift`：新增 `--game-shell-vm <UUID>` 无桌面原生全屏游戏壳模式（关闭管理主窗口、隐藏工具栏、进入全屏、支持 `Cmd+Option+G` 释放光标、VM 停止自动退出）。

### 任务 10B-2：最小补丁集、构建校验脚本与合规审计单元测试
- 交付 4 个独立补丁至 `Whisky/Modules/utm-custom/patches/`：
  - `01-default-dxmt-backend.patch`（32 行）
  - `02-cursor-and-fps-capture.patch`（29 行）
  - `02-cocoaspice-cursor-overlay.patch`（14 行）
  - `03-clean-fullscreen-game-shell.patch`（63 行）
- 交付 `Whisky/Modules/utm-custom/scripts/build_custom_utm.sh`、`graphics-lab/utm_custom_patch_verify.py` 与 `graphics-lab/test_utm_custom_patch_verify.py`：
  - 实测 `build_custom_utm.sh --check-only` 与 `utm_custom_patch_verify.py` 通过（`utm_stacked_apply_check = true`、`cocoaspice_apply_check = true`）；
  - 诚实记录构建前置条件：完整 `xcodebuild` 需 UTM 官方外部预编译 `Sysroot-macOS`（QEMU/GLib/Spice 依赖包），未在本仓库内虚构完整 `.app` 编译；
  - 补丁合规静态审计强制拦截任何修改 CPUID/SMBIOS/ACPI/TPM/Hypervisor 伪装、Windows 驱动/内核或反作弊相关的补丁目标与关键词，结果落盘于 `handoff/phase-10/evidence/p10-b/patch-audit.json`。

---

## 2. 全套门禁验收结果

| 验证项 | 命令 | 结果 |
| --- | --- | --- |
| 补丁合规与 `git apply --check` | `bash Whisky/Modules/utm-custom/scripts/build_custom_utm.sh --check-only` | **通过（4/4 补丁，叠加 apply 0 冲突）** |
| `graphics-lab` 全量单测 | `(cd graphics-lab && python3 -B -m unittest discover -v)` | **通过（含 `test_utm_custom_patch_verify.py` 3 项）** |
| Strict SwiftLint | `swiftlint lint --strict --quiet` | **0 违规** |
| 防外挂静态审计 | `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` | **132 源码 + 6 反例通过** |
| 仓库纯净与大文件检查 | `find Whisky/Modules/utm-custom graphics-lab handoff/phase-10/evidence/p10-b -size +5M` | **零新增 `>5 MiB` 文件或外部源码残留** |

严格遵守文件写入锁，未触碰 `Whisky/Whisky/`、`Whisky/WhiskyKit/`、`handoff/task-07/` 及任何 VM，未执行 `git commit / push / reset`。
