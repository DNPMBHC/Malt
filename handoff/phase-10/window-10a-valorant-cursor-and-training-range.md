# 窗口 10A 任务书：攻克游戏内光标不可见 → 实测进入无畏契约大厅与靶场（🔴 高难度 · 推荐 `Neon Medium`）

署名：`@DNPMBHC`  
难度与模型建议：**🔴 高难度 — 推荐 `Neon Medium`**（若底层 SPICE/光标排查卡死超过 2 轮再升 `Neon High`）  
启动前提：**独占使用 `golden-win11-arm64-v1` 派生的 `--trim-hardware --dx-driver DXMT` 瞬时克隆，可立即启动**  
请先阅读：`handoff/phase-10/README.md`、`handoff/module-f/valorant-phase9-runs/summary.md`、`handoff/phase-9/evidence/p9-b/report.md`

---

## 1. 独占可写路径（严格互斥）

- `handoff/module-f/valorant-phase10-runs/`（新建）
- `graphics-lab/p10_valorant_*`（新建）
- `graphics-lab/test_p10_valorant_*`（新建）
- `handoff/phase-10/evidence/p10-a/`（新建）

严禁修改 `Whisky/` 下任何源码、`handoff/task-07/`、窗口 10B 独占路径、黄金母盘与冷备 `vm-a`。

---

## 2. 核心任务拆解

Phase 9A 已实证 `QEMUDirectXDriver = 2`（`dxmt-native.framework`）彻底攻克死锁（连续稳定运行 63 分钟零崩溃、零踢线），Phase 9B 已落地 `--trim-hardware` 与优化器 v2。本任务攻破最后 1% 障碍，真正走进无畏契约大厅与靶场/训练场：

### 任务 10A-1（P0）：系统性排查并解决游戏内鼠标指针不可见问题
1. 通过 `python3 graphics-lab/golden_guest_manager.py spawn-ephemeral --trim-hardware --dx-driver DXMT --fps-limit 120` 派生极简 `dxmt-native` 瞬时克隆（并应用优化器 v2，确认 `MouseTrails = 0`）；
2. 按从简到深顺序实测定位游戏内光标不可见根因（纯标准合法配置，严禁 Hook 游戏）：
   - **试验 1（移除 `usb-tablet`，仅留纯 `usb-mouse`）**：验证去掉绝对坐标平板设备后，配合 UTM `Capture Mouse` 相对鼠标模式，UE4 游戏内光标与视角转动是否恢复可见与跟手；
   - **试验 2（SPICE `vdagent` / `viogpu3d` 光标通道排查）**：确认关闭/开启 `vdagent` 或切换 Windows 指针阴影/缩放/软件光标时，UE4 游戏界面（创角/大厅）指针可见性变化；
   - **试验 3（合法跳过一次性创角验证）**：若创角页仍仅差一次性点击，在用户亲自协助下通过键盘焦点（`Tab`/`Enter`）或同账号完成首次取名，直接进入主大厅与靶场，同时把精确的光标丢失根因写入 `handoff/phase-10/evidence/p10-a/cursor-diagnosis-for-10b.md` 供窗口 10B 在定制 UTM 的 `CocoaSpice` 层彻底根治！

### 任务 10A-2（P0）：无畏契约大厅与靶场/训练场真实 3D 实战压测 + `ACE-GAME.sys` 准入终局实证
1. 进入**无畏契约主大厅**与**靶场/训练场**（登录/创角/验证码全程由用户在可见界面亲自完成）：
   - 连续稳定运行 **3–5 分钟**，实测 1280×720（及可选 1080p）下的真实 **平均 FPS、P50/P95/P99 帧时间、宿主机 `QEMURenderServer` 与 QEMU CPU/RSS 占用**；
   - 实测移动、360° 转视角与开枪的操作跟手性（验证相对鼠标在 FPS 场景是否正常不乱飞）；
   - **终局核查 `ACE-GAME.sys (1275)` 影响**：如实记录进入靶场/训练场（以及可选自建/匹配队列预检）后，ACE 是否持续放行，还是会触发延迟踢线、报错码或限制，并完整采集 EventLog 与屏幕提示。

### 任务 10A-3（P0）：单测与零漂移收口
1. 在 `graphics-lab/test_p10_valorant_*.py` 编写离线指标/日志解析单测，保证 `(cd graphics-lab && python3 -B -m unittest discover -v)` 全绿；
2. 结束必须执行 `destroy-ephemeral` 彻底销毁瞬时克隆、恢复任何临时 UTM 偏好，并校验 `golden_zero_drift: true` 与 `primary_zero_drift: true`。

---

## 3. 验收标准与交付物

1. `handoff/module-f/valorant-phase10-runs/real-run-report.json`、`summary.md` 与 `handoff/phase-10/evidence/p10-a/report.md`（含靶场真实 FPS / 帧时间 / 跟手性 / ACE 最终准入实证与 SHA-256 绑定）；
2. `handoff/phase-10/evidence/p10-a/cursor-diagnosis-for-10b.md` 与 `zero-drift-proof.json`；
3. `graphics-lab` 全部 `unittest` 通过、零隐私泄露、零大文件残留且母盘/冷备零漂移。
