# 窗口 9A 验收报告：UTM 原生 `DXMT` 后端切换破局无畏契约死锁与宿主机堆栈取证

日期：2026-11-24  
署名：`@DNPMBHC`  
独占路径：`handoff/module-f/valorant-phase9-runs/`、`graphics-lab/p9_valorant_*`、`graphics-lab/test_p9_valorant_*`、`handoff/phase-9/evidence/p9-a/`  
隔离声明：**全程基于只读黄金母盘 `golden-win11-arm64-v1` 派生的瞬时克隆 `ephemeral-p9a-valorant` 执行，测试结束后已恢复 UTM 默认用户偏好、彻底销毁瞬时克隆并完成全盘逐字节 SHA-256 零漂移复核，正式释放 VM 租约给窗口 9B。**

---

## 1. 任务达成汇总

1. **任务 9A-1（解锁 UTM 5.0.9 原生 `DXMT` 后端与探针对比）**：**`passed`**
   - 实证 `QEMUDirectXDriver` 为沙盒偏好整数枚举：`0` = `d3dmetal-native`（`129.938 FPS`, `gpu_ms=0.0`, `0 LSB`），`1` = 禁用硬件 D3D（`18.431 FPS`），**`2` = `dxmt-native`**（`lsof` 确证 `dxmt-native.framework` 加载，**`119.460 FPS`**，**`ID3D11Query(TIMESTAMP)` 真实恢复 `gpu_ms = 1.6213 ms`**，**`0 LSB` 逐字节一致**）。
2. **任务 9A-2（`dxmt-native` 后端重测 `target-cn` + 宿主机 `sample` 堆栈取证）**：**`passed_deadlock_broken`**
   - **彻底打破 Phase 7A–8A 连续三次的 2.6 秒创角死锁**：在 `dxmt-native.framework` 下，`VALORANT-Win64-Shipping.exe` 连续稳定运行 **63 分钟**零冻结、零崩溃，帧号全程持续推进（`189 → 838 → 925 → … → 422 → 735`），原生 ARM64 `ACE-CORE10405/20405` 全程 `Running (ExitCode=0)` 无任何踢线或弹窗；
   - 对活跃 `QEMURenderServer`（PID `2719`）执行 macOS 原生只读 `sample 2719 3`，实证实时调用栈稳定运行在 `npt_transport_dispatch → dxmt::MTLD3D11ImmediateContext::Commit() → AGXMetalG16G_B0`（Apple M4 Metal 原生硬件提交）；
   - 如实记录唯一剩余交互阻塞：游戏接管焦点后即使关闭 `MouseTrails` 并切换 UTM `Capture Mouse`，游戏内鼠标指针仍不可见，导致未能通过鼠标点击完成创角进入大厅/靶场（故“受保护大厅与对局”保持 `not_verified`，“厂商 VM 准入”保持 `unknown`）。
3. **任务 9A-3（单测、能力清单、默认恢复与零漂移清理）**：**`passed`**
   - `graphics-lab` 全量 `unittest` **244 项全部通过（OK）**（含新增 4 项 `test_p9_valorant_analyzer.py`）；
   - 已输出 [utm-native-capabilities.md](utm-native-capabilities.md) 供窗口 9B 固化；
   - 已恢复 `com.utmapp.UTM` 原始用户默认值、销毁 `ephemeral-p9a-valorant` 并通过全盘 SHA-256 零漂移校验（`golden_zero_drift: true`、`primary_zero_drift: true`、`cache_disk_untouched: true`）。

---

## 2. 交付物清单

- `handoff/module-f/valorant-phase9-runs/real-run-report.json`
- `handoff/module-f/valorant-phase9-runs/summary.md`
- `handoff/phase-9/evidence/p9-a/report.md`
- `handoff/phase-9/evidence/p9-a/utm-native-capabilities.md`
- `handoff/phase-9/evidence/p9-a/dxmt-vs-d3dmetal-probe.json`
- `handoff/phase-9/evidence/p9-a/sample-renderserver-dxmt-live.json`
- `handoff/phase-9/evidence/p9-a/dxmt-1hour-stability-check.json`
- `handoff/phase-9/evidence/p9-a/zero-drift-proof.json`
- `graphics-lab/p9_valorant_analyzer.py`
- `graphics-lab/p9_valorant_session.py`
- `graphics-lab/p9_valorant_unlock_and_probe.py`
- `graphics-lab/test_p9_valorant_analyzer.py`
