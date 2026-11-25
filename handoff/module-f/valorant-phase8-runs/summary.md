# Phase 8A `target-cn` 免 Resize 与指针可见性实测总结

日期：2026-11-24  
署名：`@DNPMBHC`  
测试底座：只读黄金母盘 `golden-win11-arm64-v1` 瞬时克隆（`ephemeral-p8a-valorant`，`DynamicResolution = False`，静态 `1280×720 @ 120 Hz`，`GameUserSettings.ini` 预设 `1280×720` 窗口化 `FullscreenMode=2`，`SPI_SETMOUSETRAILS = 2` 软件光标回退）  
合规声明：**全程未修改任何游戏/反作弊二进制、未替换系统签名 DLL、未自动化登录/创角/验证码，测试结束后已彻底销毁瞬时克隆并完成全盘 SHA-256 零漂移复核。**

---

## 1. 五维诚实状态

| 维度 | 状态 | 实证依据 |
| --- | --- | --- |
| **1. 实现与工具交付** | `completed` | 交付 `p8_valorant_analyzer.py`、`p8_valorant_session.py` 与 `test_p8_valorant_analyzer.py`。 |
| **2. 本地门禁与单测** | `passed` | `graphics-lab` 全量 `unittest`（240 项）全部通过；防外挂静态审计通过；隐私扫描零泄露；仓库无 `>5 MiB` 文件残留。 |
| **3. 真实 Guest 运行** | `executed_frozen_at_character_creation_zero_resize` | 在严格关闭 UTM `DynamicResolution`、预先锁死桌面与游戏同为 `1280×720` 窗口模式且启用软件光标回退（`MouseTrails=2`）、**全程零拖拽调整窗口**的前提下，游戏仍于进入创角输入名字界面后 **2.6 秒**（`12:21:46.467`）永久冻结在帧 **`[230]`**，`QEMURenderServer` CPU 归 `0.0%`，`VALORANT-Win64-Shipping.exe` CPU 持续忙等飙升，导致鼠标键完全无法交互。 |
| **4. 厂商 VM 准入与支持** | `unknown` | 原生 ARM64 `ACE-CORE10405/20405` 持续 `Running (ExitCode=0)`，未见官方 VM 准入背书。 |
| **5. 受保护大厅与对局** | `not_verified` | 因在创角输入名字界面即稳定触发 `neptune_umd` 渲染线程死锁，未能完成创角进入大厅/靶场，`ACE-GAME.sys (1275)` 在大厅/对局中的中途踢线反应未获实证。 |

---

## 2. 关键科学纠偏（三次独立复现锁死真因）

对比 Phase 7A Run 1（默认全屏 `5120×2160`，卡死帧 `[861]`）、Phase 7A Run 2（`1280×720` 窗口化，卡死帧 `[132]`）与本次 **Phase 8A（关闭 `DynamicResolution` + 静态 `1280×720` + 零拖拽 + 软件光标，卡死帧 `[230]`）**：

1. **排除了「仅因 SwapChain Resize」与「仅因鼠标硬件」两个单因素解释**：
   - Guest 鼠标枚举为标准 `USB\VID_0627&PID_0001`（`Status=OK`）且已启用 `MouseTrails=2` 软件光标；
   - 即使全程零 Resize、零窗口拖拽，`VALORANT-Win64-Shipping.exe`（PID `1448`，WorkingSet `1457.74 MB`，131–132 线程）仍在 `LoginQueueManager` 初始化完毕、进入创角输入名字界面后 2.6 秒（`12:21:43.820 [ 79]` → `12:21:46.467 [230]`）主渲染循环永久停止推进（10 秒内帧号锁死在 `[230]`、宿主机 `QEMURenderServer` CPU 跌至 **`0.0%`**，而主进程 CPU 时间 10 秒内暴涨 **`+12.11 s`** 进入忙等死循环）；
   - 2 分钟后（`12:23:30.551`）内置 CEF 进程才因 GPU 管线超时报 `Passthrough is not supported, GL is disabled`，证实 CEF 报错是渲染死锁的**后果**而非原因；
   - 用户体感“在游戏界面里操作不了鼠标键、无法输入名字”，实质上是**游戏主线程/UI 渲染线程在 `neptune_umd` (`v100.6.101.58000`) 3D 界面提交阶段已彻底挂起**。

2. **合规边界与下一步工程方向**：
   - 在合规前提下（官方启动链会清除游戏目录 Drop-in DXVK、严禁替换 `System32` 签名 DLL），纯靠宿主机 UTM 参数与 Guest 显示/指针配置已无法绕过 `viogpu3d v100.6.101.58000`（`neptune_umd` / `mesa@68b837cda8`）在 `target-cn` 主界面渲染阶段的死锁；
   - 真正可行的合规治本路径：跟踪上游 `utmapp/mesa` (`neptune_umd`) 与 `utmapp/viogpu-wddm` 修复 WDDM2 同步死锁并发布新版 WHQL 签名驱动后，基于 `golden_guest_manager.py` 升级构建 `golden-win11-arm64-v2` 再行复测。
