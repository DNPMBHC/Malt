# Phase 10A 窗口执行报告：游戏内光标排查、DXMT 极简克隆实测与虚拟机完善交接

- 窗口角色：Phase 10 窗口 10A
- 署名：`@DNPMBHC`
- 母盘绑定：`golden-win11-arm64-v1`（`golden-guest-manifest.json` SHA-256 `1988c3217b4c97d53818ac72831360715bf0438543288cc1cb4001a9f00fa846`）

---

## 1. 任务书完成情况与诚实边界

| 任务项 | 状态 | 实测结论与诚实边界 |
| --- | --- | --- |
| **10A-1：系统性排查游戏内光标不可见并交接 10B** | **已完成** | 通过 `golden_guest_manager.py spawn-ephemeral --trim-hardware --dx-driver DXMT --fps-limit 120` 派生极简 `dxmt-native` 克隆并应用优化器 v2（`MouseTrails=0`）；完成输入栈全链路审计与试验 1（Guest 精准禁用 `QEMU USB Tablet` 仅留纯 `QEMU USB Mouse` + Capture Mouse）、试验 2（关闭指针阴影与加速、核实无 `spice-vdagent`、`GetCursorInfo()` 实证 `CURSOR_SHOWING (640,360)`）；精准定位根因至宿主机 `CocoaSpice / CSMetalRenderer` 硬件光标合成与 QEMU 侧 `usb-tablet` 移除需求，并已将含 5 项虚拟机缺陷（光标、无声、中文语言/输入法、免重装持久化、Windows Update 偷跑与页面文件不足）的诊断文档落盘至 `handoff/phase-10/evidence/p10-a/cursor-diagnosis-for-10b.md`。 |
| **10A-2：大厅与靶场 3–5 分钟压测 + `ACE-GAME.sys (1275)` 终局实证** | **受 P0 光标缺陷阻塞，已完成前大厅运行态采样并如实暂停** | `target-cn`（`VALORANT-Win64-Shipping` PID `1088`）在 `dxmt-native` + `--trim-hardware` + 优化器 v2 下零冻结运行，完成 32.77s 只读遥测（UE4 日志帧号稳定推进、宿主机 `QEMURenderServer` CPU 均值 `12.6%`、QEMU Worker CPU 均值 `196.95%`、总 RSS 均值 `1809.56 MiB`、`ACE-CORE10405/20405` 持续 `Running`）。因游戏内光标不可见阻塞首次交互且用户决策优先基于本轮实测数据完善虚拟机，本轮**未进入主大厅与靶场**；大厅/靶场 3–5 分钟真实 FPS、开枪跟手性与 `ACE-GAME.sys (1275)` 靶场踢线判定如实标为未验证，留待虚拟机光标与基础体验修复后执行。 |
| **10A-3：单测与零漂移清理** | **全部通过** | 新增 `graphics-lab/p10_valorant_analyzer.py`、`p10_valorant_session.py`、`test_p10_valorant_analyzer.py`；全量 `(cd graphics-lab && python3 -B -m unittest discover -v)` **254/254 OK**；`audit_anticheat_hardening.py --self-test` **passed (6/6)**；临时克隆彻底销毁、UTM 沙盒偏好还原、黄金母盘与 `vm-a` 全盘 SHA-256 均 `zero_drift = true`。 |

---

## 2. 证据清单与 SHA-256 绑定

| 交付文件 | SHA-256 | 说明 |
| --- | --- | --- |
| `handoff/module-f/valorant-phase10-runs/real-run-report.json` | `692b24487862698d83bde003a8d25bcc30091008287bb1ea78f1ddf4aa50c1c7` | 脱敏机读总报告（五维口径、光标试验、实时遥测、ACE 判定、VM 缺陷与零漂移） |
| `handoff/phase-10/evidence/p10-a/cursor-diagnosis-for-10b.md` | `e932acf949c893d25e256bc9da61e113675def5d321a1759652adafec65b0954` | 给窗口 10B 的光标根因分析与 5 项虚拟机完善清单 |
| `handoff/phase-10/evidence/p10-a/zero-drift-proof.json` | `fcf8f3d2a79e93bc398cc84ec48093785cc040a03723c033e2134c705cd85572` | 克隆销毁、UTM 偏好恢复、母盘与冷备全盘 SHA-256 零漂移证明 |
| `handoff/phase-10/evidence/p10-a/spawn-preflight.json` | `97ced7608653d04f25de65d554a7dc1898740153097900498675ac764c27aae6` | 克隆启动、DXMT 验证、优化器 v2、输入栈基线审计证据 |
| `handoff/phase-10/evidence/p10-a/monitor-live-dxmt-trimmed.json` | `43e7edb00b497f08ae34608bb187e51421e5c6051723ebdf7ef378b40b2b8a2c` | 32.77s 实时只读遥测与 EventLog 增量（含 `Event 26` 与 Windows Update 捕获） |
| `handoff/phase-10/evidence/p10-a/ace-eventlog-check.json` | `98c1a23bfe88193be4ef890cb60d997ec26eaf95ca77b005e75c3ae1fa5e2067` | 销毁前 `ACE-CORE` 驱动状态与 `System Event 7000` 核查 |
| `handoff/module-f/valorant-phase10-runs/summary.md` | 见正文 | Phase 10A 面向人类的结构化实测总结 |

---

## 3. 合规与文件锁自检声明

- **文件写入锁**：本次仅新建/修改 `graphics-lab/p10_valorant_*`、`graphics-lab/test_p10_valorant_*`、`handoff/module-f/valorant-phase10-runs/`、`handoff/phase-10/evidence/p10-a/`；未触碰 `Whisky/` 源码、`handoff/task-07/`、窗口 10B 独占路径、黄金母盘与冷备 `vm-a`。
- **绝对合规红线**：零修改游戏或 ACE 二进制、零替换签名系统 DLL、零隐藏虚拟化或伪造硬件标识、零 Hook 游戏、零自动化认证/创角/验证码。
- **Git 保护**：未执行 `git commit / push / reset`，未修改任何 Git 配置。
