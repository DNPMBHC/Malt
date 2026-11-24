# Phase 6 多窗口整合总控协议：大整合与黄金基线固化（Consolidation Sprint）

日期：2026-11-24  
署名：`@DNPMBHC`  
前置全绿基线（Phase 5 收尾）：
- SwiftPM **252 项（242 通过 / 10 显式跳过 / 0 失败）**；Strict SwiftLint **0 违规**；Strict `swift-format` **6/6 通过**；
- `graphics-lab` **225 项单测 OK**；`guest-optimizer` **10 项单测 OK**；防外挂静态安全门禁（130 源码 + 6 反例自检）通过；`phase2_evidence.py` `3/3` 全满贯；
- Phase 5 核心实证结论：
  1. **原生 ARM64 ACE 已真实加载**：窗口 5A 在 `Win11 24H2 ARM64 + WHQL viogpu3d + Secure Boot + TPM 2.0` 下实测抓到两份原生 `0xaa64` WHQL 签名 ACE 内核驱动（`v0.6.6.6` 与 `v21.0.2506.56`）真实进入 `SCM Running` 与内核映像加载，启动器无反作弊弹窗拒绝，主游戏进程已拉起并加载 `neptune_umd` 但在当前状态下持续黑屏；
  2. **高 Draw 压力新认知**：16,384 Draw 五路实测表明 `Wine D3DMetal`（`372.8 FPS`）、`DXVK+MoltenVK`（`370.3 FPS`）、`DXMT`（`339.5 FPS`）明显快于 `DXVK+KosmicKrisp`（`115.9 FPS`）与 `QEMU WHQL viogpu3d`（`72.7 FPS`）；
  3. **方案 B 理性边界**：5B 已证 macOS 27 原生 `VZCustomVirtioDevice` + `IOSurface` 零拷贝在 EFI Guest 上可跑通，但当前公共 SDK 缺少原生 vTPM API，短期无法替代 QEMU/swtpm 支撑 Windows 11 + ACE。

---

## 1. Phase 6 核心目标：先整合、锁基线，再做下一阶段真实游戏点亮实测

为了彻底终结“每次开虚拟机都要临时装驱动、跑优化、版本和性能不统一”的漂移问题，**本阶段暂不直接跑新的无畏契约点亮实验（推至 Phase 7）**，集中 2 个零冲突并行窗口完成全栈整合：

1. **窗口 6A（Guest 黄金基线固化）**：保留原始裸 `vm-a` 冷备永不动，构建一份**不可变、版本锁死、开箱即用**的 **`golden-win11-arm64-v1`** 黄金镜像（预装 WHQL `viogpu3d` + 预跑 4C 极简优化器 + 锁定 QEMU/swtpm/Secure Boot 参数 + `golden-guest-manifest.json` 不可变指纹），并交付一键 1 秒 APFS Copy-on-Write 克隆与自动销毁校验工具；
2. **窗口 6B（宿主机统一单 App 收口）**：合并 5C 最终封版 `GuestSurface` 稳定接口、4C 极简优化器入口、5A ACE 30 秒巡检能力与 5D 发行流水线；按 5A 16,384 Draw 实测调优 Wine 默认策略；重新产出全集成版 Release + Hardened Runtime `.app` → `.dmg`，通过四路产物一致性门禁与自动重启闭环。

---

## 2. 双窗口分工与严格文件写入锁（零冲突红线）

| 窗口 | 任务文档 | 优先级 | 依赖 VM | 核心职责 | 独占可写路径（严格互斥） |
| --- | --- | :---: | :---: | --- | --- |
| **窗口 6A** | `window-6a-golden-guest-image.md` | **P0** | 是（待 5C 释放租约后执行） | 构建不可变 **`golden-win11-arm64-v1`** 黄金镜像（WHQL `viogpu3d` + 4C 极简优化 + 锁定 QEMU/swtpm/Secure Boot + 清理 Update 缓存）；交付 `golden-guest-manifest.json` 与一键克隆/核验/销毁脚本 | `Whisky/Modules/guest-golden/`（新建）<br>`graphics-lab/golden_guest_*`（新建）<br>`graphics-lab/test_golden_guest_*`（新建）<br>`handoff/phase-6/evidence/p6-a/` |
| **窗口 6B** | `window-6b-unified-app-and-routing.md` | **P0** | 否（全程宿主机，可立即启动） | 合并 5C 最终封版稳定代码与 5D 发行流水线；依据 5A 16,384 Draw 实测调优默认图形路由（DX11→`DXMT`、DX12→`D3DMetal`、DXVK→默认 `MoltenVK` + `KosmicKrisp` 可选增强）；接入黄金镜像 manifest 读取校验；重打统一集成版 `.app`/`.dmg` 并跑通全套门禁与 `dev_restart.sh` | `Whisky/Whisky/`<br>`Whisky/WhiskyCmd/`<br>`Whisky/Whisky.xcodeproj/`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/Whisky/`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/Runtime*.swift`<br>`handoff/task-07/`<br>`handoff/phase-6/evidence/p6-b/` |

---

## 3. 全阶段硬性纪律

1. **保护原始冷备 `vm-a` 与新建 `golden-win11-arm64-v1`**：原始裸 `vm-a` 严禁直接修改；`golden-win11-arm64-v1` 验收封存后即视为**只读黄金母盘**，后续一切 Phase 7 实测只能基于其 APFS Copy-on-Write 瞬时克隆运行。
2. **Strict SwiftLint 0 违规 + 防外挂安全红线**：所有 `Whisky/` 下改动必须 0 Lint 违规、通过 `swift test`、`format_check.py` 与 `audit_anticheat_hardening.py --self-test`，绝不引入新 Lint 豁免或仓库内 `>5 MiB` 缓存。
3. **Step-by-Step 与自动重启闭环**：先输出中文 `## 思考与分析`、`## 实施计划`、`## 任务清单`，待用户批准再动手；修改 App/CLI 必走 `./handoff/task-07/dev_restart.sh` 自动重建重启验证。
4. **脱敏与 Git 保护**：严格使用中性占位符（`my-project`、`vm-a`、`golden-win11-arm64-v1`、`target-cn`、`<workspace>`、`<EXTERNAL_VOLUME>`），署名 `@DNPMBHC`；严禁执行 `git commit / push / reset` 与修改全局 Git 配置。
