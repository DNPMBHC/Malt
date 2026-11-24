# Phase 8 多窗口并行开发总控协议：无畏契约免 Resize 进训练场/对局实测与输入可见性破局

日期：2026-11-24  
署名：`@DNPMBHC`  
前置全绿基线（Phase 7 收官）：
- SwiftPM **257 项（247 通过 / 10 显式跳过 / 0 失败）**；Strict SwiftLint **0 违规**；Strict `swift-format` **6/6 通过**；
- `graphics-lab` **236 项单测 OK**（含 7A 5 项分析单测）；`guest-optimizer` **10 项 OK**；防外挂静态审计（132 源码 + 6 反例自检）通过；
- Phase 7A 关键突破：在 `golden-win11-arm64-v1` 瞬时克隆上已证实非 `AdapterRAM=0` 拒载（UE4 读到 `8192 MB` 专用显存），游戏已点亮并进入全屏界面与窗口化创角输入名字界面；卡死根因锁定为 `neptune_umd` (`v100.6.101.58000`) 在 SwapChain Resize 时渲染线程死锁（及窗口模式鼠标不可见），同时捕获 `ACE-CORE10405/20405` (`0xaa64`) `Running` 与 `ACE-GAME.sys` (`0x8664`) `1275` 拦截。

---

## 1. Phase 8 核心目标

在不修改任何游戏/反作弊二进制、不绕过完整性校验的前提下，验证 Phase 7A 定位出的纯合法缓解路径能否让用户顺利完成创角、进入**无畏契约大厅与靶场/训练场**，并拿到真实的运行性能与 `ACE-GAME.sys` 准入结论：

1. **窗口 8A（🔴 高难度 — 推荐 `Neon Medium`）**：基于 `golden-win11-arm64-v1` `spawn-ephemeral` 瞬时克隆，锁死静态 `1280×720` 分辨率（禁用 UTM `DynamicResolution` + 禁用运行期窗口拖拽，彻底规避 `neptune_umd` Resize 死锁），解决 UTM 下 UE4 游戏指针不可见/鼠标捕获问题，完成创角并尝试进入**大厅与训练场**，实测连续 FPS、帧时间与 `ACE-GAME.sys (1275)` 实际准入反应；
2. **窗口 8B（🟡 中等难度 — 推荐 `Hydrogen Medium`）**：宿主机侧同步维护 `Whisky` / `WhiskyCmd` 诊断输出、三语引导与发行 `.app` → `.dmg` 全门禁闭环，并在 8A 出具 `interface-proposal.md` 后做最小增量集成。

---

## 2. 双窗口分工、难度评级与严格文件写入锁

| 窗口 | 任务文档 | 难度与建议模型 | 依赖 VM | 核心职责 | 独占可写路径（严格互斥） |
| --- | --- | :---: | :---: | --- | --- |
| **窗口 8A** | `window-8a-valorant-training-range-and-pointer.md` | **🔴 高难度**<br>推荐 **`Neon Medium`** | 是（仅用 `spawn-ephemeral` 瞬时克隆） | 锁定静态 `1280×720` 防 `neptune_umd` Resize 死锁；排查并解决标准 UTM/Windows 输入指针不可见问题；实测进入大厅/训练场/对局状态、真实 FPS 与 `ACE-GAME.sys (1275)` 中途反应；输出 `interface-proposal.md` 并销毁克隆校验零漂移 | `handoff/module-f/valorant-phase8-runs/`（新建）<br>`graphics-lab/p8_valorant_*`（新建）<br>`graphics-lab/test_p8_valorant_*`（新建）<br>`handoff/phase-8/evidence/p8-a/`（新建） |
| **窗口 8B** | `window-8b-app-diagnostics-and-release.md` | **🟡 中等难度**<br>推荐 **`Hydrogen Medium`** | 否（全程宿主机，可立即启动） | 吸收 8A 最新 `interface-proposal.md` 实证状态与显示/指针排查建议；更新 `WhiskyCmd` 与设置页只读诊断展示；重打 Release `.app`/`.dmg` 并通过 `dev_restart.sh` 与全套静态/单测门禁 | `Whisky/Whisky/`<br>`Whisky/WhiskyCmd/`<br>`Whisky/Whisky.xcodeproj/`<br>`Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/`<br>`Whisky/WhiskyKit/Tests/WhiskyKitTests/Runtime*.swift`<br>`handoff/task-07/`<br>`handoff/phase-8/evidence/p8-b/`（新建） |

---

## 3. 全阶段硬性红线

1. **严禁越权修改或绕过反作弊**：严禁修改任何游戏/ACE 文件、严禁替换受签名 `System32` DLL、严禁虚拟化隐藏或硬件伪造、严禁自动化登录或绕过人机校验（遇账号登录/创角输入/CAPTCHA 必须请用户在可见界面亲自完成）。
2. **保护只读黄金母盘与冷备 `vm-a`**：8A 仅允许使用 `golden_guest_manager.py spawn-ephemeral` 派生克隆，结束后必须 `destroy-ephemeral` 并校验 `golden_zero_drift: true` 与 `primary_zero_drift: true`。
3. **Strict SwiftLint 0 违规 + 零大文件 + 自动重启闭环 + 脱敏署名 `@DNPMBHC`** + 严禁 `git commit / push / reset`。
