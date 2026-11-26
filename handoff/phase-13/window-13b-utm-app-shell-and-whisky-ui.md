# Phase 13 窗口 13B 任务书：`UTM-Custom` 双形态无桌面应用壳与 Whisky 统一极简前端整合

- **窗口角色**：Phase 13 窗口 13B
- **难度评级**：🔴 高难度（建议模型：**`Neon Medium`**）
- **署名**：`@DNPMBHC`
- **前置协同**：本窗口与 13A 并行。请**先完成任务 13B-1（`UTM-Custom` 补丁 08 与仓库外编译验证）**，随后直接消费 13A 在 `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/` 落盘的公共契约完成任务 13B-2（Whisky 前端整合与 `dev_restart.sh` 自动重建重启验证）。

---

## 1. 任务目标

### 任务 13B-1：`UTM-Custom` 双形态无桌面应用壳补丁（`08-seamless-app-shell-window.patch`）
在 `Whisky/Modules/utm-custom/` 新增补丁并同步更新 `ARCHITECTURE.md`、`scripts/build_custom_utm.sh` 与 `graphics-lab/utm_custom_patch_verify.py`（及单测）：
1. **紧凑无桌面安装器/启动器窗口模式（`--app-shell-vm <UUID-or-path>`）**：
   - 新增命令行参数：`--app-shell-vm <UUID-or-path>`、`--window-title "<AppName>"`、`--window-size <WxH>`（如 `1024x680` / `1280x720`）；
   - 启动时隐藏 UTM 主管理窗、隐藏显示窗口工具栏（保留功能对象仅隐藏 UI）、窗口标题直接显示 `--window-title`、尺寸自动对齐 `--window-size` 并居中显示在 macOS 桌面，**不强行立即全屏**，让安装器或游戏启动器像原生 macOS 独立窗口一样弹出；
2. **游戏主进程启动后无缝自动切全屏**：
   - 支持通过宿主机通知信号/状态文件（例如 `--app-shell-state-file <path>` 或标准分布式通知）感知 Guest 内游戏主进程进入前景 → 自动平滑执行 `toggleFullScreen(nil)`、自动激活 macOS Game Mode、自动捕获纯相对鼠标并启用 `Cmd+W/Q/H/M` 防误触屏蔽；
   - 游戏退出/VM 停止时自动优雅关闭应用壳退出，全程零 UTM 管理窗曝光。
3. **仓库外重编 `UTM-Custom.app`**：
   - 运行 `build_custom_utm.sh` 在仓库外重编 `arm64 Release` `UTM-Custom.app`，通过 `codesign --verify --deep --strict`、10 份补丁全栈合规校验与新补丁特征符号校验，落盘 `handoff/phase-13/evidence/p13-b/build-verification.json` 与 `patch-audit.json`。

### 任务 13B-2：Malt 主 App 统一极简前端整合（把 Wine 与 UTM 彻底融为一体）
在 `Whisky/Whisky/Views/Unified/` 与 `Whisky/Whisky/Views/ContentView.swift`（及 `Whisky.xcodeproj/project.pbxproj`）实现 macOS 原生 SwiftUI 统一前端（面向用户的界面品牌文案统一使用 **`Malt`**，简洁、克制、符合 macOS HIG，严格遵守 SwiftLint 0 violations）：
1. **极简 4 入口左侧边栏**：
   - **游戏库（Library，默认首页）**：统一游戏卡片网格（普通 Wine 游戏 + 反作弊安全沙盒游戏混排），每张卡片展示图标、名称、引擎微标（`原生转译` / `反作弊安全模式`）与醒目的 **`开始游戏`** 一键直达按钮（支持右键/菜单快速切换性能档、打开位置、移除）；
   - **一键安装（Install）**：支持拖拽或选择 `.exe` / `.msi` 安装包，自动调用 `UnifiedGameLibraryStore.classifyInstaller` 推荐引擎模式（可一键切换普通/反作弊模式），点击开始安装直接弹出对应安装器（反作弊软件通过 `UTM-Custom --app-shell-vm` 无桌面弹窗安装），装完自动加入游戏库；
   - **性能与智能适配（Performance & Auto-Tune）**：展示本机硬件画像卡片、一键 **`自动性能测试并优化`** 按钮（调用 `HardwareAutoTuner` 显示实时进度与推荐结果并一键套用）、三档傻瓜模式（`竞技高帧` / `平衡推荐` / `原生画质`）以及核心开关（macOS 游戏模式、高回报率鼠标合批、防误触屏蔽 `Cmd+W/Q`）；复杂底层参数默认折叠至“高级选项”；
   - **环境与存储（Runtimes & Storage）**：统一展示 Wine 运行时与反作弊运行底座健康状态灯、外置 SSD 路径、着色器缓存占用与一键清理/重置入口（保留原有 Bottle 高级管理入口折叠在底部，确保向后兼容不破坏老功能）。
2. **首次启动「3 步零门槛引导向导（`FirstRunOnboardingView.swift`）」**：
   - Step 1：自动硬件体检 + 外置高速存储目录推荐；
   - Step 2：一键确认初始化运行底座状态；
   - Step 3：15 秒自动性能校准并自动套用最优配置 → 进入游戏库（支持在设置中重新触发引导）。
3. **自动重建并重启验证（强制要求）**：
   - 完成前端修改后必须执行 `./handoff/task-07/dev_restart.sh` 完成主 App 编译、签名、重启与主窗口存活验证，并将编译/重启实证记录写入 `handoff/phase-13/evidence/p13-b/app-restart-verification.json`。

---

## 2. 独占写入范围（严禁越界）

- 允许写入：
  - `Whisky/Modules/utm-custom/**`
  - `graphics-lab/utm_custom_patch_verify.py`
  - `graphics-lab/test_utm_custom_patch_verify.py`
  - `Whisky/Whisky/Views/Unified/**`
  - `Whisky/Whisky/Views/ContentView.swift`
  - `Whisky/Whisky.xcodeproj/project.pbxproj`
  - `handoff/phase-13/evidence/p13-b/**`
- 严禁触碰：`Whisky/WhiskyKit/`（归 13A）、`Whisky/Modules/guest-optimizer/`（归 13A）、`graphics-lab/golden_guest_manager.py`（归 13A）、`handoff/task-07/`、`/Applications/UTM.app` 原件、只读母盘与冷备 `vm-a`。

---

## 3. 验收门禁与交付物

1. `handoff/phase-13/evidence/p13-b/patch-audit.json` & `build-verification.json`
2. `handoff/phase-13/evidence/p13-b/app-restart-verification.json`
3. `handoff/phase-13/evidence/p13-b/report.md`
4. 必须全绿：
   - `bash Whisky/Modules/utm-custom/scripts/build_custom_utm.sh --check-only`
   - `./handoff/task-07/dev_restart.sh`（自动编译并重启主 App 成功）
   - `swift test --package-path Whisky/WhiskyKit`
   - `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)`（0 violations）
   - `python3 handoff/task-07/format_check.py`
   - `(cd graphics-lab && python3 -B -m unittest discover -v)`
   - `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test`
   - 零 `> 5 MiB` 新增文件、零隐私路径泄漏、零 git 操作。
