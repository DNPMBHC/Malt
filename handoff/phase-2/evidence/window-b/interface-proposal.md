# 窗口 B 跨窗口接口与门禁同步提案（致窗口 D）

日期：2026-11-22（Asia/Shanghai）
提案方：窗口 B（`module-a` + `module-f`）
接收方：窗口 D（`module-e` + `module-g` 统一门禁与核心模型收口）

---

## 1. `module-a` 唯一真源路径收敛提案

- **现状**：窗口 B 已完成 `module-a` 双副本去重，确立 `<workspace>/Whisky/Modules/module-a` 为唯一物理真源；为防止 `<workspace>/handoff/task-07/integration.py`（第 43 行与第 108 行硬编码 `root / 'Modules/module-a/WindowsProbe'`）断裂，窗口 B 已将顶层 `<workspace>/Modules/module-a` 替换为指向 `../Whisky/Modules/module-a` 的相对符号链接。
- **建议窗口 D 配合项**：
  - 在窗口 D 升级 `handoff/task-07/integration.py` 时，可将第 43 行与第 108 行的 `root / 'Modules/module-a/WindowsProbe'` 显式指向唯一物理真源 `root / 'Whisky/Modules/module-a/WindowsProbe'`（或保留符号链接兼容检查，并校验 `Modules/module-a` 与 `Whisky/Modules/module-a` 解析至同一 `realpath`）。

---

## 2. `06 (module-f)` 兼容性元数据与国服安装器静态取证字段对齐

- **现状**：
  1. 窗口 D 任务书（`window-d-core-gate.md`）已包含合入 `06` 元数据字段（`distributionID`、`clientPlatform`、`guestOSBuild`、`securityCapabilities`、`driverBinaryMachine`、`sourceSnapshotID`）及三语本地化。
  2. 窗口 B 已完成对 `<workspace>/VALORANT_CN_installer_v2.17.4.510.exe` 的只读 PE/Authenticode 静态取证（见 `handoff/phase-2/evidence/window-b/valorant-cn-installer-static.json`）。
- **字段语义对齐提醒（供窗口 D 合入模型与 07 门禁消费）**：
  - **安装器外层架构 vs 内核驱动架构**：国服安装器 `VALORANT_CN_installer_v2.17.4.510.exe` 外层为 32 位 x86 NSIS 引导程序（`PE32`, `Machine = 0x014c / IMAGE_FILE_MACHINE_I386`, `FileVersion = 2.17.4.510`, `InternalName = aclos-launcher.exe`，由 `Tencent Technology (Shenzhen) Company Limited` 合法 Authenticode 签名）。
  - **严禁自动提升**：外层安装器 `Machine = I386` 仅代表安装引导器用户态可执行文件架构，**不代表内核反作弊驱动二进制架构（`driverBinaryMachine`）**。在窗口 B 于真实 Windows Guest 中完成合规动态安装采样前，`a-cn-win` 的 `driverBinaryMachine`、`driver_load`、`game_start`、`protected_session` 必须保持 `unknown` / `nil`。
