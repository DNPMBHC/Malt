# M0 / M2 补充评审（真实 Guest 验收待完成）

负责方：@DNPMBHC。范围：module-c，自有固定 16-draw 场景。

当前源码已实现 GetDesc1 / ProcessIdToSessionId 实测元数据、无 Guest 场景光栅和像素回读的 command-only v2，以及宿主实际执行 16 个场景 DrawCall 的 Metal 管线。像素模式保留作对照。两条 TCP 路径均在宿主 GPU 完成后 ACK；GPU 失败不发送成功 ACK。

首轮真实 Guest M0 已归档到 `m0-m2-guest-final/run-20261122-065700-utc/m0-adapters/manifest.json`：HARDWARE 请求成功选择 Microsoft Basic Render Driver（vendor/device 5140/140、flags 0、FL 11_1、Windows Session 1）。DXGI 同时枚举出另一个同名适配器，其 flags 为 2。Win32_VideoController 仅检测到 VirtIO GPU DOD；实测 flags 0 保留原值，显式 WARP 像素参考与正式性能仍待验收。

最终宿主 Wine M0 指纹已归档到 `m0-adapters/manifest.json`：DXVK 暴露 Apple M4（4203/1009、flags 0、FL 11_0）；D3DMetal 暴露 AMD Compatibility Mode（4098/26287、flags 0、FL 11_1）；DXMT 暴露 Apple M4（4203/0、flags 0、FL 11_1）。这是引擎暴露的 DXGI 标识。Wine session 1 不属于 Windows 桌面会话证据。

真实本机 Metal 32 帧与真实 Wine C++ v2 路径已通过。DXVK D3D11 硬件参考帧与同场景 Metal 原生 RGBA 帧的 921,600 个像素完全一致，最大误差 0 LSB；独立 FP32 CPU 辅助参考检查最大误差 1 LSB。这些结果不能替代真实 Guest D3D11 WARP 参考。

计时审查 R3 已在源码收口：Direct 逐帧等 GPU event，两条 TCP 路径逐帧等 GPU 完成 ACK。主吞吐以最后一帧完成为终点，后续 timestamp 查询采集单独计时；宿主关闭 display sync 对齐 Present(0,0)。帧间隔、GPU 时间与整轮完成吞吐分开记录。任何指标均不等于物理屏幕呈现或输入到光子的延迟。

捕获审查 R4 已在编排收口：捕获使用独立验证 pass，性能审计拒绝 capture-configured 或 capture-enabled 样本。环境门禁要求真实 Windows 11 24H2 Build 26100 ARM64；同一探针二进制、实际 Session、适配器、场景常量和每帧字节均须一致。最新本地回归与 SHA 门禁见 `m0-m2-local-gate-latest.json`。真实 Guest PowerShell 与 GPU 结果仍待验收。

尚未完成：Guest HARDWARE 所选适配器取证、显式 WARP 参考与 Metal 的逐像素验证，以及 Direct / Pixel Readback / Command-Only 三模式配对基准。共享 Guest 已由窗口 A 写入清理释放记录，下一负责方为窗口 C；本轮先做真实预检，再按门禁顺序验收，尚未发布新的 Guest FPS。

以下为历史 C3 记录，仅用于保留原始条件和旧数据。11.35 / 6.19 FPS 是旧分析器的派生结果，与本轮包含 GPU 完成边界的吞吐不可直接当作同轮比较；其中关于 WARP 的文字属于当时推定，最终以本轮 GetDesc1 的描述和 software flag 为准。历史架构判断不代表通用 D3D/WDDM 图形栈已经完成。

---

# 下一代 Windows Guest 图形卸载架构技术评审（阶段 C3 实测终版）

