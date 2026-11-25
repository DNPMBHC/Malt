# 窗口 5B：原生 VZ、同进程 Metal 4 与 IOSurface 原型实测

日期：2026-11-24  
署名：@DNPMBHC

## 结论与验收边界

已交付可构建、可重启和可调用的宿主原型：标准 VirtIO-GPU 配置、双队列框架、共享 mmap 命令环、同进程 Metal 4、真实 IOSurface、CAMetalLayer 呈现及 surface 租约。真实原生 VZ validate、EFI 启动/停止、映射与 GPU 使用均通过。

不能宣称完成全部替换验收：没有原生 Windows/WDDM/Venus/Neptune 扫描输出，也没有合法相对 HID sink；公共 SDK 的 vTPM 路线未确定。真实性边界与施工图已交接，不能把合成帧、配置容量或 IPC 微基准当成 Windows 游戏收益。

| 任务 | 已完成 | 尚未证实 / 阻塞 |
| --- | --- | --- |
| B1 | 设备配置、controlq/cursorq 框架、真实 validate、EFI 生命周期、对齐与签名矩阵 | PCI 身份未由 Guest 枚举；共享内存物理硬上限未找到；无 Windows 驱动协商 |
| B2 | 2048 draw Metal 4、同一 VZ/Metal 共享环、surface 上屏、三路基准、FFI 真实边界探针、重启闭环 | 正常 HR renderer 库加载失败；无真实 Venus/Neptune 绘制；真实 QEMU 同负载对照待 5A |
| B3 | 可调用生产者库、IOSurface 契约、14 项租约验证与 Phase 6 施工图 | 与 5C 真实 Guest 全屏会话未联调；HID unavailable |

## B1：配置与共享内存

宿主 macOS 27.2.1，SDK 27.0，Swift 6.4，ARM64，物理 RAM 16 GiB；宿主页为 16384 字节。版本与公开 SDK 头文件哈希在 `sdk-api-evidence.json`。

VZ API 的 `deviceID` 是 VirtIO 设备类型 **16**，不是现代 PCI 值。配置设置 display class 0x03、subclass 0x80、两个队列；预期标准 PCI vendor 为 0x1AF4，现代 device 为 0x1050。vendor/device 的表述属于规范预期和 API 配置推导，未做 Guest PCI 枚举。host-visible shared-memory region ID 使用 **1**。未实现的 3D/blob 特性与 capset 默认不宣称可用。

`validate.json` 是真实配置校验输出。64/256 MiB、1/2/4/8/16/64 GiB 及 **1 TiB** 均被配置校验接受；`maximumAllowedSharedMemoryRegionCount=1`，两个共享区被拒绝。配置大小增加 4 KiB 仍被接受。配置通过不等于分配该数量的 RAM。

