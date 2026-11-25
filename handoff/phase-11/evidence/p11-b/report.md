# Phase 11 窗口 11B 终局交付报告：定制 UTM 实机编译、原生全屏与渲染优化、光标与靶场终局闭环

- **署名**：`@DNPMBHC`
- **窗口角色**：Phase 11 — 窗口 11B
- **核心交付物**：
  - 7 份独立且堆叠零冲突补丁：`Whisky/Modules/utm-custom/patches/*.patch`
  - 定制架构说明：`Whisky/Modules/utm-custom/ARCHITECTURE.md`
  - 仓库外完整编译脚本：`Whisky/Modules/utm-custom/scripts/build_custom_utm.sh`
  - 合规审计器与单测：`graphics-lab/utm_custom_patch_verify.py`、`graphics-lab/test_utm_custom_patch_verify.py`
  - 实机验证工具与单测：`graphics-lab/p11_valorant_fullscreen_session.py`、`graphics-lab/test_p11_valorant_fullscreen_session.py`
  - 审计/构建/零漂移证据：`handoff/phase-11/evidence/p11-b/{patch-audit.json,build-verification.json,zero-drift-proof.json}`
  - 长期保存的 25.3 分钟真机深度分析基线：`handoff/module-f/valorant-phase11-runs/{real-run-report.json,perf-deep-dive-dataset.json,summary.md}`

---

## 1. 任务 11B-1：定制 UTM 补丁集与合规审计（7/7 全绿）

在 `Whisky/Modules/utm-custom/patches/` 完善并交付全部 7 份独立补丁（5 份 UTM v5.0.9 + 2 份 CocoaSpice）：

| 补丁文件 | 目标模块 | 核心改造 | 合规与 `git apply` |
| :--- | :--- | :--- | :---: |
| `01-default-dxmt-backend.patch` | UTM | 默认锁定 `QEMUDirectXDriver = 2`（`dxmt-native`），支持 `--dxmt-native` / `UTM_DIRECTX_BACKEND` 覆盖 | PASS |
| `02-cocoaspice-cursor-overlay.patch` | CocoaSpice | 修复 `CSDisplay.setDevice:` 线程竞态、`CSCursor` 纹理延迟重建、`SPICE_MOUSE_MODE_SERVER` 坐标不抹为 `(-1,-1)`、新增 `applyRelativeFallback(delta:)` 兜底与 `UTM_KEEP_CURSOR_VISIBLE_ON_INHIBIT` | PASS |
| `02-cursor-and-fps-capture.patch` | UTM | 失焦自动释放鼠标、跳过重复捕获弹窗、纯相对模式下非捕获位移差值转发、`Cmd+Option+G` 随时释放、`Cmd+Tab` 释放且 Game Shell 不禁用系统全局热键 | PASS |
| `03-clean-fullscreen-game-shell.patch` | UTM | `--game-shell-vm <UUID-or-path>` 隐藏主窗、原生全屏自动隐藏 MenuBar/Dock、修复全屏缩放黑边与 1:1/Retina 吸附；**实测后二次打磨**：保留 `window.toolbar` 对象仅设 `isVisible = false`（不销毁 USB 共享入口）、进全屏与点击画面自动捕获直连、`gameShellHasStarted` 收紧为 `state == .started` | PASS |
| `04-pure-relative-mouse-option.patch` | UTM | 三路统一开关（`config.plist` `Input.PureRelativeMouse=true` 对接 11A、`--pure-relative-mouse`、`UTM_PURE_RELATIVE_MOUSE=1`），不注入 `-device usb-tablet` | PASS |
| `05-render-thread-qos-and-dxmt-cache.patch` | UTM | 持久化 `DXMT_SHADER_CACHE=1` + `DXMT_SHADER_CACHE_PATH` 绑定并透传沙盒资源、`QEMUHelper` 提升至 `NSQualityOfServiceUserInteractive`、`CAMetalLayer` 三重缓冲配置 | PASS |
| `05-cocoaspice-frame-backpressure.patch` | CocoaSpice | `CSMetalRenderer` 三重缓冲非阻塞 `dispatch_semaphore_t(3)` 帧队列背压控制，防止高帧率下 `MTLCommandBuffer` 堆积 | PASS |

