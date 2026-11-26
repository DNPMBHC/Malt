# Phase 12 窗口 12B 任务书：macOS 原生游戏模式、高回报率鼠标合批、键位防误触映射与原生管线渲染提帧

- **窗口角色**：Phase 12 窗口 12B
- **难度评级**：🔴 高难度（建议模型：**`Neon Medium`**）
- **署名**：`@DNPMBHC`
- **前置基线**：`Whisky/Modules/utm-custom/` 已有 7 份合规补丁并实机编出 `UTM-Custom.app`，在 `target-cn` 靶场预热稳态已达 `55.51 FPS`（P50 `58.44 FPS`），但尚未适配 macOS 原生游戏模式、高回报率鼠标防中断风暴、防误触快捷键屏蔽（`Cmd+W/Q/H/M`），且引擎存在 `2.93 ms` 帧同步 `Slack + Slop` 优化空间。

---

## 1. 任务目标

### 任务 12B-1：新增 3 项高价值合规补丁 + 适配 macOS 原生游戏模式
在 `Whisky/Modules/utm-custom/` 完善补丁集、更新 `ARCHITECTURE.md`、`scripts/build_custom_utm.sh` 与 `graphics-lab/utm_custom_patch_verify.py`（及单测）：

1. **macOS 原生游戏模式（Game Mode）自动触发**：
   - 在 `build_custom_utm.sh` 打包 `UTM-Custom.app/Contents/Info.plist`（及对应补丁配置）中正式声明：
     - `LSApplicationCategoryType = public.app-category.games`
     - `LSSupportsGameMode = true`（以及 `GCSupportsGameMode = true` 兼容键）
   - 配合 `--game-shell-vm <UUID>` 原生全屏启动，实现“启动游戏壳 → 自动原生全屏 → 自动激活 macOS 系统游戏模式压制后台任务 → 退出全屏/游戏自动解除”的零感知闭环。

2. **`06-high-polling-mouse-coalescing.patch`（高回报率电竞鼠标无损合批适配）**：
   - 针对 1000Hz / 2000Hz / 4000Hz / 8000Hz 高回报率鼠标，在 `UTM` / `CocoaSpice` 捕获输入层引入可配置的**无损相对位移合批器（Delta Coalescer）**（默认 `1–2 ms` 时间窗，可通过环境变量 `UTM_MOUSE_COALESCE_US` 调优或设为 `0` 关闭）：
     - 在时间窗内将连续微小相对位移 `(dx, dy)` 精确累加合并发送，**保证零像素丢失、零鼠标加速畸变**，同时将 SPICE/QEMU USB HID 中断频率压降 4–8 倍，彻底消除“高速甩枪掉帧”；
     - 保持 `CGAssociateMouseAndMouseCursorPosition(false)` 原始 Raw Delta，且在点击按钮事件到达时立即 flush 累积位移，确保开枪瞬间准星零延迟。

3. **`07-game-shell-key-guard-and-mapping.patch`（macOS ↔ Windows 按键映射 + 自动屏蔽防误触快捷键）**：
   - 在 `--game-shell-vm` 游戏壳全屏激活期间：
     - **自动屏蔽防误触快捷键**：在窗口事件层（`performKeyEquivalent:` / `keyDown:`）拦截并吞掉 **`Cmd+W`（关闭窗口）、`Cmd+Q`（退出应用）、`Cmd+H`（隐藏）、`Cmd+M`（最小化）**，杜绝打游戏时手滑关闭虚拟机；
     - **macOS ↔ Windows 游戏键位映射**：支持可开关的 `Left Cmd` 防误触拦截（`UTM_BLOCK_WIN_KEY=1` 时避免误按弹出 Windows 开始菜单）、`Option` 精准对齐 Windows `Alt`、`F1–F12` 直通游戏；
     - **保留唯一安全逃生热键**：确保 `Cmd+Option+G` 随时释放鼠标、`Cmd+Tab` 切屏自动释放并切回无缝恢复，绝不锁死用户。

