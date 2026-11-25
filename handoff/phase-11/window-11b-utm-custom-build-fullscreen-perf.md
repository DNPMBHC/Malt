# Phase 11 窗口 11B 任务书：定制 UTM 实机编译、原生全屏与大场景渲染优化、光标与靶场终局闭环

- **窗口角色**：Phase 11 窗口 11B
- **难度评级**：🔴 高难度（建议模型：**`Neon Medium`**）
- **署名**：`@DNPMBHC`
- **前置基线**：`Whisky/Modules/utm-custom/` 已有 4 份合规补丁（`01-default-dxmt-backend`、`02-cursor-and-fps-capture`、`02-cocoaspice-cursor-overlay`、`03-clean-fullscreen-game-shell`），但尚未包含纯相对鼠标开关与宿主机渲染线程 QoS 优化，也尚未完成仓库外实机可运行 `UTM-Custom.app` 编译与真机光标验证。

---

## 1. 任务目标

### 任务 11B-1：补齐定制 UTM 补丁集（纯相对鼠标 + 原生全屏体验打磨 + 宿主机渲染/CPU 性能优化）
在 `Whisky/Modules/utm-custom/patches/` 完善并新增补丁，同时更新 `ARCHITECTURE.md`、`graphics-lab/utm_custom_patch_verify.py` 及单测：
1. **`04-pure-relative-mouse-option.patch`（解决 10A 定位的 QEMU `usb-tablet` 根因）**：
   - 在 UTM 的 QEMU 参数构造器中增加可选开关（例如环境变量 `UTM_PURE_RELATIVE_MOUSE=1` 或启动参数 `--pure-relative-mouse`），开启时不注入 `-device usb-tablet`，仅保留 `-device usb-mouse` + `-device usb-kbd`，消除 SPICE `CLIENT/SERVER` 指针模式冲突；
   - 同步审查 `02-cocoaspice-cursor-overlay.patch`：确认 `CSMetalRenderer` 在 `Capture Mouse` 模式下能正确渲染 Guest `SPICE CursorChannel` / `virtio-gpu` 光标位图（而不是仅改 `isVisible` 却没有光标纹理或位置更新）。
2. **完善 `03-clean-fullscreen-game-shell.patch`（打造无感原生全屏游戏体验）**：
   - 启动 `--game-shell-vm <UUID>` 后自动隐藏主管理窗、隐藏窗口标题栏与工具栏、无缝进入 macOS 原生全屏并抑制顶部菜单栏误触（`NSApplication.PresentationOptions` 自动隐藏 MenuBar/Dock）；
   - 自动将 Display 缩放模式对齐到原生 1:1 / Retina 清晰渲染（避免拉伸模糊或四周黑边）；
   - 失焦 / `Cmd+Tab` 切回桌面自动安全释放鼠标（`releaseMouse()`），重新切回全屏窗口点击后平滑恢复捕获且不重复弹出警告框；保留 `Cmd+Option+G` 随时安全释放光标；VM 关机自动干净退出。
3. **`05-render-thread-qos-and-dxmt-cache.patch`（大场景宿主机 CPU 与渲染吞吐优化）**：
   - 在合法的宿主机显示/渲染层为 `QEMURenderServer` / Metal 渲染线程配置 `.userInteractive` QoS、启用持久化 `DXMT_SHADER_CACHE=1` 路径绑定（避免每次重启重复编译着色器导致大场景卡顿），并验证高帧率下的帧队列背压控制（减少无效 CPU 空转与内存膨胀）。
   - **绝对红线**：所有补丁严禁触碰 CPUID/SMBIOS/ACPI/TPM/Hypervisor 标识或 Windows 驱动/反作弊逻辑，`utm_custom_patch_verify.py` 白名单与 5 类黑名单审计必须 100% 通过。

