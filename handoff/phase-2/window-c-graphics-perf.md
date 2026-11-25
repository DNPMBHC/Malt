# 窗口 C 任务书：Wine（DXVK vs D3DMetal）图形性能优化 + 资源策略接真实消费者（同步并行主线）

对应原模块：`task-03 / module-c` + `task-04 / module-d`
战略位置：**Phase 2 同步并行主线（与 A+B 冲刺线独立推进：先打通 Wine 下 DXVK vs D3DMetal 实测与优化，Guest 图形卸载待窗口 A 交付稳定 Guest 后接力）**
请先阅读：`handoff/phase-2/README.md`、`handoff/task-03.md`、`handoff/task-04.md`、`graphics-lab/README.md`、`graphics-lab/results.md`、`handoff/task-07/report.md`

---

## 1. 当前基线与核心问题

- **图形实验（`module-c`）**：`graphics-lab/` 已有 `d3d11_probe.cpp`、`metal_host.swift`、`synthetic_client.py`、`analyze.py`、`run_probe.py` 与 `test_metalfx_sdk_compile.py`（8 项单测与 macOS 27 SDK 类型检查通过）。但**仅在 macOS 本机跑过 Python 合成回环**，从未编译/运行过真实 `d3d11_probe.exe`，也没有任何 Wine（DXVK vs D3DMetal）或 Guest 真实图形对比数据；旧性能证据也未绑定源码/二进制不可变摘要。
- **平台能力与资源策略（`module-d`）**：静态 Metal 能力缓存、动态热状态/低电量通知、MetalFX 探测已完成，但 **`HostResourcePolicy` 目前只接入了“专用诊断计算队列”，没有真实执行消费者**；Game Mode 实际激活状态仍为 `unknown`。

---

## 2. 独占可写路径（严禁越界修改）

- `graphics-lab/`（全部脚本、D3D11 探针、Metal 接收端、实验数据与 `results.md`）
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/Host*.swift`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/Host*.swift`
- `Whisky/WhiskyKit/Documentation/`
- `Whisky/WhiskyKit/Tools/`
- `handoff/phase-2/evidence/window-c/`（新建，存放实测数据索引、架构演进评估与接口提案）

> 若需要将 `HostResourcePolicy` 的策略参数接入 `Wine.swift`、`RuntimeCoordinator.swift` 或 GUI 开关，请先在 `HostResourcePolicy` 层设计清晰的无侵入输出模型，并将接入点提案写入 `handoff/phase-2/evidence/window-c/interface-proposal.md` 交由窗口 D 统一接线。

---

## 3. 分阶段实施任务

### 阶段 C1：真实 D3D11 编译 + Wine 图形转译实测基线（可先于 VM 启动）
1. **工具链准备与真实 `d3d11_probe.exe` 编译**：
   - 检查本机 Wine / DXVK / D3DMetal（WhiskyWine）以及编译 `d3d11_probe.cpp` 的可行方案（例如 mingw-w64 交叉编译或 Windows SDK 编译）。
   - 若工具链未安装，先向用户提供最小化安装清单并确认后执行；禁止用 Python 合成脚本替代 D3D11 实测。
2. **Wine 三引擎配对基准测试与自动路由（DXMT vs D3DMetal vs DXVK）**：
   - 使用独立 disposable prefix 与 `graphics-lab/run_probe.py`，固定分辨率（如 1280×720）、帧数（120 预热 + 900 测量）、draw batch 与资源负载，至少重复 3 轮：
     - `Wine + DXMT`（新增核心升级：Direct3D 10/11 直接译至原生 Metal，跳过 Vulkan/MoltenVK 双层转译）：冷/热缓存启动时间、P50/P95/P99 帧时间、平均帧率、内存；
     - `Wine + D3DMetal`：同参数冷/热缓存启动时间、P50/P95/P99 帧时间、平均帧率、内存（DX12 唯一主力）；
     - `Wine + DXVK`：同参数冷/热缓存启动时间、P50/P95/P99 帧时间、平均帧率、内存（兼容兜底）。
   - 基于实测结果给出「按 DX 版本自动路由」提案（DX12 → `D3DMetal`、DX11 性能优先 → `DXMT`、DX11 兼容兜底 → `DXVK`），并通过 `interface-proposal.md` 同步给窗口 D。
   - 强制在结果元数据中绑定本次测试的**源码文件 SHA-256、可执行文件 SHA-256、macOS/SDK 版本、Wine/DXMT/DXVK/D3DMetal 版本与缓存状态**，彻底解决 Phase 1 报告中指出的“证据未绑定摘要”问题。

### 阶段 C2：资源策略接入真实执行消费者 + Game Mode 实测观测
1. **接入真实消费者**：
   - 在 `graphics-lab/metal_host.swift` 中接入动态资源策略消费（例如依据热状态/低电量/MetalFX 策略调整呈现帧率上限、缩放路径或缓冲区策略，支持可回退开关），并执行真实 A/B 对比。
   - 在 `HostResourcePolicy.swift` 中输出可直接被 Wine / Guest 启动层消费的结构化环境变量/运行参数建议（明确每个变量的真实下游消费者文档依据，严禁输出无消费者的空环境变量），并将接线提案交窗口 D。
2. **Game Mode 真实观测**：
   - 在 macOS 27 真机上以带 `LSSupportsGameMode` 的打包应用及子进程（Wine/渲染器）进行实际观测，记录系统级 Game Mode 激活状态与子进程调度差异；若仍无法从公开手段确认激活，如实记录为 `unknown` 及观测边界。

### 阶段 C3：Windows Guest 图形对比与下一代架构选型（待窗口 A Guest 就绪后执行）
1. 在同一个 Windows Guest 中对比 `d3d11_probe.exe` 的「本地直出」与「TCP staging 卸载至 `metal_host.swift`」。
2. 拆分每帧真实耗时（D3D GPU 渲染、`CopyResource/Map` 回读、网络传输、Metal 上传与呈现），基于实测数据撰写下一代图形卸载架构决策报告（评估共享内存环形缓冲、Virtio-GPU、API 命令流转发等路线的收益、工程复杂度与与窗口 B 的保护边界约束）。

---

## 4. 开发期验证与自动重启要求

- 每次修改 `graphics-lab/metal_host.swift` 后，必须重新编译 `metal_host`、终止旧 `metal_host` 进程并重启新进程后再采集数据。
- 每次修改 `Host*.swift` 后，重跑：
  - `swift test --package-path Whisky --filter Host`
  - `cd graphics-lab && python3 -B -m unittest discover -v`（确认 `test_metalfx_sdk_compile.py` 实际执行且未跳过）

---

## 5. 验收标准与交付物

1. 更新后的 `graphics-lab/results.md` 与 `handoff/phase-2/evidence/window-c/` 下的原始脱敏 CSV/JSONL（全部绑定源码与二进制不可变摘要）。
2. `HostResourcePolicy` 接入真实消费者的代码、回退开关单元测试与 A/B 实测报告。
3. 下一代 Guest 图形卸载方案技术评审文档（基于实测数据，无数据不宣称显著提速）。
