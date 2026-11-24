# 窗口 5B → 5C / 5D：surface 租约与接线契约（revision 1）

日期：2026-11-24  
署名：@DNPMBHC

## 可以接什么

当前提供可直接调用的 `SurfaceFrameProducer`，数据源是宿主 timer 驱动的合成 Metal 4 场景，固定标识为 `host_synthetic_not_guest_scanout`。它输出真实 IOSurface、真实完成事件和真实 GPU 渲染结果，但没有真实 Windows 应用扫描帧入口，也没有合法的 Guest 相对虚拟 HID sink。请仅接入诊断，不开放真实游戏启动或鼠标捕获。

先前只读核验的 5C 公开协议为 revision 2、生产 snapshot 3；当时 12 份源码 SHA-256 全部匹配，历史生产指纹为 `92b9e84f39bee09227c033e6bd9d0ce2a11dafeb63b5183d442c073af2d7db0d`。本窗口没有修改消费者或主 App。

## 可实际调用的入口

运行 `python3 -B graphics-lab/vz_gpu_bench_library.py` 会在仓库外重建 `ModuleX` 静态 Swift 库，编译独立消费者目标，使用 Hardened Runtime 与常规 virtualization entitlement 签名并执行。五项入口检查已通过；源码、库和消费者哈希保存在 `producer-library-binding.json`。它采用同进程静态链接，适合由 5D 添加正式 target，当前没有修改主工程依赖。静态库导出渲染生产者及下述 EFI 诊断入口，不包含 Windows Guest provider 或完整 WDDM/Venus 设备后端。

公开调用为 `SurfaceFrameProducer(width:height:draws:refreshRateMilliHz:)`、`start(onFrame:)`、`stop(completion:)`、`resize(width:height:completion:)` 与 `snapshot()`。回调运行在生产者专属串行队列，不能在回调内阻塞等待停机完成。Swift 的跨线程声明以串行状态隔离和释放锁为依据；IOSurface 的 GPU 使用仍由下面的租约规则约束。

```swift
import ModuleX
import IOSurface

let producer = try SurfaceFrameProducer(width: 1280, height: 720)
let push = GuestSurfacePushFrameSource(backend: .syntheticTest)
// 调用方先 await push.start(onFrame: consumer)，再启动 producer。
producer.start { lease in
    let metadata = lease.metadata
    let frame = GuestSurfaceFrame(
        descriptor: GuestSurfaceFrameDescriptor(
            frameID: metadata.frameID,
            width: metadata.width,
            height: metadata.height,
            pixelFormat: .bgra8Unorm,
            ioSurfaceID: IOSurfaceGetID(lease.surface),
            sharedEventSignaledValue: metadata.readyValue,
            backend: .syntheticTest
        ),
        surface: lease.surface,
        sharedEvent: lease.readyEvent,
        onRelease: { lease.release() }
    )
    push.publish(frame)
}
// 停止时先 await push.stop()，再 await 包装 producer.stop(completion:)。
```

上例是字段映射示例；独立目标入口、完整运行时消费和原生全屏的宿主合成联调均已有实证，详见下面的分项记录。以后只有在真实 Guest scanout、驱动协商和应用关联均通过后，才能把后端标为 `.vzZeroCopyIOSurface`。

## 字段与生命周期

| 生产者字段 | 消费者用途 | 规则 |
| --- | --- | --- |
| `surface: IOSurfaceRef` | 直接创建共享 MTLTexture | 传递强引用；ID 用于校验，不能替代对象租约 |
| `metadata.frameID` | descriptor.frameID | 本生产者实例内递增，restart 不倒退 |
| `metadata.generation` | resize 代次 | resize 成功后增加；当前消费者 descriptor 无该字段，适配层需保留 |
| `width / height / bytesPerRow` | 尺寸与 stride 校验 | 必须与实际 IOSurface 一致，stride 不可简单假定 width×4 |
| `pixelFormat / colorSpace / alphaMode` | 呈现配置 | 当前仅 BGRA8Unorm、linear-sRGB、opaque；不支持 HDR |
| `readyEvent / readyValue` | GPU 等待栅栏 | 同一个事件对象内 timeline 单调；不能用全局 frameID 替代 |
| `refreshRateMilliHz` | 请求的提交节奏 | 默认 120000，属于 timer 请求频率，不代表实际面板刷新率或已达 FPS |
| `origin` | 支持状态与门禁 | 当前固定宿主合成帧，不能作为真实 Guest 证据 |
| `release()` | 消费回执 | 线程安全且幂等，第一次 true，重复 false |

