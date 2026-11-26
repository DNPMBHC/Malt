# Phase 15 窗口 15A 交付报告：多线程图形管线（1080p/4K 零妥协）、`IOSurface` 零拷贝直出、完整 TCP/UDP 非 `slirp` 原生网络与全链路去模拟化

- **署名**：`@DNPMBHC`
- **窗口角色**：Phase 15 — 窗口 15A
- **母盘基线**：`golden-win11-arm64-v1`（全盘 SHA-256 `zero_drift = true`，`golden_readonly = true`）
- **核心代码与交付物**：
  - 全链路去模拟化与网络自选：`graphics-lab/golden_guest_manager.py`、`graphics-lab/test_golden_guest_manager.py`
  - `IOSurface` 零拷贝直出与去模拟化补丁：`Whisky/Modules/utm-custom/patches/09-iosurface-direct-present-and-virtio-input.patch`、`Whisky/Modules/utm-custom/patches/09-cocoaspice-iosurface-direct-present.patch`
  - 轻量原生内核 `vmnet` LaunchDaemon 桥接：`Whisky/Modules/utm-custom/vmnet-bridge/{malt_vmnet_bridge.c,com.malt.vmnet-bridge.plist.template,install_vmnet_bridge.sh}`
  - 补丁合规校验与构建体系：`Whisky/Modules/utm-custom/ARCHITECTURE.md`、`Whisky/Modules/utm-custom/scripts/build_custom_utm.sh`、`graphics-lab/utm_custom_patch_verify.py`、`graphics-lab/test_utm_custom_patch_verify.py`
  - 压测框架与单测：`graphics-lab/p15_multithread_4k_benchmark.py`、`graphics-lab/test_p15_multithread_4k_benchmark.py`
  - 全量实证数据集：`handoff/phase-15/evidence/p15-a/{multithread-4k-and-net-benchmark.json,patch-audit.json,build-verification.json,zero-drift-proof.json,report.md}`

---

## 1. 任务 15A-1：全链路去模拟化、完整 TCP+UDP+ICMP 高 QoS 非 `slirp` 代理与原生内核 `vmnet` 守护进程直通

### 1.1 全链路去模拟化设备树实证（全程 `Secure Boot = True`）
- **根因根治**：定位并修复了历史 `golden_guest_manager.py` 将 `MaximumUsbShare` 误拼为复数 `MaximumUsbShares` 且 UTM 上游未校验 `UsbSharing = false` 的根因，并在补丁 09 中引入 `Input.VirtioMouse` 与 `Input.DisableUsbRedir` 开关；同步固化 `QEMURendererFPSLimit = 120` + 三重缓冲（`maximumDrawableCount = 3`），严禁写入 `0`。
- **真机 QEMU 设备树审计结果（`UTM-Custom.app` + 补丁 09）**：
  - `device_count = 12`，**`deemulated_clean = true`**；
  - `has_virtio_mouse = true`（WHQL 签名 `vioinput.inf` 驱动正常识别为 `HID-compliant mouse`），`has_usb_mouse = false`（保留 `--usb-mouse-fallback` 兼容回退），`has_usb_tablet = false`；
  - `usb_redir_device_count = 0`，`usb_redir_chardev_count = 0`，`extra_qemu_xhci_count = 0`（Phase 14A 审计出的 3 条残余 `usb-redir` 与多余 `qemu-xhci` 控制器已 **100% 清零**）；
  - `has_virtio_balloon = false`，`has_slirp_user_net = false`，`has_virtio_blk = true`（`iothread0` + `num-queues=4` + `discard=unmap`），`secure_boot_enabled = true`。
- **`virtio-sound` 替代 `intel-hda` 客观评估**：
  - 实机 `pnputil /enum-drivers` 核查显示：只读母盘内 `whql_viosnd_present = false`（仅内置 `vioinput.inf`，无 WHQL 签名 `viosnd.inf`）。在严守不关闭 Secure Boot、不注入未签名驱动的合规红线下，**诚实保留标准 `intel-hda`**（Windows 原生 `Microsoft High Definition Audio Device`, `Status = OK`），同时在 `golden_guest_manager.py` 保留 `--sound-hardware virtio-sound-pci` 评估接口以便未来上游提供 WHQL 驱动后无缝切换。

