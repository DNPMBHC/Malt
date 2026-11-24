# 窗口 5C → 5B / 5D：原生游戏壳最小接线契约

日期：2026-11-24  
署名：@DNPMBHC

## 运行时边界

本窗口仅维护授权的运行时源码、测试和本证据目录。主 App 视图、设置持久化、三语文案、项目依赖与打包由 5D 接线。当前 QEMU 兼容路径通过后台 VM 控制运行，不把 UTM 前端窗口嵌入主 App；原生 VZ 的 Guest 生命周期由对应 WindowsGuestProvider 提供。

## 给 5D：一个协调器与两个 UI 触点

主 App 持有 GuestSurfaceCoordinator。设置区域仅提供分辨率档位、退游空闲策略、HUD 开关及鼠标捕获选项；启动动作调用协调器。关闭窗口自动取消目标进程树，窗口尺寸变化经过 200 ms 防抖同步。保留原有受保护应用授权判断，不因新入口绕过任何现有门禁。

```swift
let settings = GuestSurfaceSessionConfiguration(
  resolutionPreset: .highPerformance,
  hostDisplay: HostDisplayDescriptor.primaryOrFallback(),
  idlePolicy: .keepWarm,
  enableRawInputOnFocus: true,
  showOverlayHUD: true
)
let result = try await coordinator.run(
  request,
  provider: guestProvider,
  displaySync: displayProvider,
  configuration: settings,
  frameSource: actualFrameSource,
  pointerSink: actualGuestHIDSink
)
```

调用方在 MainActor 持有协调器和启动 Task；退出 App 时调用 cancel()。实际帧源尚未接入时不要开放游戏壳启动入口。SyntheticIOSurfaceFrameSource 仅供诊断，不表示真实 Guest 或商业游戏帧。未接入真实 HID sink 时不允许捕获光标。

结果包含进程退出状态、实际显示模式、原始显示快照、恢复结果、挂起结果、已完成 GPU 呈现帧数及光标释放回执。协调器的 lastFailureCode 和会话的 lastCleanupFailure 用于显示明确失败，不能把恢复失败记作成功。

## 给 5B：IOSurface 与同步事件

GuestSurfaceFrameSource 的 start(onFrame:) / stop() 定义消费者生命周期。已有 producer 可使用 GuestSurfacePushFrameSource，无需运行时模块引用 producer 项目名称或导入其模块。将现有 bridge 的 surface、sharedEvent、descriptor 尺寸和 signalValue 映射到 GuestSurfaceFrame：

```swift
let frame = GuestSurfaceFrame(
  descriptor: GuestSurfaceFrameDescriptor(
    frameID: sequence,
    width: width,
    height: height,
    pixelFormat: .bgra8Unorm,
    ioSurfaceID: IOSurfaceGetID(surface),
    sharedEventSignaledValue: readyValue,
    backend: .vzZeroCopyIOSurface
  ),
  surface: surface,
  sharedEvent: readyEvent,
  onRelease: { acknowledgeConsumed(sequence) }
)
pushSource.publish(frame)
```

1. 帧 ID 在一次 start 生命周期内严格递增；尺寸、格式、stride 与实际 IOSurface 必须一致。当前接受 BGRA8Unorm 与 RGBA16Float 的非平面 surface。
2. IOSurface 和同步事件使用实际对象引用；surface ID 是校验值，不单独充当安全传输与生命周期凭证。共享事件可以不绑定单一设备；若绑定设备，则需与消费者设备兼容。
3. producer 在写入提交后发布单调 timeline 值。消费者先有界等待共享事件达到 ready 值，再编码 GPU 等待；未就绪不会在主线程无限阻塞。
4. GPU 读取完成前禁止覆盖或回收对应 surface。onRelease 可从 GPU 完成线程调用，producer 必须保证其线程安全，并同时满足自身写入完成条件。释放回执保证幂等；拒收、停止和队列丢帧也会释放。
5. 消费队列仅保留最新一帧；呈现最多保留两帧在途。stop 必须有界，并关闭 producer 的接收与发布。真实扫描输出与目标应用关联仍由 producer 提供。

