# Phase 15 窗口 15A 任务书：多线程图形管线（1080p/4K 零妥协）、`IOSurface` 零拷贝直出与完整 TCP/UDP 原生网络

- **窗口角色**：Phase 15 窗口 15A
- **难度评级**：🔴 高难度（建议模型：**`Neon Medium`**）
- **署名**：`@DNPMBHC`
- **架构依据**：`handoff/phase-15/ARCHITECTURE-MULTITHREAD-GPU-PIPELINE.md`
- **母盘基线**：`golden-win11-arm64-v1`（只读不可变，必须全盘 SHA-256 `zero_drift = true`）

---

## 1. 任务目标

### 任务 15A-1：全链路去模拟化与完整 TCP + UDP 非 `slirp` 原生网络栈
在 `graphics-lab/golden_guest_manager.py`（及单测）与 `Whisky/Modules/utm-custom/` 中落地：
1. **固化 14A 实证收益**：
   - 将 WHQL 签名 **`virtio-mouse-pci`**（峰值中断 `-47.1%`，全程 `Secure Boot = True`）固化为容器默认高响应输入通道（保留 `usb-mouse` 兼容回退）；
   - 移除 14A 设备树审计发现的 **3 条残余 `usb-redir` 通道与多余 `qemu-xhci` 控制器**；
   - 固化 `QEMURendererFPSLimit = 120` + 三重缓冲（严禁使用会在真机触发按输入重绘阻塞的 `0`）；
   - 客观评估 `virtio-sound` 替代模拟 `intel-hda` 的音频延迟与 WHQL 签名驱动可用性（不可用则诚实保留 `intel-hda`）。
2. **彻底消灭最后 5 次 `slirp` 丢包告警（双轨：真·内核 `vmnet` 直通 + 零特权 TCP/UDP 兜底）**：
   - **主路径（真·内核 `vmnet.framework` 直通，无需付费开发者签名/无需关闭 SIP）**：实现或集成轻量独立 `vmnet` 桥接守护进程方案（兼容 `socket_vmnet` 或极简 `malt-vmnet-bridge` C 辅助程序 + LaunchDaemon 模板 + Unix Socket 接入 QEMU `-netdev stream/socket`），允许在用户首次标准系统密码授权后以守护进程运行，让任意 `ad-hoc` 签名 QEMU 实例的 **TCP + UDP + ICMP 全部直通 macOS 内核 `vmnet.framework`**；
   - **零特权兜底路径**：对于用户未授权密码的场景，同步保留并升级支持完整 **TCP + UDP + ICMP** 的用户态异步代理（如 `gvproxy` 或升级后的异步桥接 + 独立高 QoS），彻底淘汰单线程 `slirp`；
   - 运行 60s **TCP + 128-tick UDP 混合满载压测**（叠加 D3D11 重渲染），验证 **0% 丢包、0 Burst Loss** 且满载段 P99 RTT 显著低于 `slirp`（如宿主机有权限则同步对比真·内核 `vmnet` 守护进程数据）。

### 任务 15A-2：多线程图形管线突破 + `IOSurface` 零拷贝直出原型（1080p & 4K 零画质妥协）
1. **多线程图形 API 实证（打破单核提交瓶颈）**：
   - 在容器内实测对比：
     - **D3D11 异步线程特性**（检测 `D3D11_FEATURE_THREADING`：`DriverConcurrentCreates` / `DriverCommandLists`，并压测多线程并发资源创建与提交 vs 单线程）；
     - **WHQL `vulkan_virtio`（Vulkan 1.3+）或 `NPT_CAPSET_D3D12`（D3D12 多线程 CommandList）**：编写/复用多线程命令录制微基准（4–8 线程并行录制 CommandBuffer vs 单线程），在 **1080p (`1920×1080`) 与 4K (`3840×2160`) 原生分辨率**下实测量化 CPU 帧提交耗时与 FPS 增益；
2. **`IOSurface` 零拷贝呈现直出（消除 SPICE 4K 二次拷贝）**：
   - 调研 `QEMURenderServer` / `CSMetalRenderer` 在 `Whisky/Modules/utm-custom/` 下的显示链路，落地补丁 **`09-iosurface-direct-present-and-virtio-input.patch`**（支持零拷贝/直通低延迟金属呈现优化，以及 `virtio-mouse-pci` + 去 `usb-redir` 开关），同步更新 `ARCHITECTURE.md`、`build_custom_utm.sh` 与 `utm_custom_patch_verify.py`（所有补丁必须通过白名单与 5 类反作弊黑名单静态审计），仓库外重编 `UTM-Custom.app` 并验证 `codesign --verify --deep --strict`。

### 任务 15A-3：1080p & 4K 零妥协综合压测与零漂移铁证
新增 `graphics-lab/p15_multithread_4k_benchmark.py`（及单测），产出：
- `handoff/phase-15/evidence/p15-a/multithread-4k-and-net-benchmark.json`（含 **1080p 与 4K 原生分辨率**单线程 vs 多线程图形管线、完整 TCP+UDP 非 `slirp` 网络压测、`virtio-mouse-pci` + 去 `usb-redir` 设备树实证、`IOSurface` 呈现优化对比）；
- `handoff/phase-15/evidence/p15-a/patch-audit.json` & `build-verification.json`；
- `handoff/phase-15/evidence/p15-a/zero-drift-proof.json` & `report.md`。

---

## 2. 独占写入范围（严禁越界）

- 允许写入：
  - `graphics-lab/golden_guest_manager.py`
  - `graphics-lab/test_golden_guest_manager.py`
  - `graphics-lab/p15_multithread_4k_benchmark.py`
  - `graphics-lab/test_p15_multithread_4k_benchmark.py`
  - `graphics-lab/utm_custom_patch_verify.py`
  - `graphics-lab/test_utm_custom_patch_verify.py`
  - `Whisky/Modules/utm-custom/**`
  - `handoff/phase-15/evidence/p15-a/**`
- 严禁触碰：`Whisky/Whisky/`、`Whisky/WhiskyKit/`、`Whisky/scripts/`、`Whisky/Modules/guest-optimizer/`、窗口 15B 独占路径、`/Applications/UTM.app` 原件、只读母盘与冷备 `vm-a`。

---

## 3. 验收门禁

1. `bash Whisky/Modules/utm-custom/scripts/build_custom_utm.sh --check-only` 全绿；
2. `(cd graphics-lab && python3 -B -m unittest discover -v)` 全绿；
3. `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)` **0 violations**；
4. `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` 全绿；
5. 零 `> 5 MiB` 新增跟踪文件、零隐私路径泄漏、零 git 操作、母盘与 `vm-a` 全盘 SHA-256 `zero_drift = true`。
