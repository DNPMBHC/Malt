# 窗口 7A 任务书：基于黄金母盘的无畏契约黑屏根因定位与 Venus 点亮实测（🔴 高难度 · 推荐 `Neon Medium`）

署名：`@DNPMBHC`  
难度与模型建议：**🔴 高难度 — 推荐 `Neon Medium`**（若深层渲染/日志卡死超过 2 轮再升 `Neon High`）  
启动前提：**独占使用 `golden-win11-arm64-v1` 派生的一次性瞬时克隆（绝不触碰母盘与冷备 `vm-a`），可立即启动**  
请先阅读：`handoff/phase-7/README.md`、`handoff/phase-6/evidence/p6-a/golden-guest-report.md`、`handoff/module-f/valorant-real-runs/summary.md`、`handoff/module-f/valorant-real-runs/ace-mechanism-analysis.md`

---

## 1. 独占可写路径（严格互斥）

- `handoff/module-f/valorant-phase7-runs/`（新建）
- `graphics-lab/p7_valorant_*`（新建）
- `graphics-lab/test_p7_valorant_*`（新建）
- `handoff/phase-7/evidence/p7-a/`（新建）

严禁修改 `Whisky/` 下任何 Swift 源码、`Whisky.xcodeproj`、`handoff/task-07/` 及窗口 7B 独占路径。

---

## 2. 核心任务拆解

Phase 5A 已证实：在 `Win11 24H2 ARM64 + WHQL viogpu3d + Secure Boot + TPM 2.0` 下，原生 ARM64 ACE 驱动（`0xaa64`：`0.6.6.6` 与 `21.0.2506.56`）已真实加载且未弹窗拒载，主游戏与图形辅助进程已拉起并加载 `neptune_umd`，但画面持续黑屏。本任务在统一不可变的 `golden-win11-arm64-v1` 瞬时克隆上攻破这最后一道黑屏障碍：

### 任务 7A-1（P0）：只读全链路日志取证，精准定位 `neptune_umd` 黑屏卡点
1. 通过 `python3 graphics-lab/golden_guest_manager.py spawn-ephemeral` 从黄金母盘 1 秒派生隔离克隆（确认 `Secure Boot=true`、`Test Signing=false`、WHQL `viogpu3d` 就绪）；
2. 安装并启动最新官方 `target-cn`（遇登录、实名或 CAPTCHA 人机验证**立即暂停请用户在可见界面亲自完成**）；
3. 严禁修改任何游戏/反作弊二进制，仅做**只读观测**：
   - 采集游戏自身生成的 UE4/D3D11 日志（`%LOCALAPPDATA%\ShooterGame\Saved\Logs\` 等）、Windows Application/System/CodeIntegrity EventLog、DXGI 枚举与内存/显存状态（重点核查是否因 `AdapterRAM=0` / `DedicatedVideoMemory` 判定、着色器编译卡死、还是 `neptune_umd` 特定 D3D11 接口返回错误导致黑屏）；
   - 记录清晰的根进程与图形子进程存活状态、窗口创建/SwapChain 行为与精确自然退出码（如发生退出）。

### 任务 7A-2（P0）：实测 WHQL `vulkan_virtio_arm64.dll`（`DXVK → Venus → KosmicKrisp`）绕开黑屏可行性
1. 在确认不修改签名内核驱动、不修改游戏本体文件的前提下，测试利用 `viogpu3d` 包自带的 WHQL 签名 **`vulkan_virtio_arm64.dll`（Venus Vulkan）** 配合标准 `DXVK` 用户态实现（或标准启动参数如 `-dx11` / 窗口化模式），观察：
   - ① 能否绕过 `neptune_umd` 的黑屏卡点，成功渲染游戏大厅 / 靶场训练场画面；
   - ② 腾讯 ACE 对标准 `DXVK` 用户态 DLL 的合规反应（放行还是拒绝，如实记录精准状态与提示，绝不强行绕过或注入）；
2. **如果成功点亮大厅 / 训练场**：实测 1280×720（及原生/窗口分辨率）下的真实平均 FPS、P95/P99 帧时间、`QEMURenderServer` 宿主 CPU 占用与稳定性（至少连续稳定观测 3–5 分钟，并截图脱敏归档）；
3. **如果仍未点亮**：精确锁定阻断函数/阶段与错误码，并向窗口 7B 输出 `handoff/phase-7/evidence/p7-a/interface-proposal.md`（说明宿主机/打包侧或下一阶段最值得补齐的诊断/工程项）。

### 任务 7A-3（P0）：回归单测与母盘零漂移归档
1. 在 `graphics-lab/test_p7_valorant_*.py` 编写离线解析与日志脱敏单测，确保 `(cd graphics-lab && python3 -B -m unittest discover -v)` 全绿；
2. 实测完成后必须执行 `destroy-ephemeral` 彻底销毁临时克隆，并复核 `golden-win11-arm64-v1` 与冷备 `vm-a` 保持 `golden_zero_drift: true` / `primary_zero_drift: true`。

---

## 3. 验收标准与交付物

1. `handoff/module-f/valorant-phase7-runs/real-run-report.json`、`blackscreen-root-cause.md` 与 `handoff/phase-7/evidence/p7-a/report.md`（严格五维分离、零隐私泄露、含 SHA-256 绑定）；
2. `handoff/phase-7/evidence/p7-a/interface-proposal.md`（给 7B 的最小兼容/诊断更新建议）；
3. `graphics-lab` 全部 `unittest` 通过，且所有临时克隆已彻底销毁、母盘与冷备零漂移。
