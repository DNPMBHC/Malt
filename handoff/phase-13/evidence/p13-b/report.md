# Phase 13 窗口 13B 交付报告：`UTM-Custom` 双形态无桌面应用壳与 Whisky 4 入口统一前端

- **署名**：`@DNPMBHC`
- **窗口**：Phase 13 · 13B
- **范围**：`Whisky/Modules/utm-custom/**`、`graphics-lab/test_utm_custom_patch_verify.py`、`Whisky/Whisky/Views/Unified/**`、`Whisky/Whisky/Views/ContentView.swift`、`Whisky/Whisky.xcodeproj/project.pbxproj`、`handoff/phase-13/evidence/p13-b/**`

---

## 1. 任务 13B-1：`UTM-Custom` 双形态无桌面应用壳补丁与仓库外重编

### 1.1 新增补丁 `08-seamless-app-shell-window.patch`
- **目标文件**（严格命中允许白名单，且与 01–07 补丁零重叠冲突）：
  - `Platform/macOS/AppDelegate.swift`
  - `Platform/macOS/Display/VMDisplayWindowController.swift`
  - `Platform/macOS/Display/VMDisplayQemuMetalWindowController.swift`
- **核心能力**：
  - **紧凑无桌面安装器/启动器窗口模式**：支持 `--app-shell-vm <UUID-or-path>`、`--window-title "<AppName>"`、`--window-size <WxH>`（默认 `1024x680`）与 `--app-shell-state-file <path>`（同步支持 `UTM_APP_SHELL_*` 环境变量）；启动后隐藏 UTM 管理窗与工具栏，以原生 macOS 独立窗口弹出安装器/启动器，不强制立即全屏。
  - **游戏前景自动无缝全屏与防误触**：监听 `--app-shell-state-file`（纯文本或 JSON）及分布式通知 `com.utmapp.utm.appShellStateChanged`，检测到游戏主进程进入前景后自动平滑切入无边框原生全屏、激活 macOS Game Mode（`[.fullScreen, .autoHideMenuBar, .autoHideDock]`）、自动捕获纯相对鼠标并拦截 `Cmd+W/Q/H/M` 防误触。
  - **优雅退出**：检测到退出信号或 VM 进入 `.stopped` 状态时自动关闭应用壳，全程零 UTM 管理窗曝光。
- **同步更新**：
  - 更新 `Whisky/Modules/utm-custom/ARCHITECTURE.md`（第 8 节架构说明与 10 份补丁门禁）
  - 更新 `Whisky/Modules/utm-custom/scripts/build_custom_utm.sh`（接入补丁 08，8 UTM + 2 CocoaSpice 共 10 份补丁）
  - 更新 `graphics-lab/test_utm_custom_patch_verify.py`（断言 `patch_count >= 10` 与补丁 08 目标范围）

### 1.2 仓库外编译与实证结果
- 产物路径：`<TMPDIR>/utm-custom-build/UTM-Custom.app`（严格位于仓库外，`/Applications/UTM.app` 零修改）
- 架构：`Mach-O 64-bit executable arm64`（Release）
- 签名：`codesign --verify --deep --strict` 通过（`codesign_deep_verify_ok = true`）
- Game Mode `Info.plist`：`LSApplicationCategoryType = public.app-category.games`、`LSSupportsGameMode = true`、`GCSupportsGameMode = true`
- 补丁合规审计与特征符号：10 份补丁 standalone + stacked `git apply --check` 全绿，19/19 特征符号全部命中（详见 `patch-audit.json` 与 `build-verification.json`）。

---

## 2. 任务 13B-2：Whisky 4 入口极简统一前端与首次 3 步引导

直接消费窗口 13A 在 `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/` 落盘的公共契约（`UnifiedGameEntry`、`HardwareAutoTuner`、`UnifiedGameLibraryStore`、`UnifiedRuntimeOrchestrator`），新增并集成以下模块：

1. `Whisky/Whisky/Views/Unified/UnifiedSidebarSection.swift`：极简 4 入口导航与统一 `@AppStorage` 性能/引导偏好模型。
2. `Whisky/Whisky/Views/Unified/UnifiedGameLibraryView.swift`：**游戏库（默认首页）**，统一混排原生 Wine 与反作弊安全沙盒游戏卡片，提供引擎筛选、搜索、醒目「开始游戏」一键直达与右键快捷菜单（切换性能档、访达显示、移除）。
3. `Whisky/Whisky/Views/Unified/UnifiedInstallerView.swift`：**一键安装**，支持拖放或选取 `.exe`/`.msi` 安装包，自动调用 `classifyInstaller` 推荐普通/反作弊引擎（可手动切换），安装完成后自动入库。
4. `Whisky/Whisky/Views/Unified/UnifiedPerformanceView.swift`：**性能与智能适配**，展示 Apple Silicon 本机硬件画像、一键「自动性能测试并优化」（调用 `HardwareAutoTuner` 实时测速并一键套用）、三档傻瓜模式（竞技高帧 / 平衡推荐 / 原生画质）、游戏模式/鼠标合批/防误触核心开关及默认折叠的「高级选项」。
5. `Whisky/Whisky/Views/Unified/UnifiedRuntimeStorageView.swift`：**环境与存储**，统一展示 Wine 与反作弊运行底座健康状态灯、外置 SSD 目录、着色器缓存占用与一键清理重置、重新触发首次引导，并在底部折叠保留传统 Bottle 高级管理入口（100% 向后兼容）。
6. `Whisky/Whisky/Views/Unified/FirstRunOnboardingView.swift`：**首次启动 3 步零门槛引导向导**（硬件体检与外置盘推荐 → 一键确认运行底座 → 15 秒自动校准套用配置）。
7. `Whisky/Whisky/Views/ContentView.swift` 与 `Whisky/Whisky.xcodeproj/project.pbxproj`：完成 4 入口 `NavigationSplitView` 整合与工程文件注册。

### 2.1 自动重编与重启实证
- 已执行 `./handoff/task-07/dev_restart.sh` 完成增量编译、启动并验证主 App 存活（详见 `app-restart-verification.json`）。

---

## 3. 全量验收门禁汇总

| 验收项 | 状态 | 备注 |
| --- | --- | --- |
| `bash Whisky/Modules/utm-custom/scripts/build_custom_utm.sh --check-only` | ✅ PASS | 8 UTM + 2 CocoaSpice 补丁 standalone + stacked 0 冲突 |
| `bash Whisky/Modules/utm-custom/scripts/build_custom_utm.sh --build` | ✅ PASS | 仓库外 `arm64 Release` 编译 + `codesign --verify --deep --strict` + 19/19 特征符号 |
| `./handoff/task-07/dev_restart.sh` | ✅ PASS | 主 App 编译、重启与启动存活验证通过 |
| `swift test --package-path Whisky/WhiskyKit` | ✅ PASS | 265 tests, 0 failures |
| `swiftlint lint --strict --quiet` | ✅ PASS | 0 violations |
| `python3 handoff/task-07/format_check.py` | ✅ PASS | 格式与隐私路径检查通过 |
| `(cd graphics-lab && python3 -B -m unittest discover -v)` | ✅ PASS | 全部单测通过 |
| `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` | ✅ PASS | 6 negative self-tests, 142 production sources |
| `> 5 MiB` 新增文件 / 隐私路径 / 越界写入 / git 操作检查 | ✅ PASS | 严格合规 |
