# 窗口 8A 验收报告：无畏契约免 Resize 进大厅/训练场实测与指针可见性破局

日期：2026-11-24  
署名：`@DNPMBHC`  
独占路径：`handoff/module-f/valorant-phase8-runs/`、`graphics-lab/p8_valorant_*`、`graphics-lab/test_p8_valorant_*`、`handoff/phase-8/evidence/p8-a/`  
隔离声明：**全程基于只读黄金母盘 `golden-win11-arm64-v1` 派生的瞬时克隆 `ephemeral-p8a-valorant` 执行，测试结束后已彻底销毁克隆并完成全盘逐字节 SHA-256 零漂移复核。**

---

## 1. 任务执行与诚实结论

1. **任务 8A-1（静态 `1280×720` 防 Resize + 软件光标配置）**：`completed`
   - 在 `ephemeral-p8a-valorant` 的 `config.plist` 中锁定 `Display[0].DynamicResolution = False`；
   - 在 Guest 交互桌面会话中锁定 `1280×720 @ 120 Hz`（`ChangeDisplaySettingsExW = 0`）、启用标准软件光标回退（`SPI_SETMOUSETRAILS = 2`）、预置 `GameUserSettings.ini` 为 `1280×720` 窗口化（`FullscreenMode=2`）；
   - 核验 Guest 鼠标设备为 `USB\VID_0627&PID_0001`（`Status=OK`），原生 ARM64 ACE（`ACE-CORE10405` / `ACE-CORE20405`）持续 `Running (ExitCode=0)`。
2. **任务 8A-2（进大厅/靶场实测与 `ACE-GAME.sys (1275)` 观测）**：`executed_blocked_by_neptune_umd_ui_freeze`
   - 在**全程零 Resize、零窗口拖拽**的条件下，游戏仍在进入创角输入名字界面后 2.6 秒永久冻结在帧 **`[230]`**（`QEMURenderServer` CPU `0.0%`，`VALORANT-Win64-Shipping.exe` CPU 10 秒增长 `+12.11 s` 陷入忙等死循环），导致鼠标键无法交互、未能完成创角进入大厅与训练场；
   - 诚实结论：推翻“仅关闭 DynamicResolution 避免 Resize 即可畅玩”的乐观预期，坐实 `viogpu3d v100.6.101.58000`（`neptune_umd`）在 `target-cn` 进入创角/主界面 3D 渲染阶段存在**独立于 Resize 的 WDDM2 同步死锁**；大厅/靶场 FPS 与 `ACE-GAME.sys (1275)` 中途踢线影响均如实保持 `not_verified`。
3. **任务 8A-3（单测、接口提案与零漂移归档）**：`passed`
   - `graphics-lab` 全量 `unittest` **240 项全部通过（OK）**（含新增 4 项 `test_p8_valorant_analyzer.py`）；
   - 已向窗口 8B 输出 [interface-proposal.md](interface-proposal.md)；
   - 已销毁 `ephemeral-p8a-valorant` 并全盘 SHA-256 复核 `golden_zero_drift: true`、`primary_zero_drift: true`、`cache_disk_untouched: true`。

---

## 2. 交付物清单

- `handoff/module-f/valorant-phase8-runs/real-run-report.json`
- `handoff/module-f/valorant-phase8-runs/summary.md`
- `handoff/phase-8/evidence/p8-a/report.md`
- `handoff/phase-8/evidence/p8-a/interface-proposal.md`
- `handoff/phase-8/evidence/p8-a/spawn-preflight.json`
- `handoff/phase-8/evidence/p8-a/zero-drift-proof.json`
- `graphics-lab/p8_valorant_analyzer.py`
- `graphics-lab/p8_valorant_session.py`
- `graphics-lab/test_p8_valorant_analyzer.py`
