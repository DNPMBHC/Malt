# Phase 11 总览：虚拟机基础体验与大场景 CPU/内存优化 v3 + 定制 UTM 实机编译与原生全屏闭环

- 署名：`@DNPMBHC`
- 前置基线：
  - `Whisky` `main` 已锁定 Phase 10（`Whisky/Modules/utm-custom/` 4 份合规补丁通过静态审计与叠加 `git apply --check`）；
  - Phase 10A 实测在 `dxmt-native` + `--trim-hardware` + 优化器 v2 下 `target-cn` 零冻结运行，并精准捕获 5 项虚拟机工程缺陷（光标合成断层、无声音、默认英文无中文输入法、瞬时克隆重装启动器、`Event 26` 虚拟内存不足与 Windows Update 后台抢占）。

---

## 本阶段核心目标

1. **彻底补齐虚拟机日常游玩基础体验**（声音、中文 UI 与微软拼音输入法、持久化工作 VM 免重装、屏蔽游戏期 Windows Update 与 `Event 26` 内存抖动）。
2. **深度优化大场景游戏的 CPU 运行效率与内存占用**（Guest 侧 vCPU 拓扑/线程优先级/内存压缩与固定页面文件优化 + Host 侧 QEMU/Metal 渲染线程 QoS、DXMT 着色器缓存持久化与中断精简，并附量化前后对照基准）。
3. **完善游戏原生全屏体验与定制 UTM 实机落地**：补齐纯相对鼠标开关（移除 `-device usb-tablet`）、打磨无边框原生全屏（自动分辨率/DPI/刷新率对齐、无工具栏、切屏不卡死）、在仓库外编出真实可运行的 `UTM-Custom.app`，并在真机上完成光标恢复与 `target-cn` 创角 → 大厅 → 靶场 3–5 分钟终局实测。

---

## 并行窗口与文件写入锁

| 窗口 | 难度与建议模型 | 核心职责 | 独占写入路径 |
| --- | --- | --- | --- |
| **11A** | 🟡 中等 · **`Hydrogen Medium`** | 声卡保留 + 持久化游玩 VM + 优化器 v3（中文/免更新/固定页文件）+ **大场景 CPU 效率与内存深度优化及基准对照** | `Whisky/Modules/guest-optimizer/**`、`graphics-lab/golden_guest_manager.py`、`graphics-lab/test_golden_guest_manager.py`、`graphics-lab/p11_vm_perf_benchmark.py`、`graphics-lab/test_p11_vm_perf_benchmark.py`、`handoff/phase-11/evidence/p11-a/**` |
| **11B** | 🔴 高难度 · **`Neon Medium`** | 补齐纯相对鼠标与渲染线程 QoS 补丁 + **完善原生无边框全屏体验** + 仓库外实机编译 `UTM-Custom.app` + 光标修复与 `target-cn` 大厅/靶场终局实测 | `Whisky/Modules/utm-custom/**`、`graphics-lab/utm_custom_patch_verify.py`、`graphics-lab/test_utm_custom_patch_verify.py`、`graphics-lab/p11_valorant_fullscreen_session.py`、`graphics-lab/test_p11_valorant_fullscreen_session.py`、`handoff/module-f/valorant-phase11-runs/**`、`handoff/phase-11/evidence/p11-b/**` |

> **实机错峰提示**：两窗口编码、补丁、单测与 `UTM-Custom.app` 编译完全可并行；当需要进行真机 QEMU 重负载压测时，避免同时运行两个 VM 抢占宿主机内存与 GPU，保证性能采样数据干净准确。

---

## 绝对不可突破的红线

1. **反作弊与安全红线**：严禁 CPUID/SMBIOS/ACPI/TPM/Hypervisor 伪装、严禁修改游戏或 ACE 二进制、严禁替换签名系统 DLL、严禁关闭 Secure Boot 或开启 Test Signing、严禁自动代过登录/创角/验证码。
2. **母盘零漂移**：`golden-win11-arm64-v1` 与主冷备 `vm-a` 必须保持只读与全盘 SHA-256 `zero_drift = true`。
3. **仓库纯净与隐私**：所有外部 UTM 源码与构建产物严格置于 `${TMPDIR}/utm-custom-src` 或 `<EXTERNAL_VOLUME>`，严禁写入本仓库；不得新增 `> 5 MiB` 文件；所有文档/JSON 必须使用中性占位符，严禁泄漏本地用户名或私有卷名；严禁执行 `git commit / push / reset` 或修改全局 Git 配置。
