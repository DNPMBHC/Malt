# 窗口 7A → 窗口 7B 接口与最小诊断更新建议（`interface-proposal.md`）

日期：2026-11-24  
署名：`@DNPMBHC`  
来源：窗口 7A（基于 `golden-win11-arm64-v1` 的 `target-cn` 黑屏/卡死根因定位与 Venus 实测）

---

## 1. 背景摘要（供 7B 同步诚实状态）

基于不可变只读黄金母盘 `golden-win11-arm64-v1` 的瞬时克隆实测已经取得三项高价值一手结论：
1. **非 `AdapterRAM=0` 拒载，且已突破纯黑屏**：UE4 `LogD3D11RHI` 正确通过 DXGI 读取 `8192 MB` 专用显存（`FL 11_1`），双次实测分别进入全屏游戏界面与窗口化创角输入名字界面；
2. **卡死根因锁定**：WHQL `neptune_umd` (`v100.6.101.58000`) 在触发 SwapChain Resize（如 `virtio-ramfb-gl` 的 `DynamicResolution` 分辨率震荡或拖拽调整窗口大小）时会发生主渲染线程死锁（分别冻结在帧 `[861]` 与 `[132]`），并伴随窗口模式不显示鼠标指针；
3. **Venus / DXVK 与 ACE 边界明确**：`DXVK 2.5.3 → WHQL vulkan_virtio.dll (Venus 1.4.340) → KosmicKrisp` 在标准 `d3d11_probe.exe` 上 100% 跑通（`16384 MiB` 显存、`62.438 FPS`、`0 LSB`），但 `target-cn` 官方启动链会在启动前自动清理游戏目录中非官方 `d3d11.dll` / `dxgi.dll` 并回落原生 `neptune_umd`；同时在原生 ARM64 `ACE-CORE10405/20405` 运行外，捕获到 `ACE-GAME.sys` 仍为 `0x8664`（被 SCM 报 `Event 7000 / 1275`）。

---

## 2. 给窗口 7B 的最小增量更新建议（零越权、仅只读诊断展示）

以下建议均为可选最小增量，严格不修改内核/驱动/游戏或反作弊逻辑，不阻塞 7B 主线：

1. **兼容矩阵 / 诊断页对 `target-cn` 的诚实状态字段更新**：
   - 将状态描述从「黑屏根因未知」精确收敛为：
     - `visual_stage`: `"entered_game_ui_freeze_on_resize"`（已点亮进入全屏/窗口创角界面，SwapChain Resize 触发 `neptune_umd` 渲染线程冻结，尚未完成大厅/靶场稳定游玩）；
     - `root_cause_code`: `"neptune_umd_swapchain_resize_deadlock"`；
     - `dxvk_venus_status`: `"probe_passed_0lsb_launcher_purges_dropin_dll"`（`d3d11_probe` 跑通 `0 LSB`，但官方启动器完整性校验会自动清除游戏目录 DXVK DLL）；
     - `ace_arm64_coverage`: `"partial_core_arm64_running_ace_game_x64_blocked_1275"`（`ACE-CORE10405/20405` 原生 `0xaa64` 运行中，`ACE-GAME.sys` 仍为 `0x8664` 被 `1275` 拦截）；
     - `vendor_vm_support`: `"unknown"`（保持诚实边界）。
2. **`WhiskyCmd baseline-report` / 设置页只读提示增强（建议）**：
   - 读取 `handoff/phase-6/evidence/p6-a/golden-guest-manifest.json` 时，如检测到 `viogpu3d == 100.6.101.58000`，在只读诊断建议中增加两条已知上游限制提示（支持三语本地化）：
     - 提示 1：建议在 UTM Guest 端关闭 `DynamicResolution` 并使用固定 `1280×720` 窗口模式，避免运行中调整窗口触发 `neptune_umd` Resize 冻结；
     - 提示 2：如遇游戏目录 Drop-in DXVK 未生效，属官方启动器完整性校验自动清理行为，请勿尝试替换系统签名 DLL。
3. **无须新增任何危险或写入型接口**：保持 `Whisky` / `WhiskyCmd` 对黄金母盘与兼容诊断的**纯只读**语义。
