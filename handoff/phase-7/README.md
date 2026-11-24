# Phase 7 多窗口并行开发总控协议：基于黄金母盘的无畏契约黑屏点亮实战与宿主闭环

日期：2026-11-24  
署名：`@DNPMBHC`  
前置全绿基线（已备份至远端）：
- SwiftPM **256 项（246 通过 / 10 显式跳过 / 0 失败）**；Strict SwiftLint **0 违规**；Strict `swift-format` **6/6 通过**；
- `graphics-lab` **231 项单测 OK**（含 `golden_guest_manager` 6 项）；`guest-optimizer` **10 项 OK**；防外挂静态安全门禁（131 源码 + 6 反例自检）通过；5/5 产物级性能一致性门禁全绿；
- 黄金母盘就位：`golden-win11-arm64-v1` 已封存只读（WHQL `viogpu3d v100.6.101.58000` + 4C 极简优化 + Secure Boot + TPM 2.0），`spawn-ephemeral` APFS CoW 克隆仅需 `0.0074 s`。

---

## 1. Phase 7 核心目标

在 Phase 6 彻底消除“环境与驱动版本漂移”后，Phase 7 直接瞄准**无畏契约（`target-cn`）在 WHQL 3D + 原生 ARM64 ACE 已加载后的黑屏临门一脚**：

1. **窗口 7A（🔴 高难度 — 推荐 `Neon Medium`）**：基于 `golden-win11-arm64-v1` 一秒瞬时克隆，只读抓取游戏 UE4/DXGI/D3D11 真实运行日志定位黑屏根因，并实测标准 **`DXVK → WHQL vulkan_virtio_arm64.dll (Venus) → KosmicKrisp`** 能否绕开 `neptune_umd` 黑屏缺陷、真正点亮大厅与训练场；
2. **窗口 7B（🟡 中等难度 — 推荐 `Hydrogen Medium`）**：宿主机侧全程并行，打通“一键检验 `golden-win11-arm64-v1` + 30 秒 ACE 驱动巡检 + 无桌面壳配置入口”，吸收 7A 输出的新兼容/诊断字段，维持 Release `.app` → `.dmg` 与全套门禁 100% 全绿。

---

## 2. 双窗口分工、难度评级与严格文件写入锁

| 窗口 | 任务文档 | 难度与建议模型 | 依赖 VM | 核心职责 | 独占可写路径（严格互斥） |
| --- | --- | :---: | :---: | --- | --- |
| **窗口 7A** | `window-7a-valorant-blackscreen-and-venus.md` | **🔴 高难度**<br>推荐 **`Neon Medium`**（仅卡死再升 High） | 是（仅用 `spawn-ephemeral` 瞬时克隆） | 抓取只读 UE4/DXGI/D3D11 日志定位 `neptune_umd` 黑屏根因；实测 `DXVK → WHQL vulkan_virtio (Venus)` 替代路径与 `AdapterRAM`/着色器影响；若点亮大厅/训练场，实测真实 FPS 与稳定性，并向 7B 输出 `interface-proposal.md` | `handoff/module-f/valorant-phase7-runs/`（新建）<br>`graphics-lab/p7_valorant_*`（新建）<br>`graphics-lab/test_p7_valorant_*`（新建）<br>`handoff/phase-7/evidence/p7-a/`（新建） |
| **窗口 7B** | `window-7b-shell-and-app-readiness.md` | **🟡 中等难度**<br>推荐 **`Hydrogen Medium`** | 否（全程宿主机，可立即启动） | 在 `Whisky` / `WhiskyCmd` 集成 6A 黄金镜像巡检 & 5A 30 秒 ACE 架构巡检只读入口；按 7A `interface-proposal.md` 收口兼容/诊断展示；重打 Release `.app`/`.dmg` 并跑通全套门禁与 `dev_restart.sh` | `Whisky/Whisky/`<br>`Whisky/WhiskyCmd/`<br>`Whisky/Whisky.xcodeproj/`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/Runtime*.swift`<br>`handoff/task-07/`<br>`handoff/phase-7/evidence/p7-b/`（新建） |

---

## 3. 绝对合规与安全红线

1. **严禁修改任何反作弊或游戏二进制**：严禁 Patch/Hook ACE 驱动或游戏可执行文件、严禁绕过登录与 CAPTCHA 人机验证（遇账号登录/验证码必须暂停请用户在可见界面亲自完成）、严禁隐藏虚拟化或伪造硬件特征；若采用 `DXVK → vulkan_virtio` 替代用户态图形后端，仅限标准合法渲染链路对比且如实记录反作弊系统反应。
2. **保护只读母盘与冷备 `vm-a`**：7A 必须通过 `golden_guest_manager.py spawn-ephemeral` 派生一次性克隆运行，结束后必须 `destroy-ephemeral` 并校验 `golden_zero_drift: true` & `primary_zero_drift: true`。
3. **Strict SwiftLint 0 违规 + 仓库零大文件 + 自动重启闭环 + 脱敏署名 `@DNPMBHC`** + 严禁 `git commit / push / reset`。
