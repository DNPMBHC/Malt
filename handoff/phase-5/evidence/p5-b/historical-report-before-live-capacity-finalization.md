# 窗口 5B：原生 VZ、真实 EFI 命令与同进程 IOSurface 桥接

日期：2026-11-24  
署名：@DNPMBHC

## 实测结论与完整验收状态

已实现可重建、自动重启、可由独立目标调用的原生宿主原型。独立 ARM64 EFI Guest 实际枚举 VirtIO-GPU modern PCI、完成双队列协商并写入 2048 条共享 BAR 命令；宿主直接让同一 MTLBuffer/共享内存供 Metal 4 消费，两档整帧与独立参考 SHA-256 完全一致。IOSurface 租约经独立消费者和 5C 当前图形源码子集真实读取，GPU 等值比较与完成后释放均通过。

任务书全部验收仍未完成：共享内存物理提交最大值未建立；没有与 5A 同负载的真实 QEMU 对照；没有 Windows/WDDM/Venus/Neptune 扫描输出、原生 Windows 引导与 vTPM 或合法相对 HID。锁外缓存也使全仓零大文件要求尚未满足。这些属于明确的剩余工程/平台/依赖条件，原型验证不能代替它们。

| 任务 | 已交付并验证 | 剩余要求 |
| --- | --- | --- |
| B1 | 标准配置、真实 validate、PCI 身份、controlq/cursorq、Guest VERSION_1/DRIVER_OK、共享 BAR 写入、映射对齐、HR/权限矩阵 | 物理共享内存最大值；Windows WHQL 驱动实际协商 |
| B2 | 2048 Draw 同进程 Metal 4、同一 VZ/Metal 命令内存、真实 IOSurface/CAMetalLayer、三路 900 帧基准、真实 FFI 边界、自动重启 | 同负载真实 QEMU 对照；正常 HR 下自有 renderer；真实 Venus/Neptune 绘制与 Windows scanout |
| B3 | 单帧 EFI 可调用入口、租约契约、5C 实际图形子集联调、带工时/门禁的 Phase 6 施工图 | 连续真实 Windows 游戏会话与合法 HID 尚无可运行接口 |

五维状态：原型代码已实现；宿主合成验证通过；真实 EFI Guest 诊断通过；Windows/游戏平台厂商支持未知；真实 Windows 游戏验证未执行。

## B1：PCI、队列与共享内存实证

宿主 macOS 27.2.1、ARM64，SDK 27.0、Swift 6.4，RAM 16 GiB，宿主页 16384 字节；版本和 SDK 头文件 SHA 见 sdk-api-evidence.json。

VZ 配置的 deviceID 是 VirtIO 类型 16。独立 EFI Guest 的实际 PCI 配置空间回读为 vendor=0x1AF4、device=0x1050、class=0x03、subclass=0x80，queueCount=2；共享 region ID=1，BAR=4。Guest 读取并协商 VERSION_1，FEATURES_OK 阶段状态回读 11，设置 DRIVER_OK 后状态回读 15，controlq/cursorq 通知和请求回执均成功。早期历史报告把 FEATURES_OK 采样值放在 finalDeviceStatus 字段；当前已拆分 featuresOkDeviceStatus/finalDeviceStatus，并有实际回读断言。

64 MiB 和 256 MiB 孔径的 EFI 实验均成功；最终两档记录使用 256 MiB，当前宿主映射的命令 MTLBuffer 长度为 147456 字节。Guest 写入约 32 KiB 的 2048 个 16 字节 draw payload，宿主不把该命令区另拷到 GPU buffer。邮箱 magic、draw count、slot offset 和完成标志构成当前单帧诊断握手，不是完整生产 VirtIO-GPU 3D 协议。

真实 validate 与 29 个隔离容量用例接受到 UInt64.max，也接受非页对齐的配置长度；runtime 映射阶梯到 16 GiB。孔径验证与未触碰全部页面的虚拟映射不代表物理 RAM 分配最大值。当前没有安全、已证实的物理提交上限，不能宣称上限是 16 GiB、1 TiB 或 UInt64.max。

实际 mapMemory 的指针、offset、length 都必须按 16 KiB 对齐；不对齐用例返回 VZErrorDomain:10，越界用例在隔离子进程抛 NSInvalidArgumentException。新增公开 EFI 入口在创建 VM 前拒绝超出范围的尺寸和小于实际命令映射长度的共享孔径，避免把可预检的输入交给异常路径。

保留了映射/协商失败过程：VM start 前映射返回 VZErrorDomain:3；标准 EFI PCI I/O Mem.Read 对共享 BAR 返回 EFI_UNSUPPORTED；改为读取已分配 BAR 基址并在 Guest 进行标准 volatile MMIO 与 dmb osh 后通过。Guest 使用标准固件控制器释放/独占流程，不伪造硬件或修改共享 VM。宿主在停止 VM 前解除映射，所有夹具使用自有可丢弃 FAT 镜像。

