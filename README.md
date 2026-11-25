<div align="center">

  # Malt 🥃
  **面向 Apple Silicon (macOS) 的现代化 Windows 游戏与应用运行平台**  
  *A modern Windows gaming & application runtime for Apple Silicon Macs*

</div>

---

## 关于 Malt (About)

**Malt** 基于开源项目 [Whisky](https://github.com/Whisky-App/Whisky) 演进，专为 Apple Silicon（M 系列芯片，macOS 14+）打造。项目致力于通过简洁原生的 SwiftUI 界面，将图形转译与轻量硬件加速容器融为一体，让 macOS 用户无需繁琐的底层配置即可流畅运行 Windows 游戏与软件。

> ⚠️ **开发状态说明**：本项目目前仍处于持续开发与架构演进阶段，部分界面整合与性能优化仍在迭代完善中。

---

## 核心功能 (Features)

- **统一游戏库与一键直达**：在同一套原生界面中统一管理并快速启动 Windows 游戏与软件，告别多工具切换。
- **零门槛自动适配**：自动识别本机 Apple Silicon 硬件规格、屏幕刷新率与外置高速硬盘，提供轻量自动测速与三档预设（竞技高帧 / 平衡推荐 / 原生画质），大幅降低上手门槛。
- **双模式智能运行**：
  - **原生转译模式**：面向大多数 Windows 游戏与应用，自动路由至最优 Metal 图形转译后端；
  - **硬件加速容器模式**：面向依赖完整 Windows ARM64 环境的大型软件，通过无边框应用壳直出安装器与游戏窗口，最大程度弱化底层环境存在感。
- **原生全屏与游戏体验打磨**：
  - 支持无边框原生全屏并自动适配 **macOS 游戏模式（Game Mode）**；
  - 针对 **1000Hz–8000Hz 高回报率鼠标**提供无损相对位移合批，减少高速移动时的输入开销；
  - 全屏游戏期自动屏蔽 `Cmd+W / Cmd+Q / Cmd+H / Cmd+M` 防误触，适配 `Option→Alt`、`F1–F12` 直通，保留 `Cmd+Option+G` 与 `Cmd+Tab` 安全切出。
- **轻量与外置存储友好**：主程序保持轻量化体积，支持将运行环境与大容量游戏数据无缝存放于外置高速 SSD。

---

## 技术架构 (Architecture & Technologies)

- **多引擎图形转译路由**：整合 **DXMT**（DirectX 10/11 → Metal 默认主力）、**D3DMetal**（DirectX 12 主力）、**DXVK + MoltenVK** 及实验性 **KosmicKrisp**（Vulkan 1.4），支持 MetalFX 空间超分与持久化着色器缓存。
- **定制硬件加速呈现与输入管线**：基于开源 **UTM** 与 **CocoaSpice** 维护极简合规补丁集，默认启用 `dxmt-native` Metal 渲染、三重缓冲帧队列背压控制、`UserInteractive` 渲染线程 QoS 及无损高回报率鼠标合批。
- **原生 I/O、内存与网络优化**：启用 `VirtIO-Blk` 多队列（`num-queues` + 独立 `iothread` + `discard=unmap`）、Apple Silicon 统一内存按需分页协同，以及面向 macOS 原生 `vmnet` 与零特权异步流的低延迟网络管线。

---

## 致谢开源社区 (Credits & Acknowledgements)

**Malt** 的诞生与演进离不开众多开源项目与开发者的无私付出，在此向所有上游作者与社区贡献者致以最诚挚的感谢：

- **[Whisky](https://github.com/Whisky-App/Whisky)**（IsaacMarovitz 及全体贡献者）— 本项目的起点与原生 SwiftUI 架构基石
- **[WineHQ](https://www.winehq.org/) & [CrossOver](https://www.codeweavers.com/crossover)** — Windows 兼容层的核心基石
- **[DXMT](https://github.com/3Shain/dxmt)**（3Shain）— 卓越的 Direct3D 10/11 到 Metal 原生转译实现
- **[DXVK-macOS](https://github.com/Gcenx/DXVK-macOS)**、**[MoltenVK](https://github.com/KhronosGroup/MoltenVK)** 与 **[Mesa / KosmicKrisp](https://gitlab.freedesktop.org/mesa/mesa)** — 跨平台 DirectX / Vulkan 图形生态
- **Apple Game Porting Toolkit (`D3DMetal` & `MetalFX`)** — Apple Silicon 图形转译与超分支持
- **[UTM](https://github.com/utmapp/UTM)**、**[CocoaSpice](https://github.com/utmapp/CocoaSpice)**、**[QEMU](https://www.qemu.org/)** 与 **[VirtIO-Win](https://github.com/virtio-win/kvm-guest-drivers-windows)** — 开源虚拟化、SPICE 呈现与硬件加速驱动生态
- **[Sparkle](https://github.com/sparkle-project/Sparkle)**、**[SemanticVersion](https://github.com/SwiftPackageIndex/SemanticVersion)**、**[swift-argument-parser](https://github.com/apple/swift-argument-parser)**、**[SwiftyTextTable](https://github.com/scottrhoyt/SwiftyTextTable)**

本项目遵循 **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** 协议开源。用户在使用本软件运行任何操作系统、软件或游戏时，请自行确保拥有合法授权并遵守对应软件的最终用户许可协议（EULA）。

---

## 系统要求 (System Requirements)

- **芯片**：Apple Silicon（M1 及以上 `arm64`）
- **系统**：macOS Sonoma 14.0 或更高版本

---

## 阶段性实测参考 (Preliminary Benchmarks)

> 以下为开发版在 Apple Silicon（10 核 / 16 GiB 统一内存）上的阶段性真机测试摘要，随版本迭代持续优化：

- **《无畏契约》（VALORANT 国服，容器模式实测）**：完整跑通教学、主大厅与 `1920×1200` 靶场连续实战（25 分钟 0 崩溃），主大厅约 `102 FPS`，`1920×1200` 靶场预热稳态约 `55–58 FPS`，宿主机内存占用约 `1.6 GiB`。
- **原生转译与底层管线基准**：
  - DirectX 11 原生转译（`DXMT`）较传统路径显著降低显存占用并保持高帧率输出；
  - 容器内大场景优化后 `0.1% Low` 帧率提升 **`+72.8%`**，宿主机 CPU 占用降低 **`-31.1%`**；
  - `VirtIO-Blk` 多队列 4K 随机读 IOPS 提升 **`+52.7%`**，原生 `vmnet` 网络中位延迟降低 **`-23.5%`**，8000Hz 鼠标无损合批减包 **`11.8×`**（零像素误差）。

---

## 法律声明与免责条款 (Legal Notice & Disclaimer)

### 中文声明

1. **技术中立与非隶属声明**：**Malt** 是依据 **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** 发布的非商业、技术中立的通用兼容层与运行环境工具。本项目独立开发与维护，与任何第三方操作系统厂商、软件开发商或游戏发行商均无隶属、合作、代理、授权或背书关系。
2. **知识产权与指示性说明**：本仓库不存储、不分发、不托管任何第三方操作系统镜像、商业软件客户端、专有驱动或其他受版权保护的专有文件。文档中出于客观记录兼容性测试目的提及的第三方软件或游戏名称，仅构成事实性指示说明，其商标权、著作权及其他知识产权均归各自权利人所有。
3. **合法使用边界**：本软件不修改、不逆向、不注入、不干扰任何第三方程序的二进制文件、内存数据或网络通信，亦不提供规避技术保护措施或破坏软件正常运行的任何功能。使用者在运行任何第三方操作系统、软件或游戏前，须自行确保已取得合法授权，并独立承担遵守适用法律法规及对应第三方最终用户许可协议（EULA / ToS）的责任；严禁任何个人或组织将本项目用于任何违法、侵权或违反第三方服务条款的用途。
4. **无担保与责任限制（援引 GPL-3.0 第 15、16 条）**：依据本软件所适用的 GNU GPL v3 协议第 15 条及第 16 条，在适用法律允许的最大范围内，本软件按“现状（AS IS）”提供，不附带任何明示或暗示的担保（包括但不限于适销性、特定用途适用性、兼容性、稳定性或在线服务可用性）。因使用或无法使用本软件（包括在第三方厂商未官方支持的运行环境中运行软件）所引致的任何直接、间接、附带或后果性损失（含账号限制、数据丢失或业务中断等），均由使用者自行承担，版权持有人及项目贡献者不承担任何法律或赔偿责任。
5. **权利人通知与移除机制**：本项目充分尊重第三方合法权益。若任何权利人认为本仓库中的任何文字描述、测试记录或引用内容可能涉及其合法权益，请通过 GitHub Issue 或联系仓库维护者提供权属说明与具体位置，我们将在核实后第一时间依法配合修改或移除相关内容。

### English Disclaimer

1. **Technical Neutrality & No Affiliation**: **Malt** is an independent, non-commercial, technology-neutral open-source compatibility and runtime project licensed under **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)**. It is not affiliated with, endorsed by, sponsored by, or associated with any third-party operating system provider, software vendor, or game publisher.
2. **Intellectual Property & Nominative Reference**: This repository does not host, bundle, or distribute any proprietary operating system images, commercial software clients, proprietary drivers, or copyrighted third-party binaries. Any third-party software or game names referenced solely to document factual compatibility testing are used for nominative identification only; all trademarks and copyrights remain the property of their respective owners.
3. **Lawful Use & Non-Interference**: This software does not modify, reverse-engineer, inject into, or interfere with third-party binaries, runtime memory, or network traffic, nor does it provide any functionality to circumvent technological protection measures. Users are solely responsible for holding valid licenses and complying with all applicable laws and third-party End User License Agreements (EULAs) or Terms of Service (ToS). Any unlawful, infringing, or unauthorized use is strictly prohibited.
4. **Disclaimer of Warranty & Limitation of Liability (GPL-3.0 Sections 15 & 16)**: Pursuant to Sections 15 and 16 of the GNU General Public License v3, to the maximum extent permitted by applicable law, this program is provided "AS IS" without warranty of any kind, either expressed or implied, including without limitation implied warranties of merchantability, fitness for a particular purpose, compatibility, or uninterrupted availability. In no event shall any copyright holder or contributor be liable for any direct, indirect, incidental, special, or consequential damages (including account restrictions, data loss, or service interruption) arising out of the use or inability to use this software.
5. **Notice-and-Takedown**: If any rights holder believes that any reference, test record, or content in this repository infringes upon their legal rights, please notify the maintainer via a GitHub Issue with sufficient details, and the relevant material will be promptly reviewed and amended or removed.
