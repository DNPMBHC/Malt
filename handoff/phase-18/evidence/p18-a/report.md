# Phase 18 窗口 18A 验收报告

- **窗口角色**：Phase 18 窗口 18A（前端全链路体验闭环）
- **署名**：`@DNPMBHC`
- **完成时间**：2026-11-26

---

## 1. 实现内容摘要

### 18A-1：拖入安装 → 无桌面弹窗安装 → 扫描游戏入口 → 消歧确认登记入库
- 新增共享组件 `Whisky/Whisky/Views/Unified/InstalledGameDiscoverySheet.swift` 并注册至 `Whisky/Whisky.xcodeproj/project.pbxproj`：
  - 提供可编辑搜索关键词输入框与「扫描游戏入口」按钮，调用 `orchestrator.discoverInstalledGameCandidates(for:query:)`；
  - 多候选列表展示名称、程序路径、启动参数与工作目录摘要，**必须由用户点选并点击「确认登记」**调用 `orchestrator.registerInstalledGame(_:candidate:)` 完成二次核验并落盘（绝不自动选中第一个，也不跳过核验）；
  - 空结果或容器未就绪时展示原因指引，并提供「重新扫描」「修改关键词」及「手动填写/选择路径」退路，路径展示与错误提示均做 `~` 脱敏。
- 更新 `Whisky/Whisky/Views/Unified/UnifiedInstallerView.swift`：
  - 严格区分 `.installerRequested` 与完成状态，提交后明确提示「安装器已启动（等待你在弹窗中完成安装）」，绝不提前标为已完成；
  - 在安装阶段卡片直接嵌入扫描与消歧登记面板。
- 更新 `Whisky/Whisky/Views/Unified/UnifiedGameLibraryView.swift`：
  - 待登记条目（`.installerRequested`）主按钮提供「扫描游戏入口」弹窗闭环，并保留右键菜单手动路径退路。

### 18A-2：首次初始化部署引导 + 一键精简优化注入进度向导
- 新增共享组件 `Whisky/Whisky/Views/Unified/ContainerProvisioningPanel.swift` 并接入 `FirstRunOnboardingView.swift` 与 `UnifiedRuntimeStorageView.swift`：
  - 严格拆分 **「Malt 内嵌引擎组件」** 与 **「Windows 11 ARM64 受管工作容器」** 两项独立状态灯，绝不将“组件已打包”误标为“系统环境已就绪”；
  - 提供「导入已有受管容器（`.utm`）」入口与「从本地合法 Windows 镜像创建指南」（链接 `ContainerProvisioningService.officialWindowsARM64GuideURL()`）；
  - 绑定 `ContainerProvisioningService`，在受管容器就绪后提供「一键应用性能精简与优化注入」与「一键回滚优化」，实时展示 4 步进度条与逐项回执。

### 18A-3：原生网络 `starting` 1 秒有界轮询 + 游戏库一键启动阶段提示
- 更新 `Whisky/Whisky/Views/Unified/NativeNetworkControls.swift`：
  - 为 `.starting` 状态接入 `.task(id: isStartingState)` 1 秒有界轮询（最多 20 次），离开 `.starting` 或视图销毁时立即取消；
  - `.operationFailed(Int(ETIMEDOUT))` 时自动刷新并展示 15 秒诊断超时指引与重试/共享网络回落说明；不将 socket 存在伪报为“游戏已联网”。
- 更新 `Whisky/Whisky/Views/Unified/UnifiedGameLibraryView.swift`：
  - 已登记条目提供大按钮「开始游戏」，并在 `isLaunching` 时展示 `orchestrator.lastStatusMessage` 运行阶段提示。

---

## 2. 门禁与验证结果

| 检查项 | 命令 | 结果 |
| --- | --- | --- |
| 编译与重启存活验证 | `./handoff/task-07/dev_restart.sh` | **通过**（Debug/arm64 编译成功，PID `34255` 存活验证通过） |
| 后端单元测试 | `swift test --package-path Whisky/WhiskyKit` | **通过**（431 executed, 10 skipped, 0 failures） |
| 静态规范检查 | `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)` | **通过**（0 violations） |
| 格式检查 | `python3 handoff/task-07/format_check.py` | **通过**（`formatPassed: true`, `inputCount: 6`） |
| 反作弊加固自检 | `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` | **通过**（6 negative self-tests passed, 163 production sources） |

---

## 3. 写入边界确认
- 所有代码改动严格限定于 `Whisky/Whisky/Views/Unified/**` 与 `Whisky/Whisky.xcodeproj/project.pbxproj`。
- 未修改 `Whisky/WhiskyKit/`、`Whisky/Modules/`、`Whisky/scripts/`、`graphics-lab/`、`handoff/task-07/`、`/Applications/UTM.app` 原件、只读母盘与冷备 `vm-a`。
- 未执行任何 `git commit / push / reset`。