HR + 常规 com.apple.security.virtualization 能 validate 并实际启动/停止 EFI；缺少该 entitlement 时实际 runtime 失败 VZErrorDomain:2。Secure Boot 默认数据库导入、启用和持久化回读独立通过，KEK/db/dbx 各一项。EFI 绘制夹具没有签名入该数据库，两份实验不能合并成 Windows Secure Boot 启动证明。已安装公开 SDK 头文件未发现原生 vTPM API；该结论限于本机 SDK。

## B2：同进程 Metal、呈现与 renderer FFI

Metal 4 实际编码 2048 次 draw，以 MTLSharedEvent 的 GPU 完成作为计时边界。末帧完整图像 SHA 与 payload 变化测试通过；诊断回读不在主基准逐帧计时路径内。IOSurface 直接作为共享 MTLTexture backing，呈现没有 CPU 像素拷贝；写入 compositor drawable 仍有一次明确的 GPU 全屏 pass。

两档 CAMetalLayer 实验各提交 30 帧，最终观测到 26/25 个 presented 回调。presentedTime 为 0，所以不报告物理面板扫描时间或端到端显示延迟。主性能基准不包含 VM 启动、真实 Guest 提交或 WindowServer compositor；呈现和真实 EFI 链路分别取证。

C FFI callbacks v4=72 字节、blob args=48 字节，静态断言通过；头文件 SHA 与 macOS 分支提交 71a67414013f120c158729da7f56f29b55bf4f6c 固定。现成本地动态库的源码提交尚未证实。flags=192（Venus + NoVirgl），没有启用 render-server。

普通 HR 下现成依赖因 Team IDs/library validation 被拒绝；临时 ad-hoc 和本地身份重签副本诊断也未解决，原应用 component 哈希不变。在独立非 HR 诊断中 16/16 符号解析，renderer init=0，Venus capset=160 字节，GUEST blob create=0；context=22、map/export=-22。没有提交 Venus/Neptune 命令，也没有导出 IOSurface。该 blob 失败不能推断所有 typed image 无法互操作。

最小生产嵌入边界仍包括固定源码与同架构依赖、自有静态或一致签名构建、专属 renderer 线程、完整 decoder/context/fence、资源配额与 typed scanout。任意 mapped pointer/FD 不能当作 IOSurface；必须验证 native handle 的真实 backing、格式与双方 GPU 生命周期。

## 最终 2048 Draw 三路基准

每档每模式三轮，各轮 60 帧预热 + 300 测量帧，最大在途 1。native/control/copy 顺序逐轮轮换，末帧完整哈希一致。下表 Mean 与 nearest-rank P99 合并每模式 900 帧；CPU ms/frame 与单核百分比合计客户端/worker 的 user+system，保留负差额。

| 分辨率 | 路径 | Mean ms | P99 ms | CPU ms/frame | 单核 CPU % |
| --- | --- | --- | --- | --- | --- |
| 1280×720 | 同进程 Metal 4 | 0.5205 | 3.5661 | 0.1636 | 31.43 |
| 1280×720 | socket 命令与 ACK | 0.5426 | 4.3175 | 0.1742 | 32.10 |
| 1280×720 | socket 命令与整帧复制 | 2.6801 | 4.9867 | 2.1018 | 78.42 |
| 2560×1440 | 同进程 Metal 4 | 0.5309 | 1.6160 | 0.1506 | 28.36 |
| 2560×1440 | socket 命令与 ACK | 0.5819 | 1.6987 | 0.1774 | 30.48 |
| 2560×1440 | socket 命令与整帧复制 | 9.1677 | 13.0345 | 8.6403 | 94.24 |

1280×720：相对整帧复制路径的平均差额 2.1596 ms、CPU 差额 1.9382 ms/frame；相对命令/ACK 路径的平均差额 +0.0221 ms、CPU 差额 +0.0106 ms/frame。

2560×1440：相对整帧复制路径的平均差额 8.6368 ms、CPU 差额 8.4897 ms/frame；相对命令/ACK 路径的平均差额 +0.0510 ms、CPU 差额 +0.0268 ms/frame。

这些差额是本机宿主诊断路径的实测。命令/ACK 对照没有把图像送到客户端，完整哈希在 worker 核验；强制整帧复制路径包含读回、socket 传输和客户端复制。真实旧图形后端可能已共享像素，不能将复制路径全部差额称为“砍掉 QEMU 的收益”。当前 A 的 16384 Draw/4096 常量更新/动态 VB/双 Pass/三缓冲 pilot 与本实验也不同口径，real_qemu_comparison 保持 false。

## B3：可调用入口与 5C 对接

