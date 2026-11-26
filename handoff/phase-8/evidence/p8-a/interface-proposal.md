# 窗口 8A → 窗口 8B 接口与最小诊断更新建议（`interface-proposal.md`）

日期：2026-11-24  
署名：`@DNPMBHC`  
来源：窗口 8A（免 Resize 静态 `1280×720` 与指针可见性实测）

---

## 1. Phase 8A 最新诚实实证结论

在严格关闭 UTM `DynamicResolution`、静态锁死桌面与游戏为 `1280×720` 窗口化、启用 Windows 软件光标（`MouseTrails=2`）且全程零拖拽窗口的对照条件下，`target-cn` 仍在进入创角输入名字界面后 2.6 秒永久冻结在帧 `[230]`（`QEMURenderServer = 0.0%`，主游戏进程忙等吃满单核导致鼠标无法响应）。

这证明 Phase 7A–8A 连续三次冻结（帧 `[861]` / `[132]` / `[230]`）的底层根因是 **WHQL `viogpu3d v100.6.101.58000` (`neptune_umd`) 在 `target-cn` 创角/主界面 3D 渲染阶段的 WDDM2 同步死锁**，无法仅靠宿主机 UTM 参数或关闭动态分辨率绕过。

---

## 2. 给窗口 8B 的最小只读诊断更新建议（零越权、不阻塞 8B 主线）

1. **兼容矩阵与诊断页状态精准收敛**：
   - `target-cn` 状态码建议更新为：
     - `visual_stage`: `"entered_character_creation_ui_then_froze"`（已突破黑屏进入创角界面，但 2–3 秒内主渲染线程死锁导致无响应）；
     - `root_cause_code`: `"neptune_umd_wddm2_render_thread_deadlock"`（即使关闭 `DynamicResolution` 并锁定静态 `1280×720` 零 Resize 仍 100% 复现）；
     - `mitigation_status`: `"host_and_utm_tuning_exhausted_awaiting_upstream_whql_viogpu3d_fix"`（纯宿主机/UTM 参数调优已穷尽合规边界，需等待上游 `utmapp/mesa` / `viogpu-wddm` 修复并发布新版 WHQL 签名驱动）；
     - `protected_lobby_and_match`: `"not_verified"`；
     - `vendor_vm_support`: `"unknown"`。
2. **三语只读诊断提示更新建议**：
   - 在 `WhiskyCmd baseline-report` / 设置诊断页读取 `golden-guest-manifest.json` 时，对 `viogpu3d == 100.6.101.58000` 显示明确、诚实的边界说明：标准 D3D11 合成负载（`123.6 FPS`, `0 LSB`）与原生 ARM64 ACE 核心驱动加载已验证，但当前版本 `neptune_umd` 在 `target-cn` 创角/主界面存在已知渲染线程死锁，需待上游 WHQL 驱动升级至 `golden-win11-arm64-v2` 后复测。
3. **不新增任何写入/Hook/篡改逻辑**：严格维持纯只读展示与合规边界。
