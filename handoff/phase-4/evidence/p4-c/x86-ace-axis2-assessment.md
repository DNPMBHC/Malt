# `x86_64` 仿真环境探测 `target-cn`（ACE）轴 2（虚拟化策略态度）可行性与性价比 Go/No-Go 评估

- **日期**：2026-11-23
- **负责方**：`@DNPMBHC`（Phase 4 窗口 4C）
- **评估对象**：是否在 Apple Silicon 宿主机上通过 QEMU `x86_64` TCG（纯软件多核 JIT 仿真）临时构建最小 `x86_64` Windows Guest，以单独探测 `target-cn`（腾讯 ACE）的**轴 2（虚拟化 / Hypervisor 策略态度）**
- **核心结论**：**`No-Go`（不建议当前在 Apple Silicon 本地投入 QEMU `x86_64` TCG 专项建机探测）**。建议维持现状（轴 1 确凿阻塞、轴 2 如实标记 `unknown`），直接等待上游生态信号（如 NVIDIA RTX Spark / Windows on Arm 推动厂商下发原生 ARM64 反作弊驱动），届时直接在现有原生 `Hypervisor.framework` ARM64 `vm-a` 上零额外成本一次复测双轴。

---

## 1. 已有实锤证据基线（事实边界）

依据窗口 B 在 `vm-a`（Windows 11 Enterprise Evaluation 24H2 ARM64 `Build 26100.1`，Secure Boot + TPM 2.0 恢复基线）上完成的动态采样归档 `handoff/module-f/guest-dynamic-observations.json`（`report_sha256: c4ddb5920405f2a6efa7dbcf164fe6f195e50916f5cba435b516f6e527251da1`）：

1. **已确凿实锤（轴 1）**：`target-cn` 官方安装包 `2.17.4.510`（`installer_sha256: 686ee838411863d2eccdbe8a0596129e509819ae46626408760588ae8b0c800e`）经 Prism 转译完成用户态启动并下载客户端后，落地的 3 个 WHQL 签名厂商内核驱动全部为 **AMD64 (`0x8664`)**：
   - `driver-330.sys`（`1.0.2603.17210`，`4,125,432 B`，SHA-256 `dc2456422cc6e75f8c375ac3c9d630531b88a2ad2f8bd17191a62c5de9170615`）
   - `driver-331.sys`（`29.8.2609.445`，`3,909,808 B`，SHA-256 `2a8e8928de766d3c6ef1912d7da6d37e2f7509b5b7331805d45bce1dd9cb6f60`）
   - `driver-332.sys`（`0.1.2610.620`，`2,966,632 B`，SHA-256 `67e1e869d15396f0fe95ab09c5befbd81d023286bcbcb870ec76e478d48138a7`）
2. **当前阻断点与未知项（轴 2）**：SCM 注册了用户态保护服务及 2 个内核驱动服务项（Event 7045），但 ARM64 Windows 内核无法加载 `0x8664` 内核驱动（`kernel_load.status == "not_loaded"`），游戏启动被弹窗中止。因为驱动尚未进入内核执行，无法在 ARM64 Guest 中独立观测厂商驱动对 Hypervisor / 虚拟化环境的策略响应，故 `axis_2_guest_policy` 严谨保持为 **`unknown`**。
3. **五维状态分离现状**：`actual_driver_load = not_loaded`、`actual_game_start = rejected`、`actual_protected_online_session = not_tested`、`publisher_stance = unknown`。

---

## 2. 成本、技术约束与实验信度定量评估

### 2.1 存储空间成本（对比本地磁盘现状）
- **宿主机存储约束**：
  - 内置系统盘当前可用空间仅约 **`7.2 GiB`**，严禁放置任何 VM 镜像或临时盘；
  - 外接卷 `/Volumes/<EXTERNAL_VOLUME>`（总容量 `477 GiB`）：Phase 2/3 采样高峰期任务书记录的历史参考余量约 **`27 GiB`**；当前清理临时数据盘后实测余量约 **`135 GiB`**（其中主干净 ARM64 `vm-a` 占用 `26 GiB`，还需同时支撑窗口 4B 独立克隆快照与窗口 4C 独立克隆快照）。
- **构建最小 `x86_64` Windows 11 探测环境的最低磁盘开销估算**：

| 占用项 | 估算容量 | 说明 |
| --- | ---: | --- |
| 官方 Windows 11 `x64` ISO 安装镜像 | ~`6.0–6.5 GiB` | 必须使用官方未魔改签名镜像（严禁破签精简版） |
| Windows 11 `x64` 系统盘（含虚拟 TPM / OVMF / 基础驱动 / QGA） | ~`24–30 GiB` | 需启用 Secure Boot + TPM 2.0 满足反作弊前置基线 |
| `target-cn` 客户端 + 启动器临时数据盘 | ~`28–45 GiB` | 前期实证确认驱动在登录后下载游戏客户端阶段才落地 |
| **合计新增峰值占用** | **~`58–82 GiB`** | 远超历史 `27 GiB` 紧张余量；即使按当前 `135 GiB` 计算，也会吃掉超过一半外接卷可用空间并与 4B/4C 并行快照争抢空间 |