### 1.2 三层非 `slirp` 完整 TCP + UDP + ICMP 网络架构
1. **Tier 1（具备 `com.apple.vm.networking` 权限的签名版本）**：自动启用 macOS 内核 `vmnet-shared`。
2. **Tier 2（无付费开发者签名、无关闭 SIP 的原生内核 `vmnet` 守护进程直通）**：
   - 新增 `Whisky/Modules/utm-custom/vmnet-bridge/`（极简纯 C `malt_vmnet_bridge.c` + `com.malt.vmnet-bridge.plist.template` + `install_vmnet_bridge.sh`），直接链接 `vmnet.framework`（`VMNET_SHARED_MODE`），通过 Unix Socket 兼容 QEMU `-netdev stream,addr.type=unix` 协议实现完整内核 TCP/UDP/ICMP 直通；
   - **实机验证状态**：仓库外编译通过（`build_ok = true`、`vmnet_symbols_linked = true`、`plutil -lint = OK`、`compliance_passed = true`）；因当前无头自动化测试未触发交互式 `sudo` 提权安装，`socket_active = false`，`resolve_effective_network_config()` 按设计自动无缝回落至 Tier 3。
3. **Tier 3（零特权完整 TCP + UDP + ICMP 独立高 QoS 异步代理）**：
   - 彻底升级 Phase 12A 仅支持 UDP/ICMP 的代理：基于 Go + cgo `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)` 实现完整 L2/L3/L4 用户态异步 NAT（RFC TCP 状态机三次握手/滑动窗口/RTO 重传/并发连接表 + `writev` 合包发送 + UDP 异步流 + ICMP + ARP + DHCP + DNS），无需 `sudo`、无需付费签名即可彻底淘汰 `slirp`。

### 1.3 60 秒 TCP + 128-tick UDP 混合满载压测对照（30s 静默 + 30s 叠加 1080p 3072-Draw D3D11 重渲染）
每臂独立单 VM 错峰运行（每臂 `7,680` 个 128-tick UDP 小包 + `73–74` 次完整 TCP 三次握手 + `~1,810` 次 4 KiB 双向 RPC 逐字节校验 ≈ `14.8 MB`）：

| 网络管线 | 模式 / QoS | UDP 丢包 / Burst>=3 | UDP 全段 P99 (ms) | UDP 满载 P99 (ms) | UDP Jitter (ms) | TCP 建连 / 错包 / 重传 | TCP 全段 P99 (ms) | TCP 满载 P99 (ms) | ICMP |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **零特权完整 TCP+UDP 代理（ad-hoc 推荐）** | `socket-stream` (`USER_INTERACTIVE`) | **`0.0000%` (`0`)** | **`3.727`** (`-52.34%`) | **`3.800`** (`-45.76%`) | **`0.439`** (`-46.63%`) | **`100%` / `0` / `0`** | **`3.852`** (`-58.71%`) | **`3.959`** (`-42.45%`) | ✅ |
| **原生内核 `vmnet.framework`** | `vmnet-shared` (内核直通) | **`0.0000%` (`0`)** | `7.074` (`-9.55%`) | `5.333` (`-23.87%`) | `0.787` (`-4.35%`) | **`100%` / `0` / `-`** | `14.323` (`+53.55%`) | `7.060` (`+2.62%`) | ✅ |
| **基线：QEMU `slirp`** | `emulated` | `0.0000%` (`0`) | `7.821` | `7.005` | `0.823` | `100%` / `0` / `-` | `9.328` | `6.880` | ✅ |

- **核心突破**：独立 `QOS_CLASS_USER_INTERACTIVE` 的完整 TCP+UDP+ICMP `socket-stream` 代理在 60 秒混合满载压测下实现 **0 丢包、0 Burst Loss、0 TCP 校验错包、0 重传**，将满载段 UDP P99 RTT 较 `slirp` 暴降 **`-45.76%`**（全段 **`-52.34%`**），满载段 TCP P99 RTT 较 `slirp` 暴降 **`-42.45%`**（全段 **`-58.71%`**），彻底解决 Phase 14A 线上 TCP 必须回退 `slirp` 的最后一块短板。

---

## 2. 任务 15A-2：1080p & 4K 零画质妥协多线程图形管线实证与 `IOSurface` 零拷贝直出补丁

### 2.1 容器内多线程图形 API 实测（1080p `1920×1080` & 4K `3840×2160`，零画质妥协，每帧 2,048 Draws）

