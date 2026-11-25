# Phase 14 总览：`Malt` 品牌统一与 Release `.dmg` 正式打包 + 残余性能深挖与全员合体端到端实测

- 署名：`@DNPMBHC`
- 品牌定名：**`Malt`**（面向用户的 App 显示名、首次引导、统一前端文案与发行安装包统一命名为 **`Malt`** / **`Malt.app`** / **`Malt.dmg`**；底层 Swift Package `WhiskyKit` 标识符保持向后兼容，避免无谓破坏性重构）。
- 前置基线：
  - Phase 13 已达成 9/9 门禁全绿（`WhiskyKit` 265 tests、`graphics-lab` 283 tests、`guest-optimizer` 13 tests、10 份 UTM/CocoaSpice 补丁合规、突发大特效 P1 Low `+54.28%`、热唤醒 `0.347s`、4 入口极简前端通过 `dev_restart.sh` 编译重启验证）。

---

## 本阶段核心目标

1. **终极残余性能深挖与全员合体真机实测（14A）**：
   - 验证 **`XtaCache`（Prism ARM64 转译缓存）+ `DXMT_SHADER_CACHE` 双缓存持久化**对二次启动与团战大特效 CPU 尖峰的真实收益；
   - 压低 Phase 11B 发现的 **`2.93 ms` 帧同步损耗（`Slack + Slop`）**（对比 `QEMURendererFPSLimit = 0` vs `120` 与低延迟队列参数），并评估进一步精简 QEMU 中断源（如对比 `virtio-input` vs `usb-mouse` 中断开销）；
   - 将 Phase 11–13 全部优化（`8 vCPU / 10 GiB / VirtIO-Blk 多队列 / 去 slirp 原生网络 / Game Mode / 高回报率鼠标合批 / 防误触 / 突发优化 / 双缓存持久化`）**全员合体**，完成端到端真机实测与 `1920×1200` 靶场回归对比，冲击 `60+ FPS` 稳态并形成最终性能调研结论。
2. **`Malt` 品牌统一与正式 Release `.dmg` 打包（14B）**：
   - 将全部面向用户的 UI 文案（含 `FirstRunOnboardingView.swift`、侧边栏、标题、窗口名、关于页）统一替换为 **`Malt`**；
   - 更新构建与打包配置，产出启用 **Hardened Runtime** 的正式轻量 Release **`Malt.app`** 与 **`Malt.dmg`**（目标 `< 20 MiB`，不夹带源码或临时构建缓存）；
   - 通过全套自动化门禁、防外挂静态审计、性能平权门禁与 `./handoff/task-07/dev_restart.sh` 自动编译重启验证。

---

## 并行窗口与严格文件写入锁

| 窗口 | 难度与建议模型 | 核心职责 | 独占写入路径 |
| --- | --- | --- | --- |
| **14A** | 🔴 高难度 · **`Neon Medium`** | 残余性能深挖（`XtaCache`+`DXMT` 双缓存、帧同步 `Slack+Slop` 压降、中断源评估）+ **全员合体端到端真机实测与靶场回归对比** | `graphics-lab/p14_full_stack_perf_eval.py`、`graphics-lab/test_p14_full_stack_perf_eval.py`、`handoff/module-f/valorant-phase14-runs/**`、`handoff/phase-14/evidence/p14-a/**` |
| **14B** | 🟡 中等难度 · **`Hydrogen Medium`** | **`Malt` 品牌全面统一**（Unified UI / Display Name / Info.plist / 打包脚本）+ **Hardened Runtime Release `Malt.app` & `Malt.dmg` 正式打包** + 性能平权与 `dev_restart.sh` 验收 | `Whisky/Whisky/Views/Unified/**`、`Whisky/Whisky/Views/ContentView.swift`、`Whisky/Whisky/Info.plist`（或 `project.pbxproj` Display Name）、`handoff/task-07/package_release_dmg.sh`（或新建 `Whisky/scripts/package_malt_dmg.sh`）、`handoff/phase-14/evidence/p14-b/**` |

---

## 绝对不可突破的红线

1. **反作弊与合规红线**：严禁 CPUID/SMBIOS/ACPI/TPM/Hypervisor 伪装、严禁修改游戏/ACE/Windows 驱动、严禁 DWM Hook/进程注入、严禁自动化登录或过验证码；公开面向用户的文案（`Malt` UI / README）不宣传反作弊绕过。
2. **零漂移与仓库纯净**：只读母盘 `golden-win11-arm64-v1`、冷备 `vm-a` 与 `/Applications/UTM.app` 原件零漂移；`Malt.dmg` 成品存放于仓库外或 `Whisky/build/`（不提交 `> 5 MiB` 文件进 git）；零隐私路径泄漏；严禁执行 `git commit / push / reset`。