宿主 timer 合成源仍为 SurfaceFrameProducer，origin=host_synthetic_not_guest_scanout。新增 EFIGuestProbe.run(disk:width:height:sharedMemoryBytes:onFrame:) 输出 EFIGuestSurfaceLease：真实 IOSurface、MTLSharedEvent/readyValue、尺寸、stride、origin 和线程安全幂等 release。它同步在后台调用；每次创建并停止自己的 VM，至多发布一帧，不是连续 Windows 帧源。

origin 固定为 uefi_diagnostic_guest_commands_not_Windows_application_scanout。两档 EFI 原型各 17 项检查通过；独立静态链接消费者 10 项通过。实际 5C revision 2/candidate snapshot 4 图形子集两档各两次重启，共四帧，每次 16 项检查通过；GPU 对整帧像素等值比较，只回读 4 字节统计，在完成后释放租约。未编译完整生产运行时，未创建可见窗口或捕获光标。诊断 adapter 使用 unavailable，生产游戏入口保持关闭。

surface 写完后才发布 ready timeline，消费者 GPU 读取完成前强引用保持，旧 surface 不被下一次 capture 覆盖。来源、签名、字段映射、释放和 resize/旧租约规则见 interface-proposal.md。supports_real_guest_scanout、supports_signed_windows_vz_boot、supports_virtual_hid_sink 仍为 false；新增 EFI 诊断命令/租约能力为 true。

Phase 6 施工图分别列出 Windows ARM64 UEFI、受支持 vTPM/信任链、基础签名设备、完整 VirtIO-GPU/WDDM/Venus、typed scanout、应用关联/输入与真实对照。含 vTPM 调查、排除未知 vTPM 实现的初步估算为 24–42 人周，另加集成余量；平台门禁未通过时不能承诺交付日历工期。社区 WHQL 驱动的既有旧后端成功不代表可直接在 VZ 工作。

## 最终质量、来源绑定与复跑

211 项 graphics-lab unittest 通过，含真实 EFI、独立消费者、5C 图形子集和小孔径预检。防外挂自检 6 项反例通过，扫描 127 份生产源码。24 份模块 Swift 最大 261 行，Strict SwiftLint 0 违规；没有改 lint 配置或加豁免。宿主完成重建、停止旧 owned 实例和自动重启，各 readiness 检查通过。

最终原生二进制 SHA-256：`16dbdbf3dc5db387bf250ff9e1e61cc10b5ce5a6c8b808f0f37ceb9341a9f09f`。最终基准 SHA-256：`72baffab969a997e0d0ec5ec82f035b6a362d6067948431ad4a54b964f9bd97e`。final-binding-verification.json 逐项核对源码、entitlement、二进制、EFI 夹具、静态库、下游源码、基准和诊断；evidence-manifest.json 封存当前源文件与证据，cleanup-verification.json 记录清理结果。

已保存本轮改动前的原始基准/源码绑定和失败记录。最早一轮的 raw series 当前目录没有归档副本，仅保留旧报告和其原基准摘要哈希；historical-measurement-provenance.json 明确此限制，不从平均值重造原始帧数据。所有 historical 记录保持原来的测量范围与绑定，不作为最终源码验证。

复跑命令：

```sh
python3 -B graphics-lab/vz_gpu_bench_runner.py restart
python3 -B -m unittest discover -s graphics-lab -v
python3 -B graphics-lab/vz_gpu_bench_runner.py diagnostics
python3 -B graphics-lab/vz_gpu_bench_efi.py
python3 -B graphics-lab/vz_gpu_bench_efi.py --width 2560 --height 1440
python3 -B graphics-lab/vz_gpu_bench_efi.py --external-consumer
python3 -B graphics-lab/vz_gpu_bench_c_efi.py
python3 -B graphics-lab/vz_gpu_bench_memory_limits.py
python3 -B graphics-lab/vz_gpu_bench_runner.py bench --rounds 3 --frames 300 --warmup 60
python3 -B graphics-lab/vz_gpu_bench_finalize.py verify
python3 -B graphics-lab/vz_gpu_bench_finalize.py quality
```

验证后在确认没有其他消费者正在使用本窗口临时构建时执行 finalize cleanup；报告/状态更新完成后执行 finalize seal。清理只覆盖本窗口锁内缓存和自有仓库外临时产物，锁外文件不删除。全仓零大文件若仍未满足，在最终状态中单列；不影响已完成的原型实证，但影响任务书全量验收。

最终清理实测：本窗口 owned 进程已停止、仓库外自有 BUILD 与锁内 build/.build/PCM 已移除；锁内 >5 MiB 文件为 0，PCM 为 0。全仓锁外仍有 183 个 >5 MiB 文件、1335 个 PCM，文件锁禁止本窗口代删，因此全仓零残留验收尚未通过。
