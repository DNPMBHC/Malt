# Phase 4 多窗口并行开发总控协议：开源成果深度集成、Guest 图形破局与单 App 产品化发布

日期：2026-11-23  
署名：`@DNPMBHC`  
前置全绿基线：
- SwiftPM **183 项（173 通过 / 10 显式跳过 / 0 失败）**；Strict SwiftLint **125 文件 0 违规**；Strict `swift-format` **6/6 通过**；
- `phase2_evidence.py`（v2 真实字节 SHA-256 核验）：**`3/3` 全满贯通过**；防外挂静态安全门禁（106 源码 + 6 反例自检）通过；`module-f` 42 来源 / 45 声明通过；`graphics-lab` 152 项单测通过；
- 关键实证底牌：
  1. 宿主机 Wine 三引擎（1280×720）实测 `335–367 FPS`（`DXMT v0.80` 显存仅 `19.9 MiB`）；
  2. 跨 VM M2 真实 Metal 16-Draw 命令重放像素误差 `0–1 LSB`，带宽压缩 `1,611×`（缓存帧仅 `88 B`），宿主 Apple M4 Metal 渲染仅 `0.881 ms`，吞吐 `18.847 FPS`（反超直出 `15.673 FPS` 与像素回读 `7.096 FPS`），暴露剩余 ~`52 ms` 瓶颈在同步阻塞 TCP 往返；
  3. 窗口 B 实证自有 ARM64 (`0xaa64`) 内核探针全周期通过并恢复安全基线；同时实锤 `target-cn`（`2.17.4.510`）当前落地的 3 个 WHQL 内核驱动全部为 `0x8664`（AMD64），导致 ARM64 内核下驱动未加载（轴 1 确凿阻塞，轴 2 保持 `unknown`）。

---

## 1. Phase 4 战略聚焦（拒绝重复造轮子，最大化借力社区开源生态）

1. **战略收敛**：
   - 冻结 `RemotePhysicsBackend`（保持现有代码与单测全绿，不再投入新串流功能）；
   - 聚焦两大本地核心方向：**① 宿主机 Wine 图形转译天花板 + 单 App 产物级一致打包**；**② Windows Guest 图形卸载突破（M2.5 异步流水线 → M3 开源 ARM64 WDDM 3D）+ 反作弊专用极简 Guest 优化器**（迎接未来 WoA / 腾讯 ACE 原生 ARM64 驱动生态，并加速普通 Windows 软件）。
2. **复用开源底座清单**：
   - **Mesa `KosmicKrisp`**（LunarG / Mesa 上游 Vulkan 1.4 → Metal 4 原生驱动，替代老旧 `MoltenVK`）；
   - **`3Shain/dxmt`**（DX11 直译 Metal + `airconv` 编译器 + MetalFX Spatial 策略）；
   - **`utmapp/viogpu-wddm` (`viogpu3d.sys`) + `utmapp/mesa` (`neptune_umd.dll` / `vulkan_virtio.dll`) + `utmapp/build-viogpu3d`**（开源 ARM64 WDDM 3D 驱动栈）；
   - **`libkrun` / `krunkit` + `virglrenderer (Venus)`**（macOS `Hypervisor.framework` 跨 VM `RESOURCE_CREATE_BLOB` 共享内存 GPU 卸载开源范本）；
   - **`macOS 27 Virtualization.framework` (`VZCustomVirtioDevice` / `VZVirtioSharedMemoryRegion`)** 与微软官方 `DISM` / PowerShell 声明式白名单机制。

---

## 2. 四窗口分工与严格文件写入锁（零冲突红线）

> **铁律**：每个窗口严禁修改其独占路径之外的源码；跨窗口共享模型/UI/构建配置需求，一律写入己方 `handoff/phase-4/evidence/p4-x/interface-proposal.md`，由 **窗口 4D** 统筹评估落地。

