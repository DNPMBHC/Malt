# 窗口 4B 任务书：跨 VM 图形提速破局（M2.5 异步流水线 → M3 开源 ARM64 WDDM 3D）（P0）

署名：`@DNPMBHC`  
启动前提：**当前主 `vm-a` 已被窗口 B 释放且恢复干净基线，4B 可按步骤依次推进**  
请先阅读：`handoff/phase-4/README.md`、`handoff/phase-2/evidence/window-c/architecture-review.md`、`graphics-lab/COMMAND_ONLY.md`

---

## 1. 核心背景与问题定位

Phase 2 M2 跨 VM 三模式实测（`run-20261122-140047-utc`）已精确揭示两个事实：
1. 宿主 Apple M4 Metal 执行全部 16 次 1280×720 真实 Draw 仅需 **`0.881 ms`**，缓存命中帧仅发 **`88 字节`**；
2. 但当前 `Command-Only Metal Replay` 总帧间隔仍有 **`53.045 ms`（`18.847 FPS`）**——说明剩余 ~`52 ms` 几乎全耗在 **单帧同步阻塞 TCP 往返与 Guest 侧逐帧同步等待** 上。

本窗口分两步直击瓶颈，**最大化借力开源成果，严禁从零手写完整 WDDM 驱动**：

---

## 2. 分阶段实施任务

### 阶段 4B-1（M2.5：消除 `52 ms` 同步阻塞，实测异步流水线极限）
1. 在独立新建的 `graphics-lab/m2_async_*` 实验脚本/协议模块（或在 `Whisky/Modules/guest-gpu-lab/` 独立分支原型，绝不破坏现有 M2 回归脚本与已验证二进制）中，对比验证两项低成本提速杠杆：
   - **杠杆 1**：显式禁用 Nagle 算法（`TCP_NODELAY`）+ **有界异步多帧飞行队列（Frames-in-Flight = 2 / 3）**，通过单调递增 `fence_id` 解耦“发送下一帧命令”与“等待上一帧 GPU 完成 ACK”；
   - **杠杆 2（若条件支持）**：基于 QEMU `ivshmem` / 共享内存页或 `macOS 27 VZCustomVirtioDevice` (`VZVirtioSharedMemoryRegion`) 设计零网络栈环形缓冲原型。
2. 在同一 1280×720 16-Draw 场景下，与 M2 同步基线（`18.847 FPS`）做配对实测，**同步验证像素 0–1 LSB 一致性未退化**，拆解记录新的每帧吞吐、P50/P95/P99、队列深度、CPU 与宿主 Metal GPU 时间（修改接收端后必须重建并自动重启验证）。

### 阶段 4B-2（M3：开源 ARM64 WDDM 3D 驱动栈实测与架构选型）
> **铁律**：本阶段需在 Guest 内开启 `testsigning` 安装社区测试签名驱动，**严禁在主干净 `vm-a` 上直接修改**！必须基于主 `vm-a` 创建独立克隆测试快照（存放于外接卷 `<EXTERNAL_VOLUME>`），保护主基线 100% 干净。

1. **复用社区开源轮子调研与实测**：
   - 核实并实测社区开源 **`utmapp/viogpu-wddm` (`viogpu3d.sys`) + `utmapp/mesa` (`neptune_umd.dll` / `vulkan_virtio.dll`) + `utmapp/build-viogpu3d`** 的最新 ARM64 预编译/源码构建状态；
   - 同步调研 **`libkrun` / `krunkit` + `virglrenderer (Venus)`** 在 macOS 上打通 `RESOURCE_CREATE_BLOB` 共享内存的现成补丁，以及结合 **Mesa `KosmicKrisp`（Metal 4）** 与 **`macOS 27 VZCustomVirtioDevice`** 的工程可行性。
2. **M3 实证目标（在独立克隆测试快照上执行）**：
   - 尝试安装社区 ARM64 `viogpu3d` 栈并配合 QEMU `virtio-gpu` 3D 后端；
   - 运行**未修改的标准直出 `d3d11_probe.exe`**（不带 `--transport-host`），采集 `IDXGIAdapter1::GetDesc1` 验证其是否成功脱离 `Microsoft Basic Render Driver` (`5140/140`) 并记录真实 1280×720 帧率；
   - 若上游 `viogpu3d` / QEMU macOS 3D 后端在 ARM64 下存在崩溃、缺扩展或无法通过测试，**如实记录精确日志、崩溃点与缺失的 VirtIO Capset/Blob 特性**，输出客观技术决策报告（绝不造假或强行宣称通过）。

---

## 3. 独占可写路径（严禁越界）

- `graphics-lab/m2_async_*`（新建）
- `graphics-lab/test_m2_async_*`（新建）
- `Whisky/Modules/guest-gpu-lab/`（新建，存放 M2.5/M3 实验代码、原型与 `VZCustomVirtioDevice` 调研代码）
- `handoff/phase-4/evidence/p4-b/`（新建，存放 M2.5/M3 实测数据、SHA-256 绑定报告与 `guest-handoff.json`）

> 严禁修改已有 `graphics-lab/d3d11_probe.cpp`（若需增量新探针请复制至 `Modules/guest-gpu-lab/` 独立编译，避免破坏既有 M0/M2 冻结输入摘要）及窗口 4A/4C/4D 独占文件。

---

## 4. 验收标准与交付物

1. **M2.5 实测报告**：`handoff/phase-4/evidence/p4-b/m25-async-benchmark.json` 与 `summary.md`（绑定源码/二进制 SHA-256，独立校验像素 0–1 LSB 与吞吐对比）。
2. **M3 开源 WDDM 3D 评估与实测报告**：`handoff/phase-4/evidence/p4-b/m3-viogpu3d-report.md`（含开源仓版本/提交、WHQL 签名约束、`libkrun`/`VZCustomVirtioDevice` 复用评估与独立克隆快照实测结论）。
3. **防外挂红线**：所有图形卸载原型严禁暴露截帧导出插件钩子或合成键鼠注入通道；通过 `audit_anticheat_hardening.py --self-test`、Strict SwiftLint 0 违规与隐私脱敏检查；完成后清理独立测试快照或释放 `vm-a` 租约给 4C。
4. 保持中性占位符，署名 `@DNPMBHC`，不执行 `git commit / push`。
