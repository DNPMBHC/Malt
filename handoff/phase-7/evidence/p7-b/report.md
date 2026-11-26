# Phase 7 窗口 7B 最终验收报告：宿主机诊断一体化集成、7A 提案收口与发行级单 `.app` 同步

日期：2026-11-24  
署名：`@DNPMBHC`  
状态：**全部任务（7B-1、7B-2、7B-3）全绿验收通过。**

---

## 1. 任务执行摘要（严格遵守文件写入锁）

### 任务 7B-1 & 7B-2：`WhiskyCmd` 与设置页一体化诊断升级及窗口 7A `interface-proposal.md` 最小化接入
1. **真实 6A 黄金母盘清单解析**（`Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/GoldenGuestBaselineManifest.swift`、`GoldenGuestManifestSummary.swift`）：
   - 适配窗口 6A 真实产出的 `handoff/phase-6/evidence/p6-a/golden-guest-manifest.json` 嵌套 Schema（兼容整数 `schema_version: 1` 及嵌套 `graphics_driver`、`qemu_profile`、`security_invariants`、`optimizer`、`fingerprints`）。
2. **接入窗口 7A `interface-proposal.md` 只读诊断字段（零越权、纯只读）**：
   - 在 `CompatibilityTargetSummary` 新增并精准更新对 `target-cn` 的只读诊断状态：
     - `visualStage`: `entered_game_ui_freeze_on_resize`
     - `rootCauseCode`: `neptune_umd_swapchain_resize_deadlock`
     - `dxvkVenusStatus`: `probe_passed_0lsb_launcher_purges_dropin_dll`
     - `aceArm64Coverage`: `partial_core_arm64_running_ace_game_x64_blocked_1275`
     - `vendorVMSupport`: `unknown`
   - 当检测到黄金母盘 `viogpu3d == 100.6.101.58000` 时，自动在 `UnifiedRuntimeBaselineReport.advisoryLocalizationKeys`、`WhiskyCmd baseline-report --summary` 与 `SettingsView.swift`（`SettingsRuntimeManifestSection`）展示两条三语只读提示（关闭 `DynamicResolution` + 固定 `1280×720` 窗口化避免 SwapChain Resize 冻结；勿尝试替换系统签名 DLL）。
3. **三语本地化与单元测试**：
   - 在 `Whisky/Whisky/Localizable.xcstrings` 补齐英/简中/繁中三语翻译；
   - 在 `Whisky/WhiskyKit/Tests/WhiskyKitTests/RuntimeGoldenGuestManifestTests.swift` 扩展验证 5 个新状态字段与 `viogpu3d == 100.6.101.58000` 只读提示触发与非触发逻辑，5/5 通过。

### 任务 7B-3：统一集成版 Release + Hardened Runtime `.app` → `.dmg` 重打包与全门禁复核
1. **Release 打包**：
   - 运行 `./handoff/task-07/package_release_dmg.sh --output-dir "${TMPDIR:-/tmp}/my-project-release-p7b" --manifest-output handoff/phase-7/evidence/p7-b/release-package-manifest.json`；
   - 产物全部位于仓库外临时目录，`.dmg` 大小 `13736438` 字节（13.10 MiB），SHA-256 `cd65653bed517c21e5deb39e3f40c64b92d858227907f8494ab8f9517a325575`；
   - `hardenedRuntimeVerification.passed = true`、`bundlePurityPassed = true`、`requiredResourcesVerified = true`、`vulkanBackend.bundled = true`（`geometryShader = true`、`fillModeNonSolid = true`）。
2. **自动重建重启闭环**：
   - 运行 `./handoff/task-07/dev_restart.sh`，Debug/arm64 构建成功，新实例启动存活验证通过。
3. **Release CLI 实测**：
   - 运行打包后的 `WhiskyCmd baseline-report --summary`，确认 `Golden Guest State: ready`、`target-a` 7A 诊断字段、两条三语只读提示与 `<EXTERNAL_VOLUME>` 空间核对均正常输出。

---

## 2. 全套门禁验收结果

| 验证项 | 命令 | 结果 |
| --- | --- | --- |
| SwiftPM 全量单测 | `swift test --package-path Whisky/WhiskyKit` | **257 项（247 通过 / 10 显式跳过 / 0 失败）** |
| Strict SwiftLint | `swiftlint lint --strict --quiet` | **0 违规** |
| 格式门禁 | `python3 handoff/task-07/format_check.py` | **6/6 通过** |
| 防外挂静态审计 | `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` | **132 源码 + 6 反例通过** |
| 兼容矩阵自检 | `python3 handoff/phase-3/evidence/p3-b/compile_compatibility_matrix.py --self-test` | **7 条记录通过** |
| 自动重建重启闭环 | `./handoff/task-07/dev_restart.sh` | **通过** |
| Release + Hardened Runtime 打包 | `./handoff/task-07/package_release_dmg.sh` | **通过**（`release-package-manifest.json` 落盘） |
| Release CLI 一体化自检 | `WhiskyCmd baseline-report --summary` | **通过**（含 7A 诊断字段与 2 条只读提示） |

严格遵守文件写入锁，未触碰独占路径之外的任何文件，未操作任何 VM，未执行 `git commit / push / reset`。
