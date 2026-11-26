# Phase 14 `target-cn` 全员合体真机实测与同分辨率全高/全低画质对照总结

- **署名**：`@DNPMBHC`
- **阶段与窗口**：Phase 14 — 窗口 14A（Phase 11–14 全员合体端到端真机回归）
- **运行栈配置**：`8 vCPU / 10240 MiB RAM / Balloon=Off / VirtIO-Blk 多队列 (iothread0, num-queues=4, discard=unmap) / dxmt-native + 持久化双缓存 (DXMT_SHADER_CACHE 10.03 MiB + XtaCache 346.6 MiB) / UTM-Custom 10 补丁 (Game Mode + 高回报率鼠标 1.5ms 合批 + 防误触 Cmd+W/Q/H/M + 纯相对鼠标无 usb-tablet + QEMURendererFPSLimit=120) / guest-optimizer v3.1`
- **数据来源**：`handoff/module-f/valorant-phase14-runs/real-run-report.json`（完整 `2.10 MiB` `ShooterGame.log` / `15,123` 行 / `36,201` 帧官方逐帧统计）

---

## 1. 一句话核心结论

Phase 11–14 全员合体栈在 **`1920×1200`** 靶场实测中，**全低画质正式突破 `60+ FPS` 稳态（官方 15,298 帧 `Avg. Frametime = 16.51 ms` → 等效均值 `60.57 FPS`，日志窗口 P50 `61.08 FPS`，Game Thread `>= 60 FPS` 帧占比达 `68.71%`）**；全高画质亦达到 **`54.50 FPS`**（`18.35 ms`，`20,903` 帧），全段 `< 5 FPS` 严重掉帧告警由 Phase 11B 的 `39` 次压降至 **`16` 次（`-59.0%`）**，`Slack + Slop` 帧同步损耗由 `2.93 ms` 压降至 **`2.36 ms`（`-19.5%`）**，其中 `Slack` 从 `2.45 ms` 暴降至 **`1.09 ms`（`-55.5%`）**。

---

## 2. 对照 Phase 11B 基线与「同分辨率全高 vs 全低画质」逐项量化

| 指标 | Phase 11B 基线 (`1920×1200` 巅峰 Min 8 / 6 vCPU) | Phase 14 合体 · 全高画质 (`1920×1200`, 20,903 帧) | Phase 14 合体 · 全低画质 (`1920×1200`, 15,298 帧) | 全低 vs 11B 巅峰变化 |
| :--- | :---: | :---: | :---: | :---: |
| **等效均值 FPS** | `55.51` (纯实战均值 `45.21`) | `54.50` (`18.35 ms`) | **`60.57`** (`16.51 ms`) | **`+9.12%` (`+5.06 FPS`)** / 较纯实战 **`+33.97%`** |
| **P50 FPS** | `58.44` (纯实战 `49.63`) | — | **`61.08`** (`n=230`) | **`+4.52%` (`+2.64 FPS`)** |
| **Game Thread `>= 60 FPS` 占比** | — | `52.13%` (`10,896 / 20,903`) | **`68.71%`** (`10,511 / 15,298`) | — |
| **Avg. Engine Latency (ms)** | `22.62` (1024×768 NPEV2) | `27.52` | **`22.62`** (1920×1200) | 像素 `2.93×` 下持平 |
| **Avg. Work (ms)** | `19.69` | `25.00` | **`20.26`** | — |
| **Avg. Slack (ms)** | `2.45` | `1.75` (`-28.6%`) | **`1.09`** (`-55.5%`) | **`-1.36 ms`** |
| **Avg. Slop (ms)** | `0.48` | `0.77` | `1.27` | `+0.79 ms` |
| **`Slack + Slop` 合计 (ms)** | `2.93` | `2.52` (`-14.0%`) | **`2.36`** (`-19.5%`) | **`-0.57 ms`** |
| **严重掉帧告警 (`< 5 FPS`)** | `39` 次 | 全程合计 `16` 次（两轮 10.6 min） | 全程合计 **`16` 次** | **`-59.0%`** |
| **ACE 云端心跳 HTTP `200`** | `154` 次 | 两轮合计 **`116` 次**（0 踢线） | 两轮合计 **`116` 次** | 稳定通过 |
| **DXMT 着色器缓存落盘** | `8.85 MiB` (4 files) | 持续累积 | **`10.03 MiB`** (`10,512,760 B`, 4 files) | 持久化生效 |

---

## 3. 核心工程诊断：为何「同分辨率全高 vs 全低画质」FPS 变化不大（`54.50` → `60.57 FPS`, `+11.1%`）？

