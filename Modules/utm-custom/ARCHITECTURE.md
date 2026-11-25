# 开源 UTM 最小化定制架构与「纯净原生全屏游戏壳」设计（Phase 11）

日期：2026-11-25  
署名：`@DNPMBHC`  
上游基线：
- `utmapp/UTM`：`v5.0.9`（commit `305fd07781231754c32eac367fa83ea759ce374a`）
- `utmapp/CocoaSpice`：`e239fab0828ebafc3a5a973fa84039400d7ac703`

---

## 1. 合法合规与架构边界

本定制模块严格遵守 Phase 10 / Phase 11 五条防外挂与安全红线：
1. **仅改造 macOS 宿主机侧呈现、输入体验、默认 DXMT 后端、纯相对鼠标开关、渲染线程 QoS / 背压与无桌面全屏窗口壳**；
2. **绝对禁止**修改 QEMU CPUID / SMBIOS / ACPI / TPM / Hypervisor 标识或隐藏虚拟化特征；
3. **绝对禁止**修改 Windows 内核/签名系统驱动或任何游戏/ACE 反作弊二进制；
4. **外部源码隔离**：`utmapp/UTM` 与 `CocoaSpice` 源码树及 `UTM-Custom.app` 编译产物严格置于仓库外临时目录（`${TMPDIR}/utm-custom-src` / `${TMPDIR}/utm-custom-build`），本仓库仅保留轻量 `.patch`、合规校验器、构建脚本与文档；绝不修改 `/Applications/UTM.app` 原件。

---

## 2. 七组精准源码改造点（9 份独立且可堆叠补丁）

### 位置 1：默认图形后端锁定 `dxmt-native`（`01-default-dxmt-backend.patch`）
- **目标文件**：
  - `UTM/Services/UTMQemuVirtualMachine.swift`（`directXDriver`）
  - `UTM/Services/UTMQemuSystem.m`（`-setDirectXDriver:`）
- **改造内容**：
  - 支持 `--dxmt-native` 启动参数，且 `QEMUDirectXDriver` 未设置或无效时默认锁定 `.qemuDirectXDriverDXMT`（`2` = `dxmt-native.framework`），杜绝默认回落至已知存在创角死锁的 `d3dmetal-native`；
  - 在 `kQEMUDirectXDriverDXMT` 分支默认透传 `DXMT_SHADER_CACHE=1`。

### 位置 2：游戏内光标可见性与双模式输入修复（`02-cocoaspice-cursor-overlay.patch` + `02-cursor-and-fps-capture.patch`）
- **第一性原理根因定位**（承接 Phase 10A `cursor-diagnosis-for-10b.md` 与源码深审）：
  1. **`CSDisplay.setDevice:` 异步竞态**：上游在主线程异步派发 `_device = device` 到 SPICE 线程，却在 block 外同步调用 `self.cursor.display = self`，导致 `cs_cursor_set` 读到 `self.device == nil` 而跳过光标 Metal 纹理创建；且后续收到同尺寸光标时因未检查 `!self.texture` 永远不会重建；
  2. **`CSCursor.m` 切入 `SPICE_MOUSE_MODE_SERVER` 时将坐标重置为 `(-1, -1)`**：在 `Capture Mouse` 或纯相对鼠标模式下，若 `viogpu3d` 未立即重发 `cursor-move`，`CSMetalRenderer` 将光标绘制在屏外；
  3. **纯相对模式（无 `usb-tablet`）下非捕获移动被直接丢弃**：原 `mouseMove(absolutePoint:)` 遇到 `vmInput.serverModeCursor == true` 直接 `return`；
  4. **全局热键屏蔽阻塞 `Cmd+Tab` 切屏**：原 `VMMetalView.captureMouse()` 调用 `CGSSetGlobalHotKeyOperatingMode(.disable)` 导致 `Cmd+Tab` 失灵。
- **最小改造**：
  - **`02-cocoaspice-cursor-overlay.patch`**（`CSCursor.h`、`CSCursor.m`、`CSDisplay.m`）：
    - 将 `self.cursor.display = self` 移至 `setDevice:` 的 SPICE 线程 `_device = device` 之后，且 `setDisplay:` 保证在 SPICE 线程安全调用 `cs_cursor_set`；
    - `cs_cursor_set` 增加 `!self.texture || !self.vertices` 强制重建检查，并在坐标无效时初始化至画面中心；
    - `cs_update_mouse_mode` 切入 `SPICE_MOUSE_MODE_SERVER` 时保留有效坐标或置中，不再强行抹为 `(-1, -1)`；
    - 新增 `applyRelativeFallback(delta:)` 仅在尚未收到服务端 `cs_cursor_move` 时做宿主机相对坐标兜底（一旦收到真实 `cs_cursor_move` 则 100% 听从 Guest 真实坐标）；支持 `UTM_KEEP_CURSOR_VISIBLE_ON_INHIBIT=1` 与按需诊断日志 `UTM_CURSOR_DEBUG=1`。
  - **`02-cursor-and-fps-capture.patch`**（`VMMetalView.swift`、`VMDisplayQemuMetalWindowController.swift`）：
    - 监听 `NSApplication.didResignActiveNotification` 自动释放鼠标并记录失焦前捕获态（`wasCapturedBeforeDeactivate`），退出时干净移除 observer；
    - `--game-shell-vm` / `--pure-relative-mouse` 跳过重复捕获确认弹窗，且纯相对模式下跳过无意义的 `requestInputTablet` 切换；
    - 纯相对模式下在非捕获状态将指针位移差值（限幅 `<= 120px` 防止跨边跳变）平滑转发至 `sendMouseMotion` + `applyRelativeFallback(delta:)`，实现非捕获与捕获双模式光标均可见跟手；
    - 在 `handleCaptureKeys` 显式支持 `Cmd+Option+G` 随时安全释放光标、`Cmd+Tab` 自动释放并放行切换桌面；在 Game Shell 模式下 `VMMetalView.captureMouse()` 不禁用 macOS 全局热键。