每一帧占用三槽池中的一槽，未收到释放回执前不得重绘或回收该槽。消费者应在 GPU 读取完成回调中释放，拒收、排队丢帧与停止也应回执。生产者先等到自己的 GPU ready 事件达标，再发布，因此收到回执时写入也已完成。池满时丢弃新生产机会，不能覆盖旧帧。

resize 创建新池并增加 generation；旧租约闭包保持旧 renderer、surface 和事件，直到调用方完成释放。应合并连续 resize，避免消费者长期不回执导致多个旧池保留。未释放而直接遗失租约不会使生产者提前复用 surface；这会耗尽池，属于调用方故障。

正常 stop 在串行队列上关闭 timer 与回调，不等待所有外部租约释放。当前 render 的 GPU 等待上限为 10 秒；调用方应以 12 秒 watchdog 记录超时，且不要在主线程同步等待。编译、系统驱动或外部回调阻塞仍需 Phase 6 取消机制处理，不能宣称任意系统故障下已经满足严格停机 SLA。

已运行的 `producer-probe.json` 覆盖 14 项：三槽背压、真实布局、timeline、GPU 完成回执、幂等释放、resize、旧帧保留、未覆盖、全量回收与复用，全部通过。

## 相对输入与真实 Guest 支持边界

当前没有 `GuestRelativePointerSink` 实现。5C 应保持输入入口 unavailable，不能锁住用户光标，也不能以 QGA、全局宏、进程注入替代。Phase 6 需要公开 VZ 输入 API 对 Windows 驱动实际支持的相对 HID 设备、合法事件队列、聚焦门禁与退出释放回执。

原无磁盘 VZ 映射探针仍为 `driverNegotiated=false`；新增带独立 FAT 磁盘的 EFI Guest 夹具已完成真实队列协商。没有启动 Windows，没有 WDDM/Venus/Neptune 解析，没有 Guest scanout 资源绑定，没有真实应用/窗口关联。这些缺口及 vTPM 阻塞详见 `phase-6-construction-plan.md`。

## 跨窗口 GPU 接线追加实证（2026-11-24）

5C 已静态链接本窗口生产者与 revision 2 的实际 graphics 源码，执行两轮，各消费 12 帧，共 24 帧。每轮 18 项检查全部通过：同一 IOSurface、生产 timeline、GPU 读取完成后释放、幂等回执、resize、像素逐字节等值及全量租约回收。图像比较在 GPU 上完成，仅回读 4 字节比较统计，不回读源像素。

本窗口只读核验了该报告的全部生产者与消费者源码 SHA-256，均与当前文件匹配。原始实证副本在 `cross-window-gpu-roundtrip.json`，接收核验及来源哈希在 `cross-window-gpu-receipt.json`；运行由 5C 执行，本窗口没有重复构建或修改生产者。

这是合成源到实际 graphics 消费者的同进程 GPU 往返，不包含 VM、可见窗口、原生全屏或指针捕获。真实 Guest scanout、signed Windows VZ boot 和 HID 支持状态仍为 false。完整游戏会话与平台验收仍未完成。

## 当前可执行接线条件（2026-11-24 更新）

公开调用签名保持 producer revision 1 / consumer revision 2，消费者生产快照为 snapshot 3。`cross-window-runtime-roundtrip.json` 是完整运行时静态产物与当前生产者的两轮实证副本：共 24 帧，每轮 18 项检查通过，GPU 对全部像素做等值比较，只回读 4 字节统计。`cross-window-native-fullscreen.json` 是同一运行时的真实 NSWindow/CAMetalLayer 全屏两轮实证副本：共 24 帧，每轮 32 项检查通过。后者没有读取 drawable 像素，不以进入全屏代替像素比较。

本窗口核对了两份报告各自的 8 份生产者源码 SHA 与消费者 snapshot 3 的 12 份生产源码 SHA，均匹配。来源哈希和核验方式见 `cross-window-current-readiness.json`。这些执行由 5C 完成；本次更新只读取证据，没有执行 VM、捕获光标或改动消费者。

