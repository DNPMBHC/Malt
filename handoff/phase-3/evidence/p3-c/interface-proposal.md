# Phase 3-C → 总控接口接线提案：`RemotePhysicsBackend` 接入统一调度器

日期：2026-11-22  
提出方：Phase 3-C（`RemotePhysicsBackend`）  
接收方：总控 / 共享核心接口维护方（`RuntimeModels.swift`、`RuntimeBackends.swift`、`RuntimeCoordinator.swift`、`Whisky/`、`WhiskyCmd/`、`handoff/runtime-interface.md`）  
状态：Phase 3-C 侧模型、Provider 实现与 10 项单元测试已落地并通过 SwiftPM 与 Strict SwiftLint（0 违规）。

---

## 1. 提案背景与安全红线

- **第一性原理定位**：面向锁死物理 TPM 2.0 / 明确禁止 Hypervisor 的强硬件信任根反作弊（如国际服 Riot Vanguard `VAN 9100`、高严格模式 EAC v2、高防 DMA 策略下 ACE），本地 VM 在合法合规前提下无法绕过物理信任根。`RemotePhysicsBackend` 作为第三类合规兜底后端，调度用户自有的局域网物理 Windows 主机或合规物理云主机（通过开源 `Moonlight.app` CLI 或受控外部客户端），让游戏与反作弊运行在 100% 真实的物理 Windows 硬件上。
- **执行域隔离**：固定标记为 `RemotePhysicsExecutionDomain.remotePhysicalWindows`（`remote_physical_windows`），**严禁**与 `wine` 或 `windows_guest` 混淆，不得将远程物理机可运行误报为本地 Wine/VM 已适配。
- **零明文凭据与防外挂红线**：
  - `RemotePhysicsConfiguration` 禁止任何明文密码/PIN/Token/私钥字段（自定义 `Decodable` 与 `validate()` 双重拦截）；
  - 严禁 shell 解释器/脚本引擎作为外部客户端，参数仅以 `Process.arguments` 数组传递；
  - 不提供任何截帧导出钩子、画面识别、合成键鼠宏回注或硬件伪装能力。

---

## 2. 已落地的公共 API（位于 Phase 3-C 独占文件）

- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/RemotePhysicsModels.swift`
  - `RemotePhysicsExecutionDomain`（`.remotePhysicalWindows`）
  - `RemotePhysicsTransportKind`（`.moonlightClient` / `.externalClient`）
  - `RemotePhysicsResolution`、`RemotePhysicsStreamPreferences`
  - `RemotePhysicsStreamPolicy`（消费 `RuntimeHostSnapshot.performancePolicy`：热压力 `.serious` 限 60 FPS / 70% 码率 / `.utility` QoS；低电量或 `.critical` 限 30 FPS / 45% 码率 / `.utility` QoS；支持 `adaptiveResourcePolicyEnabled = false` 完全回退；提供 `moonlightStreamArguments(host:applicationName:)`）
  - `RemotePhysicsConfiguration`（含双重零明文凭据防线与 `validate()`）
  - `RemotePhysicsAvailability`（`.unconfigured` / `.clientMissing(String)` / `.hostUnreachable(String)` / `.ready`）
  - `RemotePhysicsError`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/RemotePhysicsBackend.swift`
  - `RemotePhysicsProvider` 协议（`executionDomain`、`configuration`、`checkAvailability()`、`resolveStreamPolicy(host:)`、`start(host:)`）
  - `UnconfiguredRemotePhysicsProvider`
  - `ExternalClientRemotePhysicsProvider`（支持 `Moonlight.app` 默认路径探测与受控外部客户端、基于 `Network.framework` 的非阻塞 TCP 探针、`Process.startRuntimeSession()` 生命周期管理、超时/取消/重复取消幂等）
  - `RemotePhysicsBackend` 外观类型

---

## 3. 建议总控合入的共享层接线点

