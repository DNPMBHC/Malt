# Phase 14 窗口 14B 验收报告：`Malt` 品牌全面统一与 Hardened Runtime `Malt.dmg` 正式打包

- **署名**：`@DNPMBHC`
- **日期**：2026-11-25
- **状态**：✅ 全部任务与门禁通过

---

## 1. 交付物清单

1. **前端品牌与工程显示名统一**：
   - `Whisky/Whisky/Views/ContentView.swift`：侧边栏分组统一为 `Section("Malt")`，主窗口添加 `.navigationTitle("Malt")`。
   - `Whisky/Whisky/Views/Unified/FirstRunOnboardingView.swift`：欢迎标题更新为 `欢迎使用 Malt`，运行时底座与按钮文案统一使用 `Malt` 与中性正式模式表述「原生转译模式 / 硬件加速容器模式」。
   - `Whisky/Whisky/Views/Unified/UnifiedGameLibraryView.swift`、`UnifiedInstallerView.swift`、`UnifiedRuntimeStorageView.swift`、`UnifiedSidebarSection.swift`：全面统一 `Malt` 品牌文案、空状态提示与「原生转译模式 / 硬件加速容器模式」中性表述；底层 `WhiskyKit` / `WhiskyApp` / `WhiskyWineInstaller` 内部接口保持向后兼容。
   - `Whisky/Whisky.xcodeproj/project.pbxproj`：在主 App Target 的 `Debug` 与 `Release` 配置中添加 `INFOPLIST_KEY_CFBundleDisplayName = Malt;`，并更新 `NSAppleEventsUsageDescription` 与 `NSHumanReadableCopyright`。
2. **可复现 Release 打包脚本与产物**：
   - 脚本：`Whisky/scripts/package_malt_dmg.sh`
   - 打包清单：[malt-release-dmg-manifest.json](./malt-release-dmg-manifest.json)
   - 产物：`Whisky/build/release/Malt.dmg`（已位于 `.gitignore` 忽略目录，未纳入 git）：
     - 体积：`14,237,715` bytes（`13.578 MiB` `< 20 MiB`）
     - SHA-256：`39c0d3d25d5678c11b659bb32e99c1eacef1b40c1861040afe270155fbf583c8`
     - Hardened Runtime：`true`（`app` 与 `cli` `runtimeFlagVerified: true`）
     - `codesign --verify --deep --strict`：`passed`（由内而外重签 `Sparkle.framework`、`WhiskyThumbnail.appex`、`WhiskyCmd` 与 `Malt.app`）
     - Entitlements：`automation.apple-events`、`device.audio-input`、`device.camera`，违规调试权限 `forbiddenEntitlementsFound: []`
     - Bundle 纯净度：`bundlePurityPassed: true`（无 `WhiskyKit` 源码或 `.build` 缓存）
     - Vulkan 后端：`KosmicKrisp` 校验通过（`x86_64SliceVerified: true`、`universalLoaderVerified: true`、`relativeICDPathVerified: true`）
3. **自动重编重启验证**：
   - [app-restart-verification.json](./app-restart-verification.json)
   - `./handoff/task-07/dev_restart.sh` 编译并重启新版主 App 成功，存活进程 `PID: 5611`，`CFBundleDisplayName = Malt`。

---

## 2. 自动化门禁实测结果

| 检查项 | 命令 | 结果 |
| --- | --- | --- |
| Release 打包与验签 | `./Whisky/scripts/package_malt_dmg.sh --manifest-output handoff/phase-14/evidence/p14-b/malt-release-dmg-manifest.json` | ✅ 通过（`13.578 MiB`，`deep --strict` 通过） |
| 开发态重编重启 | `./handoff/task-07/dev_restart.sh` | ✅ 通过（`PID: 5611` 存活） |
| WhiskyKit 单元测试 | `swift test --package-path Whisky/WhiskyKit` | ✅ 通过（265 tests executed, 10 skipped, 0 failures） |
| Strict SwiftLint | `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)` | ✅ 通过（0 violations） |
| Swift 格式检查 | `python3 handoff/task-07/format_check.py` | ✅ 通过（`formatPassed: true`） |
| 防外挂安全加固审计 | `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` | ✅ 通过（6/6 负向自测通过，142 源码文件合规） |
| 仓库纯净与红线检查 | 无 `> 5 MiB` 新增跟踪文件、零隐私路径泄漏、零 git 操作 | ✅ 通过 |