4. **低同步延迟 Metal 呈现管线微调（压低 `2.93 ms` `Slack + Slop`）**：
   - 审查并优化 `05-render-thread-qos-and-dxmt-cache.patch` 与 `05-cocoaspice-frame-backpressure.patch`：核查 `CAMetalDisplayLink` / `presentsWithTransaction` / `QEMURendererFPSLimit`（对比 `0` 不限 vs `120`）以及 QEMU/vCPU 线程在 `QEMUHelper` 下的 QoS 继承，尽量缩短提交等待时间并降低 CPU 主线程空转；
   - **协同 12A**：若 12A 落地了去 `slirp` 原生 `vmnet` 网络方案（如 `socket_vmnet`），在 `UTM-Custom` 启动参数侧确保无缝兼容，不冲突。

### 任务 12B-2：仓库外重编 `UTM-Custom.app` 并完成全项功能与真机回归验收
1. 运行升级后的 `build_custom_utm.sh` 在仓库外编出最新 `arm64 Release` `UTM-Custom.app`，通过 `codesign --verify --deep --strict`、补丁特征符号校验与 `Info.plist` 游戏模式键值校验，落盘 `handoff/phase-12/evidence/p12-b/build-verification.json` 与 `patch-audit.json`。
2. **真机功能专项验收**（落盘至 `graphics-lab/p12_gamemode_input_session.py` 及单测）：
   - 验证进入 `--game-shell-vm` 原生全屏后，系统 Game Mode 键生效且后台无干扰；
   - 压测高回报率鼠标事件（模拟 1000Hz–4000Hz 高频相对位移流），验证合批后 **0 像素位移误差** + SPICE 发送包数大幅下降 + 按钮点击立即 flush；
   - 验证游戏壳全屏期按 **`Cmd+W` / `Cmd+Q` / `Cmd+H` / `Cmd+M` 不会关闭或隐藏窗口**，按 `Cmd+Option+G` / `Cmd+Tab` 正常安全释放。
3. **`target-cn` 靶场真机回归对比（吸收 12A 的 `10 GiB` / 优化 vCPU / 原生网络成果，若 12A 已完成则合体测试；否则独立验证 12B 增益）**：
   - 在 `1920×1200` 靶场完成 3–5 分钟实测（涉及登录/验证时暂停请用户手动操作，严禁自动化绕过），与 Phase 11B 基线（热缓存第 8 分钟均值 `55.51 FPS` / P50 `58.44 FPS` / `Slack+Slop 2.93 ms`）做量化对照，并确认 `ACE-CORE10405/20405` 持续 `Running`、`0` 条 `7000/1275` 报错。
4. 清理全部临时克隆，产出 `zero-drift-proof.json` 与 `report.md`。

---

## 2. 独占写入范围（严禁越界）

- 允许写入：
  - `Whisky/Modules/utm-custom/**`
  - `graphics-lab/utm_custom_patch_verify.py`
  - `graphics-lab/test_utm_custom_patch_verify.py`
  - `graphics-lab/p12_gamemode_input_session.py`
  - `graphics-lab/test_p12_gamemode_input_session.py`
  - `handoff/module-f/valorant-phase12-runs/**`
  - `handoff/phase-12/evidence/p12-b/**`
- 严禁触碰：`Whisky/Modules/guest-optimizer/`、`graphics-lab/golden_guest_manager.py`、`Whisky/Whisky/`、`Whisky/WhiskyKit/`、`handoff/task-07/`、`/Applications/UTM.app` 原件、只读母盘与冷备 `vm-a`。

---

## 3. 验收门禁

1. `bash Whisky/Modules/utm-custom/scripts/build_custom_utm.sh --check-only` 全绿（所有补丁合规 + 叠加 `git apply --check` 零冲突）；
2. `(cd graphics-lab && python3 -B -m unittest discover -v)` 全绿；
3. `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)` **0 violations**；
4. `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` 全绿；
5. 零 `> 5 MiB` 新增文件、零隐私路径泄漏、零 git commit/push/reset、母盘与 `vm-a` 全盘 SHA-256 `zero_drift = true`。