当前 5B 的 IOSurfacePresentBridge 已公开所需 surface、sharedEvent、尺寸和信号值，字段可直接对应。它的标准 Metal 呈现同样包含一次 GPU 写入 compositor drawable。5C 从 IOSurface 直接创建共享 Metal texture，不进行 CPU 像素拷贝；不把这条路径宣称为“最终 drawable 也不发生 GPU 写入”。本窗口未修改 5B 模块或主 App 工程。

## 相对输入

GuestRelativePointerSink.submit 只接收当前聚焦游戏窗口的物理相对位移。宿主使用未加速 CGEvent 字段，不制造全局系统输入事件。sink 由合法的 Guest 虚拟 HID 输入设备实现；submit 必须非阻塞，传输失败返回 false；不要在宿主主线程等待 Guest 回执。QGA 不是 FPS 位移传输层，禁止用进程注入或全局宏替代。

Cmd+Option+G、失焦、应用停用（含 Cmd+Tab）、退游与窗口关闭都会请求释放光标。输入连接失败或消失后撤销该窗口后续捕获权限；重新建立会话才能再次捕获。系统释放调用失败会进入 releasePending，并先进行三次立即释放，再进行最多二十次非阻塞自动重试；重试强持有系统光标控制器，窗口或状态机销毁后仍继续。仍可用热键重试；释放未获成功回执时，HUD 与结果不能显示“光标已自由”。

## 显示同步与实际支持状态（候选 snapshot 4）

模式查询和切换均通过已审阅的原生桌面辅助程序进入 Session 1。先枚举支持模式并测试，再以不写注册表的动态模式切换，最后回读结果；保留原始设备名称以还原同一显示器。刷新率回退必须返回实际值。

Windows 的进程 DPI awareness 与系统显示缩放分别处理。候选 snapshot 4 新增 GuestSurfaceDPIAwareDisplaySync：显示模式使用标准 ChangeDisplaySettingsExW；缩放使用已签名系统设置的限定 UI Automation，下发 Session 1，改变前持久记录原值，并通过新建 Per-Monitor V2 窗口的 GetDpiForWindow 回读。退游先恢复 DPI，再恢复分辨率；DPI 恢复失败仍尝试分辨率恢复，返回明确失败。

调用方先通过 discoverScaleControls(configuration:) 获取真实 Guest 的控件清单。仅可选 enabled=true、ownerMatches=true、selectedPercent 有值的唯一缩放下拉框 ID；随后配置包装器。没有实测 ID 时包装器不会应用缩放，返回 actual 与 unsupported。发现结果包含多个候选时不得猜测控件 ID。

```swift
let displayProvider = try GuestSurfaceDPIAwareDisplaySync(
  provider: guestProvider,
  scaleAutomationID: observedScaleControlID
)
```

已有 coordinator.run 调用签名不变。GuestDisplayDPIStatus 新增 applied，5D 需按实际返回值显示状态。包装器与脚本已通过本地单元测试和语法编译，但 Windows UIA Apply/Restore 仍待独立克隆实测，不能把候选实现状态显示成实际已验证的系统缩放能力。

## 跨模块 GPU 耦合实证

module-bridge-roundtrip-r3.json 记录两次已签名目标执行，共 24 个已消费帧。目标静态链接 5B 的实际合成生产者与 当前 snapshot 的四份实际 graphics 源码，唯一依赖补充是从生产文件原样提取的错误枚举声明；没有模拟呈现实现。实际验证 IOSurface 导入、per-event timeline、GPU 完成后的幂等回执、resize 新池、旧帧生命周期与全量回收，并在 GPU 上对全部像素做等值比较；仅读取 4 字节比较统计，不读回像素。

此目标没有弹窗、不创建 VM、不捕获指针，该次验证的生产源码保持稳定。它验证 graphics 源码子集耦合，不能作为完整运行时二进制、NSWindow/CAMetalLayer、真实 Guest 或 HID 端到端证据。5B 当前正式声明 supports_real_guest_scanout=false、supports_signed_windows_vz_boot=false、supports_virtual_hid_sink=false；待其提供真实入口后才可进入相应验收。

复跑：`python3 handoff/phase-5/evidence/p5-c/run_module_bridge_roundtrip.py`。

## 已封版 snapshot 3 的历史接线实证

