# Phase 15B 验收报告：`demo-app` 单应用无感内嵌后端、极简防呆前端重构与 3 项实战断路根治

- **窗口**：Phase 15 窗口 15B
- **署名**：`@DNPMBHC`
- **品牌**：`demo-app`
- **证据文件**：
  - `handoff/phase-15/evidence/p15-b/demo-app-embedded-dmg-manifest.json`
  - `handoff/phase-15/evidence/p15-b/app-restart-verification.json`

---

## 1. 核心交付项核验

### 1.1 根治 `demo-appKit/Orchestration` 3 项一键打通实战 Bug
1. **【P0】普通 Wine 游戏走原生三引擎路由**（`UnifiedRuntimeOrchestrator.swift`）：
   - 删除硬编码 `/usr/bin/env wine64`，改为复用 `demo-appWineInstaller.binFolder.appending(path: "wine64")` 与 `BottleSettings.environmentVariables(...)`，完整注入 `WINEPREFIX`、`DXMT` / `D3DMetal` / `DXVK` / `KosmicKrisp` / `MoltenVK` / `WINEDLLPATH` 及隔离着色器缓存目录。
2. **【P0】多级自发现与外置 SSD 自动扫描**（`UnifiedRuntimeDiscovery.swift`）：
   - 彻底消除 `graphics-lab/golden_guest_manager.py` 与 `kiosk-app-shell.ps1` 的相对路径硬编码；
   - 按 `demo-app.app/Contents/Helpers/demo-appContainerHelper.app`（`LSUIElement = true`）→ `demo-app.app/Contents/Resources/RuntimeScripts/` → 外部/开发目录优先级自发现；
   - 自动扫描 `<mounted-volume> 外置 SSD 持久化游玩 `.utm` 实例，严格跳过只读母盘（`golden*`）与冷备（`vm-a.utm`）。
3. **【P1】无桌面安装器端到端透传 + 非阻塞磁盘测速**：
   - `installViaAntiCheatVM` 完整透传 `--app-shell-vm`、`--window-title`、`--window-size`、`--app-shell-state-file`，并通过状态 JSON 与环境变量（`demo-app_APP_SHELL_INSTALLER_EXE` / `demo-app_KIOSK_SHELL_SCRIPT`）将选中 `.exe` 透传给 Guest `kiosk-app-shell.ps1`；
   - `HardwareAutoTuner.runDiskIOBenchmark` 已迁入 `Task.detached(priority: .utility)`，彻底消除测速末段卡顿 UI 动画。

### 1.2 防呆极简前端重构、单应用无感交互与原生内核网络直通入口
- **三档性能预设收敛**（`UnifiedGameEntry.swift`）：收敛为 **`最高性能`（`maxPerformance`）** / **`平衡`（`balanced`，默认推荐）** / **`低配置兼容`（`lowSpecCompatible`）**，通过自定义 `Decodable` 完整兼容旧 JSON 键（`nativeQuality` / `balancedRecommended` / `competitiveHighFPS`）。
- **硬件自检 + 安全可调范围 + 点选 `GB` 内存**（`HardwareAutoTuner.swift` / `UnifiedPerformanceView.swift`）：
  - 根据本机总内存动态生成合法 `GB` 档位按钮并高亮推荐档（16 GB Mac：`6 / 8 / 10(推荐) / 12 GB`；24 GB：`8 / 12(推荐) / 16 GB`；32+ GB：`8 / 12 / 16(推荐) / 20 GB`；8 GB：`4 / 6(推荐) GB`），彻底取消 MiB 手输；
  - `UnifiedPreferencesModel.clampToSafeBounds(for:)` 在进入设置页或套用校准结果时自动收束内存与 vCPU 到安全范围。
- **默认静默优化 + 高级选项折叠**：macOS 游戏模式、高回报率鼠标无损合批（默认 `1500 μs`）、全屏防误触（`Cmd+W/Q/H/M`）、键位映射与持久化缓存全部默认开启并收进默认折叠的「高级选项」。
- **原生内核网络直通（`vmnet` 守护进程）状态检测与一键授权入口**：
  - 在「性能与智能适配 → 高级选项」及「环境与存储 → 运行底座健康状态」中均提供 `vmnet` 守护进程状态实时检测与「一键系统授权开启」入口；
  - 未授权开启时自动无缝回落 15A 提供的零特权完整 TCP+UDP 非 `slirp` 通道（`ContainerNetworkMode.zeroPrivilegeNativeTCPUDP`），绝不阻塞普通用户体验。

### 1.3 开箱即用内嵌打包（`package_demo-app_dmg.sh --bundle-embedded-runtime`）
- 升级 `demo-app/scripts/package_demo-app_dmg.sh` 支持 `--bundle-embedded-runtime` 与 `--embedded-runtime-source <app>`：
  - 将定制容器运行时内嵌至 `demo-app.app/Contents/Helpers/demo-appContainerHelper.app` 并将 `LSUIElement` 置为 `true`（单 Dock 图标无感交互）；
  - 内嵌 `RuntimeScripts/{golden_guest_manager.py, kiosk-app-shell.ps1}`；
  - 产出压缩只读 `demo-app/build/release/demo-app.dmg`（`336.527 MiB`，gitignored，未提交入 git），SHA-256：`1c54a046047a175f7f2b388ae03cbcd45f83f3ea70b7eff87b01ca091819d7ca`；
  - 严格通过 `Hardened Runtime`、`codesign --verify --deep --strict`、零禁止调试 entitlements 与 bundle purity 门禁。

---

## 2. 验收门禁结果汇总

| 门禁项 | 执行命令 | 结果 |
| --- | --- | --- |
| 主 App 编译重启验证 | `./handoff/task-07/dev_restart.sh` | ✅ 通过（Debug/arm64 构建成功，进程存活验证通过） |
| 开箱即用内嵌 DMG 打包 | `./demo-app/scripts/package_demo-app_dmg.sh --bundle-embedded-runtime --manifest-output handoff/phase-15/evidence/p15-b/demo-app-embedded-dmg-manifest.json` | ✅ 通过（`336.527 MiB`，`LSUIElement=true`，`codesign --verify --deep --strict` 全绿） |
| demo-appKit 单元测试 | `swift test --package-path demo-app/demo-appKit` | ✅ 267/267 通过（含 `UnifiedOrchestrationTests` 9/9，0 failures） |
| Strict SwiftLint | `(cd demo-app && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)` | ✅ 0 violations |
| 格式门禁 | `python3 handoff/task-07/format_check.py` | ✅ 通过（`formatPassed: true`，6/6 输入稳定） |
| 合规审计自检 | `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` | ✅ 通过（6/6 负向自检通过，143 个源码文件合规） |
| 仓库纯净与越界检查 | 只读检查修改路径、文件体积与隐私脱敏 | ✅ 零越界、零 `>5 MiB` 跟踪文件、零隐私路径泄漏、零 git 写入操作 |