### 2.2 QEMU `x86_64` TCG 纯软件仿真的时间与性能约束
Apple Silicon（`arm64`）的 `Hypervisor.framework` 仅能虚拟化 `arm64` Guest，无法硬件加速 `x86_64` 内核代码。因此 `x86_64` Guest 只能运行在 **QEMU TCG（Tiny Code Generator）纯软件多线程 JIT 翻译模式**下：

1. **CPU 性能衰减（10×–30×）**：
   - 在原生 HVF ARM64 `vm-a` 上，冷启到桌面仅需数秒；而在 QEMU `x86_64` TCG 下，完整安装 Windows 11 `x64`（含 OOBE、安全更新、QGA、登录器与客户端校验）通常需要 **3–6+ 小时**，单次冷启即可达 **2–5 分钟**。
2. **实验信度缺陷（高假阳性 / 不可归因风险）**：
   - **环境失真**：TCG 仿真下的指令计时（`RDTSC` / APIC timer 抖动）、内存屏障开销和单核吞吐极低，内核反作弊驱动在初始化自检或心跳超时检测时极易因 **watchdog 超时、启动超时或时钟漂移** 触发保护性退出，而非明确的“检测到 Hypervisor 策略拒绝”；
   - **签名与安全栈干扰**：QEMU `x86_64` 软件 TPM (`swtpm`) + OVMF Secure Boot + TCG 模拟 CPUID（严禁隐藏虚拟化或伪造硬件特征）下，即使观察到驱动加载失败或弹窗退出，也难以严谨剥离“TCG 纯软件仿真兼容性故障”与“商业厂商针对合法 HVF/ARM64 虚拟化的最终策略态度”；
   - **不可外推至未来 ARM64 驱动**：即使 `x86_64` 当前驱动在 TCG 下给出某种响应，未来厂商若为 Windows on Arm（如高通 Snapdragon X / NVIDIA RTX Spark）发布原生 `0xAA64` 驱动，其虚拟化策略与检测面（如是否允许 Windows 11 原生 VBS/Hyper-V 嵌套与合规 VM）完全可能随新分支调整，旧 `x86_64` 探测结论不具备跨架构外推效力。

### 2.3 工程决策矩阵（信息价值 vs 投入产出比）

| 假设 `x86_64` TCG 探测可能得到的结果 | 对 `my-project` 当前可交付产品的影响 | 投入产出比（ROI） |
| --- | --- | --- |
| **情形 A：轴 2 明确拒绝虚拟化** | 轴 1 已在 ARM64 上确凿阻塞，本地 VM 原本就无法运行该游戏，策略维持“合规远程物理机兜底 + 不宣称支持”。 | **极低**（不改变任何现有架构与产品决策） |
| **情形 B：轴 2 允许虚拟化加载** | 在没有原生 ARM64 驱动（轴 1 未解）的前提下，QEMU `x86_64` TCG 纯软件仿真完全不可玩（无硬件虚拟化、CPU 减速 10×–30×、无 GPU 硬件加速），无法转化为可用产品路径。 | **极低**（仍然必须等待厂商发布原生 ARM64 驱动） |
| **情形 C：TCG 超时 / 蓝屏 / 非明确错误码** | 无法严谨判定轴 2，结果仍为 `unknown`，白白消耗 60+ GiB 磁盘与半天以上人力/机时。 | **负收益** |

---

## 3. 最终 Go/No-Go 结论与触发重估条件

### 结论：**`No-Go`（暂缓并否决在 Apple Silicon 上搭建 `x86_64` TCG Guest 专测 ACE 轴 2）**

1. **资源聚焦**：不在纯软件仿真 `x86_64` 路线上投入磁盘（`58–82 GiB`）与工程时间，严禁任何隐藏虚拟化、伪造 CPUID/SMBIOS 或破坏安全链路的试探手段。
2. **合规口径保持不变**：
   - 在所有面向用户与总控的文档中，严格保持 `target-cn`（`2.17.4.510`）：`axis_1_native_driver_distribution = observed_amd64_only_in_sample`、`axis_2_guest_policy = unknown`、`protectedGameLaunchAuthorized = false`。
   - 无内核反作弊游戏继续主力走宿主机 Wine 路线（DXMT / D3DMetal / KosmicKrisp）；极简 ARM64 Guest 优化器（任务 C1）与开源 ARM64 WDDM 3D 图形栈（窗口 4B）负责把合规 Windows 11 24H2 ARM64 底座打磨到极致。
3. **零成本重估触发条件（何时重新检验轴 2）**：
   - **触发器 1（首要）**：当 NVIDIA RTX Spark / Windows on Arm 生态推动厂商发布官方签名 `0xAA64`（ARM64）反作弊驱动安装包，或在官方公告中明确支持 Windows on Arm 时，直接复用现有原生 `Hypervisor.framework` ARM64 `vm-a`（零新镜像成本、零 TCG 失真）在 30 分钟内完成双轴实测；
   - **触发器 2（低成本旁路）**：若未来团队恰好拥有一台闲置的物理 `x86_64` Windows 宿主机（支持原生 KVM/Hyper-V 硬件虚拟化，避免 TCG 失真），且明确需要提前确认轴 2 商业策略，可在该 `x86_64` 物理机上低成本执行一次硬件虚拟化采样，而非在 Apple Silicon 上强跑 TCG。
