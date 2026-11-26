# Phase 14 窗口 14A 终局交付报告：残余性能极限深挖与 Phase 11–14 全员合体端到端真机实测

- **署名**：`@DNPMBHC`
- **窗口角色**：Phase 14 — 窗口 14A
- **母盘基线**：`golden-win11-arm64-v1`（全盘 SHA-256 `zero_drift = true`，`golden_readonly = true`）
- **核心交付物**：
  - 评测框架与单测：`graphics-lab/p14_full_stack_perf_eval.py`、`graphics-lab/test_p14_full_stack_perf_eval.py`
  - 深度实验数据集：`handoff/phase-14/evidence/p14-a/perf-deep-dive-p14.json`
  - 全盘零漂移铁证：`handoff/phase-14/evidence/p14-a/zero-drift-proof.json`
  - 全员合体 `target-cn` 实测报告：`handoff/module-f/valorant-phase14-runs/real-run-report.json`、`handoff/module-f/valorant-phase14-runs/summary.md`

---

## 1. 任务 14A-1：3 项残余性能深挖真机实验

### 1.1 实验 1：双缓存持久化增益（`XtaCache` + `DXMT_SHADER_CACHE`）
在持久化游玩模式（`create-playable`，`8 vCPU / 10240 MiB / VirtIO-Blk 多队列 / socket-stream / dxmt-native`）下对比冷缓存首启 vs 热缓存二次启动（60s 窗口）：
- **双缓存落盘实证**：`DXMT_SHADER_CACHE` 从 `0 B` 落盘至 `955,656 B`（4 文件）并在二次启动保留递增至 `988,616 B`；Windows Prism `XtaCache`（受 TrustedInstaller ACL 保护，绝不破坏权限）持久保留 `346.26 MiB` → `346.57 MiB`。
- **前 60 秒量化收益**：
  - QGA 启动就绪时间：`13.71s` → **`12.81s`（`-6.56%`）**；
  - 60 秒窗口吞吐：冷启完成 `15` 轮（`2,250` 帧，每轮 `4.69s`），热启完成 **`20` 轮（`3,000` 帧，每轮 `3.13s`，初始化耗时 `-33.2%`，总吞吐 `+33.3%`）**；
  - 宿主机 `QEMU worker` 负载：P95 CPU 从 `196.87%` 压降至 **`116.78%`（`-40.7%`）**，峰值 CPU 从 `260.7%` 压降至 **`189.3%`（`-27.4%`）**；`QEMURenderServer` 峰值 CPU 从 `20.7%` 压降至 **`17.6%`（`-15.0%`）**。

### 1.2 实验 2：帧同步损耗（`QEMURendererFPSLimit = 0` vs `120` 与低延迟队列）
在 `UTM-Custom.app` 上对比 3 组呈现组合（`d3d11_probe` 离屏合成基准 + 真机 `target-cn` 交叉验证）：

| 配置臂 | `FPSLimit` | `drawable / inflight` | Mean FPS | P1 Low FPS | P0.1 Low FPS | P99–P50 抖动 (ms) | 真机 `target-cn` 兼容性 |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| `fps_limit_0_triple` | `0` | `3 / 3` | **`80.90`** | **`66.40`** | **`50.19`** | **`2.848`** | ⚠️ **真机触发按输入重绘与 SwapChain Present 阻塞** |
| **`fps_limit_120_triple`** | **`120`** | **`3 / 3`** | `80.30` | `62.57` | `43.43` | `3.582` | ✅ **真机全流程稳定（推荐生产默认）** |
| `fps_limit_120_lowlat_d2_i1` | `120` | `2 / 1` | `79.50` | `61.00` | `29.25` | `3.968` | 过窄队列导致突发 P0.1 Low 暴跌 |

- **关键工程洞察**：虽然离屏基准中 `FPSLimit = 0` 抖动更低（`-20.5%`），但真机 `target-cn` 实测暴露出 `QEMURendererFPSLimit = 0` 在 `CSMetalRenderer` 下会退化为鼠标移动才刷新的按需重绘并在游戏首帧 Present 卡死；而 `QEMURendererFPSLimit = 120` + 三重缓冲在真机 `target-cn` 靶场中将 `Slack + Slop` 从 Phase 11B 的 `2.93 ms` 实测压降至 **`2.36 ms`（`-19.5%`）**，其中 `Slack` 从 `2.45 ms` 暴降至 **`1.09 ms`（`-55.5%`）**。

