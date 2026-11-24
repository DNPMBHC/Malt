# Phase 5 多窗口并行开发总控协议：方案 B（`VZCustomVirtioDevice` 零拷贝）核心攻关、无畏契约双端真机实测与无桌面原生游戏壳

日期：2026-11-23  
署名：`@DNPMBHC`  
前置全绿基线（已备份至远端 `main@57eba1ee` & `backup/phase4-workspace-lab-and-handoff@a0d2fa3`）：
- SwiftPM **201 项（191 通过 / 10 显式跳过 / 0 失败）**；Strict SwiftLint **0 违规**；Strict `swift-format` **6/6 通过**；
- `graphics-lab` **163 项单测 OK**；`guest-optimizer` **10 项单测 OK**；防外挂静态安全门禁（111 源码 + 6 反例自检）通过；`phase2_evidence.py` `3/3` 全满贯；
- 核心实证底牌：
  1. 宿主机 Release + Hardened Runtime `.dmg` 已瘦身至 `8.28 MiB`，实跑三引擎全绿（DXMT `408.75 FPS`、D3DMetal `789.12 FPS`、DXVK `396.46 FPS`）；
  2. 跨 VM M3 实证社区 `viogpu3d.sys`（`v100.6.101.58000`）已获微软 **WHQL 正式签名**，在 `Secure Boot = Enabled` / `Test Signing = Disabled` 下将标准 D3D11 从 `15.67 FPS` 提至 `130.14 FPS`（`8.30×`，`0 LSB`）；但受限于 QEMU + `QEMURenderServer` 多进程 IPC，与宿主机 Wine 仍有明显代差；
  3. 极简 Guest 优化器实测降 RSS `-167.83 MiB`、QEMU CPU `-9.52%`、冷启 `-2.465 s`，一键回滚 100% 一致。

---

## 1. Phase 5 战略拍板（已锁定路线）

1. **跨 VM 图形提速正式锁定【方案 B】：macOS 27 原生 `VZCustomVirtioDevice` + `VZVirtioSharedMemoryRegion` 砍掉 QEMU 多进程税**
   - 复用社区已获微软 **WHQL 正式签名**的 `viogpu3d.sys`（零自研内核驱动成本、100% 保留 Secure Boot 信任链）；
   - 宿主机侧全力攻关在 macOS 27 原生 `Virtualization.framework` 进程内直连 `virglrenderer / KosmicKrisp / Metal 4`，将渲染结果直接输出至零拷贝 **`IOSurface` → `CAMetalLayer`**，并无缝对接无桌面原生全屏 `NSWindow`。
2. **硬性实证要求：无畏契约（`target-cn`）双端最新真实运行实测与合法 ACE 机制取证**
   - 在开启 WHQL `viogpu3d` 3D 加速 + 极简 Guest（Secure Boot + TPM 2.0）的独立测试克隆与宿主机隔离 Wine Bottle 上，双端真实运行官方最新客户端，获取一手启动链路、驱动架构（PE Machine）、Windows EventLog（7045/7000/7026/CodeIntegrity）与精确报错码，并从第一性原理做 **Apple Silicon ARM64 VM vs x86_64 VM（含 Intel PD）** 的客观事实归因；
   - **绝对合规红线**：严禁修改/Patch/Hook 反作弊驱动或启动器、严禁隐藏虚拟化/伪造硬件（CPUID/SMBIOS）、严禁绕过登录与 CAPTCHA 人机验证。
3. **体验与宿主机单 App 同步推进**
   - Guest 侧落地对接方案 B `IOSurface` 的无桌面「原生全屏游戏壳」；
   - Wine 侧将 `KosmicKrisp` 正式打入 `.app` → `.dmg` 锁版清单与四路产物级性能一致性门禁。

---

## 2. 四窗口分工与严格文件写入锁（零冲突红线）

> **铁律**：每个窗口严禁修改独占路径之外的源码；跨窗口 UI/共享模型/打包接线需求一律写入己方 `handoff/phase-5/evidence/p5-x/interface-proposal.md`，由 **窗口 5D** 统一评估落地。