日期：2026-11-22  
负责方：窗口 C（`module-c` / `module-d`）  
实测数据来源：
- C1/C1+ 真实 Wine 三引擎实测：`handoff/phase-2/evidence/window-c/wine-dxmt-three-engine/manifest.json`
- C2 `metal_host` 策略 A/B：`handoff/phase-2/evidence/window-c/metal-host-policy-ab/manifest.json`
- C2 真实 `d3d11_probe.exe` 本地 `offload_tcp` 实测：`handoff/phase-2/evidence/window-c/gamemode-and-offload/observation-manifest.json`
- **C3 真实 Windows 11 24H2 ARM64 Guest 跨 VM 配对实测**：`handoff/phase-2/evidence/window-c/guest-c3-offload/manifest.json`

---

## 1. 真实 Windows 11 24H2 ARM64 Guest 配对实测与逐段耗时拆解

### 1.1 测试环境与不可变摘要
- **Guest 环境**：Windows 11 Enterprise Evaluation 24H2 ARM64（`Build 26100.1.arm64fre.ge_release.240331-1435`），通过内置 **Prism** 运行 x64 `d3d11_probe.exe`；显示适配器为 **`Red Hat VirtIO GPU DOD controller`**（Display-Only Driver，v22.7.38.43，无硬件 3D 加速，D3D11 所选渲染器此前未采集 GetDesc1，软件标志待本轮 M0 核验）。
- **宿主机与链路**：Apple M4 / macOS 27.2.1 (`26B131`)，`metal_host.swift` 绑定 VM 隔离网桥 `192.168.64.1:39003`（Guest `192.168.64.2`）。
- **固定负载**：`1280×720` RGBA、`60` 预热 + `300` 测量帧 × 3 轮交替顺序（每模式共 900 测量帧）、16 commands、65,536 bytes resource、`--command-every 30 --resource-every 30`。
- **不可变 SHA-256**：
  - `d3d11_probe.cpp`: `011adfc0422cea672d4014865451ee0c15e17e80f3f13d9d014bf5ac3567d34f`
  - `d3d11_probe.exe`: `4498e38244e7b06ecfaecfa6d025bcb44d9c9cfe2c9487ae8e38cd0713b6c34e`
  - `metal_host.swift`: `3ab55b05d2d9936bbe31805b2df9109085fa69cb1952bccaeca36093f6d46bca`
  - `metal_host` (arm64): `99e52ec14efd70fb1c951c5b241517fbe26cf34d425e97df362f50d883df4bbc`

### 1.2 配对实测数据（3 轮均值）

| 运行模式 | 初始化 (ms) | 60 帧预热 (ms) | Derived FPS | 帧间隔 Mean / P50 / P95 / P99 (ms) | CPU Submit 均值 (ms) | Guest D3D11 GPU 均值 (ms) | 宿主机 Metal GPU 均值 (ms) | 每帧传输字节 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **Guest Direct Present**（交互式桌面会话） | 278.44 | 5286.46 | **11.35** | 93.68 / 82.22 / 181.06 / 255.10 | 93.43 | **91.14** | — | 0 |
| **Guest Offload TCP → Host `metal_host`** | 41.12 | 10553.69 | **6.19** | 172.81 / 137.65 / 363.46 / 637.83 | 172.56 | **73.08** | **0.168** | 3,688,681 (~3.52 MiB) |

> 注：通过 `utmctl exec`（Session 0）直接运行 `Direct Present` 时 `D3D11CreateDeviceAndSwapChain` 返回 `0x887A0022 (DXGI_ERROR_NOT_CURRENTLY_AVAILABLE)`，属 Windows Session 0 无交互式桌面交换链的预期系统行为；正式基准通过交互式桌面会话（Session 2）执行并完成全部 3 轮采集。

### 1.3 每帧真实耗时拆分（基于 `Offload TCP` 172.56 ms 总提交耗时）

