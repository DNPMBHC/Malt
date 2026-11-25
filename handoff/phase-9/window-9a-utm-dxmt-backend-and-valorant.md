# 窗口 9A 任务书：UTM 原生 `DXMT` 后端切换破局无畏契约死锁与宿主机堆栈取证（🔴 高难度 · 推荐 `Neon Medium`）

署名：`@DNPMBHC`  
难度与模型建议：**🔴 高难度 — 推荐 `Neon Medium`**（若连续 2 轮卡在底层堆栈分析可升 `Neon High`）  
启动前提：**优先独占使用 `golden-win11-arm64-v1` 派生的瞬时克隆（绝不触碰母盘与冷备 `vm-a`），可立即启动**  
请先阅读：`handoff/phase-9/README.md`、`handoff/module-f/valorant-phase8-runs/summary.md`、`handoff/phase-8/evidence/p8-a/report.md`

---

## 1. 独占可写路径（严格互斥）

- `handoff/module-f/valorant-phase9-runs/`（新建）
- `graphics-lab/p9_valorant_*`（新建）
- `graphics-lab/test_p9_valorant_*`（新建）
- `handoff/phase-9/evidence/p9-a/`（新建）

严禁修改 `Whisky/` 下任何源码、`handoff/task-07/`、窗口 9B 独占路径、黄金母盘与冷备 `vm-a`。

---

## 2. 核心任务拆解

本机只读审计已确认 `/Applications/UTM.app` 原生内置 `dxmt-native.framework` 以及 `QEMUDirectXDriver`、`QEMURendererBackend`、`QEMURendererFPSLimit`、`NPT_BACKEND`、`NPT_DEBUG`、`NPT_WA_FLAGS` 控制项。此前 7A/8A 连续三次创角死锁均发生在默认的 `d3dmetal-native` 后端下。

### 任务 9A-1（P0）：实证解锁 UTM 5.0.9 原生 `DXMT` 宿主机后端并做探针对比
1. 查明 UTM 5.0.9 的 `QEMUDirectXDriver`（`DXMT` vs `D3DMetal`）、`QEMURendererBackend`、`QEMURendererFPSLimit` 的精确配置入口（`defaults read com.utmapp.UTM` 或 VM `config.plist`，必要时辅以 `NPT_BACKEND=dxmt` / `NPT_DEBUG=1`）；
2. 通过 `golden_guest_manager.py spawn-ephemeral` 派生瞬时克隆并启用 **`DXMT`** 后端，先跑 `d3d11_probe.exe`（1280×720）验真：
   - 验证宿主机 `QEMURenderServer` 进程实际映射了 `dxmt-native`（可通过 `vmmap` / `lsof` 只读核查已加载 framework，或查看 `NPT_DEBUG=1` 日志）；
   - 验证 `ID3D11Query(TIMESTAMP)` 是否从 `0` 恢复真实 GPU 耗时，并对比 `DXMT` 后端 vs `D3DMetal` 后端在 Guest 侧的 FPS 与 `0 LSB` 像素一致性。

### 任务 9A-2（P0）：在 `DXMT` 宿主机后端下重测无畏契约突破创角死锁
1. 在确认 `dxmt-native` 已真实接管 `QEMURenderServer` 后，于同一静态 `1280×720` 窗口化（`DynamicResolution = False`，零拖拽、零修改游戏/ACE）瞬时克隆上启动最新官方 `target-cn`（遇登录、创角输入或 CAPTCHA 必须暂停请用户在可见界面亲自完成）；
2. 观察并记录：
   - **是否彻底打破 2.6 秒创角界面冻结**，顺利完成创角并进入**主大厅与靶场/训练场**；
   - **如果成功进入大厅/靶场**：连续稳定运行 3–5 分钟，实测真实 FPS、P95/P99、`QEMURenderServer` CPU、以及 `ACE-GAME.sys (1275)` 是否触发中途踢线或报错；
   - **如果依然冻结**：立刻在冻结瞬间对宿主机 `QEMURenderServer`（对应 `VALORANT-Win64-Shipping.exe` 的 worker PID）执行 macOS 原生只读 `sample <PID> 3` 并采集 `NPT_DEBUG=1` / `VIRGL_LOG_LEVEL` 输出，精确提取死锁线程调用栈与卡死函数名，同时补充测试 `NPT_WA_FLAGS` / `QEMURendererFPSLimit` 等合法内置项是否有缓解效果。

### 任务 9A-3（P0）：单测、提案与零漂移清理
1. 在 `graphics-lab/test_p9_valorant_*.py` 编写离线解析与脱敏单测，保证 `(cd graphics-lab && python3 -B -m unittest discover -v)` 全绿；
2. 向窗口 9B 输出 `handoff/phase-9/evidence/p9-a/utm-native-capabilities.md`（记录已验真的 UTM 原生 `QEMUDirectXDriver` / 渲染参数配置键，供 9B 固化进黄金配置规范）；
3. 结束必须执行 `destroy-ephemeral` 彻底销毁瞬时克隆、恢复任何临时修改的 `com.utmapp.UTM` 用户默认值（如改过），并复核 `golden_zero_drift: true` 与 `primary_zero_drift: true`，释放 VM 租约给窗口 9B。

---

## 3. 验收标准与交付物

1. `handoff/module-f/valorant-phase9-runs/real-run-report.json`、`summary.md` 与 `handoff/phase-9/evidence/p9-a/report.md`（含 `dxmt-native` 加载实证、探针对比、无畏契约实测或 `sample` 精确调用栈）；
2. `handoff/phase-9/evidence/p9-a/utm-native-capabilities.md` 与 `zero-drift-proof.json`；
3. `graphics-lab` 全部 `unittest` 通过、零隐私泄露、零大文件残留且母盘/冷备零漂移。
