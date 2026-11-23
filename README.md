<div align="center">

  # Whisky_new 🥃
  *Apple Silicon (macOS) 开源游戏兼容性研究、三引擎图形转译与运行时调度框架*  
  *Open-Source macOS (Apple Silicon) Game Compatibility Research, Three-Engine Graphics Translation & Runtime Orchestration Framework*

</div>

---

## 1. 项目定位与架构概览 (Project Overview & Architecture)

`Whisky_new` 是面向 Apple Silicon (`arm64`, macOS 14+) 的原生 SwiftUI 兼容性研究与运行时调度应用，整合以下核心能力：

1. **三引擎 DirectX 图形转译自动路由 (Three-Engine DirectX Translation Router)**：
   - **DXMT (v0.80+)**：`D3D10 / D3D11 -> Metal` 直接转译，作为 DirectX 11 性能优先默认引擎，支持 Bottle 级着色器缓存与 MetalFX 空间超分交换链配置。
   - **D3DMetal (Game Porting Toolkit)**：`D3D11 / D3D12 -> Metal`，独占承担 DirectX 12 工作负载并作为 DirectX 11 第二候选。
   - **DXVK (macOS MoltenVK)**：`D3D9 / D3D10 / D3D11 -> Vulkan -> Metal`，作为跨引擎兼容兜底路径。
2. **宿主自适应资源策略 (Adaptive Host Resource Policy)**：
   - 根据 macOS 热状态（Thermal State）、低电量模式与 MetalFX 能力，非破坏性地调节编译并发与进程 QoS。
3. **五维状态分离与反作弊合规研究架构 (Five-Dimension Status Separation & Anti-Cheat Compliance Research)**：
   - 严格区分 **「代码实现」「本机合成验证」「真实 Guest/Wine 验证」「厂商支持（许可 vs 支持）」「真实游戏验证（驱动加载 / 游戏启动 / 受保护在线会话）」**。
   - 严格拆分 **「裸金属 Windows on ARM 驱动可用性（Windows 11 24H2+ Prism 用户态 AVX/AVX2 转译 + 原生 ARM64 内核驱动分发）」** 与 **「虚拟化 ARM64 Guest 策略（Hypervisor / vTPM / IOMMU / VBS 硬件信任根限制）」**。
   - 内置从 `module-f` 单源编译的只读兼容规则库（`compatibility-matrix.json`）。

---

## 2. 防外挂滥用安全红线 (Anti-Cheat Abuse Hardening Red Lines)

在保证开源透明的前提下，为防止任何不法分子利用本框架制作外挂，本项目在架构与构建层强制执行以下 **5 条不可妥协的安全红线**：

1. **零作弊原语（Clean-by-Design）**：
   - 严禁在 VMM、Guest Provider、图形卸载层、探针或 CLI 中提供读取/修改目标游戏进程内存、向受保护进程注入 DLL/Hook、伪造硬件标识（HWID/SMBIOS/vTPM）或隐瞒虚拟化（Hypervisor Hiding）的任何接口或调试开关。
2. **宿主进程防寄生加固（Hardened Runtime）**：
   - 正式构建的 `Whisky.app` 及所有辅助可执行文件（含 `WhiskyCmd`、`WhiskyThumbnail`）强制启用 macOS **Hardened Runtime** + **Library Validation**，严禁开启 `com.apple.security.get-task-allow`、`com.apple.security.cs.allow-dyld-environment-variables`、`com.apple.security.cs.disable-library-validation` 与 `com.apple.security.cs.allow-unsigned-executable-memory`，防止外部外挂进程在 SIP 开启状态下附加调试或寄生读取内存。
3. **禁止“截帧 + 宏注入”AI 自瞄闭环**：
   - 生产构建禁用 QMP / GDB 调试端口与内存 dump 接口；
   - 图形呈现通道禁止暴露第三方截帧导出插件钩子；
   - 输入透传严格限定真实物理 HID 输入事件源，拒绝合成/脚本化键鼠宏回注。
4. **诚实身份与可验证官方发行链**：
   - 始终向 Guest 与反作弊系统暴露真实平台与虚拟化身份，不撒谎、不伪装；
   - 预留只读、结构化的 `RuntimeIntegrityReport` 诚实诊断接口（报告宿主机 SIP 状态、代码签名与 Hardened Runtime 状态、以及真实/虚拟执行环境），供未来与反作弊厂商的合法合规远程证明对接。
5. **诚实声明单边开源物理边界**：
   - 单边开源客户端的 Hardened Runtime 仅在宿主机开启 macOS SIP 且运行官方签名构建时提供防外部寄生保护；单边开源无法在物理上阻止用户自行关闭 SIP 后编译私有魔改分支，完整防篡改闭环须由反作弊服务端通过密码学远程证明（Cryptographic Remote Attestation）协同校验。

