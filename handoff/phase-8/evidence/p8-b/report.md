# Phase 8 窗口 8B 验收报告：宿主机诊断同步、静态显示引导与单 `.app` 同步

日期：2026-11-24  
署名：`@DNPMBHC`  
状态：**宿主机侧全部任务与门禁全绿通过；窗口 8A `handoff/phase-8/evidence/p8-a/interface-proposal.md` 尚未交付，已同步静态显示/指针引导并保持诚实 `pending_8a_verification` 状态。**

---

## 1. 任务执行摘要（严格遵守文件写入锁）

1. **静态显示与指针只读引导同步**：
   - 在 `Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/GoldenGuestManifestSummary.swift` 的 `CompatibilityTargetSummary` 新增 `recommendedDisplayMode`（`1280x720_windowed_static_no_dynamic_resolution`）、`pointerGuidanceCode`（`utm_check_usb_tablet_or_capture_cursor_on_window_mode`）与 `phase8VerificationStatus`（`pending_8a_verification`）；
   - 在 `UnifiedRuntimeBaselineReport.advisoryLocalizationKeys` 新增第 3 条指针模式排查提示键 `settings.goldenGuest.advisory.pointerModeCheck`；
   - 同步更新 `Whisky/WhiskyCmd/StoragePreflight.swift`（`baseline-report --summary`）、`Whisky/Whisky/Views/Settings/SettingsView.swift`、`Whisky/Whisky/Localizable.xcstrings`（英/简中/繁中三语）与 `Whisky/WhiskyKit/Tests/WhiskyKitTests/RuntimeGoldenGuestManifestTests.swift`。
2. **窗口 8A 提案状态核查**：
   - 实查 `handoff/phase-8/evidence/p8-a/interface-proposal.md` 尚未生成，未虚构任何大厅/训练场 FPS 或 `ACE-GAME.sys` 新结果；待 8A 交付提案后可按最小增量直接同步。

---

## 2. 全套门禁与 Release 打包验收结果

| 验证项 | 命令 | 结果 |
| --- | --- | --- |
| SwiftPM 全量单测 | `swift test --package-path Whisky/WhiskyKit` | **257 项（247 通过 / 10 显式跳过 / 0 失败）** |
| Strict SwiftLint | `swiftlint lint --strict --quiet` | **0 违规** |
| 格式门禁 | `python3 handoff/task-07/format_check.py` | **6/6 通过** |
| 防外挂静态审计 | `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` | **132 源码 + 6 反例通过** |
| 兼容矩阵自检 | `python3 handoff/phase-3/evidence/p3-b/compile_compatibility_matrix.py --self-test` | **7 条记录通过** |
| 自动重建重启闭环 | `./handoff/task-07/dev_restart.sh` | **通过**（PID 97889） |
| Release + Hardened Runtime 打包 | `./handoff/task-07/package_release_dmg.sh` | **通过**（`.dmg` 13,735,889 字节，SHA-256 `d42a6ebaf7f963e2c284fa4e3ef03096e83dd54dfa23e2aee1fc6461c04a8109`，仓库外输出） |
| Release CLI 一体化自检 | `WhiskyCmd baseline-report --summary` | **通过**（`Golden Guest State: ready`、`Phase 8 Status: pending_8a_verification`、3 条三语只读提示） |

严格遵守文件写入锁，未触碰 `Whisky/Modules/`、`graphics-lab/`、窗口 8A 独占路径或任何 VM，未执行 `git commit / push / reset`。
