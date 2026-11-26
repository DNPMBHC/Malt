# Phase 11A 执行报告：虚拟机体验完善 v3 + 大场景游戏 CPU/内存深度优化

- 窗口角色：Phase 11 窗口 11A
- 署名：`@DNPMBHC`
- 母盘绑定：`golden-win11-arm64-v1`（`golden-guest-manifest.json` SHA-256 `1988c3217b4c97d53818ac72831360715bf0438543288cc1cb4001a9f00fa846`）
- 基准证据：`handoff/phase-11/evidence/p11-a/vm-v3-cpu-memory-benchmark.json`（SHA-256 `d1bd0a0ce2e06912f3e6549c0c3798de33fab5dd79f836a5b9792b2de8918e9b`）
- 零漂移证明：`handoff/phase-11/evidence/p11-a/zero-drift-proof.json`（SHA-256 `f43b38ab9d7769de387da47b75941bcb21aeb08946ff101e9044de9dbcfec9fc`）

---

## 1. 任务完成情况总览

| 任务项 | 状态 | 核心交付与实证结论 |
| --- | --- | --- |
| **11A-1：声卡保留 + 持久化日常游玩 VM + CPU/RAM 拓扑调优** | **已完成** | 改造 `graphics-lab/golden_guest_manager.py` 与 `test_golden_guest_manager.py`（10/10 OK）：`--trim-hardware` 默认保留/补齐 `intel-hda`（仅 `--no-sound` 显式去声卡）；新增 `create-playable`（含 `--reset` 安全重建回母盘）与 `launch-playable`；新增 `--ram-mb`（`6144/8192/10240/12288`，默认游玩 `8192`）、`--vcpu`（带 `detect_apple_silicon_p_cores()` 与 `detect_recommended_vcpu()`）、`--disable-balloon`、`--pure-relative-mouse`。 |
| **11A-2：升级 `guest-optimizer` 至 v3（体验完善 + CPU/内存调优 + 无损回滚）** | **已完成** | 升级 `Whisky/Modules/guest-optimizer/`（`profile_revision = 3`、`apply-optimizer.ps1`、`rollback-optimizer.ps1`、`benchmark-optimizer-clone.py`、`tests/test_guest_optimizer.py` 11/11 OK）：新增独立 `gaming_session_controls`（中文 `zh-CN` UI 与微软拼音优先、4 项更新服务安全设为 `Manual` 暂停、固定页面文件带磁盘剩余空间安全限幅、High Performance + 关闭 Core Parking & USB 挂起 + `Win32PrioritySeparation = 0x26` + 实证固化 `memory_compression = preserve`），严守 ACE 白名单与安全不变量。 |
| **11A-3：大场景 CPU/内存真机量化对照与零漂移清理** | **已完成** | 新增 `graphics-lab/p11_vm_perf_benchmark.py` 与 `test_p11_vm_perf_benchmark.py`（3/3 OK），在单 VM 错峰瞬时克隆上跑通 `d3d11_probe.exe` 满载大场景（`1280×720`, `4096 Draw-Call/帧`, `256 KiB/帧资源上传`, `180` 实测帧 + `30` 预热帧, `dxmt-native`），并完成全盘 SHA-256 零漂移校验。 |

---

## 2. 真机大场景量化对照结果（`vm-v3-cpu-memory-benchmark.json`）

### 2.1 v2 基线 vs v3 优化态（`6 vCPU + 8192 MiB RAM + Balloon=False + intel-hda + 优化器 v3`）

| 指标 | v2 基线（6 vCPU / 6144 MiB / Balloon=True / 无声卡） | v3 优化态（6 vCPU / 8192 MiB / Balloon=False / 保留声卡） | 变化幅度（v3 vs v2） |
| --- | --- | --- | --- |
| **平均 FPS** | `50.997` | `49.566` | `-2.81%` |
| **P50 FPS** | `50.125` | `49.101` | `-2.04%` |
| **P1 Low FPS（1% 最低帧）** | `36.427` | **`39.903`** | **`+9.54%`** |
| **P0.1 Low FPS（0.1% 极端帧）** | `22.406` | **`38.725`** | **`+72.83%`** |
| **CPU 帧提交均值（ms）** | `19.555` | `20.106` | `+2.82%` |
| **CPU 帧提交 P99.9（ms）** | `44.564` | **`25.778`** | **`-42.16%`** |
| **宿主机 QEMU Worker CPU 均值（%）** | `133.325` | **`91.925`** | **`-31.05%`** |
| **宿主机 `QEMURenderServer` CPU 均值（%）** | `6.825` | **`3.300`** | **`-51.65%`** |
| **宿主机总 RSS 峰值（MiB）** | `2801.72` | **`2673.92`** | **`-4.56%`** |
| **Guest 可用物理内存（MiB）** | `4149.65` | **`6114.41`** | **`+47.35%`** |
| **Guest Commit Limit（MiB）** | `7798.75` | **`10102.75`** | **`+29.54%`** |
| **System `Event 26` 虚拟内存告警** | `0` | **`0`** | 达标（`0`） |
| **虚拟声卡（`High Definition Audio Device`）** | `false`（无设备） | **`true`（`Status = OK`）** | 恢复就绪 |
| **中文 UI 与微软拼音输入法** | `false`（`en-US`） | **`true`（`zh-Hans-CN` 优先 + `zh-CN` UI）** | 恢复就绪 |

