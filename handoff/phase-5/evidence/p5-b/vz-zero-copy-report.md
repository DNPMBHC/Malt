# module-x：原生 VZ 与同进程 IOSurface 桥接实测

日期：2026-11-24  
署名：@DNPMBHC

## 交付结果与验收边界

本窗口已交付可重建、自动重启、独立静态链接的原生宿主原型。真实独立 ARM64 EFI Guest 回读 VirtIO-GPU modern PCI，完成 controlq/cursorq 协商，向共享 BAR 写入 2048 条绘制命令。宿主直接使用同一 VZ/Metal buffer，1280×720 和 2560×1440 整帧均与独立参考 SHA-256 相同。IOSurface 强引用、timeline 和 GPU 完成后租约回执经独立消费者与本地消费子集实测。

完整任务验收仍为未完成。物理共享内存提交最大值未建立；同负载真实 QEMU 对照未运行；原生 Windows/vTPM/Secure Boot 联合启动、完整 WDDM/Venus/Neptune 绘制及真实 Windows 应用 scanout 未通过；没有合法相对 HID sink。本窗口缓存清理与全仓零大文件分别记录，锁外文件不得代删。

| 任务 | 实际完成并验证 | 未通过部分 |
| --- | --- | --- |
| B1 | PCI、双队列、真实 validate、EFI 协商/共享写入、对齐负例、HR/权限矩阵、live 孔径映射阶梯与复跑 | 物理提交最大值；原生 Windows WHQL 驱动实际协商 |
| B2 | 2048 Draw Metal 4、同一 VZ/Metal 命令内存、IOSurface/CAMetalLayer、三路 900 帧基准、FFI 边界评估、重启闭环 | 同负载真实 QEMU 对照；正常 HR 可发布 renderer；真实 Venus/Neptune 应用绘制 |
| B3 | 可调用 producer 与 EFI 租约入口、呈现契约、本地 GPU 消费回归、Phase 6 模块/工时/风险施工图 | 连续 Windows 应用会话、typed scanout 与合法 HID 的生产入口 |

五维口径：原型代码已实现；宿主合成验证通过；真实 EFI Guest 诊断通过；Windows/游戏平台厂商支持未知；真实 Windows 游戏验证未执行。

## B1：PCI、队列、容量与权限

宿主 macOS 27.2.1、ARM64，SDK 27.0、Swift 6.4，RAM 16 GiB，宿主页 16384 字节。版本与 SDK 头文件哈希见 sdk-api-evidence.json。VZ 配置中的 deviceID 是 VirtIO 类型 16，实际 EFI Guest PCI 回读为 vendor 0x1AF4、device 0x1050、class 0x03、subclass 0x80；queueCount=2、shared region ID=1、BAR=4。FEATURES_OK 阶段状态回读 11，DRIVER_OK 后回读 15；controlq/cursorq 实际通知和回执通过。

两档 EFI 报告使用 256 MiB 孔径，命令映射 147456 字节；Guest 写入 2048 个 16 字节 draw payload。宿主没有把命令另拷到 GPU buffer。邮箱 magic、count、offset 和完成标记构成单帧诊断握手，尚不是完整生产 3D 协议。

29 个隔离配置用例接受到 UInt64.max，包括非页对齐配置长度。新增 14 个独立原生进程实际执行 validate → EFI start → 全孔径 lazy map/unmap → Guest 状态检查/stop：映射接受至 32 TiB；64 TiB 返回 VZErrorDomain:10，SDK 定义为 VZErrorNotSupported。4/8/32/64 TiB 各再复跑两次，32 TiB 均映射成功，64 TiB 均失败。没有触碰全部物理页，不能将该结果解释为 RAM 上限。

本轮主阶梯 16/32 TiB 的无磁盘 EFI 夹具在最终状态采样前已自然停止；8 TiB 本轮与两次复跑仍为 running，32 TiB 仍已自然停止。此前 8 TiB 曾自然停止的原记录保留。该状态受执行时序影响，没有建立持续运行硬上限。主阶梯“最终状态仍 running 的最大通过孔径”是 8 TiB，仅是本次采样值。64 TiB 的部分诊断进入 state=error，保留 Guest VZErrorDomain:1；canStop 不可用时跳过 stop，不追加次级无效状态错误，guestStopped 不标为成功。新增终止状态回归通过。旧首轮未区分自然停机，把重复 stop 的结果误记为 LiveCapacityStop；live-capacity-first-pass.json 保留原始失败，修正后的记录不以其宣称内存上限。

live-shared-memory-capacity-boundary.json 保留每个请求的 validate/create/start、映射、Guest 状态、自然停止与错误阶段；live-capacity-repeat-verification.json 保存复跑；live-capacity-sdk-status.json 固定错误/状态定义和 SDK 头文件 SHA。live CLI 在创建 VM 前拒绝小于宿主页或超过 64 TiB 的请求，UInt64.max 负例通过。

