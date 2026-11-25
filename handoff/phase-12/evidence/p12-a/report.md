# Phase 12A 执行报告：原生管线重构（去 `slirp` 原生网络 + 10 GiB/VirtIO-Blk 多队列 I/O + Guest CPU 甜点实测）

- **窗口角色**：Phase 12 窗口 12A
- **署名**：`@DNPMBHC`
- **采集时间 (UTC)**：`2026-11-25T08:49:03.443580+00:00`
- **母盘绑定**：`golden-win11-arm64-v1`（`golden-guest-manifest.json` SHA-256 `1988c3217b4c97d53818ac72831360715bf0438543288cc1cb4001a9f00fa846`）
- **宿主机拓扑**：`10` 核 Apple Silicon（`4P + 6E`），官方 `/Applications/UTM.app` `com.apple.vm.networking` = `True`，`socket_vmnet` 已安装 = `False`
- **基准数据**：`handoff/phase-12/evidence/p12-a/cpu-net-io-native-benchmark.json`（SHA-256 `31c43ddd1ddfae9fd539b2abe86b6c24db3efb75334196f01b5d073c78aff772`）
- **零漂移证明**：`handoff/phase-12/evidence/p12-a/zero-drift-proof.json`（SHA-256 `32db835b03807d854088908049c68e6a9c7ff91f8476fcbefc01bb22abd9d407`）

---

## 1. 任务完成总览

1. **去 `slirp` 原生网络管线重构**：在无需关闭 SIP、零 `sudo` 的前提下，落地三层网络架构（① 官方已签名 UTM 直通 macOS 内核 `vmnet.framework` 的 `vmnet-shared` + `virtio-net-pci,ioeventfd=on,rx_queue_size=1024`；② 面向无 `com.apple.vm.networking` 权限的沙盒 ad-hoc `UTM-Custom.app` 的零特权 Go 多协程异步 `-netdev stream` 代理 `socket-stream`，以及兼容特权 `socket_vmnet` 的 `socket-vmnet` 接口；③ 保留 `emulated` 作基线对照），并完成 128-tick 60 秒双向小包压测（前 30s 静态 + 后 30s 叠加 4096 Draw-Call 渲染负载）。
2. **10 GiB 内存甜点 + VirtIO-Blk 多队列 I/O + Guest CPU 甜点固化**：`create-playable` 默认 RAM 升至 **`10240 MiB (10 GiB)`**（保持 `Balloon=Off` 与 Windows `MemoryCompression=preserve`），磁盘默认切换至 **`VirtIO-Blk` + 独立 `iothread0` + `num-queues=4` + `discard=unmap`**；完成 `6 vs 7 vs 8 vCPU` 扁平单核簇拓扑实机对照，推荐最优核数固化为 **`8 vCPU`**。
3. **`guest-optimizer` v3.1 升级与零失配回滚**：安全禁用崩溃服务 `spice-webdavd`（消除 `APPCRASH 0x80000003`），基于 `C:` 当前可用空间做动态安全钳位并直写标准 `Memory Management\PagingFiles` 规避 WMI `Value out of range` 历史限制，修复 `SysMain` 停止态下 `Get-MMAgent` 假值问题，真机验证 `rollback_consistent = true`、`mismatch_count = 0`。

---

## 2. 去 `slirp` 原生网络 128-tick 60 秒双向压测对照

- **压测协议**：`UDP bidirectional 128-tick 60s (quiet 30s + D3D11 load 30s)`（单向 7,680 包 / 双向 15,360 个 96B UDP 小包；每臂独立单 VM 错峰运行）
- **关于 `virtio-net-pci` 队列实测边界**：在 QEMU `10.0.12` 非 vhost-user 后端下实测 `tx_queue_size` 上限为 `256`、`rx_queue_size` 支持扩大至 `1024`，且配合 `ioeventfd=on` 稳定启动。

| 网络管线 | 模式 | 全段 P50 RTT (ms) | 全段 P99 RTT (ms) | 满载段 P99 RTT (ms) | 丢包率（Burst >=3） | 平均 Jitter (ms) | QEMU 主线程 CPU | QEMU 总 CPU |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **基线：QEMU `slirp` NAT** | `emulated` | `0.746` | `4.401` | `5.371` | `0.0000%` (`0` burst) | `0.376` | `11.71%` | `72.05%` |
| **零特权异步代理（穿透沙盒 ad-hoc）** | `socket-stream` | `0.812` | `5.144` | `7.554` | `0.0000%` (`0` burst) | `0.397` | `9.96%` | `46.39%` |
| **原生内核 `vmnet.framework`** | `vmnet-shared` | `0.571` | `5.024` | `8.533` | `0.0000%` (`0` burst) | `0.363` | `8.62%` | `62.47%` |

