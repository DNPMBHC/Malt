# 窗口 8A 任务书：无畏契约免 Resize 进大厅/训练场实测与指针可见性破局（🔴 高难度 · 推荐 `Neon Medium`）

署名：`@DNPMBHC`  
难度与模型建议：**🔴 高难度 — 推荐 `Neon Medium`**（若遇到隐蔽输入/显示状态卡死超过 2 轮可升 `Neon High`）  
启动前提：**确认 Phase 7 收口完成后，独占使用 `golden-win11-arm64-v1` 派生的瞬时克隆执行**  
请先阅读：`handoff/phase-8/README.md`、`handoff/module-f/valorant-phase7-runs/blackscreen-root-cause.md`、`handoff/phase-7/evidence/p7-a/report.md`

---

## 1. 独占可写路径（严格互斥）

- `handoff/module-f/valorant-phase8-runs/`（新建）
- `graphics-lab/p8_valorant_*`（新建）
- `graphics-lab/test_p8_valorant_*`（新建）
- `handoff/phase-8/evidence/p8-a/`（新建）

严禁修改 `Whisky/` 下任何 Swift 源码、`Whisky.xcodeproj`、`handoff/task-07/`、黄金母盘与冷备 `vm-a`。

---

## 2. 核心任务拆解

Phase 7A 已证实：`target-cn` 在固定 `1280×720` 窗口化下已顺利进入创角输入名字界面，唯一导致上次中断的两个直接因素是 **① 窗口化不显示鼠标指针**，**② 拖拽调整窗口触发 `neptune_umd` SwapChain Resize 永久冻结**。本任务在不修改任何二进制的前提下完成最终可用性与准入实测：

### 任务 8A-1（P0）：静态分辨率锁死（防 Resize 死锁）+ UTM/Guest 标准鼠标指针可见性调试
1. 通过 `python3 graphics-lab/golden_guest_manager.py spawn-ephemeral` 派生瞬时克隆后，在配置层严格锁定：
   - **关闭 UTM 动态分辨率自动自适应**（避免任何 `Monitor info changed` 触发 `ResizeBuffers`）；
   - 将 Guest 桌面分辨率预先设为 **`1280×720`**（与 `GameUserSettings.ini` 的 `FullscreenMode=2`、`1280×720` 完全对齐），确保启动后全程不触发任何窗口/显示尺寸变化；
2. 排查并验证标准输入指针可见性（仅限合法 UTM/Windows 标准输入配置，严禁 Hook 游戏）：
   - 对比 UTM「捕获鼠标（Capture Mouse / 相对模式）」vs 默认 USB Tablet 绝对模式；
   - 核查 Windows Guest 内鼠标指针方案/硬件指针渲染设置（是否受 `viogpu3d` hardware cursor 缺陷影响，以及在窗口焦点/全屏下哪种标准配置能稳定看到并点击 UI）。

### 任务 8A-2（P0）：完成创角 → 实测进入大厅、靶场/训练场及在线准入反应
1. 启动官方最新 `target-cn`（遇登录、创角输入或 CAPTCHA 必须暂停请用户在可见界面亲自操作）；
2. 在不拖拽窗口、不触发 Resize 的前提下，验证：
   - **是否能顺利点击完成创角并进入主大厅与靶场/训练场**（至少连续稳定运行 3–5 分钟）；
   - **如果成功进入靶场/训练场**：实测真实 FPS、帧间隔 P50/P95/P99、`QEMURenderServer` 与 QEMU CPU 占用、操作跟手性并截图脱敏归档；
   - **重点观测 `ACE-GAME.sys (1275)` 实际影响**：如实记录进入大厅/靶场/匹配后是否出现 ACE 踢线、弹窗报错或延迟退出（精确抓取 EventLog、退出码与屏幕提示）。

### 任务 8A-3（P0）：单测、提案与零漂移清理
1. 在 `graphics-lab/test_p8_valorant_*.py` 补齐日志/指标解析与脱敏单测，确保 `(cd graphics-lab && python3 -B -m unittest discover -v)` 全绿；
2. 向窗口 8B 输出 `handoff/phase-8/evidence/p8-a/interface-proposal.md`；
3. 执行 `destroy-ephemeral` 彻底销毁克隆并校验 `golden_zero_drift: true` & `primary_zero_drift: true`。

---

## 3. 验收标准与交付物

1. `handoff/module-f/valorant-phase8-runs/real-run-report.json`、`summary.md` 与 `handoff/phase-8/evidence/p8-a/report.md`（严格五维分离、含 SHA-256 绑定与真实 FPS/ACE 准入结论）；
2. `handoff/phase-8/evidence/p8-a/interface-proposal.md`；
3. `graphics-lab` 全量 `unittest` 通过，所有临时克隆已彻底销毁且母盘/冷备零漂移。
