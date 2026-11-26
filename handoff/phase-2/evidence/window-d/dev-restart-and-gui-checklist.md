# 窗口 D 开发期自动重启验证与 GUI / CLI 点验记录（Phase 2）

日期：2026-11-22（Asia/Shanghai）  
范围：`handoff/task-07/dev_restart.sh`、`WhiskyCmd` 端到端运行测试、GUI 交互点验清单与旧 `Process.runStream` 隐私边界审计。所有路径均已脱敏。

---

## 1. 开发期自动重建重启脚本（`handoff/task-07/dev_restart.sh`）实测

| 检查项 | 执行方式 | 结果 | 说明 |
| --- | --- | --- | --- |
| 语法与脱敏静态检查 | `test_dev_restart.py`（`bash -n`、无硬编码 `/Users/`、无 `git config --global`） | `passed` | 2/2 单测通过 |
| `--dry-run` 工程与产物发现 | `dev_restart.sh --dry-run` | `passed` | 动态解析 `TARGET_BUILD_DIR`、`FULL_PRODUCT_NAME`、`EXECUTABLE_NAME`、`PRODUCT_BUNDLE_IDENTIFIER` |
| 增量 Debug/arm64 构建 | `dev_restart.sh --no-launch` | `passed` | 无签名、锁定依赖缓存、内置 SwiftLint 0 违规 |
| 停旧启新闭环 | 连续两次 `dev_restart.sh --no-build` + 最后 `--no-build --no-launch` | `passed` | Pass 1 拉起新进程 → Pass 2 优雅关闭旧 PID 并拉起不同新 PID → Pass 3 干净退出无残留（`RESTART_CYCLE_VERIFIED=true`） |

常用开发命令：
```sh
./handoff/task-07/dev_restart.sh               # 增量 Debug/arm64 构建 → 停旧 → 重启最新应用
./handoff/task-07/dev_restart.sh --no-build    # 跳过构建，仅停旧重启最新构建产物
./handoff/task-07/dev_restart.sh --clean       # 清理后重建并重启
./handoff/task-07/dev_restart.sh --dry-run     # 仅打印解析后的命令与产物路径
```

---

## 2. `WhiskyCmd` 隔离端到端运行回归（`cli_smoke.py` + `run_cli_checks.py`）

针对最新构建的 `WhiskyCmd`（SHA-256: `51c204075ff3d5519f69f8b6dc3a4dd3b9bcce1176273d1b2e6690c07aeccbaf`），在独立 `CFFIXED_USER_HOME` 沙盒中通过合成 `wine64` 替身验证（不触碰真实用户容器、真实 Wine 或任何商业可执行文件）：

| 类别 | 用例 | 预期退出码 | 实测退出码 | 状态 |
| --- | --- | --- | --- | --- |
| 解析与帮助 | `--help` / `run --help` / `storage-preflight --help` | `0` | `0` | `passed` |
| 选项校验 | 未知选项拒绝 / `--ignore-saved-arguments=unexpected` 拒绝带值 | `64` | `64` | `passed` |
| 存储预检 | 本地容量就绪 / 文件目标不可写 / 缺失安装器 / 损坏 guest 配置 JSON | `0 / 1 / 1 / 1` | `0 / 1 / 1 / 1` | `passed` |
| 运行 E2E | 省略参数继承 `Program Settings` 已保存参数与环境变量 | `0` | `0` | `passed` |
| 运行 E2E | `--ignore-saved-arguments` 显式覆盖为空数组（跳过畸形未闭合保存参数） | `0` | `0` | `passed` |
| 运行 E2E | `--` 显式参数原样透传（含空格、空字符串、`-` 开头选项） | `0` | `0` | `passed` |
| 运行 E2E | 子进程非零退出码映射与本地化文案 | `42` | `42` | `passed` |
| 运行 E2E | 子进程 `SIGTERM` 信号终止映射与本地化文案 | `143` (`128+15`) | `143` | `passed` |
| 运行 E2E | 子进程 `SIGKILL` 信号终止映射与本地化文案 | `137` (`128+9`) | `137` | `passed` |
| 运行 E2E | 运行中 `SIGINT` 取消、输出本地化取消文案并终止子进程无残留 | `130` | `130` | `passed` |

---

## 3. GUI / 交互点验状态清单（承接 Phase 1 遗留项）

| 点验项 | 代码与自动化核验状态 | 人工交互确认状态 | 备注 |
| --- | --- | --- | --- |
| 原生目录选择与 JSON 映射导入（`RuntimeStorageSection`） | 代码路径与 `RuntimeGuestConfiguration` JSON 解码 + 错误弹窗文案（`runtime.storage.pickerErrorTitle` / `runtime.cli.storageGuestConfigInvalid`）已复核，CLI 隔离分支已通过 | 待桌面交互实点 | 依赖 macOS 原生 `fileImporter` 系统弹窗授权 |
| Finder 文件打开错误弹窗（`FileOpenView` + `.runtimeLaunchFeedback`） | 状态回退、重试、三语错误文案与 `RuntimeLaunchController` 去重逻辑已通过源码复核与单测 | 待桌面交互实点 | 依赖 Finder `Open With` 系统事件触发 |
| Shift 终端实际启动交互（`RuntimeLaunchController.openTerminal`） | AppleScript 转义、CLI 路径定位与 `RuntimeArguments.quote` 往返单测已通过 | 待桌面交互实点 | 依赖 macOS Terminal Automation TCC 权限弹窗 |
| 新增宿主自适应资源策略开关（`ConfigView`） | `BottleSettings.adaptiveResourcePolicyEnabled`（默认关闭）+ 非破坏性 DXVK 注入 + D3DMetal 不注入变量已通过 `RuntimeTests` 与 Debug 构建验证 | 已编译就绪，可由 `dev_restart.sh` 直接目检 | 三语标题与作用边界说明已合入 `Localizable.xcstrings` |

---

## 4. 旧 `Process.runStream` 日志隐私边界审计结论

- **现行调度路径安全**：`Wine.startProgramInWine` 使用 `Process.startRuntimeSession()`，不调用旧 `Process.runStream`。
- **旧辅助工具路径边界**：`Wine.runWineProcess` / `Wine.runWineserverProcess`（用于 `winecfg`/`reg`/`wineserver`）经 `Process+Extensions.swift`（非窗口 D 独占写入目录）调用 `runStream` 时，会向本机 `Logger.wineKit` 与 `~/Library/Logs/<bundleId>/` 写入原始参数、路径与环境信息。
- **门禁守卫**：本机 `~/Library/Logs/<bundleId>/` 严格排除在交付与证据归档之外，`handoff/task-07/audit_evidence.py` 与 `phase2_evidence.py` 持续拦截未脱敏 `/Users/` 路径与敏感凭据。
