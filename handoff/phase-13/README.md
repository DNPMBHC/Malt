# Phase 13 总览：统一双引擎底层架构、突发大特效稳帧、双形态无桌面应用壳与 Whisky 极简前端整合

- 署名：`@DNPMBHC`
- 产品品牌定名：**`Malt`**（自本阶段起，所有面向用户的界面标题、引导向导与窗口文案统一使用新品牌名 **`Malt`**；底层 Swift Package / 模块标识符 `WhiskyKit` 保持向后兼容，Phase 14 打包时统一产出 `Malt.app` / `Malt.dmg`）。
- 产品目标：将普通 Wine 游戏转译与反作弊安全沙盒（`UTM-Custom` + 持久化游玩 VM）彻底整合进 **Malt 统一 macOS 原生界面**，实现：
  1. **首次启动 3 步零门槛自动适配**（硬件体检 + 外置盘推荐 + 自动微基准校准，消除手工配置）；
  2. **软件内统一游戏卡片一键直达**（底层冷启动精简 + 可选热待机秒开，不区分酒瓶与虚拟机）；
  3. **反作弊软件安装与运行全程不见 Windows 桌面**（Kiosk 无桌面会话 + `UTM-Custom --app-shell-vm` 紧凑弹窗 → 进游戏自动展开无边框原生全屏与 macOS Game Mode）；
  4. **突发大特效 / 瞬间高数据量爆发流畅度保障**（4× Draw-Call + 大缓冲/PSO 爆发专项基准与队列/优先级优化）。

---

## 并行窗口与严格文件写入锁

| 窗口 | 难度与建议模型 | 核心职责 | 独占写入路径 |
| --- | --- | --- | --- |
| **13A** | 🔴 高难度 · **`Neon Medium`** | `WhiskyKit` 统一编排层 + `HardwareAutoTuner` + **突发大特效稳帧基准与优化** + 冷启动精简/热待机引擎 + 无桌面 Kiosk 会话脚本 | `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/**`、`Whisky/WhiskyKit/Tests/WhiskyKitTests/UnifiedOrchestrationTests.swift`、`Whisky/Modules/guest-optimizer/**`、`graphics-lab/golden_guest_manager.py`、`graphics-lab/test_golden_guest_manager.py`、`graphics-lab/p13_burst_perf_benchmark.py`、`graphics-lab/test_p13_burst_perf_benchmark.py`、`handoff/phase-13/evidence/p13-a/**` |
| **13B** | 🔴 高难度 · **`Neon Medium`** | `UTM-Custom` 双形态无桌面应用壳补丁（`08-seamless-app-shell-window.patch`）与仓库外重编 + **Whisky 4 入口统一前端（游戏库 / 一键安装 / 自动测速 / 首次 3 步引导）** + `dev_restart.sh` 自动重编重启验证 | `Whisky/Modules/utm-custom/**`、`graphics-lab/utm_custom_patch_verify.py`、`graphics-lab/test_utm_custom_patch_verify.py`、`Whisky/Whisky/Views/Unified/**`、`Whisky/Whisky/Views/ContentView.swift`、`Whisky/Whisky.xcodeproj/project.pbxproj`、`handoff/phase-13/evidence/p13-b/**` |

---

## 13A ↔ 13B 跨窗口 Swift 接口契约（`WhiskyKit/Orchestration`）

为保证两窗口零冲突协同，13A 在 `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/` 中提供以下 `public` API，13B 前端直接消费：

- `public enum UnifiedEngineKind: String, Codable, CaseIterable, Sendable`：`nativeWine`、`antiCheatVM`
- `public enum PerformancePresetTier: String, Codable, CaseIterable, Sendable`：`competitiveHighFPS`（竞技高帧）、`balancedRecommended`（平衡推荐）、`nativeQuality`（原生画质）
- `public struct UnifiedGameEntry: Identifiable, Codable, Hashable, Sendable`：`id: UUID`、`name: String`、`executablePath: String`、`engineKind: UnifiedEngineKind`、`presetTier: PerformancePresetTier`、`iconPath: String?`、`lastPlayedAt: Date?`、`bottleURL: URL?`、`vmBundlePath: String?`
- `public struct HardwareProfileSnapshot: Codable, Equatable, Sendable`：`chipName: String`、`totalCores: Int`、`performanceCores: Int`、`efficiencyCores: Int`、`physicalMemoryGiB: Int`、`displayRefreshRateHz: Int`、`recommendedStoragePath: String`
- `public struct AutoTuneRecommendation: Codable, Equatable, Sendable`：`hardware: HardwareProfileSnapshot`、`recommendedTier: PerformancePresetTier`、`recommendedVCPU: Int`、`recommendedRAMMiB: Int`、`recommendedResolution: String`、`enableGameMode: Bool`、`mouseCoalesceMicros: Int`、`blockAccidentalShortcuts: Bool`、`benchmarkScore: Double`、`durationSeconds: Double`
- `public final class HardwareAutoTuner`: `detectHardwareProfile() -> HardwareProfileSnapshot`、`runQuickBenchmarkAndRecommend() async -> AutoTuneRecommendation`
- `public final class UnifiedGameLibraryStore: ObservableObject`: `@Published public var entries: [UnifiedGameEntry]`、`load()`、`upsert(_:)`、`remove(id:)`、`classifyInstaller(url: URL) -> UnifiedEngineKind`
- `public final class UnifiedRuntimeOrchestrator: ObservableObject`: `launch(entry: UnifiedGameEntry) async throws`、`install(installerURL: URL, engineKind: UnifiedEngineKind, title: String) async throws -> UnifiedGameEntry`、`healthStatus() -> [String: Bool]`

> **并行顺序建议**：13B 先完成 `UTM-Custom` 补丁 `08` 与仓库外编译验证；待 13A 将 `WhiskyKit/Orchestration/` 落盘并通过 `swift test` 后，13B 立即接入前端并运行 `./handoff/task-07/dev_restart.sh` 完成主 App 自动重建重启验证。

---

## 绝对不可突破的红线

1. **反作弊与安全红线**：严禁 Hook Windows DWM、严禁进程注入、严禁 CPUID/SMBIOS/ACPI/TPM/Hypervisor 伪装、严禁修改游戏/ACE/Windows 驱动、严禁自动化登录或过验证码。
2. **零漂移与仓库纯净**：只读母盘 `golden-win11-arm64-v1`、冷备 `vm-a` 与 `/Applications/UTM.app` 原件必须零漂移；外部 UTM 源码/构建产物严禁入库；零 `> 5 MiB` 新增文件；零隐私路径泄漏；严禁执行 `git commit / push / reset`。