- **合规审计结果**（见 `patch-audit.json`）：7/7 补丁全部通过 12 文件严格白名单校验、5 类反作弊/硬件伪装黑名单零命中、5 UTM + 2 CocoaSpice 独立及全栈堆叠 `git apply --check` 零冲突。

---

## 2. 任务 11B-2：仓库外路径 A 实机编译 `UTM-Custom.app`

升级 `Whisky/Modules/utm-custom/scripts/build_custom_utm.sh`，采用**路径 A** 在仓库外（`${TMPDIR}/utm-custom-src` 与 `${TMPDIR}/utm-custom-build/UTM-Custom.app`）完成真实 `arm64 Release` 完整主 App 编译与 ad-hoc 签名：

1. **只读复用与最小外部依赖装配**：只读软链 `/Applications/UTM.app/Contents/Frameworks` 等基础库，精确编译 UTM 5.0.9 同版本 GStreamer `1.19.1` 静态插件（含 `libgstosxaudio.a`，保障真机音频就绪），使用 `brew fetch` 仅解压提取纯 C 头文件（零修改用户 `/opt/homebrew`），宿主机无 `Metal Toolchain` 时自动复用未修改的官方 `default.metallib`；
2. **签名与原件零损伤**：按官方 `package_mac.sh unsigned` 顺序对全部 Frameworks、嵌套 `QEMULauncher`/`QEMURenderServer`/`QEMUHelper`、`utmctl` 与 `UTM` 完成 ad-hoc + entitlements 签名；
3. **验证结果**（见 `build-verification.json`）：
   - `outside_repository = true`，`codesign --verify --deep --strict` 全绿（`codesign_deep_verify_ok = true`）；
   - Mach-O 二进制 **8/8 补丁特征符号全部命中**（`all_patch_markers_present = true`）；
   - `/Applications/UTM.app` 原件 `codesign --verify --deep --strict` 校验通过（`original_utm_untouched = true`）。

---

## 3. 任务 11B-3：真机光标/全屏验证 + `target-cn` 25.3 分钟终局实测

### 3.1 轻量光标、全屏与硬件拓扑实证
在派生瞬时克隆 `ephemeral-p11b-valorant.utm`（`8192 MiB RAM / 6 vCPU / 无 Balloon / 保留 intel-hda 声卡 / PureRelativeMouse=true / Emulated VLAN NAT / APFS CoW 隔离 35.9 GB 游戏数据盘`）上使用 `UTM-Custom.app --dxmt-native --pure-relative-mouse --game-shell-vm <UUID>` 验证：
- **宿主机 QEMU/渲染层实证**：`input_devices = ["usb-mouse,bus=usb-bus.0", "usb-kbd,bus=usb-bus.0"]`（`has_usb_tablet = false`、`pure_relative_mouse_only = true`）、`has_audio_device = true`、`QEMURenderServer` 确认加载 `dxmt-native`（6 处实证）、`DXMT_SHADER_CACHE=1` 落盘 `4` 文件共 **`9,284,672` bytes（`8.85 MiB`）**；
- **轻量自定义光标与 Raw Input 探测**：实测 `raw_input_events = 312`、`raw_delta = (135, -45)`、`mouse_moves = 68`，宿主机全屏截图确认无边框原生全屏（`1512×949`）、Windows 桌面光标清晰可见、音频状态 `OK`、中文输入法 `ChsIME` 就绪；
- **用户体验反馈即时闭环**：针对实测中用户反馈外接电竞鼠标直连捕获不便的问题，已将“保留 `window.toolbar` 对象仅设 `isVisible = false` + 进全屏及点击画面自动捕获直连 + `gameShellHasStarted` 收紧为 `.started`”合入 `03-clean-fullscreen-game-shell.patch`，完成重新编译、重签与 `build-verification.json` 复验。

