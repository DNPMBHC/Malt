# 窗口 B 任务书：反作弊内核实测 + 国服 VALORANT 证据与安装器采样（P0 · 第一优先冲刺主线）

对应原模块：`task-01 / module-a` + `task-06 / module-f`
战略位置：**Phase 2 第一优先冲刺主线（与窗口 A 协同，优先突破国服 VALORANT 静态/动态实证与 WDK 自有探针）**
请先阅读：`handoff/phase-2/README.md`、`handoff/task-01.md`、`handoff/task-06.md`、`handoff/module-f/engineering-input.md`、`handoff/task-07/report.md`

---

## 1. 冲刺前历史基线与核心问题

> 状态说明（2026-11-22 更新）：第 1 节是冲刺前的历史基线。当前唯一探针真源已核验，正规安装包静态采样已完成；自有 ARM64 构建、有效测试签名、三个真实生命周期及安全恢复已取证通过。当前商业动态采样仍待独占 Guest 时段。以窗口 B 的真实报告为当前状态依据。



- **自有内核探针（`module-a`）**：已完成 v2 协议 ABI、`module_a_driver.c`、`probe.c`、`verify-lifecycle.ps1` 与 Swift 侧解析测试（CTest `1/1`）；但**从未在 Windows 上编译、签名、加载或运行**。
- **工程漂移隐患**：顶层 `Modules/module-a` 与 `Whisky/Modules/module-a` 存在双份目录，经核对 `Whisky/Modules/module-a` 更新（含失败阶段证据保留的 `try/catch` 逻辑），必须尽快统一唯一真源。
- **厂商与国服证据（`module-f`）**：国际服证据较完整（24 来源、32 声明），但**中国发行区（A-CN / B-CN / C-CN）全部为 `unknown`**；工作区根目录已有实测样本 `VALORANT_CN_installer_v2.17.4.510.exe`，尚未进行只读 PE/签名静态采样。

---

## 2. 独占可写路径（严禁越界修改）