---

## 3. 法律与合规免责声明 (Legal & Compliance Disclaimer)

### 中文版（简体中文）

> **免责声明（Disclaimer）**
> 1. 本项目（`Whisky_new`）是一款面向 macOS（Apple Silicon）的开源兼容性研究、游戏运行调度与图形转译框架，**仅限用于合法技术研究、开源软件开发以及运行用户拥有合法授权的操作系统与软件/游戏**。
> 2. **严禁滥用与反作弊红线**：严禁任何人直接或间接地利用本项目、其源代码或构建产物制作、分发或辅助任何游戏外挂、作弊软件、内存修改器、自动化脚本、硬件伪造工具，或用于规避、对抗、破坏任何反作弊系统与数字版权保护（DRM）机制。
> 3. **尊重平台与厂商条款**：本项目绝不提供任何反作弊绕过或虚拟化隐藏功能。用户在运行任何第三方游戏、启动器或 Windows 操作系统前，必须自行确保已获得合法软件授权，并严格遵守对应游戏发行商与反作弊厂商的最终用户许可协议（EULA）及服务条款（ToS）。
> 4. **责任限制**：本软件按“现状（AS IS）”提供，不附带任何明示或暗示的担保（包括但不限于兼容性、稳定性或在线服务可用性）。因用户私自修改源代码、违反第三方厂商服务条款、或在厂商明确不支持/禁止虚拟化或转译的环境中强行运行所导致的账号限制、封禁、数据丢失、硬件/系统异常或其他法律与经济损失，**本项目作者及所有贡献者不承担任何直接或间接责任**。

### English Version

> **Disclaimer**
> 1. **Lawful Scope**: `Whisky_new` is an open-source compatibility research, game runtime orchestration, and graphics translation framework for macOS (Apple Silicon). **It is strictly intended for lawful technical research, open-source software development, and running operating systems, software, and games for which the user holds valid licenses.**
> 2. **Zero Tolerance for Cheating & Abuse**: Using this project, its source code, or its build artifacts—directly or indirectly—to develop, distribute, or assist any game cheats, memory tampers, aimbots, macro injectors, hardware spoofers, or to bypass, circumvent, or undermine any anti-cheat system or Digital Rights Management (DRM) mechanism is **strictly prohibited**.
> 3. **Respect for Publisher & Vendor Terms**: This project provides **no** anti-cheat bypass or hypervisor-hiding functionality. Before running any third-party game, launcher, or Windows operating system, users must ensure they hold valid software licenses and strictly comply with the End User License Agreement (EULA) and Terms of Service (ToS) of the respective publishers and anti-cheat vendors.
> 4. **Limitation of Liability**: This software is provided "AS IS", without warranty of any kind, express or implied, including but not limited to compatibility, stability, or online service availability. **In no event shall the authors or contributors be liable for any direct or indirect damages**, including account suspension, bans, data loss, system instability, or legal/financial losses arising from private source modifications, violations of third-party terms, or running software in environments unsupported or prohibited by its publisher.

---

## 4. 系统要求与开发验证 (System Requirements & Development)

- **CPU**: Apple Silicon (M-series `arm64`)
- **OS**: macOS Sonoma 14.0 or later
- **开发期自动重建与安全重启 (Auto-Rebuild & Restart)**:
  ```sh
  ./handoff/task-07/dev_restart.sh
  ```
- **防外挂安全加固与兼容矩阵静态门禁**:
  ```sh
  python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test
  python3 handoff/phase-3/evidence/p3-b/compile_compatibility_matrix.py --self-test
  ```

---

## 5. 致谢与开源许可 (Credits & License)

本项目基于 **GNU General Public License v3.0 or later (GPL-3.0-or-later)** 开源，并致敬以下上游与生态项目：
- [Whisky](https://github.com/Whisky-App/Whisky) & [CrossOver / WineHQ](https://www.codeweavers.com/crossover)
- [DXMT](https://github.com/3Shain/dxmt) by 3Shain
- [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) & [MoltenVK](https://github.com/KhronosGroup/MoltenVK)
- Apple `D3DMetal` (Game Porting Toolkit) & `MetalFX`
- [Sparkle](https://github.com/sparkle-project/Sparkle), [SemanticVersion](https://github.com/SwiftPackageIndex/SemanticVersion), [swift-argument-parser](https://github.com/apple/swift-argument-parser), [SwiftTextTable](https://github.com/scottrhoyt/SwiftyTextTable)
