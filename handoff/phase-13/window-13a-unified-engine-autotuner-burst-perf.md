# Phase 13 窗口 13A 任务书：统一双引擎编排层、自动性能校准、突发大特效稳帧与无桌面 Kiosk 会话

- **窗口角色**：Phase 13 窗口 13A
- **难度评级**：🔴 高难度（建议模型：**`Neon Medium`**）
- **署名**：`@DNPMBHC`
- **母盘基线**：`golden-win11-arm64-v1`（只读不可变，必须全盘 SHA-256 `zero_drift = true`）

---

## 1. 任务目标

### 任务 13A-1：在 `WhiskyKit` 落地统一双引擎编排层与自动性能校准器（`Orchestration/`）
在 `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/` 下严格按 `handoff/phase-13/README.md` 契约实现（必须通过 Strict SwiftLint 0 violations 与 SwiftPM 单测）：
1. **`UnifiedGameEntry.swift` & `UnifiedGameLibraryStore.swift`**：
   - 统一持久化管理普通 Wine 游戏（关联 Bottle）与反作弊 VM 游戏（关联持久化游玩 VM）的 JSON 注册表；
   - 提供 `classifyInstaller(url: URL) -> UnifiedEngineKind`（基于安全特征/文件名/已知反作弊关键词智能建议引擎模式，同时始终允许用户手动覆盖）。
2. **`HardwareAutoTuner.swift`**：
   - 使用标准 macOS `sysctl` / `ProcessInfo` / `NSScreen` / 外置卷探测实时采集本机 `HardwareProfileSnapshot`（芯片、P/E 核数、物理内存 GiB、屏幕刷新率、推荐外置高速 SSD 路径）；
   - 实现 `runQuickBenchmarkAndRecommend()`（10–15 秒轻量多线程 CPU + 磁盘 I/O 微基准），基于 Phase 11–12 实证规则自动生成最优 `AutoTuneRecommendation`（例如 16 GiB 10 核自动推荐 `8 vCPU / 10240 MiB RAM / balancedRecommended / Game Mode=true / 1500us 鼠标合批 / 防误触=true`；24+ GiB 自动解锁 `12288 MiB+` 与更高画质档）。
3. **`UnifiedRuntimeOrchestrator.swift`**：
   - 统一封装普通 Wine 启动与反作弊 VM（调用 `UTM-Custom --app-shell-vm` / `--game-shell-vm` + `golden_guest_manager.py`）的启动、安装与健康体检接口；
   - 编写完整单元测试 `Whisky/WhiskyKit/Tests/WhiskyKitTests/UnifiedOrchestrationTests.swift`。

### 任务 13A-2：突发大特效稳帧优化 + 架构级冷启动精简与可选热待机秒开
1. **突发大特效 / 瞬间高数据爆发专项基准（`graphics-lab/p13_burst_perf_benchmark.py` 及单测）**：
   - 构造“平稳段 → **突发大特效段**（瞬时 4× Draw-Call + 4–8 MiB/帧动态缓冲/纹理切换上传 + 多线程 CPU 突发计算）→ 恢复段”的真实 D3D11 压测；
   - 在派生克隆（`8 vCPU / 10240 MiB RAM / VirtIO-Blk 多队列 / 原生网络 / dxmt-native`）上对比**基线 vs 突发优化态**（前景进程 `High` 优先级、持久化 `DXMT_SHADER_CACHE` 预热、关闭非必要后台抖动），重点量化压低突发段 **P1 Low / P0.1 Low FPS 与 Max Frame Time (ms)**。
2. **冷启动架构精简 + 可选热待机秒开（`graphics-lab/golden_guest_manager.py` 及单测）**：
   - 优化无桌面应用壳模式下的启动链路，记录纯冷启动耗时；
   - 新增 `warm-standby` / `pause` / `resume-launch`（基于 QMP `stop`/`cont` 暂停驻留 `0% CPU` + macOS 原生内存压缩），实测对比 **冷启动 vs 热唤醒打开应用耗时**，并验证恢复后 `viogpu3d` 渲染与 `ACE-CORE` 驱动状态 100% 正常无异常。

### 任务 13A-3：无桌面 Kiosk 会话脚本（100% 合规，零 DWM Hook / 零注入）
在 `Whisky/Modules/guest-optimizer/` 新增 `scripts/kiosk-app-shell.ps1` 与回滚/退出清理逻辑（同步更新 `tests/test_guest_optimizer.py`）：
- 进入应用壳会话时：通过标准 Windows API 隐藏任务栏、隐藏桌面图标、背景设为纯黑；
- 直接拉起指定安装器（`.exe`/`.msi`）或启动器并将其主窗口置顶居中/贴合视口；
- 只读轮询前景进程列表，发现目标游戏主进程进入前景后输出标准 JSON 状态信号（供宿主机 13B `--app-shell-vm` 自动无缝切换为无边框原生全屏 + Game Mode），同时安全将前景游戏主进程设为 `High` 优先级；
- 退出会话时自动完整还原任务栏与桌面图标。

---

## 2. 独占写入范围（严禁越界）

- 允许写入：
  - `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/**`
  - `Whisky/WhiskyKit/Tests/WhiskyKitTests/UnifiedOrchestrationTests.swift`
  - `Whisky/Modules/guest-optimizer/**`
  - `graphics-lab/golden_guest_manager.py`
  - `graphics-lab/test_golden_guest_manager.py`
  - `graphics-lab/p13_burst_perf_benchmark.py`
  - `graphics-lab/test_p13_burst_perf_benchmark.py`
  - `handoff/phase-13/evidence/p13-a/**`
- 严禁触碰：`Whisky/Whisky/`（App 前端，归 13B）、`Whisky/Modules/utm-custom/`（归 13B）、`handoff/task-07/`、`/Applications/UTM.app` 原件、只读母盘与冷备 `vm-a`。

---

## 3. 验收门禁与交付物

1. `handoff/phase-13/evidence/p13-a/burst-and-fastlaunch-benchmark.json`
2. `handoff/phase-13/evidence/p13-a/zero-drift-proof.json`
3. `handoff/phase-13/evidence/p13-a/report.md`
4. 必须全绿：
   - `swift test --package-path Whisky/WhiskyKit`
   - `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)`（0 violations）
   - `(cd Whisky/Modules/guest-optimizer && python3 -B -m unittest discover -s tests -v)`
   - `(cd graphics-lab && python3 -B -m unittest discover -v)`
   - `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test`
   - 零 `> 5 MiB` 新增文件、零隐私路径泄漏、零 git 操作、母盘与 `vm-a` 全盘 SHA-256 `zero_drift = true`。
