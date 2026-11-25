# module-x：IOSurface 帧呈现契约

日期：2026-11-24  
署名：@DNPMBHC  
公开 producer 契约 revision 1；EFI 诊断补充入口 revision 1。

## 可调用入口与来源

`SurfaceFrameProducer(width:height:draws:refreshRateMilliHz:)` 提供 `start(onFrame:)`、`stop(completion:)`、`resize(width:height:completion:)` 和 `snapshot()`。来源固定为 `host_synthetic_not_guest_scanout`：宿主 timer 驱动的 Metal 4 诊断场景，不能据此声明真实 Windows 应用帧。

`ModuleX.EFIGuestProbe.run(disk:width:height:sharedMemoryBytes:onFrame:) throws -> EFIGuestProbeReport` 是真实独立 ARM64 EFI Guest 的单帧诊断入口。它由 Guest PCI 枚举、双队列协商及共享 BAR 写入产生 2048 条命令，宿主以同一 VZ/Metal buffer 渲染。来源固定为 `uefi_diagnostic_guest_commands_not_Windows_application_scanout`。该调用同步执行，应在专属后台队列调用；先停止本次独立 VM，再至多发布一帧 `EFIGuestSurfaceLease`。

`disk` 必须是调用方自有、可丢弃的 EFI FAT 夹具。不能传入共享 Windows VM 磁盘。尺寸和共享孔径在创建 VM 前预检，越界返回 `EFIGuestBounds`。当前命令映射长度为 147456 字节，实际值应以运行时报告为准。

`python3 -B graphics-lab/vz_gpu_bench_library.py` 在仓库外构建 `ModuleX` 同进程静态库和独立消费者。源码、库和入口 smoke 的 SHA-256 见 `producer-library-binding.json`。未接入主工程 target，不包含连续 Windows provider 或完整 WDDM/Venus 后端。

## 字段映射

| 字段 | 含义与约束 |
| --- | --- |
| `surface: IOSurfaceRef` | 强引用真实对象；消费者通过该对象创建共享 MTLTexture |
| `IOSurfaceGetID(surface)` | 仅用于身份核对；不能替代对象与资源租约 |
| `width / height / bytesPerRow` | 必须与真实 IOSurface 布局一致；stride 不假定为 width×4 |
| `readyEvent: MTLSharedEvent` / `readyValue: UInt64` | 同一事件内 timeline 单调；GPU 写入完成后发布，消费者 GPU 等待该值 |
| `origin` | 必须保留合成来源或 EFI 诊断来源；不能改为 Windows scanout |
| `release() -> Bool` | 线程安全幂等；首次回执 true，重复 false |
| `metadata.frameID / generation` | 连续合成源帧号与 resize 代次；EFI 单次租约由会话适配层分配自己的 frameID |
| `refreshRateMilliHz` | 合成源 timer 请求节奏，默认 120000；不能当作面板刷新率或实测 FPS |
| `pixelFormat / colorSpace / alphaMode` | 当前 BGRA8Unorm、linear-sRGB、opaque；HDR 未支持 |

EFI 租约直接提供 surface、readyEvent、readyValue、width、height、bytesPerRow、origin 和 release。连续合成源中的其它字段通过 `metadata` 取得。不能把不同事件的 readyValue 合并成全局帧号。

## GPU 与资源生命周期

消费者校验尺寸、stride、格式和对象身份后，导入同一 IOSurface，编码 `encodeWaitForEvent`，提交 GPU 读取或呈现。GPU 完成回调后才 release。拒收、丢帧、停止也必须回执；未完成的 GPU 读取不能因窗口关闭而提前回收 backing。

连续合成源使用三槽池，收到回执前不覆盖槽。池满时跳过新生产机会，保持旧帧有效。resize 创建新池并增加 generation；旧租约强引用旧 renderer、surface 与事件，直到释放。调用方应合并 resize，避免不回执的旧池无限积累。

正常 stop 在串行队列上关闭 timer 和回调，不等待外部租约全部释放。回调内不能同步等 stop 完成。当前 GPU 写入等待上限 10 秒；后台调用方应使用 12 秒 watchdog 记录超时。此预算不保证编译、驱动故障或外部回调任意阻塞时的严格 SLA。

EFI 每次调用创建独立 surface；发布后不重绘，release 后也不用于下一次 capture。调用方负责后台执行、时间预算和自己镜像的生命周期。

## 本窗口实际验证

两档 EFI 诊断均回读 PCI `1AF4:1050`、Display class `03`、controlq/cursorq 和 VERSION_1/DRIVER_OK，完成 Guest 2048 命令写入。1280×720 与 2560×1440 整帧 SHA 与独立参考一致，分别记录于 `efi-guest-1280.json` 与 `efi-guest-2560.json`。

独立静态消费者验证实际 IOSurface 导入、timeline、GPU 完成后的释放及幂等回执，见 `efi-guest-external-consumer.json`。本窗口还有本地消费者图形子集回归，四次独立 EFI capture 的全部像素由 GPU 等值比较，仅回读 4 字节统计，见 `efi-downstream-consumer-roundtrip.json`。该子集回归没有创建可见窗口、没有 Windows 会话或指针捕获，不能替代生产游戏验收。

连续合成源的 `producer-probe.json` 验证三槽背压、真实布局、timeline、GPU 回执、resize、旧帧保留与回收。实际 CAMetalLayer 上屏由独立呈现探针验证；主性能计时不包含 compositor。

## 生产支持边界与最小接线条件

当前 `supports_real_guest_scanout`、`supports_signed_windows_vz_boot`、`supports_virtual_hid_sink` 全为 false；真实 EFI 诊断命令与单帧租约能力为 true。

真实应用呈现须先满足：受支持原生 Windows 引导及 vTPM/Secure Boot；未修改 WHQL 驱动与完整 WDDM/Venus/Neptune 协商；应用扫描资源的 typed IOSurface backing；写入与读取两侧 GPU fence、resize/reset 资源回收；目标应用关联。当前没有上述完整入口。

当前没有合法相对虚拟 HID sink。接收端应保持生产输入 unavailable，不捕获光标；不得用 QGA、全局宏或注入替代。未来输入接口须提供有界非阻塞提交、仅当前聚焦窗口路由、失败停止捕获及失焦/退出/关闭的释放回执，并由真实 Guest 输入栈验证。

实测源码、二进制与证据以 `final-binding-verification.json` 和 `evidence-manifest.json` 为准，平台与 renderer 具体缺口见 `phase-6-construction-plan.md`。历史接口文档保留原版本，不作为当前运行能力证明。