| 窗口 | 任务文档 | 优先级 | 依赖 VM | 核心职责 | 独占可写路径（严格互斥） |
| --- | --- | :---: | :---: | --- | --- |
| **窗口 4A** | `window-4a-wine-kosmickrisp-dxmt.md` | **P0** | 否（立即开跑） | 集成开源 `KosmicKrisp`（Vulkan 1.4 → Metal 4）做四路同口径实测；将 `DXMT` MetalFX Spatial 推进至可控画质/帧率策略并输出路由升级提案 | `graphics-lab/wine_kosmickrisp_*`<br>`graphics-lab/test_wine_kosmickrisp_*`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/Host*.swift`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/Host*.swift`<br>`handoff/phase-4/evidence/p4-a/` |
| **窗口 4B** | `window-4b-guest-gpu-m25-m3.md` | **P0** | 是（串行租约 / 独立克隆快照） | **M2.5**：`TCP_NODELAY` + 异步多帧飞行队列/共享内存环，消除 `52 ms` 同步 TCP 往返；<br>**M3**：在独立测试快照上实测社区开源 ARM64 `viogpu3d` WDDM 3D 栈，并评估 `libkrun`/`VZCustomVirtioDevice` 零拷贝路径 | `graphics-lab/m2_async_*`<br>`graphics-lab/test_m2_async_*`<br>`Whisky/Modules/guest-gpu-lab/`（新建）<br>`handoff/phase-4/evidence/p4-b/` |
| **窗口 4C** | `window-4c-guest-minimal-optimizer.md` | **P1** | 是（仅在独立克隆快照上验证） | 落地 Phase 3-A「反作弊专用极简 Windows 11 24H2 ARM64 优化器」（白名单保护 Prism AVX2 / 安全链 + 一键回滚 + 量化对比）；出具低成本 `x86_64` ACE 轴 2 探测 Go/No-Go 评估 | `Whisky/Modules/guest-optimizer/`（新建）<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/UTM*.swift`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/WindowsGuest*.swift`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/UTM*.swift`<br>`handoff/phase-4/evidence/p4-c/` |
| **窗口 4D** | `window-4d-packaging-and-artifact-gate.md` | **P0** | 否（立即开跑） | 刷新 `task-07/report.md` 至全绿 `3/3` 基线；落地 `runtime-manifest.json` 版本锁死 + 外接盘存放引导 + 降级提示；交付 `.app` → `.dmg` 自动化打包脚本与**产物级性能一致性门禁** | `Whisky/Whisky/`<br>`Whisky/WhiskyCmd/`<br>`Whisky/Whisky.xcodeproj/`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/Runtime*.swift`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Whisky/`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/Runtime*.swift`<br>`handoff/runtime-interface.md`<br>`handoff/task-07/`<br>`handoff/phase-4/evidence/p4-d/` |

---

## 3. 共享 VM 保护与全阶段硬性纪律

1. **保护主 `vm-a` 干净基线**：任何涉及安装社区测试签名驱动（如 `viogpu3d.sys`）或 OS 裁剪优化（4C）的操作，**严禁在主干净 `vm-a` 上直接破坏性修改**，必须先创建独立克隆快照或保证可验证的 100% 还原；同一时刻只允许一个窗口操作运行的 VM（4B 优先跑 M2.5，释放租约后 4C 在独立克隆上跑优化对比）。
2. **Step-by-Step 流程**：每个窗口启动后先输出 `## 思考与分析`、`## 实施计划`、`## 任务清单`，待用户确认后再动手编码或运行实验。
3. **开发期自动重启规则**：任何修改了 `my-project` App、CLI 或 `metal_host` 接收端的改动，必须执行重建 → 终止旧实例 → 自动重启最新产物的闭环命令（如 `./handoff/task-07/dev_restart.sh` 或 `./graphics-lab/restart_metal_host.sh`）。
4. **防外挂安全红线与免责声明**：严格遵守 `handoff/phase-3/README.md` 的 5 条防外挂安全红线（零作弊原语、Release Hardened Runtime + Library Validation、禁止截帧+宏注入闭环、诚实身份声明、严禁伪造硬件/隐藏虚拟化），所有改动必须继续通过 `audit_anticheat_hardening.py --self-test`。
5. **脱敏、事实口径与 Git 保护**：所有落盘文档与证据仅使用中性占位符（`my-project`、`module-x`、`vm-a`、`target-cn`、`<workspace>`、`<EXTERNAL_VOLUME>`），署名仅用 `@DNPMBHC`；严格保持五维状态分离，不夸大未测商业游戏提速；未经明确指令不执行 `git commit / push / reset`，不修改全局 Git 配置。
