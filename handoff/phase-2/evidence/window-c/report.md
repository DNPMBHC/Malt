# Phase 2 窗口 C 交付验收报告（图形性能实测 + 资源策略接真实消费者）

日期：2026-11-22  
对应任务书：`handoff/phase-2/window-c-graphics-perf.md`（原 `task-03 / module-c` + `task-04 / module-d`）  
执行范围：阶段 C1（完成，含 DXMT 三引擎扩展）+ 阶段 C2（完成）+ **阶段 C3（已完成真实 Windows 11 24H2 ARM64 Guest 配对实测与最终架构决策）**。

---

## 1. 五维状态总览（严格分离，禁止混淆）

| 维度 | 当前状态 | 事实依据 |
| --- | --- | --- |
| **代码实现** | 已完成（C1 + C2 + C3） | 全部修改严格限定在窗口 C 独占路径内，零越界修改。 |
| **本机合成验证** | 已通过 | `metal_host` 策略 A/B 与回退 15 组实测；`WhiskyKit` Host 测试与全量测试 0 失败；`graphics-lab` unittest 12/12（含 `test_metalfx_sdk_compile.py`）；Strict SwiftLint 0 违规。 |
| **真实 Wine / Guest 验证** | **Wine：已完成（18 组 / 16,200 帧）**<br>**Windows Guest：已完成（6 组 / 1,800 帧）** | 真实 PE32+ `d3d11_probe.exe` 完成 Wine 三引擎对比，并在窗口 A 交付的真实 Windows 11 24H2 ARM64 Guest（`VirtIO GPU DOD`）内完成 `Direct Present` vs `Offload TCP` 跨 VM 配对实测。 |
| **厂商支持** | 不可用 | 未涉及也未假定商业反作弊厂商接口。 |
| **真实游戏验证** | 未执行 | 全部基准基于自有确定性 `d3d11_probe.exe`，未对真实商业游戏宣称提速。 |

---

## 2. 交付物清单与不可变证据索引

### 2.1 阶段 C1：真实 `d3d11_probe.exe` 编译 + Wine 三引擎（DXMT vs D3DMetal vs DXVK）配对实测
- 源码与编译脚本：
  - `graphics-lab/d3d11_probe.cpp`（SHA-256: `011adfc0422cea672d4014865451ee0c15e17e80f3f13d9d014bf5ac3567d34f`，增加 MinGW-w64 兼容 `ComPtr`，保持 MSVC 完全兼容）
  - `graphics-lab/build_probe.sh`（静态链接产出 PE32+ `graphics-lab/build/d3d11_probe.exe`，SHA-256: `4498e38244e7b06ecfaecfa6d025bcb44d9c9cfe2c9487ae8e38cd0713b6c34e`，导入表零第三方 MinGW DLL）
  - `graphics-lab/run_wine_benchmark.py` 与 `graphics-lab/test_wine_benchmark.py`（支持 `dxvk` / `d3dmetal` / `dxmt` 三引擎独立前缀隔离与同口径合并）
  - `graphics-lab/analyze.py` 与 `graphics-lab/test_analyze.py`（补充 `p50` 百分位统计，向后兼容）
- 原始脱敏数据与汇总索引：
  - 基线双引擎（保留未改写）：`handoff/phase-2/evidence/window-c/wine-dxvk-vs-d3dmetal/manifest.json`（12 组 / 10,800 测量帧）
  - 增量 DXMT 与三引擎合并同口径对比：`handoff/phase-2/evidence/window-c/wine-dxmt-three-engine/manifest.json`（新增 6 组 DXMT / 5,400 测量帧，合并总计 18 组 / 16,200 测量帧；绑定 DXMT `d3d11.dll`/`dxgi.dll`/`winemetal.dll`/`winemetal.so` 不可变 SHA-256 及 `shaders_320.db` 独立隔离缓存证据）
  - 汇总结果已同步写入 `graphics-lab/results.md`