### 1.3 实验 3：QEMU 残余轮询设备审计与 `virtio-input` vs `usb-mouse`
- **QEMU 设备树审计**：`has_usb_tablet = false`、`has_virtio_balloon = false`、`has_slirp_user_net = false`；识别出 1 项可安全移除的残余外设：`usb-redir`（3 条未使用重定向通道与多余 `qemu-xhci` 控制器）。
- **WHQL `vioinput` vs `usb-mouse`（全程 `Secure Boot = True`，绝不关闭 Secure Boot）**：
  - 确认母盘预装 Red Hat WHQL 签名 ARM64 `vioinput.inf`（`oem5.inf`, `v100.100.104.27100`）；
  - 高频相对鼠标移动实测：`usb-mouse` 均值 `1041.30 interrupts/s`（峰值 `3080.05/s`，QEMU CPU `24.9%`）vs `virtio-mouse-pci` 均值 **`885.61 interrupts/s`（`-14.95%`）**、峰值 **`1629.99/s`（`-47.1%`）**、QEMU CPU `23.1%`（`-7.2%`）。

---

## 2. 任务 14A-2：Phase 11–14 全员合体端到端真机验收

### 2.1 无桌面应用壳（`--app-shell-vm`）+ Game Mode + 热唤醒秒开
- `--app-shell-vm` 紧凑窗启动 → `app-shell-state.json` 切换 `game_foreground` 无边框全屏 + Game Mode 全通（注：实机验证发现生产模式必须确保后台同步更新 `app-shell-state.json` 并开启 `UTM_KEEP_CURSOR_VISIBLE_ON_INHIBIT=1`，否则紧凑窗会锁定分辨率并隐藏全屏光标）。
- 热待机唤醒（`warm-standby` → `resume-launch`）：总就绪耗时 **`0.379 s`**（`vm_started = 0.154s`, `qga_ready = 0.225s`），较冷启 `17.176 s` 提速 **45.3×**（缩短 **97.8%**）。

### 2.2 `1920×1200` `target-cn` 全员合体靶场回归（36,201 帧，全高 vs 全低画质对照）
详细逐项对比见 `handoff/module-f/valorant-phase14-runs/summary.md`：
- **全低画质（`15,298` 帧，4.2 min）**：官方 `Avg. Frametime = 16.51 ms` → **等效均值 `60.57 FPS`（正式突破 `60+ FPS` 稳态！）**，日志窗口 P50 **`61.08 FPS`**，Game Thread `>= 60 FPS` 占比 **`68.71%`**；较 Phase 11B 巅峰第 8 分钟（`55.51 FPS`）提升 **`+9.12%`（`+5.06 FPS`）**，较 Phase 11B 靶场纯实战均值（`45.21 FPS`）提升 **`+33.97%`（`+15.36 FPS`）**；`Slack + Slop` 降至 **`2.36 ms`（`-19.5%`）**。
- **全高画质（`20,903` 帧，6.4 min）**：官方 `Avg. Frametime = 18.35 ms` → **等效均值 `54.50 FPS`**，Game Thread `>= 60 FPS` 占比 **`52.13%`**。
- **同分辨率全高 vs 全低 FPS 差异仅 `+11.1%` 的根因铁证**：Apple Silicon GPU（`dxmt-native` → Metal）远未饱和；真正锁死上限的是 Guest 单线程 UE4 `GameThread` 在 Windows ARM64 Prism x86_64 转译下的单核 IPC 天花板（约 `60–65 FPS`），降画质无法削减 x86_64 逻辑/物理/ACE 转译指令数。
- **反作弊与稳定性**：`DXMT_SHADER_CACHE` 累积至 `10.03 MiB`（4 文件），两轮共 10.6 分钟 0 崩溃、0 踢线，`ACEManager_IssueAntiTick` 116 次 HTTP `200` OK，全段 `< 5 FPS` 严重掉帧告警由 Phase 11B 的 `39` 次压降至 **`16` 次（`-59.0%`）**。
- **网络诚实边界**：因 ad-hoc 签名 `UTM-Custom.app` 无 `com.apple.vm.networking` 且 `async_net_proxy` 仅支持 UDP/ICMP NAT，本次线上 TCP 登录回退 `Emulated`（录得 `5` 次 `slirp` 告警），正式发行版需 Apple Developer ID 签名赋予 `com.apple.vm.networking` 直连 `vmnet-shared` 或接入完整 TCP/UDP NAT（如 `gvproxy`）以实现 `0` 丢包告警。

---

## 3. 任务 14A-3：清理、全盘 SHA-256 零漂移铁证与全量门禁

- **清理与零漂移**（见 `zero-drift-proof.json`）：所有临时实验克隆与 `target-cn` E2E 克隆已彻底销毁，外置游戏母盘 `valorant-cn-data.qcow2` 未做任何写入（`game_disk_untouched = true`），`golden-win11-arm64-v1.utm`（`golden_readonly = true`, `golden_zero_drift = true`）、冷备 `vm-a`（`primary_zero_drift = true`）与 `/Applications/UTM.app`（`original_utm_codesign_ok = true`）全盘 SHA-256 **`zero_drift = true`**，宿主机无任何残留 QEMU 进程（`lease_ready = true`）。
- **门禁验收**：
  - `(cd graphics-lab && python3 -B -m unittest discover -v)`：**PASS**
  - `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test`：**PASS**
  - 仓库合规扫描：零 `> 5 MiB` 新增文件、零隐私路径泄漏、零越界修改、零 git 操作。