实际 mapMemory 的指针、offset、length 都须按 16 KiB 对齐。不对齐用例返回 VZErrorDomain:10；越界用例在隔离进程抛 NSInvalidArgumentException。EFI 入口提前拒绝非法尺寸或小于命令映射的孔径。配置 validate 接受非对齐大小不能外推为 mapMemory 接受。

HR + 常规 com.apple.security.virtualization 的 validate 和 EFI start/stop 均通过。无该 entitlement 的 runtime 失败 VZErrorDomain:2。Secure Boot 默认数据库导入、开启、持久化回读通过，KEK/db/dbx 各一项；绘制 EFI 夹具未纳入信任数据库，不能合并成开启 Secure Boot 的 Windows 启动证明。本机公共 SDK 未发现原生 vTPM API，该结论限于已检查 SDK。

## B2：Metal、呈现与 renderer FFI

Metal 4 实际编码 2048 次 draw，使用 MTLSharedEvent 的 GPU 完成边界计时；末帧完整哈希和 payload 改变后的图像变化验证通过。诊断读回在主基准逐帧计时路径之外。IOSurface 作为共享 MTLTexture backing，上屏没有 CPU 像素拷贝；写入 compositor drawable 仍有一次 GPU 全屏 pass。

两档 CAMetalLayer 探针各提交 30 帧，实际观察到 28/28 个 presented 回调。presentedTime=0，未报告物理面板扫描时间或端到端显示延迟。主性能基准不包含 VM start、真实 Guest 提交或 WindowServer compositor，呈现与 EFI 链路分别取证。

C FFI callbacks v4=72 字节、blob args=48 字节，静态断言通过。macOS 分支头文件固定于提交 71a67414013f120c158729da7f56f29b55bf4f6c；头文件 SHA 为 724308b1d66940c78bba64bd4e8b0c0eb9a0d7e00995fbd0d677183c38ecef15。现成本地库源码提交尚未证实。flags=192（Venus+NoVirgl），未启用 render-server。

正常 HR 加载现成依赖被 library validation 拒绝；临时 ad-hoc 与本地身份重签副本诊断也未解决，原应用 component 哈希保持不变。独立非 HR 诊断解析 16/16 符号、init=0、Venus capset=160 字节、GUEST blob create=0；context=22、map/export=-22。没有提交 Venus/Neptune 绘制或导出 IOSurface，不能由此推断所有 typed image 均无法互操作。

最小生产嵌入边界包括固定源码/依赖，自有静态或一致签名构建，专属 renderer 线程，完整 decoder/context/fence，资源配额与 typed scanout。任意 mapped pointer 或 FD 都不能当成 IOSurface；必须核验真实 backing、格式与两侧 GPU 生命周期。

## 2048 Draw 三路性能

每档每模式三轮，每轮 60 帧预热 + 300 测量帧，最大在途 1；native/control/copy 顺序逐轮轮换。每模式合并 900 测量帧，P99 采用 nearest-rank；CPU 合计客户端和 worker 的 user+system，以 CPU ms/frame 及单核百分比分别报告。末帧完整 SHA 相同；保留全部逐帧时序与负差额。

| 分辨率 | 路径 | Mean ms | P99 ms | CPU ms/frame | 单核 CPU % |
| --- | --- | --- | --- | --- | --- |
| 1280×720 | socket 命令与整帧复制 | 2.2902 | 2.9680 | 1.9634 | 85.73 |
| 1280×720 | socket 命令与 ACK | 0.4979 | 2.0859 | 0.1849 | 37.13 |
| 1280×720 | 同进程 Metal 4 | 0.4583 | 2.0525 | 0.1586 | 34.60 |
| 2560×1440 | socket 命令与整帧复制 | 8.5540 | 12.6545 | 8.3894 | 98.07 |
| 2560×1440 | socket 命令与 ACK | 0.6034 | 2.0445 | 0.1978 | 32.78 |
| 2560×1440 | 同进程 Metal 4 | 0.5545 | 2.0405 | 0.1689 | 30.45 |

1280×720：相对整帧复制路径，平均延迟差额 +1.8319 ms，CPU 差额 +1.8048 ms/frame；相对命令/ACK 路径，延迟差额 +0.0396 ms，CPU 差额 +0.0263 ms/frame。正号代表同进程较低，负号代表同进程较高。

2560×1440：相对整帧复制路径，平均延迟差额 +7.9996 ms，CPU 差额 +8.2205 ms/frame；相对命令/ACK 路径，延迟差额 +0.0489 ms，CPU 差额 +0.0289 ms/frame。正号代表同进程较低，负号代表同进程较高。

最终两档同进程相对命令/ACK 的平均差额仅约 40/49 微秒。终止状态修复前那轮 1440p 差额为 -0.1406 ms，P99 也更高；其完整原始数据保留于 historical-before-terminal-state-fix-vz-zero-copy-benchmark.json。后续重新测量是为了绑定容量生命周期修复后的二进制，renderer 负载没有修改；这些记录的符号变化不支持稳定的纯 IPC 优势结论，不能只选正差额。

