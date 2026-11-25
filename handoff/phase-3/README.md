# Phase 3 总控任务书：极简 Guest 优化、防外挂安全加固与单 App 产品化整合

日期：2026-11-22
前置基线：Phase 2 无镜像线已全面收口（SwiftPM 115 项 / 114 通过 / 1 跳过 / 0 失败；Strict SwiftLint 106 文件 0 违规；Xcode Debug/arm64 构建通过；三引擎 DXMT v0.80 / D3DMetal / DXVK 生产路由与 16,200 帧实测已落地；`module-f` 42 来源 / 45 声明完成 WoA/VM 双轴拆分）。

---

## 1. Phase 3 战略定位与首要焦点

1. **首要研究与验证焦点保持不变**：**VALORANT（国服 ACE + 国际服 Vanguard / On-Demand）** 仍为反作弊内核与极简 Guest 路线的核心焦点（并可辅以已上线原生 ARM64 驱动的 EAC/BattlEye 对照试金石用于排除 Guest 自身配置问题）。
2. **三条并行演进主线**：
   - **Phase 3-A（依赖 Phase 2-A2/B2 跑通干净官方基线后启动）**：[guest-minimal-optimizer.md](./guest-minimal-optimizer.md) —— 反作弊专用极简 Windows 11 24H2+ ARM64 Guest 优化器 + 原生 `Virtualization.framework` 最小设备树 + 开源 `viogpu3d` WDDM 3D 零拷贝卸载评估。
   - **Phase 3-B（不依赖 Windows 镜像，可立即启动）**：[anti-cheat-abuse-hardening-and-packaging.md](./anti-cheat-abuse-hardening-and-packaging.md) —— 防外挂滥用安全加固（Hardened Runtime / 零调试与宏注入 / 诚实身份与远程证明协议预留）、免责声明落盘（仓库 `README` + App 启动/关于页三语合规弹窗）、以及单 App 产品化整合与三引擎运行时包自动管理。
   - **Phase 3-C（不依赖 Windows 镜像，可立即启动）**：[remote-physics-backend.md](./remote-physics-backend.md) —— 面向强硬件信任根反作弊（锁死物理 TPM / 明确禁止 VM）的合规兜底后端 `RemotePhysicsBackend`（统一调度局域网物理副机/合规物理云机低延迟串流）。

---

## 2. 防外挂滥用安全红线（所有 Phase 3 窗口强制执行）

在保证反作弊正常运行与开源透明的前提下，为了防止不法分子直接利用本框架制作外挂，所有代码与构建产物必须满足以下 **5 条不可妥协的红线**：

1. **零作弊原语（Clean-by-Design）**：
   - 严禁在 VMM、Guest Provider、图形卸载层、探针或 CLI 中提供读取/修改目标游戏进程内存、向受保护进程注入 DLL/Hook、伪造硬件标识（HWID/SMBIOS/vTPM）或隐瞒虚拟化（Hypervisor Hiding）的任何接口或调试开关。
2. **宿主进程防寄生加固（Hardened Runtime）**：
   - 正式构建的 `Whisky_new.app` 及所有辅助可执行文件（含 CLI、未来 `MetalOffloadHelper` 与原生 VMM）必须启用严格 macOS **Hardened Runtime** + **Library Validation**，关闭 `com.apple.security.get-task-allow` 与 `DYLD_INSERT_LIBRARIES`，防止外部外挂进程在 SIP 开启状态下附加调试或偷读 VMM 映射的 Guest 内存。
3. **禁止“截帧 + 宏注入”AI 自瞄闭环**：
   - 生产构建禁用 QMP / GDB 调试端口与内存 dump 接口；
   - 图形呈现通道禁止暴露第三方截帧导出插件钩子；
   - Guest 输入透传严格限定真实物理 HID 输入事件源，拒绝合成/脚本化键鼠宏回注。
4. **诚实身份与可验证官方发行链**：
   - 始终向 Guest 与反作弊系统暴露真实平台与虚拟化身份，不撒谎、不伪装；
   - 官方发布采用 Apple Developer ID 签名 + 公证（Notarization）+ CI 可复现构建（公开 SHA-256 清单），并为未来与反作弊厂商的合法合规远程证明（校验宿主机 SIP + 官方签名哈希）预留结构化协议接口。
