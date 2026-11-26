# 窗口 C → 窗口 D 接口接线提案：`HostResourcePolicy` 接入真实启动层

日期：2026-11-22  
提出方：窗口 C（`module-c` / `module-d`）  
接收方：窗口 D（统筹 `Whisky/`、`WhiskyCmd/`、`Wine.swift`、`RuntimeCoordinator.swift` 与 `BottleSettings.swift`）  
状态：提案已就绪，窗口 C 侧模型与单元测试已通过编译、Strict SwiftLint 与 XCTest。

---

## 1. 提案背景与红线约束

Phase 1 中 `HostResourcePolicy.swift` 仅接入了独立诊断 `OperationQueue`，没有真实执行消费者。  
窗口 C 已在不触碰窗口 D 独占文件的前提下，于 `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/HostResourcePolicy.swift` 落地了三组无侵入、可回退、严格绑定真实下游消费者的策略输出模型：

1. `HostWineLaunchPolicy`（面向 Wine 启动层 `Wine.swift`）
2. `HostMetalHostPolicy`（已由 `graphics-lab/metal_host.swift` 真实消费并完成受控 A/B 实测）
3. `HostGuestLaunchPolicy`（面向 Windows Guest 启动与宿主机卸载呈现层）

**严格遵守的工程红线**：
- 绝不输出无真实下游消费者的空环境变量；每一条 `HostResourceConsumerBinding` 都显式声明 `consumer` 与 `documentationReference`。
- `applyingNonDestructively(to:)` 严禁覆盖用户或 Bottle 手动设置的同名环境变量。
- 所有策略均具备显式 `enabled: Bool` 回退开关；关闭后 100% 回归原始基线（`.userInitiated`、空环境变量覆盖、不限帧）。
- 对于 D3DMetal（无公开文档化帧率/热节流环境变量），明确保持 `environmentOverrides == []` 并输出 `unmanagedDomainNote`，不编造未文档化变量。

---

## 2. 新增公共 API 摘要（已位于窗口 C 独占文件）

文件：`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/HostResourcePolicy.swift`

```swift
public enum HostWineGraphicsBackend: String, Codable, Sendable {
    case dxvk
    case d3dMetal
}

public struct HostResourceConsumerBinding: Equatable, Codable, Sendable {
    public let name: String
    public let value: String
    public let consumer: String
    public let documentationReference: String
}

public struct HostWineLaunchPolicy: Equatable, Sendable {
    public let isEnabled: Bool
    public let performancePolicy: RuntimePerformancePolicy
    public let graphicsBackend: HostWineGraphicsBackend
    public let processQualityOfService: QualityOfService
    public let environmentOverrides: [HostResourceConsumerBinding]
    public let unmanagedDomainNote: String?

    public init(
        snapshot: RuntimeHostSnapshot,
        graphicsBackend: HostWineGraphicsBackend,
        enabled: Bool = true
    )

    public var environmentDictionary: [String: String]
    public func applyingNonDestructively(to existing: [String: String]) -> [String: String]
}

public struct HostMetalHostPolicy: Equatable, Codable, Sendable {
    public let isEnabled: Bool
    public let performancePolicy: RuntimePerformancePolicy
    public let targetFrameRateCap: Int?
    public let allowsMetalFXSpatial: Bool
    public let receiverQueueQoS: String
    public var cliArguments: [String]
}

public struct HostGuestLaunchPolicy: Equatable, Codable, Sendable {
    public let isEnabled: Bool
    public let performancePolicy: RuntimePerformancePolicy
    public let pausesHostOptionalBackgroundWork: Bool
    public let suggestedPresentationFrameRateCap: Int?
    public let note: String
}
```

### 下游消费者映射表

| 宿主策略 (`RuntimePerformancePolicy`) | 触发条件 | Wine `Process.qualityOfService` | DXVK 环境变量（真实消费者：DXVK `d3d11.dll`/`dxgi.dll`） | D3DMetal 环境变量 |
| --- | --- | --- | --- | --- |
| `.maximumPerformance` | `nominal` / `fair` 且非低电量 | `.userInitiated` | 无（不干扰峰值性能） | 无 |
| `.balanced` | `thermalState == .serious` | `.utility` | `DXVK_FRAME_RATE=60`、`DXVK_NUM_COMPILER_THREADS=2` | 无（交由呈现端或系统热管理） |
| `.conserveEnergy` | 低电量或 `thermalState == .critical` | `.utility` | `DXVK_FRAME_RATE=30`、`DXVK_NUM_COMPILER_THREADS=1` | 无（交由呈现端或系统热管理） |
| 回退开关关闭 (`enabled: false`) | 用户/配置显式禁用 | `.userInitiated` | 无 | 无 |

---

## 3. 建议窗口 D 实施的最小化接线点

