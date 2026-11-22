# 下一代 Windows Guest 图形卸载架构技术评审（阶段 C3 预研基线）

日期：2026-11-22  
负责方：窗口 C（`module-c` / `module-d`）  
前置数据来源：
- C1 真实 Wine D3D11 实测：`handoff/phase-2/evidence/window-c/wine-dxvk-vs-d3dmetal/manifest.json`
- C2 `metal_host` 策略 A/B：`handoff/phase-2/evidence/window-c/metal-host-policy-ab/manifest.json`
- C2 真实 `d3d11_probe.exe` 本地 `offload_tcp` 实测：`handoff/phase-2/evidence/window-c/gamemode-and-offload/observation-manifest.json`

> **严格边界声明**：当前本机尚无窗口 A 交付的真实 Windows 11 ARM64 Guest，本评审基于 Phase 1 合成回环与 Phase 2 C1/C2 真实 D3D11 数据建立定量基线；**不对未实测的跨 VM 路径宣称任何性能提升**。阶段 C3（同一 Windows Guest 内“本地直出 vs TCP staging 卸载”配对实测）将在窗口 A Guest 稳定就绪后补测并更新本报告。

---

## 1. 现有基线（TCP Staging 像素回读）实测瓶颈拆解

在 1280×720 RGBA、`--command-every 30 --resource-every 30` 条件下，真实 `d3d11_probe.exe` 的 `offload_tcp` 本地回环实测（120 测量帧）给出以下定量数据：

| 指标 | 实测值（1280×720，本地回环） | 含义与扩展推演 |
| --- | ---: | --- |
| 每帧传输载荷 | 3,688,681 bytes (~3.52 MiB) | 其中 3,686,400 bytes（99.94%）为未压缩 RGBA 像素；命令+资源摊销仅 2.2 KiB |
| 120 FPS 持续带宽 | ~422 MiB/s (~3.38 Gbps) | 仅 720p@120Hz；若升至 1080p@120Hz 将达 ~950 MiB/s，1440p@120Hz 达 ~1.69 GiB/s |
| 客户端提交至 ACK 均值 | 8.300 ms（P95 9.639 ms） | 含 `CopyResource` + `Map(READ)` 行拷贝 + TCP 发送 + 宿主机呈现 + 同步等待 ACK |
| 宿主机接收至 Metal 完成均值 | 8.040 ms（P95 9.338 ms） | 其中 Metal GPU 实际耗时仅 **0.395 ms**，其余 ~7.6 ms 主要消耗在同步 vsync 呈现等待与 TCP 接收/CPU 纹理上传 (`replaceRegion`) |
| 同步模型 | 严格单帧阻塞（Request → ACK） | 无多帧异步飞行队列（frames-in-flight），Guest 渲染与宿主机呈现完全串行 |

**核心结论**：
1. 当前 TCP Staging 原型的决定性瓶颈**不是宿主机 Metal 渲染（仅 0.395 ms）**，而是 **3 次冗余数据搬运 + 跨网络栈序列化**：`Guest GPU RT → CopyResource → Guest CPU Staging → TCP Socket (virtio-net) → Host CPU Buffer → Metal Shared Texture Upload`。
2. 在真实 Windows Guest 场景下，除了 virtio-net 吞吐与延迟开销外，若 Guest 内无硬件 GPU 加速（纯软件光栅 WARP / llvmpipe），D3D11 渲染本身就会成为第一瓶颈；若 Guest 侧已有加速渲染，则 CPU `CopyResource + Map` 回读会打断 GPU 管线并产生高额总线同步 stall。

---

## 2. 三条下一代图形卸载技术路线对比评估