### 任务 11B-2：在仓库外实机编译可运行的 `UTM-Custom.app`
升级 `Whisky/Modules/utm-custom/scripts/build_custom_utm.sh` 并在仓库外目录（`${TMPDIR}/utm-custom-src` 或 `<EXTERNAL_VOLUME>/utm-custom-build`）编出**真实可运行**的定制 `UTM-Custom.app`：
- 允许的两种合规构建路径（优先简洁稳定）：
  - **路径 A**：拉取 UTM 5.0.9 官方发布的 `Sysroot-macOS` 预编译依赖包（或复用本机 `/Applications/UTM.app/Contents/Frameworks` 中已存在的 QEMU/GLib/Spice/dxmt-native 等二进制 Framework），仅对打了补丁的 `CocoaSpice` 与 `UTM` Swift/ObjC 目标执行 `xcodebuild` + ad-hoc 签名；
  - **路径 B**：若完整主 App 链接受外部依赖阻碍，可优先独立编译打了补丁的 `CocoaSpice` Framework 并在隔离副本 `/tmp/UTM-Custom.app`（绝不修改 `/Applications/UTM.app` 原件！）中完成验证，同时在报告中诚实记录构建链路与签名校验结果。
- **严禁**将 `UTM-Custom.app`、源码树或任何 `> 5 MiB` 构建产物写入本仓库。

### 任务 11B-3：真机光标恢复验证 + 原生全屏体验验收 + `target-cn` 大厅/靶场终局实测
1. **先用轻量 DX11 光标验证程序**在 `UTM-Custom.app`（`--dxmt-native --pure-relative-mouse --game-shell-vm <UUID>`）中验证：
   - 非捕获与 `Capture Mouse` 捕获双模式下光标 **100% 可见、坐标跟手、无重影/无卡死**；
   - 原生无边框全屏无工具栏、`Cmd+Tab` 切屏释放鼠标 & 切回恢复正常、声音输出正常（若 11A 声卡配置尚未合并，可在临时克隆手动保留 `intel-hda` 验证）。
2. **真机冲刺 `target-cn` 创角 → 主大厅 → 靶场（3–5 分钟）**：
   - 如需登录/创角/验证码，暂停并明确请用户手动完成（严禁自动化绕过）；
   - 成功进入大厅与靶场后，完成 3–5 分钟只读遥测采样：
     - 真实帧率（均值 / P50 / P1 Low）、帧时间、宿主机 QEMU/RenderServer CPU% 与总 RSS；
     - 靶场开枪/转身 FPS 相对鼠标跟手性体验；
     - **`ACE-GAME.sys (1275)` 终局判定**：如实记录是否弹出反作弊报错/踢线、System EventLog `7000/1275` 状态与完整五维状态（严禁编造或粉饰）。
3. 清理全部临时克隆并恢复环境，产出 `zero-drift-proof.json`（确认母盘与 `vm-a` 零漂移）。

---

## 2. 独占写入范围（严禁越界）

- 允许写入：
  - `Whisky/Modules/utm-custom/**`
  - `graphics-lab/utm_custom_patch_verify.py`
  - `graphics-lab/test_utm_custom_patch_verify.py`
  - `graphics-lab/p11_valorant_fullscreen_session.py`
  - `graphics-lab/test_p11_valorant_fullscreen_session.py`
  - `handoff/module-f/valorant-phase11-runs/**`
  - `handoff/phase-11/evidence/p11-b/**`
- 严禁触碰：`Whisky/Modules/guest-optimizer/`、`graphics-lab/golden_guest_manager.py`、`Whisky/Whisky/`、`Whisky/WhiskyKit/`、`handoff/task-07/`、`/Applications/UTM.app` 原件、只读黄金母盘与冷备 `vm-a`。

---

## 3. 验收门禁与交付物

1. 更新后的 `Whisky/Modules/utm-custom/patches/*.patch`、`ARCHITECTURE.md`、`scripts/build_custom_utm.sh`
2. `handoff/phase-11/evidence/p11-b/patch-audit.json` & `build-verification.json`
3. `handoff/module-f/valorant-phase11-runs/real-run-report.json` & `summary.md`
4. `handoff/phase-11/evidence/p11-b/zero-drift-proof.json` & `report.md`
5. 必须全绿：
   - `bash Whisky/Modules/utm-custom/scripts/build_custom_utm.sh --check-only`
   - `(cd graphics-lab && python3 -B -m unittest discover -v)`
   - `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)`（0 violations）
   - `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test`
   - 零 `> 5 MiB` 新增文件、零隐私路径泄漏、零 git 操作。