### 2.2 阶段 C2：`HostResourcePolicy` 接入真实消费者 + 三引擎自动路由 + Game Mode 真机观测 + 窗口 D 接口提案
- **真实消费者 #1（`metal_host.swift`）**：
  - `graphics-lab/metal_host.swift`（SHA-256: `43159ad0f49076f28c1b6180c01636d0ffda09e3f4bb4f1aa94e78a474ea1784`）：接入 `--resource-policy off|auto|maximum-performance|balanced|conserve-energy`、`--metalfx off|spatial`、`--fullscreen`，并修复了低 QoS 线程直接 `usleep` 引发 XNU 计时器合并掉帧（60 FPS 掉至 18.9 FPS / 30 FPS 掉至 10.0 FPS）的问题（修复后恢复至 51.3 FPS / 26.9 FPS，回退 `off` 恢复至 120.01 FPS）。
  - `graphics-lab/restart_metal_host.sh`：开发期强制「重新编译 → 终止旧进程 → 自动重启新产物并校验 `ready`」闭环脚本。
  - `graphics-lab/run_metal_host_policy_ab.py` 与 15 组实测证据：`handoff/phase-2/evidence/window-c/metal-host-policy-ab/manifest.json`（含全部 15 组脱敏 CSV 与 JSONL）。
- **真实消费者 #2（`HostResourcePolicy.swift` + `HostWineBackendRouter.swift` + 窗口 D 提案 v2）**：
  - `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/HostResourcePolicy.swift`：新增 `HostWineGraphicsBackend`（含 `.dxvk` / `.d3dMetal` / `.dxmt`）、`HostResourceConsumerBinding`、`HostWineLaunchPolicy`（含 DXVK 与 DXMT 真实文档化/二进制实证下游消费者映射，不为 D3DMetal 伪造空变量）、`HostMetalHostPolicy`、`HostGuestLaunchPolicy`。
  - `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/HostWineBackendRouter.swift`：新增三引擎按 DX 版本确定性自动路由与降级模型（`DX12 → D3DMetal`、`DX11 性能优先 → DXMT`、`DX11 兼容兜底 → DXVK`）。
  - `Whisky/WhiskyKit/Tests/WhiskyKitTests/HostResourcePolicyTests.swift`：8 项单元测试全面覆盖 DXVK/DXMT/D3DMetal 策略映射、回退开关、用户环境变量保护与三引擎路由降级矩阵。
  - 给窗口 D 的接线提案（含 v2 三引擎路由增量章节）：`handoff/phase-2/evidence/window-c/interface-proposal.md`。
- **Game Mode 真机观测（macOS 27.2.1）与真实 `offload_tcp` 端到端冒烟**：
  - `graphics-lab/build_gamemode_app.sh` 与 `graphics-lab/run_gamemode_and_offload_probe.py`
  - 脱敏观测证据：`handoff/phase-2/evidence/window-c/gamemode-and-offload/observation-manifest.json`（含 `HostGameModeEvidence` 校验 `declaration=enabled`/`platform_eligible=true`/`activation=unknown`/`wine_child_benefit=unmeasured`、`host-state-observation.jsonl` 及真实 `d3d11_probe.exe` 1280×720 `offload_tcp` 119.95 FPS 实测 CSV/JSONL）。

### 2.3 阶段 C3 真实 Windows Guest 对比与最终架构决策
- 编排与单测：`graphics-lab/run_guest_c3_benchmark.py`、`graphics-lab/test_guest_c3_benchmark.py`
- 原始脱敏数据与耗时拆解清单：`handoff/phase-2/evidence/window-c/guest-c3-offload/manifest.json`（`Direct Present` 11.35 FPS / 91.14 ms WARP 渲染 vs `Offload TCP` 6.19 FPS / 73.08 ms 渲染+CopyResource + 99.48 ms Map/TCP/呈现，宿主 Metal GPU 仅 0.168 ms）
- 最终架构选型评审报告：`handoff/phase-2/evidence/window-c/architecture-review.md`

---

## 3. 验收门禁与脱敏审计（将在最终命令中复验）

- `swift test --package-path Whisky/WhiskyKit --filter Host`（含 `MTL_DEBUG_LAYER=1` 复验）
- `cd graphics-lab && python3 -B -m unittest discover -v`（确认 `test_metalfx_sdk_compile.py` 实际执行且未跳过）
- `handoff/task-07/.tools/swiftlint lint --strict` 0 违规
- 全量扫描 `handoff/phase-2/evidence/window-c/` 与 `graphics-lab/results.md` 确保无本机用户名、未脱敏绝对路径或私密卷名泄露
- `git status` 检查确认所有修改 100% 位于窗口 C 独占路径内，且未执行任何 `git commit`/`push`/`reset`