| 评估维度 | 路线 A：共享内存环形缓冲（IVSHMEM / Virtio-Shm + 异步多帧队列） | 路线 B：Virtio-GPU + Venus / 虚拟 GPU 驱动（Guest 内核/UMD 驱动） | 路线 C：用户态 D3D11/DXGI API 命令流转发（RPC / 远程渲染） |
| --- | --- | --- | --- |
| **消除的瓶颈** | 消除 TCP 协议栈拷贝与单帧阻塞，支持双/三缓冲异步呈现 | 消除像素回读与 CPU 中转，Guest 渲染直接下发至宿主机 GPU（Metal/MoltenVK） | 消除帧缓冲像素回读，仅传输精简 API 命令与变更资源 |
| **预期延迟与带宽特征** | 带宽上限受宿主内存带宽支配（零网络栈），但仍需 1 次 Guest GPU→CPU 回读与 1 次宿主机纹理上传 | 最接近原生：资源驻留宿主机 GPU，仅命令缓冲与同步 fence 跨越 VM 边界 | 静态资源多/分辨率高时带宽极低；但高频每帧动态 buffer / `Map(READ)` 会导致严重往返延迟 |
| **工程复杂度** | **低–中**：无需编写 Windows 内核显示驱动（WDDM），只需虚拟化共享内存设备 + 轻量环形缓冲协议 | **极高**：需要符合 Windows WDDM/UMD 规范的签名驱动（WHQL/EV 签名）+ QEMU/Apple Virtualization 侧 Virtio-GPU 3D/Venus 完整支持 | **高**：需在用户态完整拦截并序列化 D3D11/DXGI 状态机、着色器反射与复杂资源生命周期（近似重写简化版 DXVK/ANGLE） |
| **与窗口 B 反作弊保护域边界的约束（关键）** | **边界最清晰**：只传输渲染完成后的像素与显式元数据，不注入游戏进程、不读取受保护进程内存；但无法解决 Guest 内无真实 GPU 渲染加速的问题 | **保护域最合规（长期终极形态）**：驱动运行在 Windows 内核标准图形栈，与游戏及反作弊同处 Windows Guest 内核域；但**商业反作弊通常检测虚拟 PCI/GPU ID 与驱动签名**，未经厂商认可仍可能被拒绝 | **高合规风险**：通常依赖 DLL 拦截/Hook（如替换 `d3d11.dll`），在受内核反作弊保护的游戏中极易触发完整性校验失败或直接被拒绝启动 |
| **在当前项目（Apple Silicon + UTM/AVF）落地可行性** | **短期可验证（阶段 C3 后续首选原型）** | **中长期方向**（依赖上游 Apple Virtualization / QEMU Virtio-GPU 3D + 签名 Windows WDDM 驱动生态，非单团队短期可闭环） | **不推荐用于受保护游戏**（对普通无保护程序有效，但与反作弊域红线冲突） |

---

## 3. 阶段 C3 实测验证计划与决策门禁（待窗口 A 就绪后执行）

待窗口 A 交付稳定 Windows 11 ARM64 Guest 并完成共享卷挂载后，窗口 C 将按以下顺序执行 C3 实测，用真实数据收敛最终选型：

1. **同一 Windows Guest 配对采集（固定 1280×720，120 预热 + 900 测量，各 3 轮）**：
   - `Guest Direct Present`：直接运行 `d3d11_probe.exe` 本地窗口直出，记录 Guest 内 D3D11 设备类型（WARP / 虚拟适配器）、初始化耗时、帧间隔 P50/P95/P99 与 GPU 时间。
   - `Guest Offload TCP → Host metal_host`：通过 host-only 隔离网络将 `d3d11_probe.exe` 卸载至宿主机 `metal_host.swift`，拆分统计：
     - Guest 侧渲染 + `CopyResource` GPU 时间（若支持 timestamp query）
     - `Map(READ)` + TCP 往返时间（`cpu_submit_ms - host_receive_to_present_ms`）
     - 宿主机 Metal 上传 + 呈现时间（`host_receive_to_present_ms` 与 `host_gpu_ms`）
2. **基于实测数据的决策门禁**：
   - 若实测表明 Guest 侧软件渲染耗时占总帧时间 > 60%：则**仅优化传输层（路线 A 共享内存）无法带来显著帧率收益**，必须转向虚拟 GPU 加速生态（路线 B）或评估宿主机 Wine 路径（对无内核反作弊游戏，C1 已证明 Wine D3DMetal 可达 353 FPS）。
   - 若实测表明 Guest 侧渲染很快（< 4 ms）而网络传输 + 同步等待占主导：则优先落地 **路线 A（共享内存环形缓冲 + 双缓冲异步 fence + `metal_host` MetalFX 缩放）**，在严格守住窗口 B 反作弊保护边界的前提下显著降低卸载延迟。
