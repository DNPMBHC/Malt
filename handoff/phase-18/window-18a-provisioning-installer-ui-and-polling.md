# Phase 18 窗口 18A 任务书：前端全链路体验闭环（拖入安装扫描入库 + 首次部署精简优化向导 + 一键启动《无畏契约》体验）

- **窗口角色**：Phase 18 窗口 18A
- **难度评级**：🟡 中等（建议模型：**`Hydrogen Medium`**）
- **署名**：`@DNPMBHC`
- **必读前置**：
  - `handoff/phase-18/README.md`
  - `handoff/phase-17/frontend-integration.md`（必须逐条严格遵守所有诚实状态与交互合同）

---

## 1. 任务目标

### 任务 18A-1：完成「拖入安装包 → 无桌面弹窗安装 → 扫描游戏入口 → 确认登记入库」前端闭环
在 `Whisky/Whisky/Views/Unified/UnifiedInstallerView.swift` 与 `UnifiedGameLibraryView.swift` 中完整接入 Phase 17 后端接口：
1. **拖入安装与诚实状态分离**：
   - 支持直接拖放或选取 `.exe` / `.msi` 安装包；
   - 启动安装器后明确展示状态为「安装器已启动（等待你在弹窗中完成安装）」，**严禁将 `.installerRequested` 提前标为“已完成”**；
2. **安装后「扫描游戏入口」与用户消歧确认**：
   - 在安装器阶段卡片及游戏库待登记条目上提供醒目的 **「扫描游戏入口」** 按钮与可编辑搜索关键词输入框（默认预填软件名，如 `VALORANT` / `无畏契约`）；
   - 调用 `orchestrator.discoverInstalledGameCandidates(for: entry, query: keyword)`：
     - **多候选结果**：以清晰列表展示每个候选的名称、可执行文件与启动参数摘要，**必须由用户点选并点击「确认登记」**（严禁自动替用户默认选第一个），调用 `orchestrator.registerInstalledGame(entry, candidate: selected)` 完成二次核验并落盘；
     - **空结果 / 容器未登录**：展示友好原因指引，提供「重新扫描」「修改关键词」与「手动填写/选择路径」退路；
     - 严禁通过直接修改模型绕过 `registerInstalledGame` 核验，严禁在错误弹窗或上报中泄露完整本地用户名路径。

### 任务 18A-2：首次初始化容器部署引导 + 一键精简优化注入进度向导 UI
在 `Whisky/Whisky/Views/Unified/FirstRunOnboardingView.swift` 与 `UnifiedRuntimeStorageView.swift` 中消费 18B 提供的 `ContainerProvisioningService`：
1. **合规初始化部署引导（绝不把“组件已打包”误标为“Windows 系统已就绪”）**：
   - 明确拆分为两项独立状态灯：**「Malt 内嵌引擎组件」**（随包就绪）与 **「Windows 11 ARM64 受管工作容器」**（需用户导入合法容器/受管副本或按微软官方指引创建）；
   - 提供快捷操作：「导入已有受管容器（`.utm`）」、「从本地合法 Windows 镜像创建指南（附微软官方 ARM64 获取链接）」；
2. **一键精简优化与成果注入面板**：
   - 选中/导入工作容器后，提供醒目按钮 **「一键应用性能精简与优化注入」**，调用 `ContainerProvisioningService.provisionAndOptimize(...)`；
   - 实时展示 4 步进度条与逐项回执（`硬件与多队列管线配置` → `中文/免更新/突发稳帧精简优化` → `WHQL 图形驱动与着色器缓存核验` → `低延迟网络通道核验`），并保留「一键回滚优化」按钮。

### 任务 18A-3：原生网络 `starting` 态 1 秒有界轮询 + 游戏库一键直达体验打磨
1. **原生网络状态自动刷新**（`Whisky/Whisky/Views/Unified/NativeNetworkControls.swift`）：
   - 当原生 `vmnet` 服务处于 `starting` / 等待就绪态时，启动**每秒一次的有界轮询任务**，离开等待状态或视图销毁（`.onDisappear` / `Task` 取消）时立即停止；
   - 超过 15 秒诊断期限时自动展示可操作的超时诊断与重试/回落说明；严禁将 socket 存在伪报为“游戏已联网”。
2. **游戏库卡片一键直达优化**（`UnifiedGameLibraryView.swift`）：
   - 针对已登记的容器游戏（如《无畏契约》）和普通 Wine 游戏，提供大按钮 **「开始游戏」** 与清晰的运行阶段提示（准备受管网络 → 启动无桌面应用壳 → 启动器运行中 → 游戏全屏运行中），让用户直接在 `Malt` 软件内一步到位开玩。
3. **自动重编重启验收**：
   - 运行 `./handoff/task-07/dev_restart.sh` 编译并重启验证新版 `Malt` 主 App 存活，落盘 `handoff/phase-18/evidence/p18-a/{app-restart-verification.json,report.md}`。

---

## 2. 独占写入范围（严禁越界）

- 允许写入：
  - `Whisky/Whisky/Views/Unified/**`
  - `Whisky/Whisky/Views/ContentView.swift`
  - `Whisky/Whisky.xcodeproj/project.pbxproj`
  - `handoff/phase-18/evidence/p18-a/**`
- 严禁触碰：`Whisky/WhiskyKit/`（归 18B）、`Whisky/Modules/`（归 18B）、`Whisky/scripts/`（归 18B）、`graphics-lab/`（归 18B）、`handoff/task-07/`、`/Applications/UTM.app` 原件、只读母盘与冷备 `vm-a`。

---

## 3. 验收门禁

1. `./handoff/task-07/dev_restart.sh` 通过（编译、签名、重启存活验证）；
2. `swift test --package-path Whisky/WhiskyKit` 全绿；
3. `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)` **0 violations**；
4. `python3 handoff/task-07/format_check.py` 全绿；
5. `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` 全绿；
6. 零 `> 5 MiB` 新增跟踪文件、零隐私路径泄漏、零 git 操作。
