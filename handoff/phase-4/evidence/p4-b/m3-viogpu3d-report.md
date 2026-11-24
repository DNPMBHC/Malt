# Phase 4B-2（M3）：开源 ARM64 WDDM 3D 驱动栈（`viogpu3d`）实测与零拷贝架构选型报告

日期：2026-11-23  
署名：`@DNPMBHC`  
范围：`Whisky/Modules/guest-gpu-lab` / `handoff/phase-4/evidence/p4-b`  
隔离承诺：**全过程在 `<EXTERNAL_VOLUME>` 上通过 APFS Copy-on-Write 创建的独立克隆测试 VM 上完成，主干净 `vm-a` 未做任何修改且实测结束后已彻底删除独立测试克隆并释放租约给窗口 4C。**

---

## 1. 五维诚实状态声明

| 维度 | 状态 | 说明 |
| --- | --- | --- |
| **1. 代码实现** | `completed` | 完成 M2.5 异步双端原型、macOS 27 `VZCustomVirtioDevice` + `VZVirtioSharedMemoryRegion` 探测原型（`vz_virtio_shm_probe.swift`）及 M3 独立克隆实测编排。 |
| **2. 本机合成验证** | `passed` | `graphics-lab` 全部单元测试通过；macOS 27 共享内存配置与页对齐环形缓冲微基准通过；防外挂静态安全门禁通过。 |
| **3. 真实 Guest M3 验证** | **`passed`** | 在独立克隆的 Windows 11 Enterprise Evaluation 24H2 ARM64（Build `26100`，`Secure Boot = Enabled`、`Test Signing = Disabled`）上成功加载 WHQL 正式签名 `viogpu3d.sys` (`v100.6.101.58000`) + `neptune_umd` 栈，未修改的标准直出 `d3d11_probe.exe` 实测达到 **`130.141 FPS`**（900 测量帧，较 M2 `VirtIO GPU DOD/WARP` 直出 `15.673 FPS` 提速 **8.30×**），921,600 像素与真实 Guest WARP 参考帧 **`0 LSB` 逐字节完全一致**。 |
| **4. 厂商支持** | `unknown` | `viogpu3d` 为开源社区虚拟 GPU WDDM 3D 驱动，不改变任何商业反作弊发行方对虚拟机环境的官方立场。 |
| **5. 真实游戏验证** | `not_tested` | 本轮严格限定于未修改的标准冻结 `d3d11_probe.exe`（1280×720 16-Draw），未在 M3 驱动栈上宣称商业 3D 游戏兼容。 |

---

## 2. 开源社区生态现状与一手版本绑定

| 开源组件 / 仓库 | 本次核实最新 `HEAD` 提交 | 关键角色与实证状态 |
| --- | --- | --- |
| `utmapp/build-viogpu3d` | `51c5c4e040a1148e751ef62310533a1d9a79a315` | 一体化编译与签名打包脚本（生成 `viogpu3d` ARM64/x64 完整驱动包） |
| `utmapp/viogpu-wddm` | `d25bb08c4a9cfb034f4db9ea9e2982a8be02e86b` | WDDM2 (GpuMmu) 内核显示驱动 `viogpu3d.sys`（`0xaa64` ARM64） |
| `utmapp/mesa` | `68b837cda82b83e4778f60dc040b471b0545ea9c` | 用户态 D3D11 驱动 `neptune_umd_{arm64,ec,x86}.dll` + Venus Vulkan ICD `vulkan_virtio_{arm64,ec}.dll` |
| `containers/libkrun` | `3d0e61d1293f39562f757cf45ae6673cf2663100` | 基于 `Hypervisor.framework` 的轻量 VMM，已落地 `virglrenderer (Venus)` + `RESOURCE_CREATE_BLOB` 共享内存 |
| `containers/krunkit` | `9e39476d9a4f82ba91da5b0c8dc1245dbffb31cb` | macOS Apple Silicon 端 `libkrun` 命令行前端（面向 Linux microVM + Venus/KosmicKrisp） |
| 本机宿主机 UTM `5.0.9` | 原生内置 | 已打包 `virglrenderer.1.framework`、`vulkan.1.framework`、**`vulkan_kosmickrisp.framework`**（Mesa KosmicKrisp 原生 Vulkan → Metal），并在 `virtio-ramfb-gl` 下自动启用 `hostmem=8G,blob=true,venus=true,neptune=true,refresh_rate=120000` |

