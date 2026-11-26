# Phase 15 窗口 15B 任务书：`Malt` 单应用无感内嵌后端、极简防呆前端重构与 3 项一键打通实战修复

- **窗口角色**：Phase 15 窗口 15B
- **难度评级**：🔴 高难度（建议模型：**`Neon Medium`**）
- **署名**：`@DNPMBHC`
- **产品铁律依据**：`handoff/phase-15/ARCHITECTURE-MULTITHREAD-GPU-PIPELINE.md` 第四节（用户 2026-11-25 拍板）

---

## 1. 任务目标

### 任务 15B-1：彻底修通 `UnifiedRuntimeOrchestrator` 3 项一键打通实战 Bug（`WhiskyKit/Orchestration/`）
在 `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/`（及 `UnifiedOrchestrationTests.swift`）中根治此前代码体检发现的 3 个断路问题：
1. **【P0】普通 Wine 游戏启动与安装走原生三引擎路由**：
   - 删除 `UnifiedRuntimeOrchestrator.swift` 中硬编码的 `/usr/bin/env wine64`；
   - 改为复用 `WhiskyKit` 既有 `WhiskyWineInstaller` 路径与 `BottleGraphicsRouting`（完整注入 `DXMT` / `D3DMetal` / `DXVK` / `MoltenVK` / `KosmicKrisp` / `WINEDLLPATH`），确保用户点击卡片或拖入普通安装包真正享受到全套图形转译路由。
2. **【P0】容器后端内嵌自发现（告别外置 UTM 依赖与相对路径硬编码）**：
   - 消除 `graphics-lab/golden_guest_manager.py` 与 `kiosk-app-shell.ps1` 的相对路径硬编码；
   - 实现多级自动发现：`Malt.app/Contents/Helpers/` 内嵌运行时 → `Malt.app/Contents/Resources/RuntimeScripts/` 内嵌辅助脚本 → 外部开发目录兜底；并自动扫描外置高速 SSD 卷上已建好的持久化游玩实例（无需用户手填路径）。
3. **【P1】无桌面安装器端到端透传 + 非阻塞磁盘测速**：
   - `installViaAntiCheatVM` 完整透传 `--app-shell-vm`、`--window-title`、`--window-size`、`--app-shell-state-file` 并将用户选中的安装包 `.exe` 路径透传给 Guest `kiosk-app-shell.ps1` 自动弹出无桌面安装器；
   - 将 `HardwareAutoTuner.runDiskIOBenchmark` 迁入 `Task.detached(priority: .utility)`，彻底消除测速末段卡顿 UI 动画。

### 任务 15B-2：按用户铁律重构 `Malt` 极简防呆前端与单应用无感交互
修改 `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/HardwareAutoTuner.swift`、`UnifiedGameEntry.swift` 与 `Whisky/Whisky/Views/Unified/**`、`ContentView.swift`：
1. **三档直观性能预设收敛**：
   - 统一收敛为 **`最高性能`**（`maxPerformance`）、**`平衡`（默认推荐，`balanced`）**、**`低配置兼容`**（`lowSpecCompatible`，面向 8 GB 或轻薄本），保持旧 JSON 键反序列化向后兼容；
2. **硬件自检 + 安全可调范围约束 + 点选 `GB` 内存**：
   - `HardwareAutoTuner` 新增 `safeMemoryOptionsGiB(for hardware:)` 与 `safeVCPUOptions(for hardware:)`，根据本机总内存动态生成合法档位（如 16 GB Mac 仅提供 **`6 GB` / `8 GB` / `10 GB` / `12 GB`** 按钮并高亮推荐档 `10 GB`；24 GB 提供 `8 / 12 / 16 GB`；32+ GB 提供 `8 / 12 / 16 / 20 GB`）；
   - 前端内存设置**彻底改为点选 `GB` 卡片/分段控件，禁止手输 MiB 数字**；
3. **默认静默优化 + 高级选项折叠**：
   - **高回报率鼠标无损合批（默认 1500us）**、**macOS 游戏模式**、**全屏防误触（屏蔽 `Cmd+W/Q/H/M`）**、**键位映射**与**持久化缓存**全部默认开启，**不再在主性能设置页堆砌一堆开关**；
   - 将上述细项全部收进默认折叠的 `DisclosureGroup("高级选项")` 中供极客按需微调，并在「环境与存储」/「高级选项」中提供**「原生内核网络直通（`vmnet` 守护进程）」状态检测与一键标准系统授权开启入口**（未开启时自动无缝回落零特权非 `slirp` 代理）；
4. **单应用无感交互**：
   - 启动容器模式应用/游戏时，默认调用内嵌于 `Malt.app/Contents/Helpers/` 的无 Dock 图标辅助进程（`LSUIElement = true` / 隐藏独立 Dock 图标），或在 `Malt` 主进程原生窗口中无缝承载，彻底消除“弹出第二个独立 UTM 软件”的割裂感。

### 任务 15B-3：升级 `package_malt_dmg.sh` 为开箱即用打包 + `dev_restart.sh` 实机验证
1. 升级 `Whisky/scripts/package_malt_dmg.sh`：
   - 支持 `--bundle-embedded-runtime`（默认自动探测仓库外 `<TMPDIR>/utm-custom-build/UTM-Custom.app` 或指定路径，将其轻量核心运行时与 `RuntimeScripts/` 安全内嵌进 `Malt.app/Contents/Helpers/` 与 `Resources/`，并将内嵌 Helper 的 `LSUIElement` 置为 `true` 实现单 Dock 图标无感运行；若未找到外部编译产物则清晰记录并仍可产出标准 `Malt.dmg`）；
   - 允许合理增大包体以实现开箱即用，严格保持 `Hardened Runtime` + `codesign --verify --deep --strict` 全绿，绝不将 `.dmg` 或内嵌大二进制提交入 git；
2. 运行 `./handoff/task-07/dev_restart.sh` 完成主 App 编译、签名、重启与主窗口存活验证，落盘 `handoff/phase-15/evidence/p15-b/{malt-embedded-dmg-manifest.json,app-restart-verification.json,report.md}`。

---

## 2. 独占写入范围（严禁越界）

- 允许写入：
  - `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/**`
  - `Whisky/WhiskyKit/Tests/WhiskyKitTests/UnifiedOrchestrationTests.swift`
  - `Whisky/Whisky/Views/Unified/**`
  - `Whisky/Whisky/Views/ContentView.swift`
  - `Whisky/Whisky.xcodeproj/project.pbxproj`
  - `Whisky/scripts/package_malt_dmg.sh`
  - `handoff/phase-15/evidence/p15-b/**`
- 严禁触碰：`Whisky/Modules/utm-custom/`（归 15A）、`Whisky/Modules/guest-optimizer/`、`graphics-lab/`（归 15A）、`handoff/task-07/`、`/Applications/UTM.app` 原件、只读母盘与冷备 `vm-a`。

---

## 3. 验收门禁

1. `./handoff/task-07/dev_restart.sh` 通过；
2. `./Whisky/scripts/package_malt_dmg.sh` 通过且 `codesign --verify --deep --strict` 全绿；
3. `swift test --package-path Whisky/WhiskyKit` 全绿；
4. `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)` **0 violations**；
5. `python3 handoff/task-07/format_check.py` 全绿；
6. `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` 全绿；
7. 零 `> 5 MiB` 新增跟踪文件、零隐私路径泄漏、零 git 操作。