### 位置 3：无桌面「纯净原生全屏游戏壳」（`03-clean-fullscreen-game-shell.patch`）
- **目标文件**：
  - `UTM/Platform/macOS/AppDelegate.swift`
  - `UTM/Platform/macOS/Display/VMDisplayWindowController.swift`
  - `UTM/Platform/macOS/Display/VMDisplayQemuMetalWindowController.swift`
- **改造内容**：
  - `--game-shell-vm <UUID-or-utm-path>`（或 `UTM_GAME_SHELL_VM`）启动后自动关闭/隐藏所有非 `VMDisplayWindow` 主管理窗口，直接支持按 UUID 匹配或直开指定 `.utm` 包路径；仅在 VM 状态真正到达 `.started` 后置位 `gameShellHasStarted`（防止启动前报错被误杀弹窗），关机进入 `.stopped` 时自动干净 `NSApp.terminate(nil)` 且不弹二次退出确认；
  - 默认隐藏工具栏（仅设 `window.toolbar?.isVisible = false` 而**不**将 `window.toolbar` 置为 `nil`，既保持全屏零遮挡，又保留 USB 共享直通与 Capture 按钮对象供用户随时唤出）、隐藏标题栏、启用 `.fullSizeContentView` 与纯黑底色，并在 `enterLive()` 自动进入 macOS 原生全屏；
  - 在 `window(_:willUseFullScreenPresentationOptions:)` 与全屏激活回调设置 `[.fullScreen, .autoHideMenuBar, .autoHideDock, .autoHideToolbar]` 抑制顶部菜单栏与 Dock 误触（失焦或退出全屏恢复 `[]`）；
  - 修复 `windowDidEnterFullScreen` 缺失缩放重算导致的黑边问题，并在 `updateHostScaling` 中为 Game Shell 增加 1:1 / Retina 整数倍吸附（误差 `< 0.02` 自动对齐整数倍率，支持可选 `UTM_GAME_SHELL_FILL_SCALE=1`）；
  - 在 Game Shell 或 `--pure-relative-mouse` 模式下，进入原生全屏自动调用 `captureMouse()`，且任意非捕获状态下点击游戏画面内即可无缝恢复鼠标直连捕获（按 `Cmd+Option+G` 或 `Cmd+Tab` 随时安全释放，绝不锁死宿主机）。

### 位置 4：纯相对鼠标 QEMU 硬件拓扑开关（`04-pure-relative-mouse-option.patch`）
- **目标文件**：`UTM/Configuration/UTMQemuConfiguration+Arguments.swift`（`usbArguments`）、`UTM/Configuration/UTMQemuConfigurationInput.swift`（`PureRelativeMouse` 配置键）
- **改造内容**：
  - 新增三路统一触发开关：`config.plist` 的 `Input.PureRelativeMouse = true`（无缝对接窗口 11A 的 `golden_guest_manager.py --pure-relative-mouse`）、`--pure-relative-mouse` CLI 参数与 `UTM_PURE_RELATIVE_MOUSE=1` 环境变量；
  - 开启后跳过注入 `-device usb-tablet,bus=usb-bus.0`，仅保留标准 `-device usb-mouse,bus=usb-bus.0` 与 `-device usb-kbd,bus=usb-bus.0`，从 QEMU/SPICE 源头消除绝对/相对指针混装导致的 `CLIENT/SERVER` 模式冲突。

### 位置 5：宿主机渲染线程 QoS、持久化 DXMT 缓存与低同步延迟呈现管线（`05-render-thread-qos-and-dxmt-cache.patch` + `05-cocoaspice-frame-backpressure.patch`）
- **目标文件**：
  - `UTM/Services/UTMQemuSystem.m`
  - `UTM/QEMUHelper/QEMUHelper.m`
  - `UTM/Platform/macOS/Display/VMDisplayQemuMetalWindowController.swift`
  - `CocoaSpice/Sources/CocoaSpiceRenderer/include/CSMetalRenderer.h`
  - `CocoaSpice/Sources/CocoaSpiceRenderer/CSMetalRenderer.m`