### 3.1 `RuntimeModels.swift`
1. `RuntimeBackendKind` 新增 `case remotePhysics`：
   - `title`: `"Remote physical Windows"`
   - `localizationKey`: `"runtime.backend.remotePhysics"`
   - **向后兼容**：检查全部 `switch`（`RuntimeCoordinator`、`RuntimeBackends`、UI 视图），确保原有 `.wine` / `.windowsGuest` 解码与默认逻辑不变。
2. `GameCompatibilityProfile`（可选增量）：新增可选字段 `remotePhysicsCompatibility: RuntimeCompatibility? = nil`（默认 `nil`，解旧 JSON 100% 兼容；对物理 Windows 原生支持的商业游戏可显式声明 `.supported` 或由调度器按执行域说明提示用户自行确认发行商云/串流条款）。

### 3.2 `RuntimeBackends.swift`
1. `RuntimeIssue` 新增：
   - `remotePhysicsUnconfigured`
   - `remotePhysicsClientMissing`
   - `remotePhysicsHostUnreachable`
   - `remotePhysicsTimeout`
2. 补齐三语本地化键（`Whisky/Whisky/Localizable.xcstrings`）：`runtime.backend.remotePhysics` 及上述 4 个 `runtime.issue.remotePhysics*`。
3. 如需让 `RemotePhysicsBackend` 直接遵循 `RuntimeBackend` 协议，可在共享层为其补齐 `kind: .remotePhysics` 与 `capability(for:host:)` 适配桥接（注意同步调用 `capability` 时缓存最新异步 `checkAvailability()` 状态，避免在主线程阻塞网络 I/O）。

### 3.3 `RuntimeCoordinator.swift`
1. `RuntimeCoordinator` 构造器增加可选参数 `remotePhysicsProvider: any RemotePhysicsProvider = UnconfiguredRemotePhysicsProvider()`（保留默认参数确保所有旧调用与测试零改动通过）。
2. `plan(...)` 兜底提示策略：
   - 当用户显式传入 `backend: .remotePhysics` 时，进入 `remotePhysics` 分支；
   - 当 `backend == nil` 且目标游戏在本地 Wine（`requiresWindowsKernel`）与本地 Windows Guest（`vendorRestricted` 或未确认厂商 VM 支持）均被阻塞时：**不静默自动切走**（若未配置），而在规划建议/UI 提示中推荐合规兜底路径 `.remotePhysics`（若用户已配置且 `availability == .ready` 可由用户一键选择或显式启用）。
3. `validate(_:)` 注意事项：当目标后端为 `.remotePhysics` 时，**不要求本地存在 `.exe` 文件**（远程物理机上的游戏位于物理 Windows 端，通过 `RemotePhysicsConfiguration.applicationName` 标识），只需校验 `RemotePhysicsConfiguration.validate()` 即可。
4. `start(_:)` 在 `case .remotePhysics` 下直接委托 `try await remotePhysics.start(host: request.host)`，并继续通过 `RuntimeCoordinator.launch` 统一处理取消、退出码与终止信号。

### 3.4 配置存储与 UI / CLI（`Whisky/`、`WhiskyCmd/`）
1. **配置存储**：在应用级配置或 Bottle 设置中保存 `RemotePhysicsConfiguration`（仅存非敏感字段，严禁保存明文密码/PIN/Token；由 `RemotePhysicsConfiguration` 解码器自动守卫）。
2. **UI / CLI 展示**：明确标注执行域为「远程物理 Windows 主机（`remote_physical_windows`）」，并展示热状态/低电量下的当前生效帧率与码率（如 `1080p · 60 FPS · 14 Mbps`）及回退开关。
3. **开发期自动重启验收要求**：总控合入上述改动到 `Whisky.app` / `WhiskyCmd` 后，必须执行开发期自动重建重启脚本（构建 → 终止旧进程 → 自动重启新产物）后再进行界面与 CLI 端到端验证。
