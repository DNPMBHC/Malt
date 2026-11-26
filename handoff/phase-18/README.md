# Phase 18 总览：真实使用体验端到端闭环（一键部署精简优化 + 拖入安装扫描入库 + 软件内直接启动《无畏契约》）

- **署名**：`@DNPMBHC`
- **品牌**：`Malt`
- **前置基线**：Phase 15–17 已锁定至 `Whisky` `main`（`swift test` 416 项全绿、Strict SwiftLint 0 违规、自包含 `Malt.dmg` 与 `/Applications/Malt.app` 搬迁及隔离启动全绿）。

---

## 本阶段核心目标（全部围绕真实玩家上手体验）

1. **首次初始化与容器一键部署/精简优化流水线**：
   - 提供合规的合法 Windows 11 ARM64 获取指引 / 本地镜像与已有受管副本导入入口（绝不分发光盘镜像、绝不将空壳伪报为就绪）；
   - 导入/创建受管游玩容器后，一键自动执行 **4 步成果整合与优化注入**（实时展示分步进度与回执，支持失败重试与无损回滚）：
     1. 硬件与原生管线配置（动态安全 `GB` 内存 & `vCPU`、`VirtIO-Blk` 多队列 `iothread` + `discard=unmap`、WHQL `virtio-mouse-pci`、零 `usb-redir`、`intel-hda` 声卡、`QEMURendererFPSLimit = 120` + 三重缓冲）；
     2. 自动注入并验证 `guest-optimizer v3.1`（`zh-CN` 中文界面与微软拼音优先、暂停游戏期后台更新、动态安全页面文件、禁用 `spice-webdavd` 崩溃服务、突发稳帧与前台高优先级）；
     3. 自动校验 WHQL 图形驱动（`viogpu3d`）与持久化 `DXMT_SHADER_CACHE`；
     4. 网络与外设成果整合（随包托管零特权完整 TCP+UDP 非 `slirp` 高 QoS 代理，或在用户授权时直通原生内核 `vmnet` 守护进程）。
2. **软件内安装包拖入安装 → 自动扫描候选 → 确认登记入库闭环**：
   - 严格按 `handoff/phase-17/frontend-integration.md` 合同完成前端接线：拖入 `.exe`/`.msi` → 无桌面紧凑弹窗跑安装器 → 点击「扫描游戏入口」→ 支持关键词搜索与多候选用户消歧确认 → 后端二次核验真实 `.exe`、参数与工作目录并落盘游戏库生成统一卡片。
3. **直接在 `Malt` 软件内一键启动《无畏契约》并自动切无边框原生全屏**：
   - 升级 `GuestAppShellSession` / `kiosk-app-shell.ps1` 支持**官方启动器（Launcher）派生游戏子进程树的前台归属证明**（纯只读进程树 + 前台窗口核验，零 Hook/零注入），实现在 `Malt` 软件内点一下《无畏契约》卡片 → 紧凑无桌面弹窗登录/点开始 → 游戏主进程进入前景后**自动平滑展开无边框原生全屏 + Game Mode + 高回报率鼠标 + 防误触** → 退出游戏自动收尾。
4. **当前打包版本端到端实机复验**：
   - 将 Phase 15–18 全部成果合体打包至最新 `Malt.dmg` 并通过隔离启动与真机验证。

---

## 并行窗口与严格文件写入锁（零重叠）

