# `target-cn` 黑屏/卡死根因定位与 Venus 替代路径实证分析（Phase 7A）

日期：2026-11-24  
署名：`@DNPMBHC`  
测试底座：只读黄金母盘 `golden-win11-arm64-v1` 瞬时克隆（`ephemeral-p7a-valorant`，`Win11 24H2 ARM64 Build 26100`、`Secure Boot=Enabled`、`Test Signing=Disabled`、TPM 2.0、WHQL `viogpu3d v100.6.101.58000`）  
合规声明：**全程严禁修改游戏/反作弊二进制、严禁替换系统签名 DLL、严禁 Hook/绕过 ACE、严禁隐藏虚拟化或自动化登录/验证码。**

---

## 1. 核心结论速览

| 待解问题 | 本轮一手实证结论 | 关键证据 |
| --- | --- | --- |
| **1. 是否为 `AdapterRAM=0` 导致 DXGI/UE4 拒载？** | **证伪（否）** | UE4 `LogD3D11RHI` 实际通过 DXGI 读到 **`8192 MB DedicatedVideo / 3067 MB SharedSystem`**（`Texture pool is 6807 MB`，`Feature Level 11_1`），`CreateDirect3DDevice` 成功且无 `DXGI_ERROR_DEVICE_REMOVED`。 |
| **2. 此前“黑屏/卡死”的真正卡点是什么？** | **`neptune_umd` 在 SwapChain Resize / 窗口尺寸变更路径触发主渲染线程永久死锁**（双次独立复现）+ UTM 窗口下光标不可见 | **Run 1（默认全屏）**：`virtio-ramfb-gl` 报告桌面 `1024×768` 但最高模式 `5120×2160`，引发 `1280×720 ↔ 5120×2160` 与 8 次 `Monitor info changed` 震荡；在以 ~110 FPS 推进超 1,800 帧并点亮全屏游戏界面后，于 `11:34:24` 永久冻结在帧 `[861]`（`QEMURenderServer` CPU 跌至 `0.0%`）。<br>**Run 2（固定 `1280×720` 窗口化）**：成功点亮并进入创角输入名字界面（WorkingSet `1434 MB`），但不显示鼠标光标；用户拖拽调整窗口大小后，主渲染线程立即永久冻结在帧 `[132]`（持续 100s 零推进，仅后台 XMPP 线程写日志）。 |
| **3. WHQL `vulkan_virtio.dll`（`DXVK 2.5.3 → Venus → KosmicKrisp`）链路本身是否可用？** | **已证实可用（`0 LSB` + `16384 MiB`）** | `d3d11_probe.exe`（x86_64）同目录加载标准 `DXVK 2.5.3`（`d3d11.dll` + `dxgi.dll`）成功走 `vulkan-1.dll → WHQL vulkan_virtio.dll (Venus 26.0.99 / Vulkan 1.4.340) → Apple M4 KosmicKrisp`，识别 `Virtio-GPU Venus (Apple M4)`、显存 `16384 MiB`、实测 `62.438 FPS`、逐像素 `0 LSB` 一致。 |
| **4. ACE / 官方启动器对游戏目录内 `DXVK` DLL 的反应？** | **启动前完整性校验静默清除非官方 DLL（未弹窗拒载，自动净化后回落原生 `neptune_umd`）** | 启动前核验 `ShooterGame\Binaries\Win64\{d3d11.dll,dxgi.dll}` 已就位；点击「进入游戏」后官方启动链在拉起主游戏前将其删除（`BIN_DLLS: []`、`DXVK_LOGS: []`），游戏继续以系统原生 `d3d11.dll → neptune_umd` 启动。 |
| **5. 原生 ARM64 ACE 保护链最新实证？** | **双份 `0xaa64` 驱动持续 `Running` 且强保护生效，同时捕获一份 `0x8664` `ACE-GAME.sys` 被拦截** | `ACE-CORE10405` / `ACE-CORE20405` 保持 `Running (ExitCode=0)`，`SYSTEM` 权限调用 `Stop-Process` 返回 `Access is denied`；同时 `System` EventLog 捕获 `ACE-GAME.sys`（`1,840,456 B`, `Valid`, `PE Machine=0x8664`）被 SCM 报 `Event 7000 / 1275` 阻止加载。 |

---

## 2. 两次实测对照与根因拆解