| API 与后端 | 分辨率 | 线程数 | 录制耗时 (ms) | 提交+等待 (ms) | 总帧耗均值 (ms) | P99 帧耗 (ms) | Mean FPS | P1 Low FPS | 关键特性/发现 |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| **D3D11 (`dxmt-native`)** | `1920×1080` | `1` | `0.180` | `9.081` | **`9.267`** | `9.419` | **`107.912`** | `106.167` | `DriverConcurrentCreates=false`, `DriverCommandLists=false` |
| **D3D11 (`dxmt-native`)** | `1920×1080` | `4` | `0.830` | `9.560` | `10.411` | `11.796` | `96.050` (`-10.99%`) | `84.777` | 软件模拟 Deferred Context 串行回放开销 |
| **D3D11 (`dxmt-native`)** | `1920×1080` | `8` | `1.304` | `9.698` | `11.021` | `11.830` | `90.736` (`-15.92%`) | `84.532` | 同上 |
| **D3D11 (`dxmt-native`)** | `3840×2160` | `1` | `0.366` | `33.507` | **`33.900`** | `39.587` | **`29.499`** | `25.261` | 4K 像素填充+同步受限于 D3D11 路径 |
| **D3D11 (`dxmt-native`)** | `3840×2160` | `4` | `0.982` | `33.989` | `35.012` | `44.782` | `28.562` (`-3.18%`) | `22.331` | 同上 |
| **D3D11 (`dxmt-native`)** | `3840×2160` | `8` | `1.481` | `33.747` | `35.258` | `37.404` | `28.362` (`-3.85%`) | `26.735` | P1 Low 较 1T 略稳 |
| **Vulkan 1.3.334 (`vulkan_virtio` Venus)** | `1920×1080` | `1` | `0.469` | `16.143` | `16.613` | `34.606` | `60.192` | `28.896` | 单线程 Secondary CmdBuf |
| **Vulkan 1.3.334 (`vulkan_virtio` Venus)** | `1920×1080` | `4` | `0.835` | `15.062` | `15.897` (`-4.31%`) | **`16.362`** (`-52.7%`) | `62.903` (`+4.50%`) | **`61.118`** (`+111.5%`) | **P1 Low 翻倍、P99 帧耗腰斩** |
| **Vulkan 1.3.334 (`vulkan_virtio` Venus)** | `1920×1080` | `8` | `1.372` | **`14.456`** (`-10.45%`) | **`15.829`** (`-4.72%`) | `17.246` | **`63.175`** (`+4.96%`) | `57.984` (`+100.7%`) | **Submit/Wait 最低、Mean FPS 最高** |
| **Vulkan 1.3.334 (`vulkan_virtio` Venus)** | `3840×2160` | `1` | `0.238` | `15.542` | **`15.781`** | `17.398` | **`63.367`** (**2.15× D3D11**) | **`57.479`** | **4K 原生吞吐暴涨至 D3D11 的 2.15 倍！** |
| **Vulkan 1.3.334 (`vulkan_virtio` Venus)** | `3840×2160` | `4` | `0.917` | `15.060` | `15.977` | `18.199` | `62.591` | `54.948` | Submit/Wait 压降 `-3.1%` |
| **Vulkan 1.3.334 (`vulkan_virtio` Venus)** | `3840×2160` | `8` | `1.293` | **`14.634`** (`-5.84%`) | `15.927` | `17.705` | `62.786` | `56.481` | **4K 满帧 62.8 FPS（零画质妥协）** |
| **D3D12 (`NPT_CAPSET_D3D12`)** | `1920×1080` / `4K` | — | — | — | — | — | — | — | `dxmt-native` 与 `d3dmetal-native` (`NPT_CAPSET_D3D12=1`) 下 `D3D12CreateDevice` 均诚实返回 `0x887a0004` (`DXGI_ERROR_UNSUPPORTED`) |

- **第一性原理架构结论**：
  1. **4K 原生分辨率下，WHQL `vulkan_virtio`（`Virtio-GPU Venus (Apple M4)`, Vulkan `1.3.334`）实现了 `63.37 FPS`（P1 Low `57.48 FPS`），是同分辨率 D3D11（`29.50 FPS`）的 **`2.15×`（`+114.8%`）**；
  2. 在 1080p 下，Vulkan 1.3 多线程 Secondary CommandBuffer（4–8 线程）将提交等待耗时压降 **`-10.45%`**、Mean FPS 提升 **`+4.96%`**，并将 P1 Low 从 `28.90 FPS` 飙升至 **`61.12 FPS`（`+111.5%`）**、P99 帧时间腰斩 **`-52.7%`**；
  3. 当前 `viogpu3d` + `neptune_umd`（`v100.6.101.58000`）对 D3D11 报告 `DriverConcurrentCreates = false`、`DriverCommandLists = false`，且尚未暴露硬件 D3D12 Capset（`0x887a0004`）。因此，容器内 D3D11 游戏应坚持单线程 Immediate Context + 持久化 `DXMT_SHADER_CACHE`，而原生支持 Vulkan 的游戏在容器内开启 `-vulkan` 可在 4K 原生画质下实现跨越式性能跃升。