| 窗口 | 难度与建议模型 | 核心职责 | 独占写入路径 |
| --- | --- | --- | --- |
| **18A** | 🟡 中等 · **`Hydrogen Medium`** | **前端全链路体验闭环**：接入安装后候选扫描/消歧登记、首次部署与一键精简优化进度向导 UI、原生网络 `starting` 1 秒有界轮询、游戏库一键启动真实阶段反馈 + `dev_restart.sh` | `Whisky/Whisky/Views/Unified/**`、`Whisky/Whisky/Views/ContentView.swift`、`Whisky/Whisky.xcodeproj/project.pbxproj`、`handoff/phase-18/evidence/p18-a/**` |
| **18B** | 🔴 高难度 · **`Neon Medium`** | **后端自动化部署与成果整合**：`ContainerProvisioningService`、Launcher 派生子进程树前台联动、零特权完整 TCP+UDP 代理随包托管、重打全合体 `Malt.dmg` + 真机端到端复验 | `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/**`、`Whisky/WhiskyKit/Tests/WhiskyKitTests/**`、`Whisky/Modules/guest-optimizer/**`、`Whisky/scripts/**`、`graphics-lab/p18_malt_app_e2e.py`、`graphics-lab/test_p18_malt_app_e2e.py`、`handoff/phase-18/evidence/p18-b/**` |

---

## 18B → 18A 跨窗口 Swift 公共接口契约（`ContainerProvisioningService`）

18B 在 `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/ContainerProvisioningService.swift` 提供以下 `public` API，18A 前端直接消费：

- `public enum ContainerProvisioningStage: String, Codable, CaseIterable, Sendable`:
  - `verifySourceContainer`（校验合法容器/受管副本）
  - `configureHardwarePipeline`（应用动态安全 RAM/vCPU、VirtIO-Blk 多队列、virtio-mouse、去 usb-redir、声卡与 120FPS 三重缓冲）
  - `applyGuestOptimization`（注入 `guest-optimizer v3.1`：中文/输入法、停后台更新、安全页文件、禁 `spice-webdavd`）
  - `verifyGraphicsAndNetwork`（核验 WHQL `viogpu3d`、`DXMT_SHADER_CACHE` 与托管网络通道）
- `public enum ProvisioningStepState: String, Codable, Equatable, Sendable`: `pending`、`running`、`succeeded`、`failed`、`skipped`
- `public struct ProvisioningStepReport: Identifiable, Codable, Equatable, Sendable`: `id: ContainerProvisioningStage`、`stage: ContainerProvisioningStage`、`state: ProvisioningStepState`、`detail: String`
- `public struct ContainerProvisioningReport: Codable, Equatable, Sendable`: `containerPath: String`、`steps: [ProvisioningStepReport]`、`allPassed: Bool`、`completedAt: Date`
- `public final class ContainerProvisioningService: ObservableObject`:
  - `@Published public private(set) var steps: [ProvisioningStepReport]`
  - `@Published public private(set) var isRunning: Bool`
  - `@Published public private(set) var lastReport: ContainerProvisioningReport?`
  - `public func provisionAndOptimize(containerPath: String, settings: UnifiedLaunchSettings) async throws -> ContainerProvisioningReport`
  - `public func rollbackOptimization(containerPath: String) async throws`
  - `public static func officialWindowsARM64GuideURL() -> URL`

> **并行协同提示**：18A 先完成 `InstalledGameRegistration` 扫描登记 UI、`NativeNetworkControls` 1 秒有界轮询与游戏库一键启动卡片打磨；待 18B 将 `ContainerProvisioningService.swift` 落盘并通过 `swift test` 后，18A 直接绑定一键部署优化进度面板并运行 `./handoff/task-07/dev_restart.sh` 完成全量编译与重启验收。

---

## 绝对不可突破的红线

1. **法律与合规红线**：绝不分发/内置任何 Windows 镜像或游戏客户端；绝不跳过后端校验伪报“就绪”或“已安装”；绝不做任何 CPUID/SMBIOS/ACPI/TPM/Hypervisor 伪装、DWM Hook、进程注入或修改游戏/ACE/Windows 驱动；涉及登录或验证码必须交由用户手动完成。
2. **零漂移与仓库纯净**：只读母盘 `golden-win11-arm64-v1`、冷备 `vm-a` 与 `/Applications/UTM.app` 原件零漂移；git 跟踪目录零 `> 5 MiB` 文件；零隐私路径泄漏；严禁执行 `git commit / push / reset`。
