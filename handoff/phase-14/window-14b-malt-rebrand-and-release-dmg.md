# Phase 14 窗口 14B 任务书：`Malt` 品牌全面统一与 Hardened Runtime `Malt.dmg` 正式打包

- **窗口角色**：Phase 14 窗口 14B
- **难度评级**：🟡 中等（建议模型：**`Hydrogen Medium`**）
- **署名**：`@DNPMBHC`
- **产品品牌**：**`Malt`**（面向用户的一切界面文案、首次引导、App Display Name 与最终 `.dmg` 统一为 `Malt`；底层 Swift Package 名称 `WhiskyKit` 及既有 Bundle ID 前缀保持向后兼容以遵循 KISS 原则，不破坏现有 265 项单测与既有配置迁移）。

---

## 1. 任务目标

### 任务 14B-1：`Malt` 品牌前端与元数据统一
在 `Whisky/Whisky/Views/Unified/**`、`Whisky/Whisky/Views/ContentView.swift` 与 `Whisky/Whisky.xcodeproj/project.pbxproj`（仅更新面向用户的显示名/标题，不破坏既有模块导入）：
1. **统一全部面向用户的界面文案为 `Malt`**：
   - 修复 `FirstRunOnboardingView.swift` 中的 `欢迎使用 Whisky 统一游戏中心` → `欢迎使用 Malt`（以及引导步骤中面向用户的产品名称统一为 `Malt`）；
   - 统一主窗口标题、侧边栏标题、关于/版本描述与空状态提示为 **`Malt`**；
   - 确保面向用户的界面文案专业克制，使用「原生转译模式」「硬件加速容器模式」等中性正式表述（与新版 `README.md` 风格保持 100% 一致）。
2. **设置 App 显示名为 `Malt`**：
   - 在 `Info.plist` / `project.pbxproj` 中将 `CFBundleDisplayName`（`INFOPLIST_KEY_CFBundleDisplayName`）设为 `Malt`，使 macOS 访达、程序坞、菜单栏与启动台统一显示为 **`Malt`**。

### 任务 14B-2：Hardened Runtime Release `Malt.app` & `Malt.dmg` 正式打包与验签
1. 新增轻量可复现打包脚本 `Whisky/scripts/package_malt_dmg.sh`（严格把最终 `.dmg` 产出到仓库外或 `Whisky/build/release/Malt.dmg`，严禁提交 `> 5 MiB` 二进制进 git）：
   - 以 `Release` + `arm64` 编译主 App（启用 **Hardened Runtime** + 严格校验无违规调试 entitlement，符合防外挂安全加固门禁）；
   - 自动核查已打包的 `KosmicKrisp` / `runtime-manifest.json` / 资源完整性，严禁把 `WhiskyKit` 源码或 `.build` 缓存打进 App；
   - 封装成带 `/Applications` 快捷拖放链接的压缩只读 **`Malt.dmg`**（目标体积 `< 20 MiB`），输出 SHA-256、体积、`codesign --verify --deep --strict` 与 `codesign -dv --entitlements` 实证。
2. 落地打包校验报告 `handoff/phase-14/evidence/p14-b/malt-release-dmg-manifest.json`。

### 任务 14B-3：自动重编重启验证与全量质量门禁
1. 执行 `./handoff/task-07/dev_restart.sh` 验证新版 `Malt` 主 App 编译、启动与进程存活，记录 `handoff/phase-14/evidence/p14-b/app-restart-verification.json`；
2. 跑通全量门禁并落盘 `handoff/phase-14/evidence/p14-b/report.md`。

---

## 2. 独占写入范围（严禁越界）

- 允许写入：
  - `Whisky/Whisky/Views/Unified/**`
  - `Whisky/Whisky/Views/ContentView.swift`
  - `Whisky/Whisky.xcodeproj/project.pbxproj`
  - `Whisky/scripts/package_malt_dmg.sh`
  - `handoff/phase-14/evidence/p14-b/**`
- 严禁触碰：`Whisky/WhiskyKit/`、`Whisky/Modules/utm-custom/`、`Whisky/Modules/guest-optimizer/`、`graphics-lab/`、窗口 14A 独占路径、`/Applications/UTM.app` 原件、只读母盘与冷备 `vm-a`。

---

## 3. 验收门禁与交付物

1. `Whisky/scripts/package_malt_dmg.sh`
2. `handoff/phase-14/evidence/p14-b/malt-release-dmg-manifest.json`
3. `handoff/phase-14/evidence/p14-b/app-restart-verification.json`
4. `handoff/phase-14/evidence/p14-b/report.md`
5. 必须全绿：
   - `./handoff/task-07/dev_restart.sh`
   - `swift test --package-path Whisky/WhiskyKit`
   - `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)`（0 violations）
   - `python3 handoff/task-07/format_check.py`
   - `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test`
   - 零 `> 5 MiB` 文件落入 git 跟踪路径、零隐私路径泄漏、零 git 操作。