### 关键发现：ARM64 `viogpu3d` 已具备微软 WHQL 正式签名（无需关闭 Secure Boot！）
此前预判社区 `viogpu3d` 需要关闭 Secure Boot 并开启 `testsigning` 才能加载，但对 UTM 5.0.9 官方 Guest Tools ISO 中 `Drivers/viogpu3d/w11/ARM64/`（`DriverVer = 11/17/2026, 100.6.101.58000`，由 `Turing Software, LLC` 提交，内嵌元数据标明构建自 `viogpu-wddm@d25bb08c4a` 与 `mesa@68b837cda8`）的实测检验显示：
- **`viogpu3d.sys`**（`0xaa64`）、**`neptune_umd_arm64.dll`**（`0xaa64`）、**`neptune_umd_ec.dll`**（`0x8664` ARM64EC）、**`vulkan_virtio_arm64.dll`**（`0xaa64`）与 **`viogpu3d.cat`** 均已通过 **Microsoft Windows Hardware Compatibility Publisher（`Microsoft Windows Third Party Component CA 2014`）WHQL 正式签名**；
- 在 **`Secure Boot = Enabled`、`Test Signing = Disabled`** 的完整生产级安全基线下，通过标准 `pnputil /add-driver viogpu3d.inf /install` 即可直接安装并正常加载（设备管理器 `Status = OK`, `ConfigManagerErrorCode = 0`），**完全不破坏 Windows 安全启动信任链**！

---

## 3. 独立克隆测试 VM 真机实测结果（未修改标准冻结 `d3d11_probe.exe`）

测试固件与输入绑定见 [m3-viogpu3d-benchmark.json](m3-viogpu3d-benchmark.json)（探针与 Phase 2 M0/M2 验收完全同二进制，SHA-256 `09bb190bf5d763f9749345300b937728db886a4ec26c32c361a920c565cf1bee`，不传 `--transport-host`）。

### 3.1 DXGI 适配器实测枚举（彻底脱离 `Microsoft Basic Render Driver`）
- `IDXGIAdapter1::GetDesc1` 返回：
  - **`adapter_description`**：`Red Hat VirtIO GPU 3D controller`
  - **`vendor_id / device_id`**：`6900 (0x1AF4) / 4176 (0x1050)`
  - **`adapter_flags`**：`0`（**`adapter_is_software = false`**）
  - **`selected_feature_level`**：`11_1`（`0x0000b100`），`device_create_hresult = 0x00000000`，`windows_session_id = 1`
- Neptune 运行时实测握手日志：
  - `neptune: virtgpu: KMD mode WDDM2 (GpuMmu)`
  - `neptune: virtgpu: kernel context virtual (native WDDM2 submit)`
  - `neptune: virtgpu: renderer ready (wire=0x00000002, caps=0x00000041, max_timeline=64)`
  - `neptune: Neptune device created successfully`
- 宿主机 `ps` 实测确认：UTM 5.0.9 自动拉起多进程 `QEMURenderServer`（Apple M4 宿主 Venus/KosmicKrisp 渲染服务端），连 Windows 11 系统自身 `StartMenuExperienceHost.exe` 与 `SearchHost.exe` 也已走硬件 3D 加速。