### 3.1 `BottleSettings.swift`（配置回退开关）
- 在 `BottleWineConfig`（或 `BottleInfo`）增加可选持久化字段 `adaptiveResourcePolicyEnabled: Bool = false`（默认关闭，向后兼容旧 Bottle plist 解码，支持 UI/CLI 一键回退）。

### 3.2 `Wine.swift`（真实消费 `HostWineLaunchPolicy`）
- 在 `startProgramInWine(_ request: RuntimeLaunchRequest)` 与 `runProcess(...)` 中：
  1. 根据 `bottle.settings.dxvk` 映射为 `HostWineGraphicsBackend`（`true -> .dxvk`，`false -> .d3dMetal`）。
  2. 通过 `HostCapabilityProvider.current()` 构造 `HostWineLaunchPolicy(snapshot:graphicsBackend:enabled: bottle.settings.adaptiveResourcePolicyEnabled)`。
  3. 仅在启用时应用：
     - `process.qualityOfService = winePolicy.processQualityOfService`
     - `let finalEnv = winePolicy.applyingNonDestructively(to: constructWineEnvironment(for: bottle, environment: request.environment))`
- `generateTerminalEnvironmentCommand(bottle:)` 也可同步反映启用的 `environmentOverrides`，确保终端调试与 GUI 启动一致。

### 3.3 `RuntimeCoordinator.swift` 与 GUI / CLI
- `RuntimeCoordinator` 可在启动诊断结果中透出当前生效的 `HostWineLaunchPolicy` / `HostGuestLaunchPolicy`（包括 `unmanagedDomainNote`），便于用户与验收报告分辨“策略是否生效、作用于哪个执行域”。
- GUI（Bottle Settings 视图）新增一个显式开关（默认关闭）：“启用宿主热/低电量自适应资源策略”，并在提示文案中说明对 DXVK 与 D3DMetal 的真实作用边界，不夸大效果。

---

## 4. 验收与回归要求

窗口 D 合入接线后建议补充以下集成测试：
1. 默认配置（开关关闭）下，`Wine.startProgramInWine` 与 `constructWineEnvironment` 输出与 Phase 1 完全一致。
2. 开关开启 + `.dxvk` + 低电量/热压力快照下，环境变量包含 `DXVK_FRAME_RATE` 与 `DXVK_NUM_COMPILER_THREADS`，且不覆盖调用方显式传入的同名变量。
3. 开关开启 + `.d3dMetal` 下，不注入任何未文档化环境变量，仅按策略设置 `Process.qualityOfService`。

---

## 5. 增量升级提案（v2）：引入开源 DXMT + 三引擎按 DX 版本自动路由

> 说明：第 1–4 节基础接线已由窗口 D 合入并通过门禁；本节为总控新增的三引擎（DXMT / D3DMetal / DXVK）增量升级提案，窗口 C 侧模型与单元测试已落地且对现有调用方 100% 向后兼容。

### 5.1 实测支撑结论（1280×720，120 预热 + 900 测量，3 轮冷/热，总计 18 组 / 16,200 测量帧）
完整同口径清单见 `handoff/phase-2/evidence/window-c/wine-dxmt-three-engine/manifest.json`：

| 引擎（热态 3 轮均值） | Feature Level | 平均 FPS | 帧间隔 P50 / P95 (ms) | Probe 初始化 (ms) | DXGI 显存 (MiB) | GPU 时间戳覆盖 | 定位 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| **DXMT v0.80** | `11_1` | 344.96（冷 366.98） | **1.983** / 8.317 | **395.90** | **19.91** | 92.5% | **DX11 性能与低显存优先** |
| **D3DMetal (GPTK 4.0-1)** | `11_1` / `12` | **353.63**（冷 309.55） | 2.574 / 7.199 | 574.37 | 67.34 | 0%（不支持） | **DX12 唯一主力 / DX11 第一降级** |
| **DXVK 1.10.3 + MoltenVK 1.2.1** | `11_0` | 335.31（冷 324.12） | 2.704 / **6.928** | 538.02 | 223.72 | 100% | **DX11/10/9 兼容兜底** |

### 5.2 新增公共 API 摘要（窗口 C 独占文件，已通过 SwiftPM 与 Strict SwiftLint）

1. **`HostResourcePolicy.swift` 增量扩展**：
   - `HostWineGraphicsBackend` 增量新增 `case dxmt`（遵循 `CaseIterable`，零破坏现有 `.dxvk` / `.d3dMetal` 调用）。
   - `HostWineLaunchPolicy` 新增 `.dxmt` 真实下游消费者参数映射（已通过 `dxmt-v0.80` `d3d11.dll` / `dxgi.dll` / `winemetal.so` 二进制实证，零虚构空变量）：

