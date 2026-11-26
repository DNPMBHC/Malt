# Phase 9 窗口 9B 最终验收报告：UTM 虚拟硬件瘦身规范与 Windows 11 极简优化器 v2

日期：2026-11-24  
署名：`@DNPMBHC`  
状态：**全部任务（9B-1、9B-2、9B-3）全绿验收通过。**

---

## 1. 任务执行摘要（严格遵守文件写入锁）

### 任务 9B-1：UTM 虚拟硬件瘦身规范与 9A `utm-native-capabilities.md` 对齐
- 固化 `Whisky/Modules/guest-golden/profiles/golden-win11-arm64-v2-trim.json`：
  - 锁定 `DynamicResolution = false`、`UsbSharing = false`、`MaximumUsbShares = 0`、移除空 CD-ROM 槽位、关闭剪贴板与目录共享；
  - 严格对齐窗口 9A `utm-native-capabilities.md` 实证：固化 `QEMUDirectXDriver` 整数枚举映射（`D3DMetal = 0`、`SoftwareFallback = 1`、`DXMT = 2`，推荐 `2` 即 `dxmt-native.framework`）及 `MouseTrails = 0` 约束。
- 升级 `graphics-lab/golden_guest_manager.py` 与 `graphics-lab/test_golden_guest_manager.py`：
  - `spawn-ephemeral` 支持 `--trim-hardware`、`--dx-driver`（`D3DMetal`→`0`、`DXMT`→`2`）与 `--fps-limit`（仅修改派生瞬时克隆，只读母盘与冷备 `vm-a` 零改动）。

### 任务 9B-2：Windows 11 24H2 ARM64 极简优化器 v2
- 升级 `Whisky/Modules/guest-optimizer/profiles/anticheat-minimal-win11-arm64.json`（`profile_revision: 2`）：
  - 补全 `ACE-CORE10405`、`ACE-CORE20405`、`AntiCheatExpert`、`EasyAntiCheat_EOSSys` 硬白名单；
  - 新增 6 个无用服务裁剪（`wisvc`、`RemoteRegistry`、`WalletService`、`TrkWks`、`diagnosticshub.standardcollector.service`、`diagsvc`）、4 项遥测/诊断计划任务、8 项 `HKCU:\` v2 注册表项（GameDVR/GameBar 覆盖禁用、Widgets/Copilot 禁用、ContentDeliveryManager 推荐禁用、Edge `AllowPrelaunch` 禁用）。
- 升级 `Whisky/Modules/guest-optimizer/scripts/apply-optimizer.ps1` 支持跨版本增量快照合并，确保 v1→v2 升级后一键回滚 100% 完整且幂等。

---

## 2. 任务 9B-3：瞬时克隆真机前后对比实测（`utm-trim-and-optimizer-v2-benchmark.json`）

在 `golden-win11-arm64-v1` 派生的瞬时克隆上实测对比（`ephemeral-p9b-baseline` vs `ephemeral-p9b-v2`）：

| 指标 | 基线 v1 克隆 | UTM 硬件裁剪 + 优化器 v2 | 变化量（Delta） |
| --- | ---: | ---: | ---: |
| 宿主机总 RSS 均值（QEMU + RenderServer + swtpm） | `2750.11 MiB` | `2557.19 MiB` | **`-192.92 MiB`** |
| 空载 QEMU CPU % 均值 | `16.68 %` | `12.54 %` | **`-4.14 %`** |
| Guest 进程数 | `118` | `102` | **`-16`** |
| Guest 运行中服务数 | `84` | `73` | **`-11`** |
| 冷启 QGA 就绪耗时 | `24.691 s` | `20.585 s` | **`-4.106 s`** |
| `d3d11_probe.exe` 帧率（1280×720） | `112.486 FPS` | `117.841 FPS` | **`+5.355 FPS`（0 LSB）** |

- **硬件裁剪实证**：移除空 CD-ROM 槽位 `2` 个、`DynamicResolution = false`、`UsbSharing = false`、`MaximumUsbShares = 0`、`RendererFPSLimit = 120`；
- **一键回滚验证**：`rollback_consistent = true`、`mismatch_count = 0`、`security_invariants_passed = true`；
- **零漂移证明**（`zero-drift-proof.json`）：两轮瞬时克隆已全部彻底销毁（`all_ephemeral_deleted = true`），`golden_zero_drift = true`、`primary_zero_drift = true`。

---

## 3. 全套门禁验收结果

| 验证项 | 命令 | 结果 |
| --- | --- | --- |
| `guest-optimizer` 单测 | `python3 -B -m unittest discover -s Whisky/Modules/guest-optimizer/tests -v` | **10/10 通过** |
| `graphics-lab` 全量单测 | `(cd graphics-lab && python3 -B -m unittest discover -v)` | **242/242 通过** |
| Strict SwiftLint | `swiftlint lint --strict --quiet` | **0 违规** |
| 防外挂静态审计 | `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` | **132 源码 + 6 反例通过** |

严格遵守文件写入锁，未触碰 `Whisky/Whisky/`、`Whisky/WhiskyKit/`、`handoff/task-07/`、黄金母盘与冷备 `vm-a`，未执行 `git commit / push / reset`。