5C 新增的预启动 Guest 显示/生命周期探针仅完成 build-only 验证：编译通过、执行开关关闭、VM 动作为零、冷启动未验证。它不是 Windows VZ provider，也没有补齐真实帧源或相对 HID。

真实游戏接线须同时满足以下条件；当前全部尚未交付：

1. 原生 Windows provider 完成实际启动，提供 Guest PCI 枚举、WHQL 驱动加载与 WDDM/Venus/Neptune 协商证据，明确固件、Secure Boot 和 vTPM 支持边界。
2. 扫描输出绑定实际 Guest 资源和目标应用，帧来源标识来自已验证资源；写入完成后发布 ready timeline，在消费者 GPU 完成回执前保留 IOSurface 与旧 resize 代次资源。
3. 合法相对虚拟 HID sink 提供非阻塞 `submit`，限定当前聚焦窗口，传输失败停止捕获，并验证失焦、退出和窗口关闭后的释放回执。当前没有可调用 sink；QGA、全局宏和注入不构成该接口。
4. 在合法隔离的实际 Guest 会话中完成扫描输出、分辨率回读、应用退出及恢复的端到端验证。消费者 build-only 或宿主合成全屏不能替代该验证。

当前 `supports_real_guest_scanout`、`supports_signed_windows_vz_boot`、`supports_virtual_hid_sink` 均保持 false。`.syntheticTest` 可用于本机诊断；真实游戏启动与鼠标捕获继续受上述条件约束。Phase 6 的 renderer 加载、协议实现、Windows 平台与物理共享内存上限缺口仍见 `phase-6-construction-plan.md`。

上节属于先前 snapshot 3 的只读协调记录；本轮已经重建并重新执行性能与 EFI 实验，当前源码/二进制绑定和清理状态以 final-binding-verification.json、cleanup-verification.json 和 evidence-manifest.json 为准。旧测量保留原有来源与哈希，不认作本轮数据。

## EFI Guest 诊断租约入口（supplementary revision 1）

日期：2026-11-24；署名：@DNPMBHC。既有 `SurfaceFrameProducer` 的 producer revision 1 与公开字段不变；它仍是宿主合成 timer 源。以下是新增的独立诊断入口，不改变 Windows 支持声明。

`ModuleX.EFIGuestProbe.run(disk:width:height:sharedMemoryBytes:onFrame:) throws -> EFIGuestProbeReport` 现已加入静态库构建源清单。`disk` 必须是调用方自有的可丢弃 EFI 诊断 FAT 镜像，由 `vz_gpu_bench_efi.py` 编译并写入；不能传入共享 Windows VM 磁盘。入口同步运行，应在专属后台工作队列调用。它启动独立原生 VZ，完成 EFI PCI/双队列协商、共享命令写入和 GPU 渲染，停止该夹具后至多发布一份不可重绘的租约。

`onFrame` 收到 `EFIGuestSurfaceLease`，提供 `surface: IOSurfaceRef`、`readyEvent: MTLSharedEvent`、`readyValue: UInt64`、`width`、`height`、`bytesPerRow`、`origin` 和线程安全幂等的 `release() -> Bool`。消费者导入同一 IOSurface，等待 ready timeline，完成 GPU 读取后调用 release；强引用持有 surface、事件及渲染资源。该入口每次创建自己的 surface，发布后不覆盖它。消费者应自行分配 start 会话内递增的 frameID，不能把来自不同事件的 readyValue 当成全局序号。

固定 origin 为 `uefi_diagnostic_guest_commands_not_Windows_application_scanout`。EFI Guest 实际产生 2048 条 draw 数据，写入 Guest 枚举的共享 BAR；宿主直接把同一 VZ 映射/MTLBuffer 命令槽交给 Metal 4。两档分辨率整帧 SHA 与独立参考一致，证据为 `efi-guest-1280.json` 和 `efi-guest-2560.json`。EFI PCI I/O 包装接口返回 EFI_UNSUPPORTED 的失败保留在相应旧记录；已分配 BAR 的直接标准 MMIO 访问通过。

该帧不是 Windows 应用扫描输出，也没有 WDDM/Venus/Neptune 应用链路；当前没有连续 Windows 会话 provider、目标应用关联或合法相对 HID sink。5C 可增加明确标识来源的诊断互操作实证，不能据此开放真实游戏或捕获光标。`supports_real_guest_scanout`、`supports_signed_windows_vz_boot`、`supports_virtual_hid_sink` 均继续为 false。