### 3.2 `target-cn` 25.33 分钟实测与反作弊终局结论
详细逐分钟曲线、官方 35,837 帧直方图拆解、39 次 `< 5 FPS` 告警归因与 Phase 12 优化路线图已永久保存至 `handoff/module-f/valorant-phase11-runs/summary.md` 与 `perf-deep-dive-dataset.json`。核心摘要如下：
- **里程碑全通**：`Init` → **`NPEV2` 教学通关（`500.44 s`，`1024×768`，纯实战 P50 `64.86 FPS`，官方 35,837 帧等效均值 `71.61 FPS`，`Avg. Engine Latency 22.62 ms = Work 19.69 + Slack 2.45 + Slop 0.48 ms`）** → **`MainMenuV2` 主大厅（`102.3 FPS`）** → **`RangeV2` 靶场连续实战 `9.01 分钟`（`1920×1200`，纯实战均值 `45.21 FPS` / P50 `49.63 FPS`；热缓存完全预热后第 8 分钟飙升至均值 `55.51 FPS` / P50 `58.44 FPS` / P5 `42.42 FPS` / P1 `25.74 FPS` / `0` 次严重卡顿）** → `ManualQuit` 干净退出，**`0` 崩溃**；
- **瓶颈第一性原理定位**：像素量扩大 `2.93×` 后热缓存 P50 帧率仅降 `9.5%`，且 `QEMURenderServer` CPU 仅占 `33%–45%`、`QEMU worker` 飙至 `587.8%`——**Guest 侧 6 vCPU（Prism 转译 + 游戏主线程）与 ad-hoc 签名被迫使用的 `slirp` NAT** 是下一阶段提帧降卡的绝对首要瓶颈；
- **反作弊与 `1275` 终局判定**：`ACE-CORE10405.sys` & `ACE-CORE20405.sys` 双核驱动 `Running / OK`，`ACEManager_IssueAntiTick` 累计 **`154` 次 HTTP `200` OK**，System EventLog ACE `7000/1275 = 0`，CodeIntegrity 新增错误 `= 0`，判定 **`training_range_3to5m_clean_no_1275_kick`**（实测 `9.01 min` 干净通过；诚实标注 `protected_matchmaking = not_verified`，`vendor_vm_support = unknown`）。

---

## 4. 清理与全盘 SHA-256 零漂移铁证（`zero-drift-proof.json`）

- 瞬时克隆 `ephemeral-p11b-valorant.utm` 已优雅停机（`UTM-Custom.app` Game Shell 自动干净退出）并彻底删除（`ephemeral_deleted = true`）；
- 宿主机无任何 QEMU / UTM 残留进程，`golden_guest_manager.py check-lease` 确认 `ready = true`；
- 全盘 SHA-256 校验确认：
  - 只读黄金母盘 `golden-win11-arm64-v1.utm`：`golden_readonly = true`，`golden_zero_drift = true`（`config_sha256` 与 `bundle_sha256` 与 Phase 11A 基线字节级一致）；
  - 冷备 `vm-a`（`Windows11-ARM64.utm`）：`primary_zero_drift = true`（`config_sha256` 与 `bundle_sha256` 字节级一致）；
  - 外置游戏盘 `valorant-cn-data.qcow2` 通过 APFS CoW 隔离未做任何写入，`/Applications/UTM.app` 原件 `codesign --verify --deep --strict` 完整无损，临时调试偏好键已复原。

---

## 5. 验收门禁实证结果

- `bash Whisky/Modules/utm-custom/scripts/build_custom_utm.sh --check-only`：**PASS**（7/7 补丁合规 + 独立/堆叠 `git apply --check` 全绿）
- `(cd graphics-lab && python3 -B -m unittest discover -v)`：**PASS**
- `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)`：**PASS（0 violations）**
- `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test`：**PASS**
- 仓库安全扫描：零新增 `> 5 MiB` 文件、零外部源码树残留、零隐私信息泄漏、零越界文件修改、零 git commit/push/reset。