### 2.1 Run 1：原生 `neptune_umd` 默认全屏基线
- **硬件初始化**：`ShooterGame.log` 第 7–20 行记录 `Red Hat VirtIO GPU 3D controller`（`FL 11_1`, `0x1AF4/0x1050`, `8192/0/3067 MB`）成功初始化，完全排除“显存为 0 拒载”与“不支持 FL 11_0”猜想。
- **分辨率震荡与冻结轨迹**：
  - `GameUserSettings.ini` 被默认配置为 `PreferredFullscreenMode=0`、`ResolutionSizeX=5120`、`ResolutionSizeY=2160`；
  - `11:32:24–11:32:34` 连续出现 `5120×2160 ↔ 1280×720` 来回切换，`11:34:00–11:34:06` 连续出现 8 次 `Monitor info changed (1024x768)`；
  - `11:34:06–11:34:22` 期间引擎帧循环正常以 **~108–112 FPS** 推进（超 1,800 帧），用户确认进入全屏游戏界面；
  - `11:34:24.070` 内置 CEF 报 `[ERROR:gpu_init.cc(426)] Passthrough is not supported, GL is disabled`，`11:34:24.200` 起渲染帧号永久锁死在 **`[861]`**，宿主机 `QEMURenderServer` CPU 降至 `0.0%`，而 `VALORANT-Win64-Shipping.exe` 后台网络线程持续写 XMPP 日志直到停机。

### 2.2 Run 2：固定 `1280×720` 窗口化 + `DXVK 2.5.3` 合规对照
- **实验前准备**：冷重启瞬时克隆，将两份 `GameUserSettings.ini` 设为 `1280×720` 窗口模式（`FullscreenMode=2`），在 `ShooterGame\Binaries\Win64\` 放置 `DXVK 2.5.3` 的 `d3d11.dll` + `dxgi.dll` 并设置 `DXVK_LOG_PATH` / `DXVK_HUD`。
- **官方完整性校验行为**：点击「进入游戏」后，官方启动链在创建 `VALORANT-Win64-Shipping.exe` 前自动移除了目录内非官方 `d3d11.dll` 与 `dxgi.dll`，未弹出任何错误或封禁提示，游戏顺利以系统 `System32\d3d11.dll`（WHQL `neptune_umd`）启动。
- **窗口化复现锁死根因**：
  - 消除全屏 `5120×2160` 震荡后，游戏更快点亮并呈现**创角输入名字界面**（WorkingSet `1434.16 MB`，130 线程）；
  - 但窗口内**不显示鼠标指针**（UE4 隐藏系统光标 / UTM 指针捕获交互问题）；
  - 当用户手动拖拽调整窗口大小（触发 `IDXGISwapChain::ResizeBuffers`）时，主渲染线程于 `11:43:55.341` 立刻永久冻结在帧 **`[132]`**（后续 100 秒内帧号零推进，`QEMURenderServer` CPU 跌至 `2.47%`）。
  - 结合 Phase 4B 记录的 `neptune: virtgpu: window release (res 72) failed 0xc0000001`，可确认为 **WHQL `neptune_umd`（`mesa@68b837cda8`）在 WDDM2 窗口 Resize / SwapChain 重建路径存在渲染线程死锁缺陷**。

---

## 3. 工程边界与合规出路

1. **合规前提下无法通过游戏目录 Drop-in DXVK 绕开 `neptune_umd`**：官方启动器会净化目录，且严禁替换受签名的 `System32\d3d11.dll` 或绕过完整性校验；同时 `target-cn` Shipping 客户端日志显示 `r.Vulkan.UseRealUBs` 为未注册 CVar，不支持直接切换原生 VulkanRHI。
2. **明确可落地的后续合规优化方向**：
   - **短期缓解（零修改二进制）**：保持 `1280×720` 窗口模式（`FullscreenMode=2`）并避免在游戏运行期拖拽调整窗口大小，同时在 UTM 显示设置中固定桌面分辨率（关闭 `DynamicResolution`）以防触发 `Monitor info changed` 导致 SwapChain Resize；并排查 UTM 相对/绝对指针模式对游戏内鼠标显示的影响；
   - **中期治本（上游开源 WHQL 驱动升级）**：跟踪 `utmapp/mesa`（`neptune_umd`）与 `utmapp/viogpu-wddm` 上游对 WDDM2 `ResizeBuffers` / 窗口资源释放（`0xc0000001`）与指针呈现的修复，待 UTM 发布新版官方 WHQL 签名 `viogpu3d` 后升级构建 `golden-win11-arm64-v2`；
   - **反作弊覆盖边界**：需继续关注厂商是否向 ARM64 补齐 `ACE-GAME.sys` 原生 `0xaa64` 版本（当前实测 `ACE-GAME.sys` 仍为 `0x8664` 被报 `Event 7000 / 1275`），以及正式 VM 准入政策（仍为 `unknown`）。