独立静态链接消费者已实际运行并通过 10 项检查，包含 Guest 2048 命令、来源标识、整帧参考匹配、同一 IOSurface 导入、共享 timeline、GPU 读取完成后释放及幂等回执，结果见 `efi-guest-external-consumer.json`；生产入口和来源声明写入 `efi-diagnostic-interface.json`。该实证不能替代 5C 自己对当前生产快照的消费者/原生全屏重验。

## 本轮实际 5C 图形消费者对接

本窗口读取 5C 公开协议 revision 2、candidate snapshot 4 的实际图形源码，静态编译图形子集和从原源码提取的精确错误枚举；没有调用会写入 5C 路径的脚本，也没有修改消费者。`python3 -B graphics-lab/vz_gpu_bench_c_efi.py` 可复跑两档各两次独立 EFI capture，共四帧。每次 16 项检查通过，包含 push 接受、同一 IOSurface、写入 timeline、GPU 对整帧逐像素等值比较、仅回读 4 字节统计、GPU 完成后释放及幂等回执，明细为 `efi-downstream-consumer-roundtrip.json`。

这是实际 EFI 数据与实际 5C 图形子集的联调；没有编译完整生产运行时，没有创建可见窗口，没有原生全屏、Windows 会话、应用关联或 HID。适配器用 `.unavailable` 表示生产游戏入口关闭；真实 EFI origin 单独随诊断记录保留，不能改成宿主合成或 Windows 应用扫描帧。candidate snapshot 的冻结状态以来源清单为准，不能用本窗口子集编译证明 5C 已完成生产封版。

输入前置检查拒绝越界尺寸以及小于实际命令映射长度的共享孔径，错误为 `EFIGuestBounds`，在 VM 创建前返回。单次 capture 仅发布一帧；调用方承担后台执行、时间预算和自己的可丢弃镜像生命周期。帧中的 IOSurface 与事件强引用持续有效，release 后该独立 surface 不会重新用于下一次 capture；生产者不会在消费者 GPU 读取前覆盖它。

三个生产能力标记仍为 false；本轮新增的 true 能力是 `supports_efi_diagnostic_guest_commands` 与 `supports_efi_diagnostic_surface_lease`。来源、可调用入口、证据 SHA 与消费者子集版本在 `efi-diagnostic-interface.json`。

## 最新接线确认：5C candidate snapshot 4

日期：2026-11-24；署名：@DNPMBHC。已只读核验当前公开协议 revision 2、candidate snapshot 4，生产指纹 `0b566ec936c95093f998e4a7dd72a03e30a5ac6c785f383c8b7c085f4b96f0ed`，16 份来源源码 SHA 全部匹配；该候选尚未冻结供生产打包。最新完整运行时 GPU 与原生全屏报告各两轮共 24 帧，通过项分别为每轮 18/32 项，来源仍为宿主合成，两个报告中的 8 份 B 生产者源码 SHA 与当前一致。副本和核验方式见 cross-window-current-readiness-r4.json；B 未重复执行这些报告，也没有控制 C 的克隆。

5B 当前三个生产能力标志仍为 false：真实 Windows 应用 scanout、signed Windows VZ boot、合法虚拟 HID 相对输入均没有新的可调用实现或通过证据。当前实际可调用入口只有既有宿主合成 SurfaceFrameProducer 和新增单帧 EFI 诊断 EFIGuestProbe；后者保留 uefi_diagnostic_guest_commands_not_Windows_application_scanout 来源、真实 surface/timeline 和幂等租约释放，但没有连续 Windows 应用关联。C 已具备自己的测试克隆条件，不会自动补齐 B 的原生 VZ 平台或 renderer 接口。

最小后续施工顺序是原生 Windows/vTPM/Secure Boot 平台门禁 → 未修改 WHQL 驱动与完整 WDDM/Venus/Neptune 协商 → typed application scanout/IOSurface 双方 fence 与旧资源保留 → 合法、限定聚焦状态的相对虚拟 HID 队列和退出回执。阻塞期间真实游戏入口与光标捕获继续关闭；EFI 诊断和合成完整运行时可继续分别验证，来源不可互换。B 保留代码封存与缓存清理，本次仅更新接口支持边界与跨窗口证据清单。