- **改造内容**：
  - 在 `UTMQemuSystem.m` 为 `kQEMUDirectXDriverDXMT` 自动创建并绑定持久化 `DXMT_SHADER_CACHE_PATH`（支持 `UTM_DXMT_SHADER_CACHE_PATH` 覆盖，默认 `~/Library/Caches/dxmt-shader-cache`）并将缓存目录加入 `self.resources` 以支持沙盒权限透传；
  - 在 `QEMUHelper.m` 调用 `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)` 并将启动 `QEMULauncher` / `QEMURenderServer` 的 `task.qualityOfService` 提升至 `NSQualityOfServiceUserInteractive`，保证 XPC 服务与子进程 QoS 继承，优先调度于 Apple Silicon 性能核（P-cores）；
  - 在 `VMDisplayQemuMetalWindowController.swift` 为 `CAMetalLayer` 配置 `presentsWithTransaction = false`、可配置 `maximumDrawableCount`（`UTM_METAL_DRAWABLE_COUNT`，默认 `3`）、`allowsNextDrawableTimeout = false`、`UTM_DISPLAY_SYNC_ENABLED` 与 `UTM_RENDER_FPS_LIMIT`（便于无 UI 对照 `0` vs `120`）；在 `CAMetalDisplayLink` 回调先检查 `renderer.hasPendingRenderUpdate` 空帧直接短路跳过 `update.drawable` 获取，压降 Phase 11B 发现的 `2.93 ms` 帧同步 `Slack + Slop`；
  - 在 `CSMetalRenderer.m` 暴露只读 `hasPendingRenderUpdate` 并引入可配置深度非阻塞背压信号量（`UTM_MAX_INFLIGHT_FRAMES`，默认 `2`，范围 `1..3`），在压低帧排队延迟的同时杜绝高帧率大场景下无限制堆积 `MTLCommandBuffer`。

### 位置 6：高回报率电竞鼠标无损合批器（`06-high-polling-mouse-coalescing.patch`）
- **目标文件**：`UTM/Platform/macOS/Display/VMMetalView.swift`
- **改造内容**：
  - 针对 1000Hz–8000Hz 高回报率电竞鼠标，在 `VMMetalView` 捕获相对位移入口引入可配置时间窗（`UTM_MOUSE_COALESCE_US`，默认 `1500` μs，`0` 关闭，上限 `16000` μs）的无损微位移合批器；
  - 窗口内线性累加 `(dx, dy)`（0 像素丢失、无加速曲线畸变），到期或超窗统一发送，将 SPICE/QEMU USB HID 中断频率压降 4–8 倍；
  - 在 `mouseDown` / `rightMouseDown` / `otherMouseDown` / `mouseUp` / `rightMouseUp` / `otherMouseUp` / `scrollWheel` / `releaseMouse` 到达前立即 `flushPendingRelativeMotion()`，保证开枪、开镜与释放瞬间准星零延迟；
  - 保持 `CGAssociateMouseAndMouseCursorPosition(0)` 原始 Raw Delta。

### 位置 7：macOS 原生游戏模式 + 游戏壳防误触快捷键屏蔽与键位映射（`07-game-shell-key-guard-and-mapping.patch`）
- **目标文件**：
  - `UTM/Platform/macOS/Info.plist`
  - `UTM/Platform/macOS/Display/VMMetalView.swift`
  - `UTM/Platform/macOS/Display/VMDisplayQemuMetalWindowController.swift`
- **改造内容**：
  - **macOS 原生 Game Mode**：在 `Info.plist` 声明 `LSApplicationCategoryType = public.app-category.games`、`LSSupportsGameMode = true` 与 `GCSupportsGameMode = true`，进入 `--game-shell-vm` 原生全屏自动触发系统游戏模式，退出自动解除；
  - **防误触快捷键屏蔽**：游戏壳全屏期（或 `UTM_GAME_SHELL_KEY_GUARD=1`）在 `handleCaptureKeys(for:)` 与 `VMMetalView.performKeyEquivalent(with:)` 双层拦截并吞掉 `Cmd+W`、`Cmd+Q`、`Cmd+H`、`Cmd+M`，杜绝游戏中误关窗/退应用/隐藏/最小化；
  - **键位映射与安全逃生**：支持 `UTM_BLOCK_WIN_KEY`（游戏壳全屏默认 `1`，可设 `0` 关闭）屏蔽左 `Command` 防误弹 Windows 开始菜单，保持 `Option → Alt` 精准对齐与 `F1–F12` 游戏直通，并严格保留 `Cmd+Option+G` 与 `Cmd+Tab` 最高优先级安全逃生热键。

---

## 3. 自动化合规与白名单门禁

所有 9 份补丁必须通过 `graphics-lab/utm_custom_patch_verify.py` 的：
1. **严格白名单文件范围检查**（仅允许上述 14 个宿主机/渲染层源码与 `Info.plist` 文件）；
2. **5 类违规模式黑名单拦截**（CPUID/Hypervisor 伪装、SMBIOS/ACPI 伪装、TPM/Secure Boot 篡改、Windows 内核/驱动修改、反作弊/游戏篡改）；
3. **独立与全量堆叠 `git apply --check` 校验**（0 冲突）。