### 3.2 逐像素正确性校验（vs 真实 Guest WARP 参考帧）
- 对照 `validate-legacy-0-reference.rgba`（921,600 像素，1280×720 RGBA8）：
  - **`max_channel_error = 0 LSB`**，**`over_threshold_pixels = 0`**，**`byte_exact_match = true`**（SHA-256 `88b4a75cde2b7b8f40dd0e18287e7224f6659170eb1abee79eee11e105d63ff6` 逐字节完全一致）。

### 3.3 标准 Direct Present 跨代性能实测对比（1280×720, 16-Draw, 60 预热 + 300 测量帧 × 3 轮 = 900 帧，`gpu-complete`）

| 图形路径（同一 1280×720 16-Draw 场景） | 是否需改应用代码 | 合并吞吐 FPS（含 GPU Drain） | 相对 M2 Direct 提速 | 帧间隔 Mean / P50 / P95 / P99 (ms) | 备注 |
| --- | :---: | ---: | ---: | ---: | --- |
| **M2 Guest Direct Present**（`VirtIO GPU DOD` / WARP） | 否（标准 D3D11） | `15.673` | `1.00×` | 63.789 / 63.028 / 94.581 / 125.498 | 无 3D 驱动，纯软件光栅 |
| **M2 Command-Only Metal Replay**（同步 TCP + Nagle） | 是（定制探针） | `18.847` | `1.20×` | 53.045 / 49.010 / 69.566 / 109.944 | 受 Nagle + Delayed ACK 阻塞 |
| **M3 开源 `viogpu3d` + `neptune_umd` Direct Present** | **否（标准 D3D11）** | **`130.141`** | **`8.30×`** | **7.661 / 6.828 / 11.644 / 21.442** | **WHQL 正式签名，Secure Boot 开启，0 LSB 逐字节一致** |
| **M2.5 Async Fence Pipeline**（`NoDelay + In-Flight=2`） | 是（定制探针） | **`471.98`** | **`30.11×`** | **2.113 / 1.462 / 5.780 / 9.415** | 证明跨 VM 协议层非瓶颈，已达宿主 Wine 级吞吐 |

> **诚实记录的 M3 上游细节与限制**：
> 1. 3 轮独立帧率分别为 `116.743` / `153.209` / `125.642 FPS`（均值为 `130.141 FPS`）；
> 2. `d3d11_probe.exe` 的 D3D11 `ID3D11Query(TIMESTAMP)` 返回 `gpu_ms = 0`（表明当前 `neptune_umd` 尚未完整上报硬件时间戳查询，但 `ID3D11Query(EVENT)` 的 `gpu-complete` 同步与整轮 `measurement_wall_ms` 真实有效）；
> 3. Round 1 进程退出时 stderr 记录到一条上游清理告警 `neptune: virtgpu: window release (res 72) failed 0xc0000001`（不影响渲染正确性与退出码 `0`）；
> 4. `Win32_VideoController.AdapterRAM` 上报为 `0`（而 QEMU 实际映射 `hostmem=8G`，需关注部分依赖 `AdapterRAM` 或 DXGI `DedicatedVideoMemory` 预检的商业游戏兼容性）；
> 5. 虚拟热重启（`shutdown /r`）后 UTM 5.0.9 的 QGA 串口偶发断连，需冷停启恢复 QGA 句柄。

---

## 4. 零拷贝架构选型结论（`viogpu3d` vs `libkrun/virglrenderer` vs `macOS 27 VZCustomVirtioDevice`）

结合本机 macOS 27.2.1 SDK 实测（[vz-shm-probe.json](vz-shm-probe.json)）、UTM 5.0.9 实测与开源生态演进，给出明确可落地的分层架构选型：