| 宿主策略 (`RuntimePerformancePolicy`) | Wine `Process.qualityOfService` | DXMT 环境变量（真实消费者：`DXMT d3d11.dll / dxgi.dll / winemetal.so`） |
| --- | --- | --- |
| `.maximumPerformance` | `.userInitiated` | 无（不干预峰值性能与用户默认设置） |
| `.balanced`（热压力 `.serious`） | `.utility` | `DXMT_CONFIG="d3d11.preferredMaxFrameRate=60"`、`DXMT_METALFX_SPATIAL_SWAPCHAIN="0"` |
| `.conserveEnergy`（低电量或 `.critical`） | `.utility` | `DXMT_CONFIG="d3d11.preferredMaxFrameRate=30"`、`DXMT_METALFX_SPATIAL_SWAPCHAIN="0"` |
| 回退开关关闭 (`enabled: false`) | `.userInitiated` | 无 |

2. **`HostWineBackendRouter.swift`（新建，窗口 C 独占路径）**：
   ```swift
   public enum HostDirectXAPIRequirement: String, Codable, CaseIterable, Sendable {
       case directX12, directX11, directX10OrEarlier, unknown
   }
   public enum HostGraphicsRoutingPreference: String, Codable, CaseIterable, Sendable {
       case performanceFirst, compatibilityFallback
   }
   public struct HostAvailableWineBackends: Equatable, Codable, Sendable {
       public let hasD3DMetal: Bool
       public let hasDXMT: Bool
       public let hasDXVK: Bool
   }
   public struct HostWineBackendRoute: Equatable, Codable, Sendable {
       public let apiRequirement: HostDirectXAPIRequirement
       public let preference: HostGraphicsRoutingPreference
       public let selectedBackend: HostWineGraphicsBackend?
       public let fallbackChain: [HostWineGraphicsBackend]
       public let usedFallback: Bool
       public let reason: String
   }
   public enum HostWineBackendRouter {
       public static func route(
           apiRequirement: HostDirectXAPIRequirement,
           preference: HostGraphicsRoutingPreference = .performanceFirst,
           available: HostAvailableWineBackends = .all
       ) -> HostWineBackendRoute
   }
   ```

   **确定性路由与降级表**：
   - `DX12` → `[.d3dMetal]`（缺失 D3DMetal 时返回 `selectedBackend = nil` 并给出明确原因，严禁误路由到不支持 DX12 的 DXMT/DXVK）。
   - `DX11`（`performanceFirst`）→ `[.dxmt, .d3dMetal, .dxvk]`。
   - `DX11`（`compatibilityFallback`）→ `[.dxvk, .dxmt, .d3dMetal]`。
   - `DX10 及更早` → `performanceFirst: [.dxmt, .dxvk, .d3dMetal]`；`compatibilityFallback: [.dxvk, .dxmt, .d3dMetal]`。
   - `unknown` → `performanceFirst: [.d3dMetal, .dxmt, .dxvk]`；`compatibilityFallback: [.dxvk, .d3dMetal, .dxmt]`。

### 5.3 建议窗口 D 实施的增量接线点
1. **`BottleSettings.swift`**：
   - 将原二元布尔 `dxvk: Bool` 升级为可选三态/自动路由枚举（如 `wineGraphicsBackendMode: auto | dxmt | d3dMetal | dxvk`），保留对旧 plist `dxvk` 字段的向后兼容解码；
   - 在 `environmentVariables(wineEnv:)` 中按实际路由结果传入 `HostWineGraphicsBackend`（含 `.dxmt`）构造 `HostWineLaunchPolicy`。
2. **`Wine.swift` / `WhiskyWineInstaller.swift`**：
   - 探测宿主机实际安装的 `DXMT` / `D3DMetal` / `DXVK` 组件状态构建 `HostAvailableWineBackends`，调用 `HostWineBackendRouter.route(...)`；
   - 当路由至 `.dxmt` 时，配置 `WINEDLLPATH` 指向 DXMT `wine` 目录并将 `d3d11.dll`/`dxgi.dll`/`d3d10core.dll`/`winemetal.dll` 同步至 Bottle `system32`，同时隔离 `DXMT_SHADER_CACHE=1` 与 Bottle 级 `DXMT_SHADER_CACHE_PATH`。
3. **`RuntimeModels.swift` / `RuntimeBackends.swift` / GUI**：
   - 新增重载 `wineResourcePolicy(backend: HostWineGraphicsBackend, enabled: Bool)`（保留旧 `wineResourcePolicy(dxvk:enabled:)` 重载以兼容既有测试）；
   - 在 GUI Bottle 设置页与运行诊断输出中展示 `HostWineBackendRoute.selectedBackend`、`usedFallback` 与 `reason`。
   - 窗口 D 合入 Swift 改动后，请使用其开发期自动构建重启脚本重新构建并重启 `Whisky.app` / `WhiskyCmd` 验证。

