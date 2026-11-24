# Phase 6：原生 VZ 全量替换施工图与停止条件

日期：2026-11-24  
署名：@DNPMBHC

## 立项依据与当前结论

Phase 5 已证明自定义 VirtIO-GPU 配置可 validate、独立 ARM64 EFI Guest 可启动/停止、Guest 实际枚举 1AF4:1050/class 03 并完成双队列协商、Guest 写入的 2048 条命令可由同内存 Metal 4 消费，以及真实 IOSurface 可上屏。本窗口独立消费者与本地图形子集回归的 EFI 帧 GPU 逐像素比较也已通过。它没有证明原生 VZ 能启动满足全部要求的 Windows 11 ARM64，更没有完成 QEMU 替换。

生产路线应先通过 Windows 引导、vTPM 与官方签名驱动三个 go/no-go 门禁，然后才投入完整图形桥。不能以配置通过、capset 存在或宿主合成 FPS 代替这些门禁。

## 分阶段工程量

以下是熟悉 VZ、Windows 驱动协议与 Mesa 的团队的工程估算，单位为人周，属于估算而非实测。部分工作可并行，但 vTPM 和引导可行性位于关键路径。

| 工作包 | 主要交付与验收 | 估算 | 当前缺口 |
| --- | --- | --- | --- |
| P6.0 平台可行性 | 独立磁盘、ARM64 UEFI、Windows 安装/启动、设备管理器真实 PCI 枚举 | 2–4 | 独立 FAT EFI Guest 已枚举标准 PCI 并完成队列/共享 BAR 诊断；Windows 安装/启动未验证 |
| P6.1 vTPM 与信任链 | 官方支持的 TPM 2.0 路径、持久化、PCR/密钥与关机恢复；Secure Boot 启动验证 | 2–4 的可行性调查 | SDK 公共 VZ 头文件未发现原生 vTPM 接口；无法承诺实现工期 |
| P6.2 基础 Windows 设备 | 启动存储、网卡、键鼠、时钟、熵源、音频与干净关机 | 3–5 | VZ 设备与可用 ARM64 签名驱动矩阵未验证 |
| P6.3 VirtIO-GPU 协议 | descriptor/feature 协商、资源、blob、scanout、fence、context、cursor 与错误响应 | 4–7 | 双队列已由 EFI Guest 实际协商和通知；有限查询响应及失败关闭通过；完整 WDDM/Venus 3D 未实现 |
| P6.4 同进程 renderer | 固定 upstream ABI、自己的可发布构建与签名、Venus/Neptune 命令及 Vulkan ICD | 5–8 | 正常 HR 现成库无法加载；非 HR context 与 map/export 仍失败 |
| P6.5 scanout 与 surface | typed MTLTexture/IOSurface 互操作、格式/stride、resizes、资源与跨 GPU fence 生命周期 | 3–5 | EFI Guest 命令已渲染成真实 surface，独立消费者和 5C 图形子集已读取；Windows typed scanout 未实现 |
| P6.6 应用关联与输入 | 真实扫描帧到 5C、合法相对 HID、聚焦与取消、显示模式回读 | 2–4 | 已有单帧 EFI 诊断租约入口；缺连续 Windows 应用扫描帧、应用关联与合法 HID sink |
| P6.7 对照与分发 | 同一 Guest 工作负载对照、长时间压力、签名/公证、可回滚分发 | 3–5 | 当前为宿主合成单帧串行微基准 |

含 2–4 人周 vTPM 可行性调查、排除未知的 vTPM 实现后，已列工作约 24–42 人周，另加 25%–40% 集成与系统变动余量。两到三名工程师在平台门禁通过后可按约 12–20 个日历周规划；遇到缺失 API、驱动不兼容或商业游戏平台拒绝时，此估算作废。不能把“现成 WHQL 驱动”理解为免除宿主协议实现。

## Windows、UEFI、vTPM、Secure Boot

`VZEFIVariableStore` 默认签名数据库导入、开启 Secure Boot 与重新打开持久化回读已通过，KEK/db/dbx 各一项。这不能证明该默认 db 包含需要的 Windows Boot Manager 信任锚，也不能证明启动过程执行了要求的签名检查。应验证 Microsoft 启动与驱动签名链、dbx 更新行为及坏签名拒绝，不关闭 Secure Boot 或开启测试签名。