生产 snapshot 3 已封版，公开协议保持 revision 2，调用签名未改变。源码指纹和 12 份文件 SHA 见 production-interface-version-r3.json。原生窗口启动会将全屏请求排入主事件循环下一轮，并要求应用活动及窗口处于 key；关闭会取消待处理请求。调用方应观察实际进入事件，不依赖同步调用后样式立即改变。

runtime-binary-roundtrip-r3.json 已静态链接完整生产运行时与实际合成 producer，执行两次、24 帧，18 项检查全部通过，包含 GPU 逐像素等值比较。native-fullscreen-probe-r3.json 通过标准 App 启动完成两次真实 NSWindow/CAMetalLayer 全屏，24 帧，每次 32 项检查通过，包含 resize、自动关闭、待处理请求取消和缺少 HID 时拒绝捕获。修复前的第二轮进入失败记录已保留。

两个目标均保持 origin=host_synthetic_not_guest_scanout，真实 Guest 和 HID 状态为 false；原生 fullscreen drawable 未读回像素。当前接口可用于明确的本机诊断，真实游戏入口仍要求实际 Guest 帧源和合法 HID。

## 当前候选与验证状态

署名：@DNPMBHC。

当前选择由 production-validation-selection.json 指向 production-interface-version-candidate4.json：snapshot 4、iteration 5、19 份生产文件，契约 revision 2。历史 snapshot 3 的发行证据单独保留。候选本地 SwiftPM 252 项（242 通过、10 项既有显式跳过、0 失败），全仓 Strict SwiftLint 0 违规，严格格式、format_check、防外挂审计与租约反例门禁通过。

runtime-binary-roundtrip.json 已重新绑定当前完整生产运行时，两轮 24 帧 GPU 逐像素比较、resize、共享事件及幂等释放通过；来源仍为宿主合成。native-fullscreen-probe.json 已独立复跑当前候选，两轮 24 帧，实际全屏转换、resize、自动关闭与缺少 HID 时拒绝捕获均通过。原生 drawable 未读回像素，来源仍为宿主合成。

本轮运行时修复了重复覆盖正在运行的 helper 所致的 EXE 共享冲突：仅在 Guest SHA256 不匹配时上传，初次安装后回读。每次状态和取消查询另外验证独立随机 nonce、owner 和根 request ID，拒绝同会话的陈旧 Running 响应。相关回归测试已纳入 252 项。

C 自有克隆已独立取得 WHQL 3D、硬件适配器 FL 11_1、Session 1、根退出码 0 和 AdapterRAM=0。标准缩放控件已发现，极简优化与安全不变量通过。上述较早实证保留各自源码绑定；需要本轮绑定的验收仍须复跑。游戏是否检查 AdapterRAM 为 unknown。

实际 Guest 枚举 23 个显示模式，未提供宿主 3024×1964，也未提供 2560×1600 或 2560×1440。原生尺寸在 60/120 Hz 的 CDS_TEST 均失败，未应用显示更改。三档真实生命周期、DPI 150% 往返仍未通过；supported-lifecycle 最新在取消树时失败，该次 baselineRestored=false；已有恢复日志来自前次实测，最新状态须独立回读。UI 必须显示实际结果和 unsupported/failed 状态，禁止把宿主策略计算当作 Guest 已切换成功。

真实 Windows scanout、签名 Windows VZ boot 和合法相对 HID 的完整链路仍缺实证；这些能力缺失时应拒绝真实游戏壳入口与鼠标捕获。EFI 诊断与宿主合成 IOSurface 不能代替 Windows 游戏帧。

官方安装器已在 C 自有只读光盘内完成独立验签并由 Session 1 启动；游戏盘为外部 APFS 独立副本。本轮未完成官方安装、未登录或运行 target-cn，尚未取得精确弹窗、完整脱敏截图、实际游戏退出码及大厅/训练场状态。按用户最新指示，这些真实联调延期到下一阶段，当前登录等待已撤销。自有克隆清理与主源、原备份独立 SHA/size/mtime 复核见 own-cleanup-proof.json；本轮收尾状态与完整任务验收分别记录在 phase-closeout.json 和 acceptance-matrix.json。

本提案只落盘供后续读取，不发送跨窗口工作汇报。当前候选与完整验收状态以 acceptance-matrix.json 为准。
