# 窗口 5B 任务书：【方案 B 核心主轴】macOS 27 `VZCustomVirtioDevice` 砍掉 QEMU 进程内零拷贝 GPU 桥接（P0）

署名：`@DNPMBHC`  
启动前提：**无需占用 UTM `vm-a`，全程在宿主机原生 `Virtualization.framework` 实验进程推进，可立即启动**  
请先阅读：`handoff/phase-5/README.md`、`handoff/phase-4/evidence/p4-b/m3-viogpu3d-report.md`、`handoff/phase-4/evidence/p4-b/vz-shm-probe.json`

---

## 1. 独占可写路径（严格互斥）

- `Whisky/Modules/vz-gpu-bridge/`（新建）
- `graphics-lab/vz_gpu_bench_*`（新建）
- `graphics-lab/test_vz_gpu_*`（新建）
- `handoff/phase-5/evidence/p5-b/`（新建）

严禁修改 `Whisky/Whisky/`、`Whisky/WhiskyKit/`、`Whisky/Modules/guest-gpu-lab/`、`Whisky/.swiftlint.yml` 及其他窗口独占路径。
> **硬红线**：`Whisky/Modules/vz-gpu-bridge/` 下所有 `.swift` 文件**必须严格通过 `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)` 0 违规**（按职责合理拆分为 <= 400 行的小文件，行宽 <= 120、函数体 <= 50 行），严禁请求豁免 SwiftLint；交付前必须清理本地 `build/` 编译产物与 `.pcm` 缓存（仓库内 0 个 `>5 MiB` 文件）。

---

## 2. 核心任务拆解（方案 B 全栈落地原型）

总控与用户已正式拍板采用 **【方案 B】** 作为跨 VM 图形提速的主攻路线：
> **核心架构**：`Guest Windows 11 ARM64 (复用社区 WHQL viogpu3d.sys，保持 Secure Boot 开启)` → `macOS 27 原生 VZCustomVirtioDevice + VZVirtioSharedMemoryRegion` → `同进程 virglrenderer / KosmicKrisp / Metal 4` → `零拷贝 IOSurface` → `原生全屏 NSWindow (CAMetalLayer)`。

窗口 5B 负责把方案 B 的核心宿主机桥接引擎从理论推进到**可实测、可量化、可对接 5C 原生窗口的工程原型**：

### 任务 B1（P0）：原生 macOS 27 `VZCustomVirtioDevice` 完整 VirtIO-GPU PCI 设备模型与校验
1. 在 `Whisky/Modules/vz-gpu-bridge/` 中实现标准 VirtIO-GPU PCI 设备配置与双 VirtQueue（`controlq` / `cursorq`）调度框架：
   - PCI `vendorID = 0x1AF4`、`deviceID = 0x1050`（VirtIO-GPU modern PCI）、`class = 0x03`（Display），挂载 `VZVirtioSharedMemoryRegion` 作为 `hostmem` 零拷贝区域；
   - 真实构造包含 `VZGenericPlatformConfiguration`（ARM64 + UEFI）与该自定义 VirtIO-GPU 设备的 `VZVirtualMachineConfiguration`，调用真实 `validate()` 接口验证通过，并完整实测记录 macOS 27.2.1 下的硬性边界（最大可分配共享内存容量、页对齐要求、是否兼容 Hardened Runtime 与常规 `com.apple.security.virtualization` 权限）。

### 任务 B2（P0）：砍掉 QEMU / `QEMURenderServer` — 同进程零拷贝渲染与 `IOSurface` 上屏实测
1. 构建同进程零拷贝桥接原型（带重建→杀旧进程→自动重启验证脚本）：
   - 实现 `SharedMemory Ring / VirtQueue 模拟提交 → 同进程 KosmicKrisp (Vulkan 1.4) / Metal 4 渲染 → 共享 IOSurface (MTLTexture 零拷贝绑定) → CAMetalLayer 上屏` 完整闭环；
   - 实测评估本机直接链接或 C FFI 嵌入开源 `virglrenderer`（Venus/Neptune 后端）的真实可行性（核查依赖动态库、`virgl_renderer_init` / `RESOURCE_CREATE_BLOB` / `IOSurface` 导出能力、线程模型与阻塞点）。
2. **与 5A 标尺同口径的性能收益量化**：
   - 在 **2,000+ Draw Call 高压力负载** 与 **1280×720 / 2560×1440** 分辨率下，对比：
     - **方案 B（同进程 SharedMemory → Metal/KosmicKrisp → `IOSurface` 零拷贝呈现）**
     - **旧路径基线（跨进程 Socket / `QEMURenderServer` IPC + 拷贝）**
   - 精确量化砍掉 QEMU 模拟与多进程 IPC 后省下的单帧微秒/毫秒延迟、P99 帧时间与宿主 CPU 占比。

### 任务 B3（P0）：输出对接 5C 的 `IOSurface` 零拷贝呈现契约 + Phase 6 完整替换 QEMU 施工图
1. 定义面向窗口 5C `GuestGameSurfaceWindow` 的标准零拷贝帧呈递协议（`IOSurfaceID` / `IOSurfaceRef` + 尺寸 + 刷新率 + `MTLSharedEvent` 同步栅栏），写入 `handoff/phase-5/evidence/p5-b/interface-proposal.md`；
2. 产出基于真实编译与运行数据的 **Phase 6 方案 B 工程施工图**：清晰拆解“在原生 `Virtualization.framework` 启动 Windows 11 ARM64 + vTPM + Secure Boot + 挂接 WHQL `viogpu3d.sys` 跑通真实桌面与 3D 渲染”还缺哪些具体模块与工时评估（诚实指出任何 macOS 27 API 限制，绝不隐瞒风险）。

---

## 3. 验收标准与交付物

1. `Whisky/Modules/vz-gpu-bridge/` 代码模块化清晰、带自动重启验证脚本、**Strict SwiftLint 0 违规**；
2. `graphics-lab/test_vz_gpu_*.py` 单元测试全部通过，`(cd graphics-lab && python3 -B -m unittest discover -v)` 全绿；
3. `handoff/phase-5/evidence/p5-b/vz-zero-copy-report.md`、`vz-zero-copy-benchmark.json`（含 SHA-256 绑定与真实 `VZVirtualMachineConfiguration.validate()` 日志）与 `interface-proposal.md`；
4. 通过 `audit_anticheat_hardening.py --self-test`，且仓库内零 `>5 MiB` 构建缓存残留。