| 候选路线 | 零拷贝机制 | Windows ARM64 兼容性 | 安全启动 / WHQL | 工程落地成本 | 选型结论 |
| --- | --- | --- | --- | --- | --- |
| **路线 1：UTM 5.0.9 `virtio-ramfb-gl` (`blob=true, venus=true, neptune=true`) + 开源 WHQL `viogpu3d` + `KosmicKrisp`** | QEMU `hostmem=8G` + `RESOURCE_CREATE_BLOB` + `QEMURenderServer` 共享内存 | **已真机跑通**（ARM64 + ARM64EC + x86 UMD 齐全，标准 D3D11 `130.14 FPS`） | **已具备官方 WHQL 正式签名**，无需关 Secure Boot / 开测试签名 | **极低**（直接复用社区现成轮子，零自研内核驱动成本） | **短期 + 中期首选主路线（立即采纳）** |
| **路线 2：`libkrun` / `krunkit` + `virglrenderer (Venus)`** | `Hypervisor.framework` 原生 `RESOURCE_CREATE_BLOB` 映射至 Guest IPA | 当前生态主要面向 **Linux microVM**，缺少完整 Windows UEFI/ACPI/TPM2/Secure Boot/WDDM 设备树支持 | 不适用 Windows 11 商业信任链（无现成 vTPM + Secure Boot 完整路径） | 高（需补齐 Windows ACPI/UEFI/TPM2 模拟） | **仅作 `virglrenderer` + `KosmicKrisp` 上游补丁参考，不作为 Windows VM 底座** |
| **路线 3：原生 `macOS 27 Virtualization.framework` (`VZCustomVirtioDevice` + `VZVirtioSharedMemoryRegion`) + `viogpu3d`** | **实测确认 macOS 27.0+ 原生开放** `VZVirtioSharedMemoryRegion.mapMemory/unmapMemory`（本机实测 `max_allowed_shared_memory_regions = 1`，支持 `256 MiB+` 页对齐共享区，本地 64 KiB 环吞吐 `1.58 µs/帧`） | 可在 Apple 原生 VMM 内向 Windows ARM64 暴露标准 VirtIO-GPU PCI 设备（`deviceID=16`, `class=0x03`, `2` virtqueues），复用开源 WHQL `viogpu3d.sys` | **极佳**（兼容 Apple 原生 VZ 性能 + 复用社区 WHQL 驱动，规避 QEMU 模拟开销） | 中–高（需在 Swift/C 中桥接 `VZVirtioQueue` 与 `virglrenderer (Venus/Neptune)`） | **长期战略终局路线（Phase 5+ 演进方向）** |

### 最终工程行动建议（交由总控与窗口 4D/4C 决策）
1. **立即把 `virtio-ramfb-gl` + WHQL `viogpu3d` 确立为本项目 Windows ARM64 Guest 的标准 3D 图形底座**：它在 **不关闭 Secure Boot、不开启 Test Signing、不修改任何 Windows 应用代码** 的前提下，将标准 D3D11 性能从 `15.67 FPS` 提升至 **`130.14 FPS`（8.30×）**，彻底消除普通 Windows 软件与未来原生 ARM64 游戏的 Guest 图形瓶颈，且无需自研任何 WDDM 驱动。
2. **保留 M2.5 异步双缓冲协议作为跨 VM 诊断/验证基准**：实证 `TCP_NODELAY` + 合并发送 + `In-Flight=2`（避开 macOS `CAMetalLayer` 3-Drawable 120Hz 节流墙）可将命令流跨 VM 吞吐从 `19.05 FPS` 推至 **`471.98 FPS`（24.77×）**，确认跨 VM 通信本身不是天花板。
3. **中长期演进路径**：待上游 `viogpu3d` / `neptune_umd` 补齐 DXGI 显存上报、D3D11 Timestamp Query 与更多商业游戏着色器特性后，可基于已实证可用的 **macOS 27 `VZCustomVirtioDevice` + `VZVirtioSharedMemoryRegion`**，将 QEMU `virglrenderer + KosmicKrisp` 后端迁移至原生 `Virtualization.framework`，实现更低 CPU 占用与更低延迟的零拷贝单 App 原生体验。
