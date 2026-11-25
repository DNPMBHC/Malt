# 窗口 D 任务书：核心调度收口 + 共享接口统筹 + 门禁升级（P1 / 持续 P0）

对应原模块：`task-05 / module-e` + `task-07 / module-g`
请先阅读：`handoff/phase-2/README.md`、`handoff/runtime-interface.md`、`handoff/task-05.md`、`handoff/task-07.md`、`handoff/task-07/findings-behavior.md`、`handoff/task-07/report.md`

---

## 1. 当前基线与核心问题

- **任务 05（`module-e`）**：共享接口与 UI/CLI/快捷方式主流程已冻结并通过 90/91 SwiftPM + 0 Lint 违规。但 `runtime-interface.md` 与 `findings-behavior.md` 明确记录了 4 项收尾缺口：
  1. 自动选卷容量排序在两个卷的估算值同为 `0` 时可能选错较大卷；
  2. CLI `--ignore-saved-arguments` 实际覆盖保存参数的运行分支，以及子进程取消/信号/非零退出码经 CLI 映射后的端到端验证尚未补齐；
  3. 档案说明与部分错误原因仍有英文未全量三语本地化；旧 `Process.runStream` 路径日志脱敏需核查；
  4. `module-f` 建议的发行区域/架构/版本兼容元数据字段尚未评估合入共享接口。
- **任务 07（`module-g`）**：本地门禁完备，但冷缓存 Xcode 依赖拉取仍易超时（curl 28 / exit 124），且尚未接入 Phase 2 真实 Guest / WDK / Wine 证据的自动校验与摘要绑定。

**本窗口完全不依赖 Windows Guest，可立即开工！**

---

## 2. 独占可写路径（严禁越界修改）

- `Whisky/Whisky/`（SwiftUI 界面、AppDelegate、快捷方式、本地化 `Localizable.xcstrings`）
- `Whisky/WhiskyCmd/`（CLI 与 `StoragePreflight.swift`）
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/Runtime*.swift`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/GameCompatibilityDatabase.swift`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/JSONKeyUniquenessScanner.swift`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Whisky/`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/Runtime*.swift`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/IntegrationBoundaryTests.swift`
- `handoff/runtime-interface.md`
- `handoff/task-07/`
- `handoff/phase-2/evidence/window-d/`（新建，存放 Phase 2 综合集成门禁快照）

> 严禁直接修改窗口 A（`UTM*`/`WindowsGuest*`）、窗口 B（`module-a`/`AntiCheatProbe*`/`module-f`）、窗口 C（`graphics-lab`/`Host*`）的文件。跨窗口接线时读取对方 `interface-proposal.md` 后在本窗口路径内统一落地。

---

## 3. 分阶段实施任务

### 阶段 D1：任务 05 已知缺口清零（立即执行）
1. **修复自动选卷容量排序缺陷**：
   - 定位 `RuntimeStorage.swift` 中卷容量排序逻辑，修复当多个候选卷估算值同为 `0`（或缺少估算值）时的比较缺陷，确保回退比较真实可用容量且排序稳定；补充确定性边界单元测试。
2. **补齐 CLI 完整运行入口端到端回归**：
   - 为 `WhiskyCmd` 补齐真实隔离运行测试：覆盖 `--ignore-saved-arguments` 显式覆盖已保存参数为空数组、子进程返回非零退出码、信号终止（如 `SIGTERM`/`SIGKILL`）、以及运行中取消经 CLI 映射后的真实退出码与错误文案。
3. **兼容元数据接口演进与本地化收尾**：
   - 审阅 `handoff/module-f/engineering-input.md` 提案字段（`distribution_id`、`client_platform`、`host_cpu_architecture`、`guest_cpu_architecture`、`guest_os_build`、`driver_binary_machine`、`driver_file_version`、`source_snapshot_id` 等），以向后兼容、可选/默认值清晰的方式合入 `RuntimeModels.swift`、`GameCompatibilityDatabase.swift` 及 `handoff/runtime-interface.md`。
   - 审阅并响应窗口 A/B/C 的 `interface-proposal.md`（例如窗口 C 的 `HostResourcePolicy` 下游消费者接线）。
   - 补齐档案说明与剩余错误原因的英文 / 简体中文 / 繁体中文三语本地化；审计旧 `Process.runStream` 日志输出边界，防止敏感路径/环境泄露。

### 阶段 D2：开发期自动构建重启工具与 GUI 交互点验
1. 编写开发期标准重建与自动重启脚本（例如放入 `handoff/task-07/dev_restart.sh`）：
   - 执行增量 Debug/arm64 构建 → 安全终止正在运行的旧 `Whisky` 应用实例 → 自动重启最新构建产物并输出日志位置，方便快速验证 UI 改动。
2. 完成 Phase 1 遗留的 GUI/交互人工+自动化点验清单：原生目录选择与 JSON 映射导入、Finder 打开错误弹窗、Shift 终端实际启动交互，记录脱敏点验结论。

### 阶段 D3：任务 07 门禁升级与 Phase 2 最终汇总验收
1. **构建与依赖拉取稳定性治理**：
   - 在不修改全局 Git 配置前提下，为 `verify.py` 明确拆分「锁定缓存快速门禁」与「进程级冷缓存探测」两种模式，定位并缓解 Xcode 依赖拉取超时问题，清晰报告网络故障与代码故障。
2. **升级真实环境证据 Schema 与校验器**：
   - 扩展 `handoff/task-07/verify.py` 与 `integration.py`，支持校验并收录 `handoff/phase-2/evidence/window-{a,b,c}/` 的真实 Guest、真实 WDK 探针、真实 Wine/D3D11 实测证据，**强制要求每份实测性能/运行证据绑定源码与二进制不可变 SHA-256 摘要**。
3. **最终集成门禁**：
   - 待窗口 A/B/C 交付物就绪后，统一运行全量门禁：
     - SwiftPM 全量测试（0 失败）
     - Strict SwiftLint（`handoff/task-07/.tools/swiftlint`，0 违规）
     - Xcode 无签名 Debug/arm64 构建
     - `python3 handoff/task-07/format_check.py`
     - `cd graphics-lab && python3 -B -m unittest discover -v`（确认 `test_metalfx_sdk_compile.py` 未跳过）
     - `python3 handoff/module-f/validate_evidence.py`
     - 可移植探针 ABI CTest
   - 更新 `handoff/task-07/report.md`，如实给出 Phase 2 五维验收结论。

---

## 4. 验收标准与交付物

1. 修复后的源码、新增边界测试与更新后的 `handoff/runtime-interface.md`。
2. 开发期自动重建重启脚本（`dev_restart.sh`）及 GUI/CLI 点验记录。
3. 升级后的 `handoff/task-07/` 校验工具链与 Phase 2 最终脱敏验收报告（`handoff/task-07/report.md`）。
4. 未获明确指令不执行 `git commit / git push`，不修改全局 Git 配置。
