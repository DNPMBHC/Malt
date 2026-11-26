# Phase 12 窗口 12A 任务书：Guest CPU 吞吐重构、去 `slirp` 原生网络管线与 10 GiB/多队列 I/O 优化

- **窗口角色**：Phase 12 窗口 12A
- **难度评级**：🔴 高难度（建议模型：**`Neon Medium`**）
- **署名**：`@DNPMBHC`
- **母盘基线**：`golden-win11-arm64-v1`（只读不可变，全盘 SHA-256 必须保持 `zero_drift = true`）
- **核心问题来源**：Phase 11B 25.3 分钟真机遥测证明 `1920×1200` 下 GPU 远未触顶（`QEMURenderServer` 仅 `33%–45%` CPU），真正制约帧率与稳帧的两大元凶是 **Guest 6 vCPU 打满（`587.8%`）** 与 **ad-hoc 签名被迫使用用户态 `slirp` NAT 导致的 `256-packet ack` 丢包积压（占严重掉帧 `12.8%`）**。

---

## 1. 任务目标

### 任务 12A-1：去 `slirp` 原生网络管线重构（允许尝试新架构，优先 macOS 原生 `vmnet` 管线）
在 `graphics-lab/golden_guest_manager.py`（及单测）中设计并实测替代用户态 `slirp` 的高性能原生网络管线：
1. **调研并实现优先级阶梯（选出本机无需关闭 SIP 即可稳定落地的最优原生方案）**：
   - **首选路径 A（原生 `vmnet.framework` 内核管线）**：评估并验证以下两种原生方式之一：
     - 方式 A1：通过 `socket_vmnet` / 独立原生 `vmnet` 桥接守护进程 + QEMU `-netdev socket` / `virtio-net-pci`（彻底绕开 ad-hoc App 缺失 `com.apple.vm.networking` entitlement 的限制，直通 macOS 内核 `vmnet.framework`）；
     - 方式 A2：验证本机是否具备可用开发签名或是否支持让官方已签名 `QEMULauncher` 承担 `vmnet-shared` 管线。
   - **备选路径 B（原生异步网络栈 + `virtio-net-pci` 多队列加速）**：若系统权限受限无法部署特权 `vmnet` 助手，则落地现代化高性能非 `slirp` 代理（或对 `virtio-net-pci` 开启 `mq=on`、独立 `iothread`、`ioeventfd=on` 与 UDP 缓冲调优）并诚实记录与 `slirp` 的量化对比。
2. **量化验收网络改进**：编写并运行高包频 UDP/TCP 压测（模拟 128-tick 游戏高频小包双向收发，如 128–256 pkt/s 持续 60 秒），对比 **`slirp` 基线 vs 新原生网络管线** 的 **P50/P99 RTT 延迟、丢包率、Jitter 抖动与 QEMU 主线程 CPU 占用**。

### 任务 12A-2：Guest CPU 拓扑、10 GiB 内存甜点与 VirtIO-Blk 多队列 I/O 重构
在 `graphics-lab/golden_guest_manager.py` 与 `Whisky/Modules/guest-optimizer/` 中落地：
1. **10 GiB 内存甜点与 macOS 原生按需分页协同**：
   - 将日常持久化游玩 VM（`create-playable`）默认 RAM 升级为 **`10240 MiB (10 GiB)`**（16 GiB 统一内存 Mac 甜点，保持 `--disable-balloon` 与 Windows `MemoryCompression = preserve`），让大场景冷页交给 macOS 原生内存压缩器而非慢速虚拟盘 `pagefile.sys`。
2. **VirtIO-Blk 原生多队列 I/O 与 `discard=unmap`**：
   - 为系统盘与游戏数据盘配置多队列 `num-queues`（匹配 4–6）、独立 `iothread` 与 `discard=unmap`，减少大场景 `FlushAsyncLoading` 流式加载时的 vCPU 阻塞与 APFS 稀疏镜像膨胀。
3. **Guest CPU 吞吐与 vCPU 甜点 A/B 实测（10 核 Apple Silicon：`4P+6E`）**：
   - 保持 100% 合规（零 CPUID/SMBIOS/Hypervisor 伪装），在真机上完成 **`6 vCPU` vs `7 vCPU` vs `8 vCPU`**（扁平单核簇拓扑）在高 Draw-Call + 多线程 CPU 负载下的量化对照，找出既不挤爆宿主机 `QEMURenderServer`、又能最大化 Guest 吞吐的最佳核数并固化为推荐默认值。
4. **`guest-optimizer` v3.1 补强**：
   - 安全禁用 11B 捕获的崩溃无用服务 **`spice-webdavd`**（消除 `APPCRASH 0x80000003` 与 Windows Error Reporting 后台抖动，支持完整回滚）；
   - 复验 `apply-optimizer.ps1` 动态页面文件钳位与 `rollback-optimizer.ps1`（确保 **`rollback_consistent = true` 且 `mismatch_count = 0`**）。

### 任务 12A-3：综合基准落盘与全盘零漂移证明
新增 `graphics-lab/p12_cpu_net_benchmark.py` 与 `graphics-lab/test_p12_cpu_net_benchmark.py`，产出：
- `handoff/phase-12/evidence/p12-a/cpu-net-io-native-benchmark.json`（含 `6 vs 7 vs 8 vCPU`、`slirp vs 原生网络 128-tick 压测`、`10 GiB + 多队列 I/O`、`spice-webdavd` 清理与 `rollback_consistent = true` 全量实测数据）；
- `handoff/phase-12/evidence/p12-a/zero-drift-proof.json`；
- `handoff/phase-12/evidence/p12-a/report.md`。

---

## 2. 独占写入范围（严禁越界）

- 允许写入：
  - `Whisky/Modules/guest-optimizer/**`
  - `graphics-lab/golden_guest_manager.py`
  - `graphics-lab/test_golden_guest_manager.py`
  - `graphics-lab/p12_cpu_net_benchmark.py`
  - `graphics-lab/test_p12_cpu_net_benchmark.py`
  - `handoff/phase-12/evidence/p12-a/**`
- 严禁触碰：`Whisky/Modules/utm-custom/`、`Whisky/Whisky/`、`Whisky/WhiskyKit/`、`handoff/task-07/`、窗口 12B 独占路径、`/Applications/UTM.app` 原件、只读母盘与冷备 `vm-a`。

---

## 3. 验收门禁

1. `(cd Whisky/Modules/guest-optimizer && python3 -B -m unittest discover -s tests -v)` 全绿；
2. `(cd graphics-lab && python3 -B -m unittest discover -v)` 全绿；
3. `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` 全绿；
4. 零 `> 5 MiB` 新增文件、零隐私路径泄漏、零 git commit/push/reset、母盘与 `vm-a` 全盘 SHA-256 `zero_drift = true`。