5. **诚实声明单边开源物理边界**：
   - 任何文档与产品文案均不得夸称“单边开源即可 100% 物理阻止关掉 SIP 后的私有魔改”；必须如实区分「官方签名版防寄生加固」与「需反作弊服务端协同的密码学远程证明」。

---

## 3. 法律与合规免责声明（强制纳入仓库与 App 界面）

以下免责声明核心条款必须在仓库根目录 `README`、本系列文档以及 App 首次使用/关于页（英 / 简中 / 繁中三语）中明确呈现：

> **免责声明（Disclaimer）**
> 1. 本项目（`Whisky_new`）是一款面向 macOS（Apple Silicon）的开源兼容性研究、游戏运行调度与图形转译框架，**仅限用于合法技术研究、开源软件开发以及运行用户拥有合法授权的操作系统与软件/游戏**。
> 2. **严禁滥用与反作弊红线**：严禁任何人直接或间接地利用本项目、其源代码或构建产物制作、分发或辅助任何游戏外挂、作弊软件、内存修改器、自动化脚本、硬件伪造工具，或用于规避、对抗、破坏任何反作弊系统与数字版权保护（DRM）机制。
> 3. **尊重平台与厂商条款**：本项目绝不提供任何反作弊绕过或虚拟化隐藏功能。用户在运行任何第三方游戏、启动器或 Windows 操作系统前，必须自行确保已获得合法软件授权，并严格遵守对应游戏发行商与反作弊厂商的最终用户许可协议（EULA）及服务条款（ToS）。
> 4. **责任限制**：本软件按“现状（AS IS）”提供，不附带任何明示或暗示的担保（包括但不限于兼容性、稳定性或在线服务可用性）。因用户私自修改源代码、违反第三方厂商服务条款、或在厂商明确不支持/禁止虚拟化或转译的环境中强行运行所导致的账号限制、封禁、数据丢失、硬件/系统异常或其他法律与经济损失，**本项目作者及所有贡献者不承担任何直接或间接责任**。

---

## 4. Phase 3 窗口分工与文件写入锁

| 窗口 | 任务文档 | 启动时机 | 核心职责 | 独占可写路径 |
| --- | --- | --- | --- | --- |
| **Phase 3-A** | `guest-minimal-optimizer.md` | **待 Phase 2-A2/B2 跑通干净基线后启动** | 极简 Windows 11 24H2+ ARM64 优化器（含 Prism 白名单与一键回滚）、原生 `Virtualization.framework` 最小设备树、`viogpu3d` 零拷贝卸载评估 | `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/UTM*.swift`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/WindowsGuest*.swift`<br>`Whisky/Modules/guest-optimizer/`（新建）<br>`handoff/phase-3/evidence/p3-a/` |
| **Phase 3-B** | `anti-cheat-abuse-hardening-and-packaging.md` | **可立即启动（无需 VM 镜像）** | 防外挂安全加固（Hardened Runtime / entitlements 审计 / 禁用调试与宏注入检查）、三语免责声明落地、单 App 产品化整合与三引擎运行时包管理器 | `Whisky/Whisky/`（UI、免责声明、关于页、Info.plist/entitlements）<br>`Whisky/Whisky.xcodeproj/`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/`<br>`Whisky/README.md`<br>`handoff/phase-3/evidence/p3-b/` |
| **Phase 3-C** | `remote-physics-backend.md` | **可立即启动（无需 VM 镜像）** | `RemotePhysicsBackend` 协议与实现（强硬件信任根反作弊合规兜底：局域网物理副机/合规物理云机低延迟串流接入统一调度器） | `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/RemotePhysics*.swift`（新建）<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/RemotePhysics*.swift`（新建）<br>`handoff/phase-3/evidence/p3-c/` |

> 跨窗口共享模型修改（`RuntimeModels.swift`、`RuntimeCoordinator.swift`、`handoff/runtime-interface.md`、`handoff/task-07/`）继续采用提案制，统一经总控审核后合入，严禁并行踩踏。
