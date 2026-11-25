# Phase 10A 实测总结：`target-cn` 极简 DXMT 瞬时克隆光标排查、运行态遥测与虚拟机缺陷清单

- 署名：`@DNPMBHC`
- 关联报告：`handoff/module-f/valorant-phase10-runs/real-run-report.json`（SHA-256 `692b24487862698d83bde003a8d25bcc30091008287bb1ea78f1ddf4aa50c1c7`）
- 关联交接：`handoff/phase-10/evidence/p10-a/cursor-diagnosis-for-10b.md`（SHA-256 `e932acf949c893d25e256bc9da61e113675def5d321a1759652adafec65b0954`）
- 零漂移证明：`handoff/phase-10/evidence/p10-a/zero-drift-proof.json`（SHA-256 `fcf8f3d2a79e93bc398cc84ec48093785cc040a03723c033e2134c705cd85572`）

---

## 1. 五维诚实口径结论（Phase 10A）

| 维度 | 状态 | 实证说明 |
| --- | --- | --- |
| **1. 代码实现（implementation）** | `implemented_and_verified` | 新增 `graphics-lab/p10_valorant_analyzer.py`、`p10_valorant_session.py`、`test_p10_valorant_analyzer.py`，完整串通 `--trim-hardware --dx-driver DXMT --fps-limit 120` 派生、优化器 v2 应用、输入栈审计、实时只读采样与全盘 SHA-256 零漂移回收。 |
| **2. 本地门禁（local_gates）** | `passed_254_unit_tests_and_anticheat_audit` | `graphics-lab` 全量 `unittest discover` **254/254 OK**；`audit_anticheat_hardening.py --self-test` **6/6 负向用例通过**；零隐私泄露、零 `>5 MiB` 大文件残留。 |
| **3. 真实 Guest 运行（real_guest_run）** | `executed_live_dxmt_trimmed_cursor_blocked_before_lobby` | `ephemeral-p10a-valorant`（克隆 `0.0046 s`，QGA 就绪 `24.075 s`）加载 `dxmt-native.framework` 与优化器 v2；`target-cn`（`VALORANT-Win64-Shipping` PID `1088`）成功启动并在 32.77s 实测窗口内持续推进帧号（无死锁、无崩溃），但因游戏内光标不可见阻塞首次交互，未进入主大厅与靶场。 |
| **4. 厂商 VM 准入（vendor_vm_support）** | `unknown` | 始终不宣称官方认可或放行虚拟化环境。 |
| **5. 受保护大厅与对局（protected_lobby_and_match）** | `not_reached_blocked_by_in_game_cursor_visibility` | 本轮受游戏内光标不可见阻塞且用户决策优先完善虚拟机基础能力，**未进入主大厅与靶场/训练场，亦未进行队列预检或对局**；因此靶场 3–5 分钟实测 FPS、开枪跟手性与 `ACE-GAME.sys (1275)` 靶场踢线判定均如实保留为未完成，严禁虚报。 |

---

## 2. 本轮实测关键量化数据（全部来自真实运行采样）

### 2.1 派生与渲染后端核验（`spawn-preflight.json`）
- 派生命令：`golden_guest_manager.py spawn-ephemeral --trim-hardware --dx-driver DXMT --fps-limit 120`
- 克隆耗时：`0.0046 s`；QGA 就绪：`24.075 s`；优化器 v2 应用：`true`
- UTM 沙盒偏好：`QEMUDirectXDriver = 2`（`dxmt-native`）、`QEMURendererFPSLimit = 120`（结束已还原）
- 宿主机 `QEMURenderServer`：`active_backend = "dxmt-native"`、`dxmt_native_loaded = true`（`dxmt_evidence_count = 6`）
- Guest 显卡与显示：`Red Hat VirtIO GPU 3D controller (100.6.101.58000)`，静态 `1280×720 @ 120 Hz`（`DynamicResolution = False`、`FullscreenMode = 2`、`MouseTrails = 0`）

