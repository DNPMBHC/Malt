# 开源 UTM 最小化定制架构与「纯净原生全屏游戏壳」设计

日期：2026-11-24  
署名：`@DNPMBHC`  
上游基线：
- `utmapp/UTM`：`v5.0.9`（commit `305fd07781231754c32eac367fa83ea759ce374a`）
- `utmapp/CocoaSpice`：`e239fab0828ebafc3a5a973fa84039400d7ac703`

---

## 1. 合法合规与架构边界

本定制模块严格遵守 Phase 10 五条防外挂与安全红线：
1. **仅改造 macOS 宿主机侧呈现、输入体验、默认 DXMT 后端与无桌面全屏窗口壳**；
2. **绝对禁止**修改 QEMU CPUID / SMBIOS / ACPI / TPM / Hypervisor 标识或隐藏虚拟化特征；
3. **绝对禁止**修改 Windows 内核/签名系统驱动或任何游戏/ACE 反作弊二进制；
4. **外部源码隔离**：`utmapp/UTM` 与 `CocoaSpice` 源码及编译产物仅存在于仓库外临时目录（`${TMPDIR}/utm-custom-src`），本仓库仅保留轻量 `.patch`、校验脚本与架构文档。

---

## 2. 三处精准源码定位与改造设计

### 位置 1：默认图形后端锁定 `dxmt-native` 与渲染调优
- **文件**：
  - `UTM/Services/UTMQemuVirtualMachine.swift`（`directXDriver` 计算属性，第 261–271 行）
  - `UTM/Services/UTMQemuSystem.m`（`-setDirectXDriver:`，第 86–135 行）
  - `UTM/Services/UTMQemuSystemBackends.h`（`UTMQEMUDirectXDriver` 枚举，`kQEMUDirectXDriverDXMT = 2`，第 46–50 行）
- **现状问题**：上游在未设置 `QEMUDirectXDriver` 时默认选择 `0`（`kQEMUDirectXDriverDefault`），若 `D3DMetal.framework` 存在则回落 `d3dmetal-native`（已实证在 `target-cn` 创角界面 2.6 秒死锁）。
- **最小改造**（`01-default-dxmt-backend.patch`）：
  - 支持 `--dxmt-native` 启动参数或 `UTMQemuVirtualMachine.directXDriver` 默认回落至 `.qemuDirectXDriverDXMT`（`2` = `dxmt-native.framework`）；
  - 在 `UTMQemuSystem.m` 中启用 `kQEMUDirectXDriverDXMT` 时自动透传 `DXMT_SHADER_CACHE=1` 持久化环境变量。

### 位置 2：游戏内光标可见性与 FPS 相对鼠标安全释放
- **文件**：
  - `CocoaSpice/Sources/CocoaSpice/CSCursor.m`（`-isVisible`，第 149–151 行）
  - `CocoaSpice/Sources/CocoaSpiceRenderer/CSMetalRenderer.m`（`_renderCommand:`，第 420–435 行）
  - `UTM/Platform/macOS/Display/VMDisplayQemuMetalWindowController.swift`（`captureMouse()` / `releaseMouse()` / `stopAllCapture()`，第 236–254、550–625 行）
- **现状问题**：游戏焦点接管后 `CSCursor` 收到隐藏/抑制状态（`isInhibited` 或 `cursorHidden`），导致 `CSCursor.isVisible == NO`，`CSMetalRenderer` 不再绘制 `_cursorSource`，而宿主机光标同时处于隐藏状态。
- **最小改造**（`02-cursor-and-fps-capture.patch` + `02-cocoaspice-cursor-overlay.patch`）：
  - 在 `VMDisplayQemuMetalWindowController.swift` 增加失焦/应用停用（`applicationDidResignActiveNotification`）自动调用 `releaseMouse()` 的安全保护，避免失焦卡死指针，并支持跳过重复捕获弹窗；
  - 在 `CocoaSpice` `CSCursor.m` 增加可选环境变量开关 `UTM_KEEP_CURSOR_VISIBLE_ON_INHIBIT=1`（仅在显式开启诊断/兼容模式时保留软件光标合成叠加），预留吸纳窗口 10A `cursor-diagnosis-for-10b.md` 实测结果。

### 位置 3：无桌面「纯净原生全屏游戏壳模式」（`--game-shell-vm <UUID>`）
- **文件**：
  - `UTM/Platform/macOS/AppDelegate.swift`（应用生命周期与终止策略）
  - `UTM/Platform/macOS/UTMApp.swift`（SwiftUI `homeWindow` 入口）
  - `UTM/Platform/macOS/Display/VMDisplayQemuMetalWindowController.swift`（显示窗口与全屏控制）
- **设计方案**（`03-clean-fullscreen-game-shell.patch`）：
  - 解析命令行参数 `--game-shell-vm <UUID>`：启动后不打开 UTM 图书馆管理主窗口，直接定位对应 UUID 的虚拟机并调用 `data.run(vm:)`；
  - 显示窗口进入无工具栏原生全屏（`window.toolbar?.isVisible = false` + `toggleFullScreen(nil)`）；
  - 保留 `Cmd+Option+G` / `Ctrl+Option` 安全释放光标快捷键；
  - 当该 VM 关机进入 `.stopped` 状态时自动退出 UTM 进程（`NSApp.terminate(nil)`）。