当前公共 SDK 中没有找到 VZ vTPM API。自定义 VirtIO 设备能力不能直接当作 Windows 的 TPM2 ACPI/CRB 接口；Windows 固件、ACPI 暴露与持久化均未实现。必须先获得公开、受支持且能维持 TPM 身份的实现路线。若没有该路线，按当前“vTPM + Secure Boot 全保留”的目标应标为平台阻塞，保留旧兼容后端；不得以跳过安装检查或降低平台要求宣称完成。

不得把旧 VM 磁盘直接挂到新 VM 做风险实验。独立测试镜像需保留自己的 NVRAM 与 TPM 状态；迁移 BitLocker/PCR 封装密钥需设计用户可审阅的恢复流程。全量替换还要核验 suspend/resume、状态保存、磁盘一致性、网络、声音、USB 与设备热更新等应用实际依赖。

## WHQL 驱动复用的条件

既有阶段报告可作为在旧后端上的签名与行为证据，不能外推为原生 VZ 驱动已成功。Phase 6 必须重新核验目标 ARM64 驱动 PE 架构、CAT/INF、硬件 ID `1AF4:1050`、VirtIO modern transport 与 device feature 协商，并在 Secure Boot 开启、测试签名关闭下实测安装、Code Integrity 与 WDDM 初始化。

驱动期待的 GPU 资源、Venus/Neptune capset、context 与 fence 协议必须逐项实现。不改变已签名内核文件来迁就宿主。若原包没有匹配硬件 ID、架构或协议支持，应停止“直接复用”承诺，记录需取得上游正式支持或另行签名认证的范围。

## 内存、同步与 renderer 的真实边界

29 个隔离配置用例将孔径验证推进到 UInt64.max（包括非对齐配置长度）；新增 14 个独立原生进程执行 validate、EFI start、全孔径 lazy map/unmap 与停止状态检查，映射接受至 32 TiB，64 TiB 返回 VZErrorDomain:10（SDK 定义为 NotSupported）。关键 4/8/32/64 TiB 又各复跑两次；32 TiB 均可映射，64 TiB 均失败。8 TiB 停机前状态随运行时序变化，32 TiB 夹具已自然停止，因此没有建立持续运行硬上限。旧首轮把已停止 Guest 的重复 stop 失败记为上限，原始记录已保留且不用于上限结论。配置容量与 lazy 虚拟映射均不代表物理 RAM 分配上限；没有触碰全部页面。实际 EFI 绘制 Guest 仅触碰约 144 KiB 命令映射，物理提交最大值未建立。宿主页为 16 KiB，Guest 常见 4 KiB 粒度必须由有界子分配器处理；映射指针、offset、length 均以宿主页对齐。不得把任意堆分配包装成可跨 VZ/Metal 使用的共享内存；当前已使用专属 mmap 页面并由 MTLBuffer deallocator 释放。

Guest 命令会并发变化，需快照固定长度的 header/descriptor 和验证后的 payload，以消除 TOCTOU；零拷贝目标针对像素面，不禁止必要的命令复制。检查整数溢出、GPA 越界、descriptor 链循环、资源配额、队列公平性、异常 Guest 停止、reset 与 resize，不能依赖消费者永远及时回执。

renderer 应由自有构建与一致团队签名解决依赖，不添加禁用 library validation 的权限。非 HR 诊断已初始化 renderer、取得 160 字节 Venus capset、创建 Guest blob；context 返回 22，map/export 返回 -22，尚未跑 Vulkan 命令。callbacks v4、结构大小和上游头文件哈希已固定，macOS 分支头文件已固定至提交 71a67414013f120c158729da7f56f29b55bf4f6c；现成本地库的源码提交仍未证实，必须自有构建并固定完整依赖。

采用专属串行 renderer 线程与异步 fence 分发。资源销毁需同时等 producer 写入和 consumer 读取完成。不能在主线程忙等 Vulkan 或 GPU。上游 native scanout handle 可为 MTLTexture，必须检查其 IOSurface backing、格式和权限；任意导出的 FD 或 mapped pointer 均不是 IOSurface 合约。