整帧复制基线包含读回、socket 传输与客户端复制；命令/ACK 基线在 worker 核验像素，客户端没有收到图像。真实旧后端可能已经共享像素，因此上述差额不等于移除 QEMU 的收益。real_qemu_comparison=false，未拿其它负载 FPS/P99 相除。

## B3：可调用租约与施工图

连续宿主合成源为 SurfaceFrameProducer，origin=host_synthetic_not_guest_scanout。EFIGuestProbe.run(disk:width:height:sharedMemoryBytes:onFrame:) 输出单帧 EFIGuestSurfaceLease：真实 IOSurface、MTLSharedEvent/readyValue、尺寸、stride、origin 与线程安全幂等 release；来源固定为 uefi_diagnostic_guest_commands_not_Windows_application_scanout。它同步在后台调用，停止自己的 VM 后发布，不能当作连续 Windows scanout。

两档 EFI 原型各 17 项检查通过；独立静态消费者 10 项通过；本地实际图形子集两档各两次 capture 共四帧，每帧 16 项检查通过。后者在 GPU 比较全部像素，仅回读 4 字节统计；没有创建可见窗口、Windows 会话或指针捕获。写入 timeline 完成后发布，消费者 GPU 完成前强引用保留 surface，旧帧不覆盖，回执幂等。

interface-proposal.md 给出字段、调用、来源、背压、resize、停机与租约规则。本窗口没有真实 Windows scanout、signed Windows VZ boot 或合法相对 HID sink，三个生产能力标志保持 false；EFI 诊断命令/租约能力为 true。

phase-6-construction-plan.md 拆解 Windows ARM64 UEFI、vTPM/Secure Boot、基础签名设备、完整 VirtIO-GPU/WDDM/Venus、typed scanout、应用关联/输入和真实对照。估算 24–42 人周包括 vTPM 可行性调查，排除未知实现工期，另加集成余量；平台门禁未通过不能承诺日历交付。

## 质量与证据绑定

221 项全部 unittest 通过；防外挂自检 6 反例通过，扫描 127 份生产源码。25 份 Swift 最大 261 行，Strict SwiftLint 0 违规，无新增豁免。宿主完成重建、停止旧 owned 实例与自动重启；readiness 与当前二进制绑定通过。

本轮二进制 SHA-256：`ba2880814ac11ee4f213c5d8209e24b0a77f14aaf51c46c6753d41afe837de59`。本轮基准 SHA-256：`5b5c1b7a03838147819e378267f08e311a1d786e672f3a47ceebc1d9bd908517`。final-binding-verification.json 核对源码、entitlement、二进制、EFI 夹具、静态库、消费源码、配置/live 容量、测试日志、重启和基准。evidence-manifest.json 封存源文件与证据，cleanup-verification.json 单列锁内清理与全仓统计。

已保存改动前的基准、绑定、报告及错误记录；historical 文件保持原范围与哈希，不作为当前源码实测。最早一轮 raw series 未归档，只保留旧报告及摘要哈希，historical-measurement-provenance.json 如实记录；不由均值重造原始数据。

## 复跑顺序

```sh
python3 -B graphics-lab/vz_gpu_bench_runner.py restart
python3 -B -m unittest discover -s graphics-lab -v
python3 -B graphics-lab/vz_gpu_bench_runner.py diagnostics
python3 -B graphics-lab/vz_gpu_bench_efi.py
python3 -B graphics-lab/vz_gpu_bench_efi.py --width 2560 --height 1440
python3 -B graphics-lab/vz_gpu_bench_efi.py --external-consumer
python3 -B graphics-lab/vz_gpu_bench_c_efi.py
python3 -B graphics-lab/vz_gpu_bench_memory_limits.py
python3 -B graphics-lab/vz_gpu_bench_live_memory_limits.py --repeat-boundary
python3 -B graphics-lab/vz_gpu_bench_runner.py bench --rounds 3 --frames 300 --warmup 60
python3 -B graphics-lab/vz_gpu_bench_finalize.py verify
python3 -B graphics-lab/vz_gpu_bench_finalize.py quality
```

复跑时另执行防外挂脚本 --self-test，并更新测试/审计日志。基准须在诊断和库绑定更新后运行。确认没有其它进程使用自有临时构建后执行 finalize cleanup，报告/状态完成后执行 finalize seal；seal 后不再改纳入清单的文件。本窗口只清理自己锁内和自有临时产物。

最终清理实测：本窗口实验进程已停止，自有仓库外构建目录和锁内 build/.build/PCM 已移除；锁内 >5 MiB 文件 0 个、PCM 0 个。全仓锁外仍有 184 个 >5 MiB 文件、1335 个 PCM；文件锁禁止代删，因此全仓零残留门禁未通过。完整任务验收保持未完成。
