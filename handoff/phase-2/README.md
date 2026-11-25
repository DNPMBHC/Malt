# Phase 2 多窗口并行开发总控协议

日期：2026-11-22
前置基线：Phase 1 冻结门禁（见 `handoff/task-07/report.md`：SwiftPM 91 项总数 / 90 通过 / 1 跳过 / 0 失败；Strict SwiftLint 100 文件 0 违规；Xcode Debug/arm64 构建通过；整体真实环境状态 `incomplete`）。

本目录为 **4 个独立开发窗口并行协作** 而设计，不覆盖 `handoff/task-01.md` ~ `task-07.md` 及历史证据。

---

## 1. 阶段核心目标与已确认战略优先级（用户已确认）

Phase 1 已完成接口冻结、Mock 单测、静态证据与合成回环基准。
**Phase 2 的唯一衡量标准是从“纸面/合成闭环”进入“真实执行闭环”**，已确认推进优先级如下：

- **第一优先冲刺主线（P0 冲刺）**：**窗口 A + 窗口 B** —— 集中突破「真实 Windows Guest 端到端打通」与「国服 VALORANT 证据/安装包只读静态取证 + 真实 Windows 内核探针实测 + 合规动态采样」。本机外接卷（约 59.9 GiB）空间与环境搭建时间优先服务此主线。
- **同步并行主线（P0/P1 同步启动）**：**窗口 C** —— 同步启动「Wine（DXVK vs D3DMetal）图形性能实测与优化 + 资源策略接真实消费者」，先在宿主机 Wine 路径独立产出真实 D3D11 性能数据，不阻塞也不等待 Windows Guest；Guest 图形卸载对比（C3）待窗口 A 就绪后再接力。
- **底座支撑与收口线（P1 支撑）**：**窗口 D** —— 清理 Phase 1 已知代码小缺陷、提供开发期自动构建重启脚本、统筹 A/B/C 的接口提案并升级 07 真实环境验收门禁。

---

## 2. 本机起始环境基线（2026-11-22 实查）

- 宿主平台：Apple Silicon (arm64) / macOS 27 / Xcode 27 / Swift 6.4 / Python 3.12。
- 已就绪工具：`clang`、`swift`、`python3`、本地 `handoff/task-07/.tools/swiftlint`、`xcrun swift format`。
- 尚未安装/配置项：`UTM.app`、`Parallels Desktop.app`、`wine` / `wine64`、`mingw`、`cmake`（`PATH` 中均未检出），本机无已配置的 Windows Guest。
- 工作区资产：根目录已有 `VALORANT_CN_installer_v2.17.4.510.exe`；外接候选卷可用空间约 59.9 GiB（约 64 GB）。
- 已知仓库隐患：顶层 `Modules/module-a` 与 `Whisky/Modules/module-a` 存在双份副本漂移（`Whisky/Modules/module-a` 为较新版本）；所有代码变更位于 `Whisky/` 子仓库未提交工作区中。

---

## 3. 四窗口分工与严格文件写入锁（防冲突红线）

> **铁律**：每个窗口只能修改其“独占可写路径”下的文件。跨窗口接口或构建配置变更，必须先写入己方 `handoff/phase-2/evidence/window-x/interface-proposal.md`，由 **窗口 D** 统一合入。

| 窗口 | 任务文档 | 优先级 | 映射原模块 | 可立即开工内容（无 VM 依赖） | 独占可写路径（严格互斥） |
| --- | --- | --- | --- | --- | --- |
| **窗口 A** | `window-a-guest-runtime.md` | P0 | `02 (module-b)` | 宿主虚拟化环境体检、生成真实 UTM 配置模板与外接卷映射方案、引导搭建 Windows Guest | `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/UTM*.swift`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/WindowsGuest*.swift`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/UTM*.swift`<br>`handoff/phase-2/evidence/window-a/` |
| **窗口 B** | `window-b-anticheat-cn.md` | P0 | `01 (module-a)`<br>`06 (module-f)` | 统一 `module-a` 唯一真源；补齐 CN 区官方文档证据；对 `VALORANT_CN_installer_v2.17.4.510.exe` 做只读 PE/签名静态取证 | `Whisky/Modules/module-a/`<br>`Modules/module-a/`（仅用于归档/去重）<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/AntiCheatProbe.swift`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/AntiCheatProbe*.swift`<br>`handoff/module-f/`<br>`handoff/phase-2/evidence/window-b/` |
| **窗口 C** | `window-c-graphics-perf.md` | P1 | `03 (module-c)`<br>`04 (module-d)` | 搭建 Wine（DXVK/D3DMetal）与 `d3d11_probe.exe` 编译链路；跑 Wine 对比基准；将 `HostResourcePolicy` 接入真实消费者并实测 Game Mode | `graphics-lab/`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/Host*.swift`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/Host*.swift`<br>`Whisky/WhiskyKit/Documentation/`<br>`Whisky/WhiskyKit/Tools/`<br>`handoff/phase-2/evidence/window-c/` |
| **窗口 D** | `window-d-core-gate.md` | P1 / 持续 P0 | `05 (module-e)`<br>`07 (module-g)` | 修复自动选卷排序 bug；补全 CLI 端到端运行测试；合入 06 元数据字段与三语本地化；编写开发期自动重建重启脚本；升级 07 真实证据门禁 | `Whisky/Whisky/`<br>`Whisky/WhiskyCmd/`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/Runtime*.swift`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/GameCompatibilityDatabase.swift`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/JSONKeyUniquenessScanner.swift`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Whisky/`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/Runtime*.swift`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/IntegrationBoundaryTests.swift`<br>`handoff/runtime-interface.md`<br>`handoff/task-07/`<br>`handoff/phase-2/evidence/window-d/` |