- `Whisky/Modules/module-a/`（唯一真源）
- `Modules/module-a/`（仅用于核对差异后的清理/去重，操作前先确认无脚本硬编码引用）
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/AntiCheatProbe.swift`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/AntiCheatProbeTests.swift`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/AntiCheatProbeTestSupport.swift`
- `handoff/module-f/`（`evidence.json`、`evidence-matrix.md`、`engineering-input.md`、`validate_evidence.py` 等）
- `handoff/phase-2/evidence/window-b/`（新建，存放静态取证、真机探针报告与接口提案）

> 严禁修改 `WhiskyKit/Runtime/Runtime*.swift`、`GameCompatibilityDatabase.swift` 或 UI 文件；若有模型字段变更需求，写入 `handoff/phase-2/evidence/window-b/interface-proposal.md` 交由窗口 D 统一落地。

---

## 3. 分阶段实施任务

### 阶段 B1：立即可执行（不依赖 Windows Guest）
1. **统一 `module-a` 唯一真源**：
   - 完整 diff `Modules/module-a` 与 `Whisky/Modules/module-a` 的所有非构建产物文件，核查 `handoff/task-07/integration.py`、`verify.py` 及全部测试对路径的引用。
   - 确认以 `Whisky/Modules/module-a` 为唯一真源，制定安全移除或归档顶层重复副本的方案（经用户批准后执行），确保 `CTest` 与 `AntiCheatProbeTests` 全部通过。
2. **国服（CN）与 Windows on ARM 新动态一手证据补齐（VALORANT 为首要开发焦点）**：
   - 保持 **VALORANT（国服 ACE + 国际服 Vanguard / On-Demand 按需模式）** 为第一研究焦点，并同步覆盖 LoL 国服（`B-CN`）、THE FINALS 国服（`C-CN`，若存在）的官方反作弊体系、系统与架构要求、VM 政策及公开接口信息。
   - 结合 NVIDIA N1/N1X (RTX Spark) 推动原生 ARM64 反作弊驱动普及的新趋势，在 `module-f` 证据体系中明确拆分 **「裸金属 Windows on ARM 驱动可用性」** 与 **「虚拟化 ARM64 Guest 策略（Hypervisor / vTPM 硬件信任根限制）」**，不再将二者混为一谈。
   - 遵循 `handoff/module-f/evidence.schema.json` 严格格式（页面标题、公开 URL、访问日期、原文摘录），通过 `python3 handoff/module-f/validate_evidence.py` 及反向语义检查；无可靠一手资料的项继续保持 `unknown`。
3. **工作区国服安装包只读静态取证**：
   - 对 `VALORANT_CN_installer_v2.17.4.510.exe` 进行**纯只读静态分析**（绝不修改文件、绝不逆向绕过反作弊）：
     - 计算文件大小与 SHA-256；
     - 解析 PE 头（Machine 架构、子系统、Timestamp、版本资源、清单权限要求）；
     - 提取 Authenticode 签名者/证书链信息与内嵌元信息（若为自解压/封装包，仅做只读结构识别并如实记录边界）。
   - 将脱敏静态报告写入 `handoff/phase-2/evidence/window-b/valorant-cn-installer-static.json` 与摘要文档，并同步更新 `handoff/module-f/engineering-input.md`。

### 阶段 B2：真实 Windows 内核探针与合规实测（待窗口 A Windows Guest 就绪后执行）
1. **WDK 编译与测试签名加载自有探针**：
   - 在与目标架构匹配的真实 Windows Guest（ARM64 或 x64）中，使用 WDK 编译 `ModuleAProbe.sys` 与 `module_a_probe.exe`。
   - 开启测试签名（仅用于自有诊断探针，明确标注环境状态），运行 `verify-lifecycle.ps1` 的 `cycle`、`before-reboot`、`after-reboot` 全流程。
   - 完整取证：服务加载、请求进程对象匹配、常驻进程创建通知、暂停子进程 PID 绑定与驱动回传 PID 一致性、退出回收、卸载与重启后状态。
2. **合规动态采样（以 VALORANT 为首要焦点，需用户明确二次授权后执行安装器）**：
   - 优先沿官方正常安装路径执行国服 VALORANT 安装器，并核查国际服 Vanguard On-Demand 模式在 Windows 11 24H2+ ARM64 下的真实驱动分发状态，如实记录安装阶段、实际释放的驱动二进制架构（PE Machine）/签名/版本、实际加载结果或官方拒绝错误码（精确区分“无 ARM64 驱动”与“Hypervisor / vTPM 拒绝”）。
   - **辅助对照试金石（可选补充）**：在不分散 VALORANT 焦点的前提下，可辅以 1 款已推出官方原生 ARM64 驱动且不封杀 VM 的 EAC/BattlEye 样本，验证「Windows 11 24H2+ Prism x64 用户态 + 原生 ARM64 官方内核驱动」对照基线，用来排除 Guest 环境配置本身的问题。
   - **绝对红线**：严禁伪造硬件标识、隐瞒虚拟化、修改保护组件或尝试绕过反作弊检测。

---

## 4. 验证与交付标准

- 每次修改 `AntiCheatProbe.swift` 或 `module-a` 源码后，必须重跑 `swift test --package-path Whisky --filter AntiCheatProbeTests`、可移植 ABI CTest（重建后运行最新产物）以及 `python3 handoff/module-f/validate_evidence.py`。
- 交付物：
  1. `handoff/phase-2/evidence/window-b/module-a-dedup-report.md`（真源治理与验证记录）
  2. 更新并通过 schema 校验的 `handoff/module-f/evidence.json` 与 `engineering-input.md`
  3. `handoff/phase-2/evidence/window-b/valorant-cn-installer-static.json`（只读静态取证）
  4. `handoff/phase-2/evidence/window-b/real-windows-probe-report.json`（真实 Windows Guest 实测报告或明确环境阻塞清单）
- 四类状态严格独立报告：**发行方立场 / 实际驱动加载 / 实际游戏启动 / 实际受保护在线会话**。自有探针通过绝不等于商业反作弊通过。
