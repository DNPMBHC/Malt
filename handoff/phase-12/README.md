# Phase 12 总览：原生管线重构（Guest CPU 突破 + 去 `slirp` 原生网络）与电竞级外设/游戏模式闭环

- 署名：`@DNPMBHC`
- 前置基线：
  - Phase 11 已实机编出可运行的 `UTM-Custom.app`，并在 `target-cn` 上完整跑通 25.33 分钟教学 + 主大厅 + 9.01 分钟 `1920×1200` 靶场实战（热缓存第 8 分钟均值 `55.51 FPS` / P50 `58.44 FPS`，ACE `154` 次 HTTP `200` OK、`0` 崩溃、`0` 条 `1275` 报错）；
  - Phase 11 深度遥测精准锁定两大性能天花板：**① Guest CPU（6 vCPU 打满 `587.8%`，GPU 仅 `33%–45%`）与 `2.93 ms` 帧同步 `Slack/Slop`；② ad-hoc 签名被迫回退用户态 `slirp` NAT 导致的 `256-packet ack` 丢包积压（贡献 `12.8%` 的 `<5 FPS` 严重掉帧）**。

---

## 本阶段核心目标

1. **重构网络与 I/O 原生管线（彻底消灭 `slirp` 丢包与磁盘流式卡顿）**：
   - 落地 macOS 原生 `vmnet.framework` 管线（优先评估 `socket_vmnet` / 原生 vmnet 助手或复用官方已签名网络组件 + `virtio-net-pci` 多队列 `mq=on`），彻底替代单线程用户态 `slirp`，将 `Burst Loss` 与 `256-packet ack` 积压压降至 `0`；
   - 为 VirtIO-Blk 启用独立 `iothread` + 多队列 `num-queues` + `discard=unmap`，把持久化日常游玩 VM 默认 RAM 升至 **`10240 MiB (10 GiB)`**（充分利用 macOS 按需分页与原生内存压缩）。
2. **突破 Guest CPU 天花板与降低帧同步损耗**：
   - 在 Apple Silicon 10 核宿主机上完成 **`6 vCPU` vs `7 vCPU` vs `8 vCPU`** + 扁平单核簇拓扑 + QEMU `Hypervisor.framework` 原生加速参数实测对照，配合清理 `spice-webdavd` 崩溃服务与游戏进程调度优化，突破 `1920×1200` 稳态 `60+ FPS`；
   - 压低 `Avg. Slack + Slop (2.93 ms)` 显示提交同步等待。
3. **电竞级 macOS 原生游戏体验闭环**：
   - 为 `UTM-Custom.app` 适配 **macOS 原生游戏模式（Game Mode）**（`LSApplicationCategoryType = public.app-category.games` + `LSSupportsGameMode = YES`），进全屏自动压制宿主机后台抢核；
   - 落地 **高回报率鼠标（1000Hz–8000Hz）无损微位移合批（Delta Coalescing）**，消除甩枪中断风暴掉帧；
   - 落地 **macOS ↔ Windows 按键映射 + 自动屏蔽 `Cmd+W / Cmd+Q / Cmd+H / Cmd+M`** 防误关窗，保留 `Cmd+Option+G` 安全逃生热键。

---

## 并行窗口与文件写入锁

| 窗口 | 难度与建议模型 | 核心职责 | 独占写入路径 |
| --- | --- | --- | --- |
| **12A** | 🔴 高难度 · **`Neon Medium`** | **原生网络管线（去 `slirp` / 原生 `vmnet`）+ Guest CPU/vCPU 拓扑与 `10 GiB` 内存/多队列 I/O 重构** + 清理 `spice-webdavd` 崩溃服务 + 前后量化基准 | `Whisky/Modules/guest-optimizer/**`、`graphics-lab/golden_guest_manager.py`、`graphics-lab/test_golden_guest_manager.py`、`graphics-lab/p12_cpu_net_benchmark.py`、`graphics-lab/test_p12_cpu_net_benchmark.py`、`handoff/phase-12/evidence/p12-a/**` |
| **12B** | 🔴 高难度 · **`Neon Medium`** | **macOS 原生 Game Mode + 高回报率鼠标无损合批 + 键位映射/防误触屏蔽（`Cmd+W/Q/H/M`）+ 低同步延迟 Metal 管线** + 重编 `UTM-Custom.app` 并完成 `target-cn` 靶场回归对比 | `Whisky/Modules/utm-custom/**`、`graphics-lab/utm_custom_patch_verify.py`、`graphics-lab/test_utm_custom_patch_verify.py`、`graphics-lab/p12_gamemode_input_session.py`、`graphics-lab/test_p12_gamemode_input_session.py`、`handoff/module-f/valorant-phase12-runs/**`、`handoff/phase-12/evidence/p12-b/**` |

> **实机错峰提示**：两窗口编码、补丁与 `UTM-Custom.app` 编译零冲突可完全并行；执行真机 QEMU 重负载基准或 `target-cn` 靶场实测时单 VM 错峰运行，确保 CPU/网络/帧率采样不受干扰。

---

## 绝对不可突破的红线

1. **反作弊与安全红线**：严禁任何 CPUID/SMBIOS/ACPI/TPM/Hypervisor 伪装、严禁修改游戏或 ACE 二进制、严禁替换签名系统 DLL、严禁关闭 Secure Boot 或开启 Test Signing、严禁自动代过登录/创角/验证码。
2. **母盘与原件零漂移**：`golden-win11-arm64-v1`、冷备 `vm-a` 与 `/Applications/UTM.app` 原件必须保持零漂移、完整无损。
3. **仓库纯净与隐私**：外部源码与编译产物严格置于 `${TMPDIR}` 或 `<EXTERNAL_VOLUME>`，严禁写入仓库；零新增 `> 5 MiB` 文件；所有文档/JSON 严格使用中性占位符，严禁泄漏本地用户名或私有卷名；严禁执行 `git commit / push / reset` 或修改全局 Git 配置。
