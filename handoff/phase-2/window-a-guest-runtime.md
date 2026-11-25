# 窗口 A 任务书：真实 Windows Guest 后端与环境打通（P0 · 第一优先冲刺主线）

对应原模块：`task-02 / module-b`
战略位置：**Phase 2 第一优先冲刺主线（与窗口 B 协同，最高资源优先级）**
请先阅读：`handoff/phase-2/README.md`、`handoff/runtime-interface.md`、`handoff/task-02.md`、`handoff/task-07/report.md`

---

## 1. 当前基线与核心问题

- **已有代码**：`UTMWindowsGuestProvider`、`UTMGuestSession`、`WindowsGuestTransport`、`UTMGuestStoragePreflight`、`WindowsGuestProbeService` 及完整 Mock 单元测试已实现，6 份文件通过严格 `swift-format`。
- **核心阻塞**：本机目前未安装 UTM / Parallels，也没有已配置的 Windows Guest，真实执行状态为 `environment_not_verified`（0 次真实运行）。
- **本窗口核心使命**：**彻底解除 `environment_not_verified`**，完成真实 Windows Guest 的落地对接与端到端全生命周期实测，为窗口 B（内核探针）和窗口 C（Guest 图形对比）提供可复用的真实 Windows 执行环境。

---

## 2. 独占可写路径（严禁越界修改）

- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/UTMWindowsGuestProvider.swift`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/UTMGuestSession.swift`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/WindowsGuestTransport.swift`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/UTMGuestStoragePreflight.swift`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/WindowsGuestProbeService.swift`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/UTMWindowsGuestProviderTests.swift`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/UTMGuestStoragePreflightTests.swift`
- `handoff/phase-2/evidence/window-a/`（新建，存放本窗口证据、配置模板与接口变更提案）

> 若发现需要修改 `RuntimeGuestConfiguration` 或 `RuntimeCoordinator`，严禁直接改动窗口 D 的文件，请写入 `handoff/phase-2/evidence/window-a/interface-proposal.md`。

---

## 3. 分阶段实施任务

### 阶段 A1：宿主环境体检与真实 Guest 落地指南（立即启动）
1. 核查当前 macOS 宿主虚拟化能力、UTM / `utmctl` 安装状态、外接候选卷挂载及读写权限。
2. 审阅现有 `UTMWindowsGuestProvider` 对 `utmctl`、QEMU Guest Agent、共享目录路径映射的真实命令契约，排查 Mock 与真实 UTM 行为可能存在的不一致（例如 `utmctl status` / `utmctl exec` / 退出码格式 / 路径转义 / 超时处理）。
3. 若本机尚未就绪 Windows 11 ARM64 Guest，输出**最小化、可一步步执行的安装与配置手册**及符合 `RuntimeGuestConfiguration` 的脱敏 JSON 模板（挂载外接候选卷中的测试目录，不污染系统盘），引导用户完成环境搭建。**镜像最低版本强制锁定为 Windows 11 24H2 或更新版本的官方 ARM64 镜像**（确保内置支持 AVX/AVX2 的新版 Prism x64 转译引擎，避免现代竞技游戏因缺指令集闪退）。
4. **防空转红线**：在真实 Guest 未就绪前，只允许修复与真实 `utmctl` 契约不符的明确代码问题，禁止为了凑进度继续新增纯 Mock 测试。

### 阶段 A2：真实 Windows Guest 端到端验证（Guest 就绪后执行）
1. 连接本机已配置的真实 Windows Guest，依次验证并取证：
   - 配置校验与 Guest 架构识别（明确记录 `host_cpu_architecture`、`guest_cpu_architecture`、`guest_os_build`、`guest_os_edition`）。
   - 启动/已运行附着、Guest Agent 就绪握手。
   - 存储预检升级：宿主共享目录映射在 Guest 内实际验证待执行文件可见，状态从 `configured` 真实达到 **`verified`**。
   - 执行普通无害 Windows 测试程序（含带空格/引号参数、自定义环境变量、预期 0 与非 0 退出码），验证真实退出码与输出回传。
   - 验证运行中 `cancel()`、重复 `cancel()`（无副作用）、正常停止、以及异常中断/超时后的会话回收。
2. 采集基础设施基线：记录 Guest 冷/热启动耗时、空载与执行测试程序时的宿主内存占用、CPU 占用及共享目录文件读写延迟。
3. 验证 `WindowsGuestProbeService` 能在真实 Guest 中调用命令并取回 JSON 报告，为窗口 B 交接可用入口。

---

## 4. 开发期验证与自动重启要求

- 每次修改 `UTM*.swift` 或 `WindowsGuest*.swift` 后：
  1. 运行 SwiftPM 定向测试与全量测试：`swift test --package-path Whisky`。
  2. 运行格式门禁：`python3 handoff/task-07/format_check.py`。
  3. 若通过 `WhiskyCmd` 实测真实 Guest，必须重新构建目标二进制并在测试前清理/重启残留的旧 `utmctl`/测试会话，避免旧状态干扰。

---

## 5. 验收标准与交付物

1. `handoff/phase-2/evidence/window-a/guest-setup-guide.md`：最小化真实 Guest 配置手册与脱敏 JSON 模板。
2. `handoff/phase-2/evidence/window-a/e2e-verification.json` 与 `summary.md`：
   - 必须包含本次测试对应的源码/产物摘要、真实 Guest 系统与架构元数据、`verified` 文件映射证据、真实退出码/取消/超时实测结果与宿主资源基线。
3. 严禁因 Guest 握手和普通程序通过，就把任何商业反作弊游戏标为受支持。