## 性能与合规门禁

正式对照必须让两后端运行同一 Guest 二进制、同一 draw payload、分辨率、图形 API、预热、帧数与最大在途数；核对完整帧哈希、GPU 完成、present 回执，合计所有宿主进程 CPU，并分别报告 CPU ms/frame、平均/P95/P99、呈现延迟、RSS 和功耗。要复测旧路径是否已共享像素，禁止强迫它整帧复制后将全部差额归功于移除 QEMU。

Phase 5 三路微基准仅拆解本宿主上的进程通信与像素复制成本，不含真实 QEMU 模拟、真实 Windows 驱动或商业游戏。命令+ACK 路径在 worker 验证像素，客户端没有收到图像；主微基准不含 compositor 呈现，单独上屏探针不能拼接成端到端游戏 FPS。

硬件虚拟化、WHQL、Secure Boot 与 TPM 通过也不保证反作弊厂商支持 ARM64 VM。只使用合法平台能力，不改反作弊、不隐藏虚拟化、不伪造设备、不注入游戏。由厂商支持政策与真实启动日志决定兼容状态；遇账号或人机验证由用户操作。

## 完成定义

原生 Windows 可受支持启动，TPM 身份与 Secure Boot 保持，官方签名 GPU 驱动实际协商，真实应用扫描帧经同进程 renderer 与 IOSurface 到达 5C，合法 HID 可输入且所有退出路径释放，完整基准与稳定性通过，分发可回滚，才能称为“全量替换”。任何平台门禁失败都必须公开记录；当前状态是可运行宿主原型及明确的 Phase 6 缺口。

## EFI 实证与下一条最小可施工链

`EFIGuestProbe.run(disk:width:height:sharedMemoryBytes:onFrame:)` 提供一帧真实 EFI Guest 诊断绘制结果；其来源为 `uefi_diagnostic_guest_commands_not_Windows_application_scanout`。独立消费者完成实际 IOSurface/GPU 读取与回执，当前 5C 图形子集在两档分辨率各两次重启下读取共四帧，每次 16 项检查通过。该单帧诊断把 PCI、队列、共享 BAR、命令内存、Metal 与下游 surface 读取连成一条可执行链，但 VM 已在发布前停止，不能验证连续 Windows 会话、DWM scanout 或实际游戏。

下一步可在同样隔离的 EFI 夹具上实现有限多帧命令环、带 generation 的资源绑定和 reset/cancel 回收，继续验证 transport；进入 Windows 生产路线前，仍须先通过平台门禁。当前随附 EFI 夹具未纳入 Secure Boot 信任数据库；独立 Secure Boot 配置/持久化探针与该 EFI 执行是两份分离证据，不合并成“开启 Secure Boot 的 Windows 启动”证明。

同团队签名的临时 framework 副本实验也已执行，HR 下现成 renderer 的加载仍被拒绝，原应用哈希未变。该记录是签名可行性诊断，不证明拥有可发布的生产证书/公证链。应从固定源码构建同架构静态 renderer 或同团队动态依赖，并用正式发布身份验证；不能用头文件 SHA 推断现成二进制源码，也不能由 GUEST blob 的 map/export=-22 推断所有 typed native image 都无法互操作。

当前微基准为 2048 Draw、16 字节诊断命令、单 Pass、最大在途 1。真实 QEMU 对照必须迁移同一 Guest 工作负载，并冻结三轮各 300 测量帧；不同 draw 数量、常量更新、顶点缓冲、pass 或在途深度的结果不能相除。旧路径若已共享像素，应以真实共享路径为基线，保留其生命周期及所有进程 CPU。

本轮容量探针按 canStop 检查执行停止操作。64 TiB 映射失败后可能已 stopped，也可能进入 error（SDK state rawValue=3）；进入 error 的原始 Guest 错误保留为 VZErrorDomain:1，不能当作 clean stop。禁止把 probe 的重复 stop 所产生的次级错误解释为内存硬上限。对应终止状态回归、源码和二进制均已重新验证。
