# Phase 15 总览：`Malt` 单应用无感内嵌 + 防呆极简前端重构 + 多线程图形管线（1080p/4K 零妥协）与完整 TCP/UDP 原生网络

- 署名：`@DNPMBHC`
- 品牌：`Malt`
- 架构蓝图：[ARCHITECTURE-MULTITHREAD-GPU-PIPELINE.md](./ARCHITECTURE-MULTITHREAD-GPU-PIPELINE.md)
- 前置基线：Phase 14 已在 `1920×1200` `target-cn` 靶场突破 **`60.57 FPS`**（较 11B 提升 `+33.97%`），严重掉帧腰斩 `-59.0%`，WHQL `virtio-mouse-pci` 实证将鼠标峰值中断压降 `-47.1%`，正式产出 `Malt.dmg`（`13.578 MiB`）。

---

## 本阶段核心目标

1. **彻底把虚拟机引擎整合进 `Malt.app` 内部，实现单一软件无感交互（15B）**：
   - 不再拉起独立的外部 UTM 窗口与双 Dock 图标；将轻量虚拟化运行时、图形库、优化器与核心配置直接内嵌进 `Malt.app` 并随 `Malt.dmg` 开箱即用打包（允许合理增大包体，彻底消灭用户手工配置）；
   - 安装器、启动器与游戏画面直接由 `Malt` 统一托管与无感呈现。
2. **按用户产品铁律重构前端设置并修通 3 项实战断路 Bug（15B）**：
   - 启动自动检测硬件并**动态限制安全可调范围**；
   - 内存改为直接点选 **`GB` 档位**（如 `6 GB / 8 GB / 10 GB / 12 GB`，高亮推荐档，绝不让用户手输 MiB）；
   - 性能预设收敛为 **`最高性能` / `平衡`（默认）/ `低配置兼容`** 三档；
   - 高回报率鼠标合批、macOS 游戏模式、全屏防误触（`Cmd+W/Q/H/M`）与键位映射**全部默认开启且不堆砌在主界面**，仅保留在折叠「高级选项」；
   - 根治 `UnifiedRuntimeOrchestrator` 3 项断路（复用原生 `Wine`+三引擎路由、消除脚本相对路径硬编码并自动发现内置后端与外置 SSD 游玩实例、无桌面安装器 `.exe` 端到端透传给 Guest `kiosk-app-shell.ps1` + 非阻塞磁盘测速）。
3. **翻新落后管线、零画质妥协冲击 1080p / 4K 多线程图形吞吐（15A）**：
   - 固化 14A 实证收益（默认 WHQL `virtio-mouse-pci`、移除 3 条残余 `usb-redir`、固化 `QEMURendererFPSLimit = 120` + 三重缓冲），评估 `virtio-sound` 替代 `intel-hda`；
   - 落地完整 **TCP + UDP** 非 `slirp` 原生/高性能网络栈（如 `gvproxy` 或完整 `vmnet` 通道 + 独立高 QoS），彻底消灭最后 5 次 `slirp` 丢包告警；
   - 探索并实测多线程图形管线（容器内 `D3D12` / `vulkan_virtio` Vulkan 1.3+ 多线程命令录制、`D3D11_FEATURE_THREADING`）与跳过 SPICE 二次拷贝的 **`IOSurface` 零拷贝直出原型**，以 **1080p 与 4K 原生分辨率（零降质）**作为硬性对比基线。

---

## 并行窗口与严格文件写入锁（零重叠）

| 窗口 | 难度与建议模型 | 核心职责 | 独占写入路径 |
| --- | --- | --- | --- |
| **15A** | 🔴 高难度 · **`Neon Medium`** | 多线程图形管线（D3D12/Vulkan/D3D11 线程化）、`IOSurface` 零拷贝直出补丁、完整 TCP+UDP 非 `slirp` 原生网络、固化 `virtio-mouse-pci` & 去 `usb-redir` + 1080p/4K 零妥协压测 | `graphics-lab/golden_guest_manager.py`、`graphics-lab/test_golden_guest_manager.py`、`graphics-lab/p15_multithread_4k_benchmark.py`、`graphics-lab/test_p15_multithread_4k_benchmark.py`、`graphics-lab/utm_custom_patch_verify.py`、`graphics-lab/test_utm_custom_patch_verify.py`、`Whisky/Modules/utm-custom/**`、`handoff/phase-15/evidence/p15-a/**` |
| **15B** | 🔴 高难度 · **`Neon Medium`** | **`Malt` 单应用内嵌后端与开箱即用打包** + **防呆极简前端重构（点选 GB / 三档预设 / 默认优化收进高级）** + **3 项 `UnifiedRuntimeOrchestrator` 实战断路根治** + `dev_restart.sh` 实机验收 | `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/**`、`Whisky/WhiskyKit/Tests/WhiskyKitTests/UnifiedOrchestrationTests.swift`、`Whisky/Whisky/Views/Unified/**`、`Whisky/Whisky/Views/ContentView.swift`、`Whisky/Whisky.xcodeproj/project.pbxproj`、`Whisky/scripts/package_malt_dmg.sh`、`handoff/phase-15/evidence/p15-b/**` |

---

## 绝对不可突破的红线

1. **反作弊与安全红线**：严禁 CPUID/SMBIOS/ACPI/TPM/Hypervisor 伪装、严禁修改游戏/ACE/Windows 驱动、严禁关闭 Secure Boot、严禁 DWM Hook/进程注入、严禁自动化登录或过验证码；面向用户的界面文案保持中立正式，不宣传反作弊绕过。
2. **零漂移与仓库纯净**：只读母盘 `golden-win11-arm64-v1`、冷备 `vm-a` 与 `/Applications/UTM.app` 原件零漂移；所有大体积构建产物（`.dmg` / 内嵌 QEMU 二进制 / 外部源码树）严禁提交入 git（git 跟踪目录零 `> 5 MiB` 新增文件）；零隐私路径泄漏；严禁执行 `git commit / push / reset`。