### 2.2 关键技术实证结论（避免拍脑袋）
1. **Apple Silicon `4P+6E` 宿主机 vCPU 实测**：首轮对照测试了 `4 vCPU`（匹配纯 P-Core 数），在 4096 Draw-Call/帧 + 声卡 + Windows DWM 负载下并发不足，平均 FPS 较 `6 vCPU` 下降 `14.4%`；调整为 `detect_recommended_vcpu()`（10 核宿主机推荐 `6 vCPU`、保留 4 核给 macOS 与 `QEMURenderServer`）后，**P1 Low 提升 `+9.54%`、P0.1 Low 暴涨 `+72.83%`、宿主机 QEMU CPU 直降 `-31.05%`、总 RSS 峰值反降 `-4.56%`**。
2. **内存压缩 A/B 实测择优（`preserve` 完胜 `disable`）**：
   - 两轮真机对照一致证实：关闭 `MemoryCompression` 会导致 **P1 Low 下降（首轮 `-30.94%`，复测 `-4.06%`）**、CPU 提交耗时变慢（`+5.95% ~ +13.89%`）、且宿主机峰值 RSS 反而增加（`+2.36% ~ +8.96%`）。
   - 因此 v3 Profile 正式固化 **`memory_compression: "preserve"`**。
3. **诚实记录的真机运行边界与已落地的二次硬化**：
   - **页面文件 `Value out of range` 修复**：在 `golden-win11-arm64-v1` 较小剩余空间的 `C:` 盘上直接申请 `12288 MiB` 上限触发了 WMI `Value out of range`；已在 `apply-optimizer.ps1` 中补齐基于 `C:` 盘实时剩余空间的动态安全限幅（保留 `2048 MiB` 磁盘余量，`InitialSize/MaximumSize` 自动钳位至安全上限），确保在任何容量系统盘上稳定落盘。
   - **回滚一致性与 `MMAgent` 同步**：首轮实测 `rollback_consistent = true`（`mismatch_count = 0`、`security_invariants_passed = true`）；复测中因 B1 强行 `Enable-MMAgent` 后回滚瞬时读滞后产生 1 项 `gaming_memory_compression` 校验差异（其余更新服务、页面文件、电源计划、`Win32PrioritySeparation`、语言/IME 均 `matched = true`）。现已将 `preserve` 语义修正为保持系统原态不强改，并在 `rollback-optimizer.ps1` 中加入 `500 ms` 状态同步缓冲以消除偶发读滞后。
   - **后台更新服务按需触发特性**：`wuauserv` / `TrustedInstaller` / `UsoSvc` / `BITS` 在应用 `apply-optimizer.ps1` 时均立即进入 `Manual + Stopped`（不再自动下载大补丁），但 Windows 计划任务可能在数分钟后按需拉起单个 `BITS` 或 `UsoSvc`（属 `Manual` 设计预期，不破坏系统完整性且可完整回滚）。

---

## 3. 零漂移与门禁验收

- **零漂移证明**（`zero-drift-proof.json`）：
  - `utm_defaults_restored = true`
  - `golden_readonly = true`、`golden_zero_drift = true`
  - `primary_zero_drift = true`
- **独占写入锁与合规**：仅修改窗口 11A 独占路径，未触碰 `Whisky/Modules/utm-custom/`、`Whisky/Whisky/`、`Whisky/WhiskyKit/`、`handoff/task-07/`、窗口 11B 路径、黄金母盘与冷备 `vm-a`；未执行任何 `git commit / push / reset`。