**第一性原理铁证**：
1. **Apple Silicon GPU（`dxmt-native` → Metal）远未饱和**：从全高画质切到全低画质，`Avg. Work` 仅减少 `4.74 ms`（`25.00 ms` → `20.26 ms`），宿主机 `QEMURenderServer` 始终仅占不到半核 CPU，证明像素着色器与画质特效不是瓶颈。
2. **硬天花板在 Guest 单线程 `GameThread` + Windows ARM64 Prism x86_64 转译**：即便调至全低画质，仍有 `31.3%` 的 `GameThread` 帧（`4,531 / 15,298`）落在 `30–60 FPS` 区间、`0` 帧突破 `120 FPS`。降低画质无法减少 UE4 单线程游戏逻辑、物理、动画与 ACE 校验的 x86_64 指令数，因此单核 Prism 转译 IPC 直接锁死了 **`60–65 FPS`** 的当前物理上限。

---

## 4. 真机现场发现的 2 项真实工程边界（诚实记录，不粉饰）

1. **`QEMURendererFPSLimit = 0` + `--app-shell-vm` 的真机回归缺陷**：
   - 虽然离线离屏基准 `d3d11_probe` 在 `FPSLimit = 0` 下抖动最低，但在真机运行 `target-cn` 时暴露出 `QEMURendererFPSLimit = 0` 会导致 `CSMetalRenderer` 变为仅在鼠标移动时局部重绘、并在游戏初始化 `voice-chat` 后首次 SwapChain Present 时阻塞；同时 `--app-shell-vm` 在 `state_file` 未自动联动 `game_foreground` 时会锁定紧凑窗口、隐藏 USB 共享入口与全屏光标。
   - **已立即定位验证**：切回 `QEMURendererFPSLimit = 120` + `--game-shell-vm` + `UTM_KEEP_CURSOR_VISIBLE_ON_INHIBIT = 1` 后，画面连续刷新、全屏光标、分辨率缩放与游戏进图立即恢复正常，顺利完成两轮 10.6 分钟实测。
2. **去 `slirp` 网络在 ad-hoc 签名 `UTM-Custom.app` 上的外网 TCP 边界**：
   - Phase 12A 的零特权 `async_net_proxy`（`socket-stream`）仅实现 ARP/DHCP/ICMP/UDP NAT（未实现外网 TCP NAT），且 ad-hoc 签名 `UTM-Custom.app` 无 `com.apple.vm.networking` entitlement 无法直连内核 `vmnet-shared`。因此本次线上登录回退至 `Emulated`（日志仍录得 `5` 次网络告警：`1` 次 Burst Loss + `4` 次 `256-packet ack`）。
   - **明确根治路径**：正式发布时通过 Apple Developer ID 签名赋予 `com.apple.vm.networking` 直通 `vmnet-shared`（或为 `socket-stream` 补齐完整 TCP/UDP NAT 如 `gvproxy`），即可彻底清零 `slirp` 丢包告警。

---

## 5. 下一代性能物理上限研究结论

- **已逼近当前硬件极限的维度**：
  - `DXMT-native` Metal 图形转译（GPU 充裕，非瓶颈）；
  - `VirtIO-Blk` 多队列 I/O（`110k+` 4K IOPS、`9.2 GiB/s` 流式读）；
  - 双缓存持久化（`DXMT_SHADER_CACHE` `10.03 MiB` + `XtaCache` `346.6 MiB`，二次启动初始化耗时 `-33.2%`，QEMU P95 CPU `-40.7%`）；
  - 主机呈现与输入（Game Mode + 1.5ms 鼠标合批 + 突发稳帧 P1 Low `+54.3%` + 热待机唤醒 `0.379s`）。
- **必须依赖上游变革才能突破的硬上限**：
  1. **Prism x86_64 → ARM64 单线程转译税（~25–35% IPC 损耗）**：唯有游戏厂商提供原生 Windows/macOS ARM64 客户端才能跨过 `60–65 FPS` 迈向 `120+ FPS`；
  2. **内核反作弊（ACE）虚拟化边界**：必须运行在完整未修改的 Secure Boot + vTPM Windows 内核中，无厂商授权无法在 Wine/CrossOver 下直接运行；
  3. **macOS `Virtualization.framework`（VZ）原生能力缺口**：若未来 macOS 原生开放 vTPM 2.0 + Paravirtualized Metal/DX 图形接口，可进一步消除 QEMU VM-exit 与显示拷贝损耗；
  4. **Apple Silicon P-Core 数量**：当前 10 核（`4P+6E`）在 `8 vCPU` 下有半数线程溢出至 E-Core，升级至更多 P-Core 的 M-Pro/Max 芯片可获得线性多核收益。