| 耗时阶段 | 实测均值 (ms) | 占总提交耗时比例 | 瓶颈归因 |
| --- | ---: | ---: | --- |
| **1. Guest D3D11 渲染 + `CopyResource`**（`gpu_ms`） | **73.08 ms**（Direct 直出纯渲染为 **91.14 ms**） | **42.4%**（直出路径占 **97.5%**） | Guest 无硬件 3D 驱动（仅 `VirtIO GPU DOD`），软件光栅为当时的推定；实际所选适配器待本轮 M0 核验 |
| **2. `Map(READ)` + 行拷贝 + 跨 VM TCP 往返 + 宿主纹理上传与同步呈现** | **99.48 ms** | **57.6%** | 每帧 ~3.52 MiB 像素 CPU 回读、virtio-net TCP 传输与同步 ACK 阻塞 |
| **3. 宿主机 Apple M4 Metal GPU 呈现**（`host_gpu_ms`） | **0.168 ms** | **< 0.1%** | 宿主机 GPU 极度空闲，完全不是瓶颈 |

---

## 2. 三条下一代图形卸载技术路线对比与实测收敛结论

| 评估维度 | 路线 A：共享内存环形缓冲（IVSHMEM / Virtio-Shm + 异步多帧队列） | 路线 B：Virtio-GPU + Venus / WDDM 3D 虚拟 GPU 驱动 | 路线 C：用户态 D3D11/DXGI API 命令流转发（RPC / 远程渲染） |
| --- | --- | --- | --- |
| **实测收益上限（基于 C3 数据）** | 可消除 `99.48 ms` 中的网络与同步等待，但**无法消除 `73–91 ms` 的 Guest WARP 软件渲染瓶颈**（上限仅约 ~11 FPS） | **唯一能同时消除 Guest 软件光栅（`91 ms`）与像素回读（`99 ms`）的路线**，将渲染下发至 Apple M4 Metal | 消除像素回读，但仍受限于用户态拦截与高频状态同步开销 |
| **工程复杂度** | 低–中 | **极高**（需符合 Windows WDDM/UMD 规范的签名驱动 + QEMU/AVF Virtio-GPU 3D/Venus 支持） | 高 |
| **与窗口 B 反作弊保护边界冲突** | 边界清晰，但性能不足以支撑 3D 游戏 | 运行在 Windows 标准内核图形栈内，但商业反作弊仍可能检测虚拟 GPU PCI ID 与驱动签名 | **高合规风险**：依赖 DLL Hook/拦截，极易触发内核反作弊完整性阻断 |

---

## 3. 最终架构选型结论（基于 C1 + C2 + C3 + Phase 3-C 全量实测）

C3 真机实测已直接触发第 3 节预设的决策门禁（Guest 软件渲染仅 **11.35 FPS**，耗时 `91.14 ms`，占直出帧时间 97.5%），据此正式确立项目的分层图形架构选型：

1. **不把资源投入「路线 A（纯像素共享内存传输层）」作为 3D 游戏主方案**：在当前 `VirtIO GPU DOD` 无 3D 加速的 Guest 中，仅优化传输层最多将帧率从 `6.19 FPS` 拉回 `Direct Present` 的 `~11.35 FPS`，无法满足真实 3D 游戏可玩性。

---

## 4. M0 / M2 真机闭环实测更新（三模式 × 3 轮跨 VM 配对验收）