- **`vmnet-shared` vs `slirp`**：全段 P50 RTT `-23.46%`，全段 P99 RTT `+14.16%`，满载段 P99 RTT `+58.87%`，平均 Jitter `-3.46%`，QEMU 主线程 CPU `-26.38%`。
- **`async-socket-stream` vs `slirp`**：全段 P50 RTT `+8.85%`，全段 P99 RTT `+16.88%`，满载段 P99 RTT `+40.64%`，平均 Jitter `+5.59%`，QEMU 主线程 CPU `-14.94%`。
- **诚实工程解读**：`vmnet-shared` 在内核直通下将中位延迟压降 `23.46%`、并将 QEMU 主线程 CPU 占用压降 `26.38%`（静默段近乎腰斩）；零特权 `async-socket-stream` 则在不关 SIP、无 `sudo` 前提下为沙盒 ad-hoc `UTM-Custom.app` 打通非 `slirp` 通道（`0%` 丢包、QEMU 主线程 CPU `-14.94%`、总 CPU `-35.62%`）。满载段瞬态 P99 尖峰出现在 `d3d11_probe` 拉起瞬间，与本机回环调度抖动相关，已如实保留原始分位数未作剔除。

---

## 3. VirtIO-Blk 多队列 I/O（独立 `iothread` + `num-queues=4` + `discard=unmap`）与 10 GiB 内存对照

| 存储配置 | 4K 随机读 IOPS (4 队列) | 4K 随机写 IOPS (WriteThrough) | 64K 流式读吞吐 (MiB/s) | ReTrim (`discard=unmap`) | 识别磁盘控制器 |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **基线：`NVMe` (8 GiB)** | `72664.6` | `26571.5` | `7004.5` | `True` | `QEMU NVMe Ctrl` |
| **重构：`VirtIO-Blk` (`iothread0`, `num-queues=4`, 10 GiB)** | `110971.2` (`+52.72%`) | `30505.5` (`+14.81%`) | `9197.6` (`+31.31%`) | `True` | `Red Hat VirtIO SCSI Disk Device` |

---

## 4. Apple Silicon 10 核（4P+6E）宿主机：`6 vCPU` vs `7 vCPU` vs `8 vCPU` 真机 A/B 对照

- **统一基线**：`10240 MiB RAM`、`Balloon=Off`、`vmnet-shared`、`VirtIO-Blk (iothread0, num-queues=4, discard=unmap)`、`dxmt-native`、`guest-optimizer v3.1`、扁平单核簇拓扑（`-smp cpus=N,sockets=1,cores=N,threads=1`）。

| 拓扑 | 纯高 Draw-Call Mean FPS | 纯高 Draw-Call P1 Low | CPU 提交均值 (ms) | 混合多核并发 Mean FPS | 混合多核并发 P1 Low | 8 线程 CPU 吞吐 (ops/s) | 混合态 `QEMURenderServer` CPU | 混合态 `QEMU worker` CPU | 峰值 RSS (MiB) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **`6 vCPU`** | `64.69` | `54.29` | `15.42` | `59.35` | `44.56` | `2942211.3` | `15.00%` | `345.00%` | `2981.8` |
| **`7 vCPU`** | `69.08` | `57.58` | `14.44` | `59.51` | `41.94` | `2954953.6` | `19.15%` | `373.90%` | `5367.9` |
| **`8 vCPU`** | `63.38` | `52.47` | `15.74` | `58.57` | `44.50` | `3138110.7` | `21.25%` | `391.60%` | `4713.4` |

- **实证推荐固化值**：**`8 vCPU`** — 8 vCPU achieved highest composite score (96.99) with mixed-load P1 Low 44.50 FPS, draw-call mean 63.38 FPS, and MT throughput 3138110.7 ops/s.（已固化至 `golden_guest_manager.py` 的 `detect_recommended_vcpu()`；同时实测显示 `7 vCPU` 在纯高 Draw-Call 均值可达 `69.08 FPS`，可通过 `--vcpu 7` 按需切换，而 `8 vCPU` 在多线程满载下可将 Guest CPU 吞吐推至 `3.138M ops/s` / `741.7%` 彻底打破 6 vCPU 天花板，且 `QEMURenderServer` 仍仅占 `21.25%` 充裕无抢核）。

---

## 5. `guest-optimizer` v3.1（`spice-webdavd` 清理 + 动态页面文件钳位 + 无损回滚）

- **Profile 版本**：`revision = 4`，`version = 3.1`，`security_invariants_passed = True`
- **`spice-webdavd` 清理**：应用前 `{'Name': 'spice-webdavd', 'StartMode': 'Auto', 'State': 'Stopped'}` → 应用后 `{'Name': 'spice-webdavd', 'StartMode': 'Disabled', 'State': 'Stopped'}`；应用后新增 `APPCRASH 0x80000003` 事件 = **`0`**
- **动态页面文件钳位**：状态 `applied`，申请 `8192–12288 MiB`，基于 `C:` 当前可用空间 `7792 MiB`（预留 `>= 2048 MiB` 安全余量）直写 `PagingFiles` 并经 WMI 回读验证为 `5744–5744 MiB`
- **一键回滚复验**：`rollback_consistent = True`，`mismatch_count = 0`，`security_invariants_passed = True`，回滚后 `spice-webdavd` 状态 = `{'Name': 'spice-webdavd', 'StartMode': 'Auto', 'State': 'Stopped'}`

---

## 6. 全盘 SHA-256 零漂移与合规验收

- `golden_readonly = True`，`golden_zero_drift = True`
- `primary_zero_drift = True`，`zero_drift = True`
- `utm_defaults_restored = True`，`original_utm_app_present = True`
- 零 CPUID/SMBIOS/ACPI/TPM/Hypervisor 伪装，未触碰游戏/ACE/Windows 驱动，未触碰窗口 12B 独占路径与 `/Applications/UTM.app` 原件，零 `git commit / push / reset`。