`runtime-probe.json` 来自独立、无磁盘的 EFI 夹具，包含真实设备创建回调、VM 启动与停止。16 KiB、256 MiB、1/2/4/8/**16 GiB** 依次映射与解除映射成功。此阶梯主要测试虚拟地址映射，未触碰所有页，不能称为物理容量上限；配置接受到 1 TiB 和映射到 16 GiB 都只是已验证下界。

指针、offset、length 非 16 KiB 对齐时，运行期返回 `VZErrorDomain:10`。范围越界则在隔离子进程抛 `NSInvalidArgumentException`，退出 -6；这是预期反例，未用于主程序运行。例子与原始错误在 `mapping-negative-cases.json`。

同一个 **147456 字节 mmap 命令环** 被 VZ 映射，同时以无额外 backing copy 的 MTLBuffer 供 Metal 4 使用并完成绘制。专属页面由 buffer deallocator 释放；宿主模拟写入并非 Guest 提交，`driverNegotiated=false`。

Hardened Runtime + 常规 `com.apple.security.virtualization` 可 validate 并运行 EFI。HR 缺少该 entitlement 时 runtime 失败，`VZErrorDomain:2`；不能只看探针进程退出 0，而忽略 JSON 中的失败状态。非 HR + virtualization 同样可运行，仅用于边界诊断。

Secure Boot 默认签名导入、启用、持久化回读成功，KEK/db/dbx 各 1。没有执行 Windows Boot Manager 信任链、Windows 安装或 Windows 驱动校验。当前公共 SDK 头文件未发现原生 vTPM API；此结论的范围限于已安装 SDK，不使用私有 API 推断支持。

## B2：真实 GPU、呈现与 renderer FFI

渲染原型使用真实 MTL4 编译器、命令队列和参数表，编码 **2048 次 draw 调用**。每帧 wait 到 MTLSharedEvent 完成后才计入测量；测试证明改变 draw payload 会改变完整帧 SHA-256。像素读取用于末帧哈希等诊断，位于主基准计时之外；同进程路径不做逐帧 CPU 像素复制。

两档 NSWindow/CAMetalLayer 探针各提交 30 帧，分别观测到 26 / 25 次 presented 回调。真实 texture 的 IOSurface backing 与 lookup 校验通过。独立 WindowServer 元数据探针也观测到自己的窗口处于 onscreen；只记录本实验窗口，没有截图或其他窗口记录。

presentedTime 返回 0，因此不声称测出了物理显示扫描时间或端到端显示延迟。呈现包含一次 GPU 全屏 pass 写入 drawable；零 CPU 像素复制不等于没有 GPU 写入。主基准测量至 renderer GPU 完成，不包含窗口 compositor；呈现探针单独记录。

FFI C 探针按 upstream macOS callbacks v4 ABI 编译，callbacks 72 字节，blob args 48 字节，静态断言通过。flags=192（Venus + NoVirgl），没有启用 render-server。现成动态库在默认 HR 下因不同 Team IDs 被 library validation 拒绝；临时复制并 ad-hoc 重签依赖仍失败，原应用 component SHA-256 前后相同，没有修改原应用或禁用库验证。

在独立非 HR 签名案例中，16/16 符号解析，`virgl_renderer_init=0`（约 0.062 ms），Venus capset 为 160 字节，Guest blob create=0；context create=22，blob map/export=-22。它证明初始化与一部分 ABI 可调用，不能证明同进程 Vulkan 绘制已运行。没有提交 Venus/Neptune 命令或导出 IOSurface。callbacks 仅是探针，不是生产 fence 实现。

typed native scanout handle 与 IOSurface 互操作仍待实现；上游可返回 MTLTexture，任意 mapped blob pointer/FD 不等于可呈现 IOSurface。最小生产嵌入边界是有一致签名的 renderer/ICD 构建、稳定 ABI、合法资源映射、真实命令 decoder、typed scanout 与双方 GPU fence 生命周期。

## 2048 draw 三路实测

每分辨率、每模式三轮，各轮 60 帧预热 + 300 测量帧；最大在途为 1。三轮轮换 native/control/copy 顺序，核对相同 payload 与末帧完整哈希。平均和 P99 汇总每模式 900 帧，P99 使用 nearest-rank；CPU 合计 IPC client + worker，排除预热。CPU 占比以单核心 100% 口径计算，不能理解为整机总容量百分比。

| 分辨率 | 路径 | 平均 ms | 汇总 P99 ms | CPU ms/frame | 宿主 CPU 占比 |
| --- | --- | ---: | ---: | ---: | ---: |
| 1280×720 | 同进程共享环 | 0.7776 | 5.3519 | 0.1690 | 21.72% |
| 1280×720 | 多进程命令 + ACK | 0.8714 | 5.4923 | 0.2036 | 23.35% |
| 1280×720 | 多进程命令 + 整帧复制 | 4.6045 | 10.3812 | 2.8573 | 62.05% |
| 2560×1440 | 同进程共享环 | 0.9233 | 3.6364 | 0.1821 | 19.72% |
| 2560×1440 | 多进程命令 + ACK | 0.9704 | 3.7294 | 0.2024 | 20.86% |
| 2560×1440 | 多进程命令 + 整帧复制 | 9.2865 | 14.0297 | 8.7140 | 93.83% |

- 1280×720：相对整帧复制路径，平均减少 3.8269 ms/frame，CPU 减少 2.6883 ms/frame；相对命令 + ACK，平均差额仅 93.7 µs/frame，CPU 差额 34.6 µs/frame。
- 2560×1440：相对整帧复制路径，平均减少 8.3632 ms/frame，CPU 减少 8.5318 ms/frame；相对命令 + ACK，平均差额仅 47.0 µs/frame，CPU 差额 20.3 µs/frame。

纯命令 IPC 差额比整帧复制差额小得多；三轮样本不足以证明几十微秒差距有统计稳定性。早期未轮换的试跑曾出现 720p ACK 路径更快，正式数据保留各轮原始序列，不将噪声或负差值过滤掉。结论是本机合成实验中像素复制成本明显，不能外推为已经移除 QEMU 模拟开销。

ACK 模式逐帧只回 8 字节序号，客户端未收图；图像哈希来自 renderer worker，JSON 明确标注其来源。全帧复制模式逐帧发送 3686400 / 14745600 字节像素，另有 32768 字节命令。旧后端也可能已共享像素，不能强加复制后宣传全部差额都是方案 B 收益。

与 5A 仅对齐了 draw 数和分辨率，尚未对齐 Guest 程序、图形 API、异步在途与 VM 系统负载。因此 `real_qemu_comparison=false`，没有声称真实 Windows 或商业游戏提速。

## 验证、对接与复现

- 全部 graphics-lab unittest：**199 项，0 失败**，源码输入哈希保持稳定。
- 全项目 Strict SwiftLint：**0 违规**，未增加豁免；全部 21 个 Swift 文件 ≤400 行，函数和行宽由严格规则检查。
- 现有防外挂审计 `--self-test`：6 个反例通过，exit 0。
- 优化编译使用 Swift warnings-as-errors，C 使用 Wall/Wextra/Werror；构建源码快照与执行文件均绑定 SHA-256。
- 多次执行 build → stop old owned instance → restart，旧实例停止和新实例 ready 已记录。正式实验使用 Hardened Runtime 与 virtualization entitlement。
- `producer-probe.json` 14 项真实租约检查全部通过；独立静态消费者库入口五项检查通过。

正式实验执行文件 SHA-256：`4630131e1f00d7dbcd1b21aa7f4dd7806ed3ca2d9c651b478e029224024ae680`。`vz-zero-copy-benchmark.json` 内包含真实 validate 输出、runtime 映射、构建源码绑定与独立证据哈希；`evidence-manifest.json` 索引最终文档与日志。临时执行文件和编译缓存交付时清理，复现需要重新构建，禁止绕过 runner 使用旧缓存二进制。

```sh
python3 -B graphics-lab/vz_gpu_bench_runner.py restart
python3 -B graphics-lab/vz_gpu_bench_runner.py diagnostics
python3 -B graphics-lab/vz_gpu_bench_library.py
python3 -B graphics-lab/vz_gpu_bench_visibility.py
(cd graphics-lab && python3 -B -m unittest discover -v)
python3 -B graphics-lab/vz_gpu_bench_runner.py bench --rounds 3 --frames 300 --warmup 60
python3 -B graphics-lab/vz_gpu_bench_runner.py clean
```

命令从中性工作区根运行；Strict lint 使用项目现有锁定工具。对接详情在 `interface-proposal.md`，支持状态在 `interface-capabilities.json`，Windows/vTPM/WHQL/renderer/HID 施工与停止条件在 `phase-6-construction-plan.md`。

## 清理与文件锁

本窗口只修改授权模块、基准/测试脚本及 p5-b 证据，没有 commit/push/reset 或全局 Git 配置变更，也没有操作共享主 VM。所有署名为 @DNPMBHC，日志使用中性路径占位符。

本窗口 build 与 PCM 会清理并以 `cleanup-verification.json` 核验。全仓零 >5 MiB 的条件仍须看同一文件：仓库中存在锁外历史产物与其他窗口缓存，不能越文件锁删除。整体验收不能因本窗口清理完成就宣称全仓已满足该红线。

## 跨窗口 GPU 接线追加实证（2026-11-24）

5C 已静态链接本窗口生产者与 revision 2 的实际 graphics 源码，执行两轮，各消费 12 帧，共 24 帧。每轮 18 项检查全部通过：同一 IOSurface、生产 timeline、GPU 读取完成后释放、幂等回执、resize、像素逐字节等值及全量租约回收。图像比较在 GPU 上完成，仅回读 4 字节比较统计，不回读源像素。

本窗口只读核验了该报告的全部生产者与消费者源码 SHA-256，均与当前文件匹配。原始实证副本在 `cross-window-gpu-roundtrip.json`，接收核验及来源哈希在 `cross-window-gpu-receipt.json`；运行由 5C 执行，本窗口没有重复构建或修改生产者。

这是合成源到实际 graphics 消费者的同进程 GPU 往返，不包含 VM、可见窗口、原生全屏或指针捕获。真实 Guest scanout、signed Windows VZ boot 和 HID 支持状态仍为 false。完整游戏会话与平台验收仍未完成。