- **负责方**：`@DNPMBHC`
- **验收归档**：`handoff/phase-2/evidence/window-c/m0-m2-guest-final/run-20261122-140047-utc/acceptance.json`（SHA-256: `dff5c9a2d32390275ff37db74da4b53135bc368c4d31502dd4f69c59e230b327`）
- **M0 真实适配器实锤**：在 `vm-a`（Windows 11 Enterprise Evaluation 24H2 ARM64 build `26100`，交互式 Session `1`）中，`Win32_VideoController` 为 `Red Hat VirtIO GPU DOD controller`，D3D11 `HARDWARE` 请求实际落到 `Microsoft Basic Render Driver`（`vendor_id=5140 / 0x1414`，`device_id=140 / 0x008C`，`flags=0`，`feature_level=11_1`）；显式 `WARP` 请求同样为 `Microsoft Basic Render Driver`（`flags=2`，`software=true`）。
- **M2 逐像素一致性验收**：显式 Guest WARP 参考帧与宿主机 Apple M4 Metal 原生 16-Draw 重放输出 4 组独立对照全部通过（`legacy` 帧 0 最大误差 **0 LSB**，`seeded` 帧 0/30/31 最大误差 **1 LSB**，每组 `921,600` 像素，未混入性能样本）。
- **M2 三模式 × 3 轮配对性能实测**（同 Session `1`、同二进制 `09bb190bf5d763f9749345300b937728db886a4ec26c32c361a920c565cf1bee`、`1280×720`、16 Draw、64 KiB 资源、每轮 60 预热 + 300 测量帧，共 9 轮 / 2,700 测量帧，`gpu-complete` 边界）：

| 模式（3 轮 × 300 帧） | 合并吞吐 FPS（含 GPU Drain） | 轮均 FPS | 帧间隔 Mean / P50 / P95 / P99 (ms) | 每帧应用层字节 | 宿主机 Metal GPU 均值 (ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| **Direct Present** | **15.673** | 15.674 | 63.789 / 63.028 / 94.581 / 125.498 | 0.000 | — |
| **Pixel Readback TCP** | **7.096** | 7.192 | 140.909 / 127.983 / 219.438 / 332.853 | 3,688,681.067 | 0.205007 |
| **Command-Only Metal Replay** | **18.847** | 18.922 | 53.045 / 49.010 / 69.566 / 109.944 | **2,289.600** | **0.881399** |

### 4.1 架构收敛补充结论
1. **命令流重放显著优于像素回读与本地软件直出**：在自有固定 16-Draw 场景下，`Command-Only Metal Replay` 彻底跳过 Guest 场景 Draw、`CopyResource` 与像素回读，将跨 VM 每帧平均带宽压缩 **1,611×**（缓存命中帧仅 **88 B**，每 30 帧刷新帧 **66,136 B**），宿主机 Apple M4 Metal 执行全部 16 次真实绘制仅需 **0.881 ms**，合并吞吐达到 **18.847 FPS**（为 `Pixel Readback TCP` 的 **2.66×**，较 `Direct Present` 提升 **+20.25%**）。
2. **范围与边界声明**：本次 M2 验收严格限定于自有固定 D3D11 探测场景与 `gpu-complete` 完成边界（未计入物理显示管线输入到光子延迟），证明“命令级宿主 Metal 重放”在带宽与算力卸载方向上的可行性，不代表通用 WDDM/D3D 商业游戏虚拟 GPU 栈已完成；无内核反作弊游戏仍以宿主机 Wine（DXMT / D3DMetal / DXVK）为主力，强硬件信任根反作弊游戏继续由 Phase 3-C 合规远程串流方案兜底。

2. **无强内核反作弊限制的 Windows 游戏 → 坚定采用宿主机 Wine 三引擎自动路由（C1 实证）**：
   - 同款 `d3d11_probe.exe`（1280×720）在宿主机 Wine 下：**DXMT v0.80 达 344.96–366.98 FPS（19.9 MiB 显存）**、**D3DMetal 达 353.63 FPS**、**DXVK 达 335.31 FPS**，较 Guest 软件直出（`11.35 FPS`）快 **~30×**。
3. **Windows Guest 长期 3D 演进 → 评估路线 B（`viogpu3d` / Virtio-GPU WDDM 3D，交由 Phase 3-A 进一步评估）**：只有提供 Guest 内核级虚拟 3D 驱动，才能绕开 WARP 软件渲染与像素回读。
4. **锁死物理 TPM / 禁止 VM 的强反作弊游戏 → 采用 `RemotePhysicsBackend`（Phase 3-C）**：通过局域网物理 Windows 副机或合规物理云机低延迟串流（Moonlight/外部客户端），在 100% 真实物理硬件与合法合规边界内运行。
