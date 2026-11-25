# Phase 14 窗口 14A 任务书：残余性能极限深挖与全员合体端到端真机实测

- **窗口角色**：Phase 14 窗口 14A
- **难度评级**：🔴 高难度（建议模型：**`Neon Medium`**）
- **署名**：`@DNPMBHC`
- **母盘基线**：`golden-win11-arm64-v1`（只读不可变，全盘 SHA-256 必须 `zero_drift = true`）

---

## 1. 任务目标

### 任务 14A-1：残余性能深挖（3 项高杠杆实验，数据说话、拒绝玄学）
在 `graphics-lab/p14_full_stack_perf_eval.py`（及单测 `test_p14_full_stack_perf_eval.py`）中设计并完成以下 3 项真机量化实验：
1. **双缓存持久化增益实证（`XtaCache` + `DXMT_SHADER_CACHE`）**：
   - 在持久化游玩模式（`create-playable`）中对比 **冷缓存首启 vs 热缓存二次启动**（保留 Windows ARM64 Prism 转译缓存 `XtaCache` + 宿主机 `DXMT_SHADER_CACHE`），量化前 60 秒进图 CPU 占用、P1 Low FPS 与严重掉帧次数降幅；
2. **消除 `2.93 ms` 帧同步损耗（`Slack + Slop`）实验**：
   - 对比 `QEMURendererFPSLimit = 0`（不限）vs `120`（与显示器对齐）以及游戏内/驱动低延迟呈现组合，实测对平均帧时间、P1 Low 与输入响应延迟的影响；
3. **虚拟设备中断开销深挖**：
   - 检查 QEMU 启动参数中是否还存在可安全移除的非必要轮询外设，并客观评估 `virtio-input`（若 WHQL `vioinput` 驱动可用）vs `usb-mouse` 在高频移动下的 Guest 中断率与 CPU 占用对比（若不可用则诚实记录现状，绝不关闭 Secure Boot）。

### 任务 14A-2：Phase 11–13 全员合体端到端真机验收
将全部已验证优化合体至同一运行栈（**`8 vCPU / 10240 MiB RAM / VirtIO-Blk 多队列 iothread / 去 slirp 原生网络 / dxmt-native + 持久化双缓存 / UTM-Custom 10 补丁（Game Mode + 高回报率鼠标 1.5ms 合批 + 防误触 Cmd+W/Q/H/M + --app-shell-vm 双形态壳）+ guest-optimizer v3.1 + 突发优化`**）：
1. 实测验证无桌面应用壳（`--app-shell-vm` 紧凑窗 → 进游戏自动切无边框原生全屏 + Game Mode）与热唤醒秒开全链路；
2. 在 **`1920×1200`** 下运行 **`target-cn` 靶场 3–5 分钟合体回归实测**（涉及登录/验证时暂停请用户手动完成，严禁自动化绕过），与 Phase 11B 基线（`1920×1200` 靶场热缓存第 8 分钟均值 `55.51 FPS` / P50 `58.44 FPS` / `Slack+Slop 2.93 ms`）做逐项量化对照，重点观察是否突破 `60+ FPS` 稳态以及 `slirp` 丢包告警是否彻底归零；
3. 给出客观、诚实的**“下一代性能物理上限研究结论”**（明确哪些已接近当前 Apple Silicon + Prism + QEMU 硬件极限，哪些必须依赖上游原生 ARM64 客户端或未来 macOS 原生 vTPM/GPU 虚拟化 API）。

### 任务 14A-3：清理与零漂移铁证
销毁所有临时实验克隆（若保留用户日常持久化游玩 VM 则明确记录状态），确保只读母盘 `golden-win11-arm64-v1`、`vm-a` 与 `/Applications/UTM.app` 全盘 SHA-256 `zero_drift = true`。

---

## 2. 独占写入范围（严禁越界）

- 允许写入：
  - `graphics-lab/p14_full_stack_perf_eval.py`
  - `graphics-lab/test_p14_full_stack_perf_eval.py`
  - `handoff/module-f/valorant-phase14-runs/**`
  - `handoff/phase-14/evidence/p14-a/**`
- 严禁触碰：`Whisky/Whisky/`、`Whisky/WhiskyKit/`、`Whisky/Modules/utm-custom/`、`Whisky/Modules/guest-optimizer/`、`handoff/task-07/`、窗口 14B 独占路径、`/Applications/UTM.app` 原件、只读母盘与冷备 `vm-a`。

---

## 3. 验收门禁与交付物

1. `handoff/phase-14/evidence/p14-a/perf-deep-dive-p14.json`
2. `handoff/module-f/valorant-phase14-runs/real-run-report.json` & `summary.md`
3. `handoff/phase-14/evidence/p14-a/zero-drift-proof.json` & `report.md`
4. 必须全绿：
   - `(cd graphics-lab && python3 -B -m unittest discover -v)`
   - `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test`
   - 零 `> 5 MiB` 新增文件、零隐私路径泄漏、零 git 操作、母盘与 `vm-a` `zero_drift = true`。