---

## 4. 所有窗口必须遵守的工程纪律

1. **Step-by-Step 流程**：每个窗口接手后必须先输出 `## 思考与分析`、`## 实施计划`、`## 任务清单`，**等待用户确认方案后再写代码或安装软件**。
2. **禁止空转写 Mock**：不允许为了“产出代码量”继续堆砌假 Provider、假测试或合成基准。若缺少真实环境（UTM/Windows 镜像/Wine/WDK），必须给出精确前置步骤，由用户配合就绪后再进入实测。
3. **开发环境自动重启规则**：任何修改了 `Whisky.app`、`WhiskyCmd`、`metal_host` 或后台验证进程的代码变更，验证方案中必须包含“构建 → 终止旧进程 → 自动重启新产物”的命令或脚本，避免测到旧进程。
4. **合规、防外挂滥用与事实红线**：
   - 严禁伪造硬件标识、隐瞒虚拟化、篡改反作弊组件或绕过保护检查；真实拒绝、架构阻塞与错误码均属于一等有效结果。
   - **严禁留存任何可被直接用于制作外挂的框架接口**：禁止在宿主/VMM/图形卸载/探针中暴露游戏进程内存读写、DLL 注入、调试/内存 dump 端口、或“截帧导出 + 合成键鼠回注”能力；所有正式产物需遵循 Hardened Runtime 防注入与诚实环境身份原则（详见 `handoff/phase-3/README.md` 与 `handoff/phase-3/anti-cheat-abuse-hardening-and-packaging.md`）。
   - **免责声明红线**：本项目仅限开源技术研究与合法授权软件调度，严禁用于外挂制作或违反游戏厂商条款；任何违反厂商政策或私自魔改导致的账号封禁与法律后果由使用者自行承担。
5. **五维状态分离**：所有报告必须分别标明「代码实现」「本机合成验证」「真实 Guest/Wine 验证」「厂商支持」「真实游戏验证」，严禁混为一谈。
6. **版本控制与脱敏**：未经用户明确指令，不执行 `git commit`、`git push`、`git reset`，不修改全局 Git 配置；所有落盘证据与报告不得泄露本机真实用户名、私密卷名或未脱敏路径。
7. **门禁回归**：合并验收前，最终需通过窗口 D 维护的统一门禁（SwiftPM 全通、Strict SwiftLint 0 违规、Xcode Debug/arm64 构建、`graphics-lab` 单元测试与 SDK 检查、`format_check.py`）。

---

## 5. 推进节奏（按用户确认优先级执行）

1. **冲刺主线立即启动（P0 · 窗口 A + 窗口 B）**：
   - **窗口 A**：立即环境体检并引导搭建 UTM Windows 11 ARM64 Guest 与外接卷共享目录；一旦就绪立刻跑通普通程序全生命周期与 `verified` 映射，第一时间交接给窗口 B。
   - **窗口 B**：立即清理 `module-a` 双副本漂移、补齐国服 VALORANT 官方证据、完成 `VALORANT_CN_installer_v2.17.4.510.exe` 只读 PE/签名静态取证；拿到窗口 A 的 Guest 后立刻实跑 WDK 探针与（经授权的）国服安装器合规动态采样。
2. **图形性能线同步启动（P0/P1 · 窗口 C）**：
   - **窗口 C**：与 A/B 同步开工，先完成 `d3d11_probe.exe` 编译与 **Wine（DXVK vs D3DMetal）** 冷/热启动和帧时间实测，以及 `HostResourcePolicy` 接入真实消费者；等窗口 A Guest 稳定后再执行阶段 C3 的 Guest 图形卸载对比。
3. **底座收口线并行支撑（P1 · 窗口 D）**：
   - **窗口 D**：立即清零 `05` 已知小缺陷、落盘开发期重建重启脚本、响应 A/B/C 接口提案并升级 `07` 真实环境门禁，最后汇总 `handoff/phase-2/evidence/window-{a,b,c}/` 更新 `handoff/task-07/report.md`。

---

## 6. 下一阶段衔接（Phase 3 预备）

- 当前 Phase 2 优先跑通干净官方最小基线以拿到无变量污染的真实结论；
- 待基线跑通后，**尽量砍掉所有反作弊不需要内容的极简 Guest 优化器**（含官方 LTSC/IoT 选型、声明式服务/壳层裁剪白名单与回滚机制、Apple `Virtualization.framework` 最小设备树减负）已提前沉淀至 `handoff/phase-3/guest-minimal-optimizer.md`，不在 Phase 2 阶段打断当前四个并行窗口。