### 2.2 游戏实时运行态遥测（`monitor-live-dxmt-trimmed.json`，32.77s 窗口）
- 主进程存活：`VALORANT-Win64-Shipping`（PID `1088`）全程存活（`shipping_alive_all_samples = true`，WS `692.72–719.63 MiB`，线程 `187–188`）
- UE4 日志帧号推进：`119 → 480 → 902`（无冻结；按 `mod 1000` 日志增量口径估算均值 `23.99 FPS`、P50 `23.99`、P95 `26.42`、P99 `26.64`，对应帧时间均值 `42.22 ms`；注：此处为进入大厅前的实时画面下界估值，**非靶场 3D 压测帧率**）
- 宿主机 `QEMURenderServer` CPU：均值 **`12.6%`**（P50 `12.9%`、P95 `13.08%`、Max `13.1%`）
- 宿主机 QEMU Worker CPU：均值 **`196.95%`**（P50 `196.45%`、P95 `204.95%`、Max `205.1%`）
- 宿主机 Hypervisor 总 RSS：均值 **`1809.56 MiB`**（P50 `1789.55 MiB`、P95 `2020.52 MiB`、Max `2051.94 MiB`）

### 2.3 ACE 驱动与 EventLog 观察（`ace-eventlog-check.json`）
- `ACE-CORE10405` / `ACE-CORE20405`：均保持 `State = Running, ExitCode = 0`；
- 在进入大厅前的停留阶段内，`System` 日志（`RecordId > 2075`）未触发 `Event 7000 / 1275`（`system_service_errors = []`）；`ACE-GAME.sys (1275)` 在靶场与队列预检中的最终影响待虚拟机完善后实测补齐。

---

## 3. 光标排查与本轮新暴露的 5 项虚拟机核心缺陷（已交接 10B）

1. **P0 — 游戏内光标不可见**：宿主机同时挂载 `usb-tablet + usb-mouse`，Guest 无 `spice-vdagent`；试验 1（Guest 侧精准禁用 `QEMU USB Tablet` `Problem=22` 仅留纯 `QEMU USB Mouse`）与试验 2（关闭指针阴影与加速、保持 `MouseTrails=0`）均未恢复游戏内光标显示，而 `GetCursorInfo()` 实测为 `CURSOR_SHOWING (flags=1, pos=(640,360))`。根因已锁定在宿主机 `CocoaSpice / CSMetalRenderer` 硬件光标合成链路与 QEMU 侧移除 `usb-tablet` 支持，详见 `cursor-diagnosis-for-10b.md`。
2. **P0 — 无声音**：`--trim-hardware` 默认清空 `config.plist` 的 `Sound: []`，需改为默认保留虚拟声卡。
3. **P1 — 系统默认英文 / 无中文输入法**：母盘已预装 `zh-CN` 语言包与微软拼音，但默认配置为 `en-US`（本轮会话内已现场切换 `zh-Hans-CN` 微软拼音并验证生效，需固化进母盘 v2 / 预置脚本）。
4. **P1 — 瞬时克隆 `C:` 重置导致每次需重跑安装器**：`F:\VALORANT_CN`（33+ GiB）虽已通过 APFS CoW 秒挂，但 `C:` 启动器注册表每次归零；面向日常体验需提供持久化工作 VM 模式。
5. **P1 — 后台 `WindowsUpdateClient` 偷跑与 `Event 26` 虚拟内存不足**：本轮监测捕获到游戏运行期间 `WindowsUpdateClient` 自动安装 `KB5036908` 及语言包，并弹出 `System Event 26: Windows - Virtual Memory Minimum Too Low`，需在优化器中暂停会话期 Windows Update 并扩大 RAM/页面文件配额。

---

## 4. 零漂移回收验证（`zero-drift-proof.json`）
- `ephemeral_deleted = true`（`utmctl list` 与 `<EXTERNAL_VOLUME>/whisky-phase2-guest/vms/` 确认无残留）
- `utm_defaults_restored = true`（`QEMUDirectXDriver` 与 `QEMURendererFPSLimit` 已还原）
- `golden_zero_drift = true`（只读 `dr-xr-xr-x`，全盘 SHA-256 与 `golden-guest-manifest.json` 逐字节一致）
- `primary_zero_drift = true`（`vm-a` 保持 `stopped`，全盘 SHA-256 零漂移）
- `cache_disk_untouched = true`