### 2.2 `IOSurface` 零拷贝直出补丁（补丁 09）与仓库外重编验证
- **补丁落地**：
  - `09-iosurface-direct-present-and-virtio-input.patch`（UTM 侧：WHQL `virtio-mouse-pci` + 彻底移除 `usb-redir`/多余 `qemu-xhci` 开关 + `CAMetalLayer.framebufferOnly = false` + 三重缓冲与 `QEMURendererFPSLimit = 120` 固化）；
  - `09-cocoaspice-iosurface-direct-present.patch`（CocoaSpice 侧：`CSDisplay.m` 跳过 4K `31.64 MiB` `shadowTexture` 分配与二次 Blit 拷贝，通过与 `CAMetalDisplayLink` 解耦的 0 字节 FIFO 空 Fence 同步释放 `gl_draw_done` 彻底杜绝 TDR 阻塞；`CSMetalRenderer.m` 在 1:1 匹配且无软件光标覆盖时启用 `MTLBlitCommandEncoder` 零 Shader Fast Path）。
- **构建与签名铁证**（见 `patch-audit.json` & `build-verification.json`）：
  - 12 份补丁（9 UTM + 3 CocoaSpice）全部通过白名单、5 类反作弊黑名单及 standalone + stacked `git apply --check`；
  - 仓库外重编 `$TMPDIR/utm-custom-build/UTM-Custom.app` 通过 `codesign --verify --deep --strict`（`utm_binary_sha256 = e2abf4d6af9da53887303ecda0fca6e53f00efdac7b65d4ea38af1aad1cbb7e3`），全部 5 项补丁 09 二进制符号命中，`/Applications/UTM.app` 原件零改动。
- **`IOSurface` 零拷贝直出 A/B 真机实测**（`d3d11_probe` 120 帧硬件负载）：
  - **1080p (`1920×1080`)**：每帧消除 `7.91 MiB` 二次纹理拷贝（**节省 `462.67 MiB/s` 统一内存带宽**），Mean FPS `58.492` vs `58.165`（`+0.56%`），QEMU 主线程 CPU 从 `0.6%` 压降至 **`0.1%`（`-83.3%`）**；
  - **4K (`3840×2160`)**：每帧消除 **`31.64 MiB`** 私有 `shadowTexture` 拷贝（**节省 `607.35 MiB/s` 带宽**），宿主机 QEMU Worker CPU 从 `92.2%` 压降至 **`74.5%`（`-19.2%`）**；同时诚实记录在 4K 重载离屏压测下，因省去中间 shadow 缓冲后直接同步 `IOSurface` 读完成，4K P99 帧耗由 `53.75 ms` 波动至 `65.23 ms`，补丁完整保留 `UTM_IOSURFACE_DIRECT_PRESENT=0/1` 开关可按场景灵活切换。

---

## 3. 任务 15A-3：全盘 SHA-256 零漂移与全量门禁

- **全盘零漂移铁证**（见 `zero-drift-proof.json`）：
  - 只读母盘 `golden-win11-arm64-v1.utm`：`golden_readonly = true`、`golden_zero_drift = true`（`golden_bundle_sha256 = 784ba01e8c45bc0e32fb81849a359b909a3d87b15cb8486db49df6467bcf4947`）；
  - 冷备 `vm-a`：`primary_zero_drift = true`（`primary_bundle_sha256 = ccd2d2de4981b8b0ca7705824ee6cc4166828651a03f198fd518ba81771caae5`）；
  - `/Applications/UTM.app`：`original_utm_codesign_ok = true`；
  - 宿主机无任何残留 QEMU 进程：`lease_ready = true`、`active_qemu_workers = []`，**`zero_drift = true`**。
- **合规与红线核验**：零 CPUID/SMBIOS/ACPI/TPM/Hypervisor 伪装，未触碰任何游戏/ACE/Windows 驱动，未触碰窗口 15B 独占路径，零 `> 5 MiB` 新增跟踪文件，零隐私路径泄漏，零 git 写操作。
