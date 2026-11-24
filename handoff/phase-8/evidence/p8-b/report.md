# Phase 8 窗口 8B 最终验收报告：接入 8A 实证只读诊断与单 `.app` 同步收口

日期：2026-11-24  
署名：`@DNPMBHC`  
状态：**Phase 8 窗口 8B 全部任务（含 8A `interface-proposal.md` 最终只读收口）全绿验收通过。**

---

## 1. 窗口 8A `interface-proposal.md` 最小化只读接入（严守文件锁）

1. **状态码精准收敛**（`Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/GoldenGuestManifestSummary.swift`）：
   - 将 `CompatibilityTargetSummary` 对 `target-cn` 的诊断状态更新为窗口 8A 实测结论：
     - `visualStage`: `entered_character_creation_ui_then_froze`
     - `rootCauseCode`: `neptune_umd_wddm2_render_thread_deadlock`
     - `mitigationStatus`: `host_and_utm_tuning_exhausted_awaiting_upstream_whql_viogpu3d_fix`
     - `protectedLobbyAndMatch`: `not_verified`
     - `vendorVMSupport`: `unknown`
2. **三语只读说明更新**（`Whisky/Whisky/Localizable.xcstrings`、`Whisky/WhiskyCmd/StoragePreflight.swift`、`Whisky/Whisky/Views/Settings/SettingsView.swift`）：
   - 当检测到 `viogpu3d == 100.6.101.58000` 时，三语只读提示明确说明：合成 D3D11（123.6 FPS, 0 LSB）与原生 ARM64 ACE 核心加载已验证，但当前 `neptune_umd` 在 `target-cn` 创角/主界面存在已知 WDDM2 死锁，需等待上游新版 WHQL 驱动后升级至 `golden-win11-arm64-v2` 复测。
   - 严格保持纯只读诊断展示，未新增任何写入型或绕过反作弊接口。
3. **单元测试扩展**（`Whisky/WhiskyKit/Tests/WhiskyKitTests/RuntimeGoldenGuestManifestTests.swift`）：
   - 新增 `testCompatibilitySummaryReflectsPhase8AFindings` 验证上述状态码与提示键，全套 6 项测试通过。

---

## 2. 全套门禁与 Release 打包验收结果

| 验证项 | 命令 | 结果 |
| --- | --- | --- |
| SwiftPM 全量单测 | `swift test --package-path Whisky/WhiskyKit` | **258 项（248 通过 / 10 显式跳过 / 0 失败）** |
| Strict SwiftLint | `swiftlint lint --strict --quiet` | **0 违规** |
| 格式门禁 | `python3 handoff/task-07/format_check.py` | **6/6 通过** |
| 防外挂静态审计 | `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` | **132 源码 + 6 反例通过** |
| 兼容矩阵自检 | `python3 handoff/phase-3/evidence/p3-b/compile_compatibility_matrix.py --self-test` | **7 条记录通过** |
| 自动重建重启闭环 | `./handoff/task-07/dev_restart.sh` | **通过**（PID 612） |
| Release + Hardened Runtime 打包 | `./handoff/task-07/package_release_dmg.sh` | **通过**（`.dmg` 13,736,524 字节，SHA-256 `e2f6f1f5890ed018681b306c36a5119e33f354d01875a415b13be7bf9af6d0f6`，仓库外输出） |
| Release CLI 一体化自检 | `WhiskyCmd baseline-report --summary` | **通过**（完整输出 8A 诊断状态与三语只读提示） |

严格遵守文件写入锁，未触碰 `Whisky/Modules/`、`graphics-lab/`、窗口 8A 独占路径或任何 VM，未执行 `git commit / push / reset`。
