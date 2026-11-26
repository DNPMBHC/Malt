# Phase 3-B 交付报告：防外挂安全加固、免责声明与单 App 产品化整合

日期：2026-11-22（Asia/Shanghai）
任务标识：Phase 3-B（`anti-cheat-abuse-hardening-and-packaging.md`）

---

## 1. 任务完成概览

| 任务模块 | 状态 | 核心交付物与验证结果 |
| --- | --- | --- |
| **B1. 防外挂安全加固与静态安全门禁** | `passed` | 1. 移除 `Whisky/Whisky/Whisky.entitlements` 中 `com.apple.security.cs.allow-unsigned-executable-memory`，确认 `Whisky`、`WhiskyCmd`、`WhiskyThumbnail` 在 Debug/Release 下均启用 `ENABLE_HARDENED_RUNTIME = YES` 且 0 危险豁免权限；<br>2. 新增 `RuntimeIntegrityReport.swift`（诚实报告宿主 SIP、代码签名、Hardened Runtime、宿主物理/虚拟化性质及单边开源物理边界说明）；<br>3. 交付 `audit_anticheat_hardening.py --self-test` 与 `hardening-audit-report.json`（扫描 99 份生产源码 + 6 项负向变异自检全部通过）。 |
| **B2. 三语免责声明与反作弊合规提示落地** | `passed` | 1. 更新 `Whisky/README.md`（中英双语项目定位、三引擎与反作弊研究架构、5 条防外挂安全红线与 4 条完整免责声明）；<br>2. 新增 `ComplianceDisclaimerView.swift` 并在 `Localizable.xcstrings` 补齐 44 项英/简中/繁中三语词条；<br>3. 接入 `ContentView` 首次启动免责声明确认弹窗、`SettingsView` 安全完整性与免责声明专区、以及 `ProgramView` 内核级反作弊/Guest 路径合规警示横幅。 |
| **B3. 单 App 产品化整合与三引擎运行时管理** | `passed` | 1. 新增 `RuntimeEnginesStatusSummary.swift` 并在 `SettingsView` 落地 `Rosetta 2` + `WhiskyWine` + `DXMT / D3DMetal / DXVK` 三引擎状态与 DX11/DX12 默认自动路由面板；<br>2. 交付 `compile_compatibility_matrix.py --self-test`，从 `handoff/module-f/evidence.json` 单源编译生成 `Whisky/Whisky/Resources/compatibility-matrix.json`（SHA-256: `0545f3c83c69d3cb3b81ef2b18f742446bf3ce2b5a45e8a084b7cfee71c3c34a`）并接入 `project.pbxproj` 打包至 `Whisky.app/Contents/Resources/compatibility-matrix.json`；<br>3. 执行 `./handoff/task-07/dev_restart.sh` 完成 Debug/arm64 重建与自动重启验证。 |

---

## 2. 验证与门禁记录

1. **Strict SwiftLint 门禁**：
   - 命令：`(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict)`
   - 结果：`Done linting! Found 0 violations, 0 serious in 113 files.`
2. **防外挂安全加固静态门禁**：
   - 命令：`python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test --output handoff/phase-3/evidence/p3-b/hardening-audit-report.json`
   - 结果：`{"negative_self_tests_passed": 6, "production_source_count": 99, "result": "passed"}`
3. **兼容规则库单源编译与 App Bundle 打包校验**：
   - 命令：`python3 handoff/phase-3/evidence/p3-b/compile_compatibility_matrix.py --self-test`
   - 结果：`{"compiled_sha256": "0545f3c83c69d3cb3b81ef2b18f742446bf3ce2b5a45e8a084b7cfee71c3c34a", "records": 7, "result": "passed", "source_snapshot_id": "2026-11-22#e554fb57615c2cd3"}`
   - App Bundle 内置资源校验：`Whisky.app/Contents/Resources/compatibility-matrix.json` 已随 Xcode 构建自动打包，与源文件 SHA-256 完全一致。
4. **SwiftPM 测试与 `dev_restart.sh` 自动重建重启**：
   - `swift test --package-path Whisky/WhiskyKit`：全量通过（0 失败）。
   - `./handoff/task-07/dev_restart.sh`：构建成功并自动停止旧实例、启动新构建的 `Whisky.app`。

---

## 3. 五维状态声明

| 维度 | 状态 | 说明 |
| --- | --- | --- |
| **代码实现** | `passed` | Hardened Runtime 加固、`RuntimeIntegrityReport`、三语免责声明、三引擎状态面板与 `compatibility-matrix.json` 单源打包全部落地 |
| **本机合成验证** | `passed` | Strict SwiftLint 113 文件 0 违规、SwiftPM 测试 0 失败、6 项防外挂负向变异自检通过、`dev_restart.sh` 重建重启通过 |
| **真实 Guest/Wine 验证** | `passed` (Wine 三引擎面板与宿主完整性检测) / `not_tested` (Windows Guest 待镜像) | 宿主机三引擎探测与诚实完整性报告已在真实 macOS 宿主运行；Windows Guest 内核探针待镜像就绪 |
| **厂商支持** | `unknown` (CN) / `not_supported` (Riot 国际 VM) / `prohibited` (THE FINALS 国际 VM) | 保持由 `module-f` 单源驱动，绝不因 UI 整合或本地诊断就绪而自动提升厂商立场 |
| **真实游戏验证** | `not_tested` | `driver_load`、`game_start`、`protected_session` 均保持 `unknown` |