| 窗口 | 任务文档 | 优先级 | 依赖 VM | 核心职责 | 独占可写路径（严格互斥） |
| --- | --- | :---: | :---: | --- | --- |
| **窗口 5A** | `window-5a-valorant-real-test-and-3d-bench.md` | **P0** | 是（独立克隆，优先运行） | **无畏契约双端最新真实运行实测 + 合法 ACE 机制归因诊断**（WHQL 3D ARM64 Guest 独立克隆 + 宿主机 Wine Bottle + 30 秒 ACE 巡检脚本 + ARM64 VM vs Intel/x86 VM 客观对比）；建立 **2,000+ Draw Call 异步真实 3D 基线**（Wine 四路 vs 当前 QEMU WHQL `viogpu3d`）作为方案 B 裁判标尺 | `graphics-lab/bench_real3d_*`<br>`graphics-lab/test_real3d_*`<br>`handoff/module-f/valorant-real-runs/`<br>`handoff/phase-5/evidence/p5-a/` |
| **窗口 5B** | `window-5b-vz-custom-virtio-zero-copy.md` | **P0** | 否（原生 VZ 实验进程，不占 UTM `vm-a`） | **【方案 B 核心主轴】砍掉 QEMU 进程内零拷贝桥接**：落地 macOS 27 `VZCustomVirtioDevice` + `VZVirtioSharedMemoryRegion` 完整 VirtIO-GPU PCI 设备模型与双 VirtQueue 调度器；实测同进程 `SharedMemory → virglrenderer/KosmicKrisp/Metal → IOSurface → CAMetalLayer` 零拷贝管线 vs QEMU IPC 延迟；定义对接 5C 的 `IOSurface` 零拷贝呈现契约与 Phase 6 全量替换 QEMU 实施路线 | `Whisky/Modules/vz-gpu-bridge/`（新建）<br>`graphics-lab/vz_gpu_bench_*`<br>`graphics-lab/test_vz_gpu_*`<br>`handoff/phase-5/evidence/p5-b/` |
| **窗口 5C** | `window-5c-headless-native-game-shell.md` | **P1** | 是（待 5A 释放 VM 后，于独立克隆联调） | **无桌面「原生全屏游戏壳」（对齐方案 B 零拷贝 `IOSurface` 契约）**：在 `WhiskyKit` 实现 Headless 后台 Guest 生命周期、`GuestGameSurfaceWindow` 原生全屏容器（支持直挂方案 B `IOSurface` 到 `CAMetalLayer`）、Mac Retina 分辨率自动下发同步、FPS Raw Input 鼠标锁定与退游自动归位 | `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/GuestSurface*.swift`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/UTM*.swift`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/GuestSurface*.swift`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/UTM*.swift`<br>`handoff/phase-5/evidence/p5-c/` |
| **窗口 5D** | `window-5d-kosmickrisp-app-and-real-game-gate.md` | **P0** | 否（立即启动） | **单 App 实战冲刺**：将 `KosmicKrisp` 正式集成进 Release `.app` → `.dmg` 打包流水线与 `runtime-manifest.json`；在 App 设置 UI 暴露 `DXMT MetalFX` 档位与 `KosmicKrisp` 开关（三语 + 防静默降级）；将产物级性能一致性门禁升级至四路后端 | `Whisky/Whisky/`<br>`Whisky/WhiskyCmd/`<br>`Whisky/Whisky.xcodeproj/`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Whisky/`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/Runtime*.swift`<br>`handoff/task-07/`<br>`handoff/phase-5/evidence/p5-d/` |

---

## 3. 共享 VM 保护、合规与全阶段硬纪律

1. **绝对保护主干净 `vm-a`**：5A 与 5C 的一切安装游戏、加载驱动、调整分辨率/外壳实验，**只能在 `<EXTERNAL_VOLUME>` 的 APFS Copy-on-Write 独立克隆上执行**，完成后必须彻底删除测试克隆并确认主 `vm-a` 零触碰；5A 先跑完 VM 实测并释放租约后，5C 再启动独立克隆联调（5C 前期可先并行写完 Swift 代码与本地单元测试）。
2. **反作弊与人机校验铁律**：测试 `target-cn` 时严禁绕过登录、严禁破解或绕过 CAPTCHA/验证码（遇人机验证或账号登录必须暂停并提示用户在界面亲自操作）、严禁修改/Hook 反作弊二进制、严禁隐藏虚拟化或伪造硬件特征、严禁触碰 5 条防外挂安全红线（每次交付必过 `audit_anticheat_hardening.py --self-test`）。
3. **Strict SwiftLint 零违规红线**：所有写入 `Whisky/` 下的新增 `.swift` 文件（含 5B 的 `Whisky/Modules/vz-gpu-bridge/` 和 5C/5D 源码）**必须通过 `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)` 0 违规**，严禁引入新豁免逃避检查；本地临时编译缓存（`build/`、`.pcm`、`>5 MiB` 二进制）交付前必须清理或排除在仓库外。
4. **Step-by-Step 与自动重启闭环**：各窗口启动后先输出中文 `## 思考与分析`、`## 实施计划`、`## 任务清单`，等待用户确认后再动手；凡修改 `Whisky.app`、`WhiskyCmd` 或独立宿主接收端，必须执行重建 → 杀旧实例 → 自动重启闭环（如 `./handoff/task-07/dev_restart.sh`）。
5. **脱敏、五维口径与 Git 保护**：所有落盘证据严禁出现本机用户名与私有卷名，仅用中性占位符（`my-project`、`vm-a`、`target-cn`、`<workspace>`、`<EXTERNAL_VOLUME>`），署名统一 `@DNPMBHC`；严禁执行 `git commit / push / reset` 与修改全局 Git 配置。
