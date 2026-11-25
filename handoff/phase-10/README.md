# Phase 10 多窗口并行开发总控协议：攻克光标进无畏契约靶场实战 + 定制 UTM 无桌面原生全屏游戏壳

日期：2026-11-24  
署名：`@DNPMBHC`  
前置全绿基线（Phase 9 收官）：
- SwiftPM **258 项（248 通过 / 10 显式跳过 / 0 失败）**；Strict SwiftLint **0 违规**；Strict `swift-format` **6/6 通过**；
- `graphics-lab` **246 项 OK**；`guest-optimizer` **10 项 OK**；防外挂静态审计（132 源码 + 6 反例自检）通过；
- Phase 9 历史性突破：
  1. 9A 实证 UTM 5.0.9 原生 `QEMUDirectXDriver = 2`（`dxmt-native.framework`）彻底打破 2.6 秒创角死锁，`target-cn` 连续稳定运行 **63 分钟**零冻结、零崩溃、零 ACE 踢线（`ID3D11Query(TIMESTAMP)` 恢复 `1.6213 ms`、`sample` 确证 `dxmt::MTLD3D11ImmediateContext::Commit() → Apple M4 Metal`）；
  2. 9B 实证 UTM 硬件裁剪 + 优化器 v2 再降宿主机总 RSS `-192.92 MiB`、空载 QEMU CPU `-4.14%`、冷启 `-4.106 s`、`d3d11_probe` 提速 `+5.355 FPS` 且一键回滚 100% 一致。

---

## 1. Phase 10 战略授权与架构目标

用户已明确授权**在 100% 合法合规前提下对开源 UTM（`utmapp/UTM` + `CocoaSpice`）进行最小化定制改造**，以彻底打通最后两公里：

1. **窗口 10A（🔴 高难度 · 推荐 `Neon Medium`）**：基于 `golden-win11-arm64-v1` 的 `--trim-hardware --dx-driver DXMT` 瞬时克隆，攻克**游戏内光标不可见**（纯标准输入配置与光标链路排查），完成创角并真正进入**无畏契约主大厅与靶场/训练场**，拿回真实 3D 靶场 FPS、视角跟手性与 `ACE-GAME.sys (1275)` 最终准入实证；
2. **窗口 10B（🟡 中等难度 · 推荐 `Hydrogen Medium`）**：面向开源 `utmapp/UTM` 设计并落地**最小侵入补丁集（`Whisky/Modules/utm-custom/`）**——专注 3 件事：① 修复/增强 `CocoaSpice`/`CSMetalRenderer` 游戏内光标合成与相对鼠标捕获；② 默认锁定 `QEMUDirectXDriver = 2 (dxmt-native)` + 静态分辨率；③ 提供**无管理界面、无工具栏的「纯净原生全屏游戏窗口模式」**（直接复用 UTM 合法的 Metal 帧源与 SPICE HID，零重复造 VMM 轮子！）。

---

## 2. 双窗口分工、难度评级与严格文件写入锁

| 窗口 | 任务文档 | 难度与建议模型 | 依赖 VM | 核心职责 | 独占可写路径（严格互斥） |
| --- | --- | :---: | :---: | --- | --- |
| **窗口 10A** | `window-10a-valorant-cursor-and-training-range.md` | **🔴 高难度**<br>推荐 **`Neon Medium`** | 是（优先独占瞬时克隆） | 排查并解决 UTM/SPICE + `viogpu3d` 下 UE4 游戏内光标不可见；完成创角进入**无畏契约大厅与靶场/训练场**，实测 3–5 分钟真实 3D FPS、P95/P99、视角/射击跟手性与 `ACE-GAME.sys (1275)` 准入表现；输出光标/输入补丁需求给 10B 并销毁克隆校验零漂移 | `handoff/module-f/valorant-phase10-runs/`（新建）<br>`graphics-lab/p10_valorant_*`（新建）<br>`graphics-lab/test_p10_valorant_*`（新建）<br>`handoff/phase-10/evidence/p10-a/`（新建） |
| **窗口 10B** | `window-10b-utm-custom-native-shell.md` | **🟡 中等难度**<br>推荐 **`Hydrogen Medium`** | 否（全程宿主机源码与构建实验，不占 VM） | 审计 `utmapp/UTM`（v5.0.9 基线）与 `CocoaSpice` 源码，在 `Whisky/Modules/utm-custom/` 交付可复现的最小化补丁集（`patches/`）与构建脚本：原生锁定 `dxmt-native`、修复游戏光标合成与相对鼠标捕获、落地无工具栏「纯净原生全屏游戏壳模式」 | `Whisky/Modules/utm-custom/`（新建）<br>`graphics-lab/utm_custom_*`（新建）<br>`graphics-lab/test_utm_custom_*`（新建）<br>`handoff/phase-10/evidence/p10-b/`（新建） |

---

## 3. 绝对合规与仓库卫生红线

1. **魔改 UTM 严守 5 条防外挂安全红线**：
   - **只允许改造 macOS 宿主机侧呈现、输入体验、默认 DXMT 后端与无桌面全屏窗口壳**；
   - **绝对禁止**在 QEMU/UTM 中伪造硬件 ID / 修改 CPUID / 隐藏 Hypervisor / 隐藏虚拟化特征、禁止修改 Windows 内核/签名驱动、禁止修改或 Hook 游戏/ACE 二进制、禁止引入宏注入或自动瞄准原语。
2. **仓库纯净与零大文件**：严禁把整个 `utmapp/UTM` 源码树、`.app` 或 `>5 MiB` 构建缓存放进本仓库（外部源码与构建目录一律放在仓库外临时目录或 `<EXTERNAL_VOLUME>`，本仓库仅保存精简的 `patches/*.patch`、构建/校验脚本与文档）。
3. **Strict SwiftLint 0 违规 + 保护母盘与冷备 `vm-a` + 脱敏署名 `@DNPMBHC`** + 严禁 `git commit / push / reset`。
