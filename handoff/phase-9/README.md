# Phase 9 多窗口并行开发总控协议：UTM 原生 `DXMT` 后端破局无畏契约死锁与系统深度安全精简

日期：2026-11-24  
署名：`@DNPMBHC`  
前置全绿基线（`main@bdaa0929`）：
- SwiftPM **258 项（248 通过 / 10 显式跳过 / 0 失败）**；Strict SwiftLint **0 违规**；Strict `swift-format` **6/6 通过**；
- `graphics-lab` **240 项 OK**；`guest-optimizer` **10 项 OK**；防外挂静态审计（132 源码 + 6 反例自检）通过；
- 核心新发现（本机 `/Applications/UTM.app` 只读实证）：
  1. UTM 5.0.9 内置两套完全独立的宿主机 Neptune 3D 后端：**`d3dmetal-native.framework`**（默认）与 **`dxmt-native.framework`**（开源 DXMT 原生 Metal 后端），且 UTM.app 原生内置 `QEMUDirectXDriver`、`QEMURendererBackend`、`QEMURendererFPSLimit` 与 `NPT_BACKEND=dxmt` / `NPT_DEBUG=1` 支持；
  2. 此前 7A/8A 连续三次创角冻结时均默认运行在 `d3dmetal` 后端且宿主机 `QEMURenderServer` CPU 归 `0.0%`，切至原生 **`DXMT`** 后端无需修改任何 Windows 内核、无需关闭 Secure Boot、无需触碰游戏/ACE 二进制。

---

## 1. Phase 9 核心目标

1. **窗口 9A（🔴 高难度 · 推荐 `Neon Medium`）**：解锁并实证 UTM 5.0.9 原生 **`DXMT` 宿主机 Neptune 后端（`QEMUDirectXDriver=DXMT` / `NPT_BACKEND=dxmt`）**，在 `golden-win11-arm64-v1` 瞬时克隆上验证能否打破 `d3dmetal-native` 的 2.6 秒创角死锁、进入无畏契约大厅/靶场并实测 FPS；若仍有冻结则用 macOS 原生 `sample <QEMURenderServer_PID>` 抓出精确宿主机死锁调用栈；
2. **窗口 9B（🟡 中等难度 · 推荐 `Hydrogen Medium`）**：深度研究 UTM 原生硬件拓扑与 Windows 11 24H2 ARM64 后台组件，在 100% 保护安全链/Prism/WHQL 3D/ACE 白名单与一键回滚前提下，升级极简优化器 v2 与 UTM 无用虚拟设备裁剪方案，进一步压低空载 RSS 与 QEMU CPU 开销。

---

## 2. 双窗口分工、难度评级与严格文件写入锁

| 窗口 | 任务文档 | 难度与建议模型 | 依赖 VM | 核心职责 | 独占可写路径（严格互斥） |
| --- | --- | :---: | :---: | --- | --- |
| **窗口 9A** | `window-9a-utm-dxmt-backend-and-valorant.md` | **🔴 高难度**<br>推荐 **`Neon Medium`** | 是（优先独占瞬时克隆） | 实证 UTM 原生 `QEMUDirectXDriver=DXMT` / `NPT_BACKEND=dxmt` 切换（用 `d3d11_probe` 验真 Timestamp Query 与性能）；在 `DXMT` 后端下重测无畏契约静态 `1280×720` 创角/大厅/靶场；若仍冻结则用 `sample` + `NPT_DEBUG=1` 抓宿主机精确堆栈；销毁克隆校验零漂移 | `handoff/module-f/valorant-phase9-runs/`（新建）<br>`graphics-lab/p9_valorant_*`（新建）<br>`graphics-lab/test_p9_valorant_*`（新建）<br>`handoff/phase-9/evidence/p9-a/`（新建） |
| **窗口 9B** | `window-9b-deep-guest-trim-and-utm-profile.md` | **🟡 中等难度**<br>推荐 **`Hydrogen Medium`** | 是（先写脚本/单测，待 9A 释放 VM 后在瞬时克隆对比实测） | 裁剪 UTM 无用虚拟外设（冗余 `usb-redir`/空 CDROM 等）并固化原生渲染配置规范；升级 4C 优化器至 v2（深度精简非必要 UWP/Edge 后台/计划任务/视觉特效，严格白名单保护安全链与 ACE + 一键回滚），量化对比 RSS/CPU/冷启并全绿单测 | `Whisky/Modules/guest-optimizer/`<br>`Whisky/Modules/guest-golden/`<br>`graphics-lab/golden_guest_*`<br>`graphics-lab/test_golden_guest_*`<br>`handoff/phase-9/evidence/p9-b/`（新建） |

---

## 3. 全阶段硬性红线

1. **零越权、零破坏安全链**：严禁修改任何游戏/ACE 文件、严禁关闭 Secure Boot / 开启 Test Signing、严禁替换 Windows 签名系统文件、严禁隐藏虚拟化或伪造硬件、严禁自动化登录或绕过人机验证码。
2. **保护只读黄金母盘与冷备 `vm-a`**：所有真机实验必须在 `golden-win11-arm64-v1` 派生的瞬时克隆上执行，9A 优先使用 VM，释放后再由 9B 跑实测对比；结束必须彻底销毁瞬时克隆并校验 `golden_zero_drift: true` 与 `primary_zero_drift: true`。
3. **Strict SwiftLint 0 违规 + 仓库零大文件 + 脱敏署名 `@DNPMBHC`** + 严禁 `git commit / push / reset`。
