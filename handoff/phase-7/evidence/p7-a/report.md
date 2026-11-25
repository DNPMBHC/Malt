# 窗口 7A 验收报告：基于黄金母盘的无畏契约黑屏根因定位与 Venus 点亮实测

日期：2026-11-24  
署名：`@DNPMBHC`  
独占路径：`handoff/module-f/valorant-phase7-runs/`、`graphics-lab/p7_valorant_*`、`graphics-lab/test_p7_valorant_*`、`handoff/phase-7/evidence/p7-a/`  
隔离声明：**全程基于只读黄金母盘 `golden-win11-arm64-v1` 派生的瞬时克隆 `ephemeral-p7a-valorant` 与 APFS CoW 游戏数据副盘执行，未改动任何游戏/反作弊二进制，未绕过登录/验证码，测试结束后已彻底销毁临时克隆并完成全盘 SHA-256 零漂移复核。**

---

## 1. 五维诚实状态声明

| 维度 | 状态 | 实证依据 |
| --- | --- | --- |
| **1. 实现与工具交付** | `completed` | 交付 `p7_valorant_analyzer.py`、`p7_valorant_session.py`、`p7_valorant_venus_probe.py` 与 `test_p7_valorant_analyzer.py`。 |
| **2. 本地门禁与单测** | `passed` | `graphics-lab` 全量 `unittest`（236 项）全部通过；防外挂静态安全门禁通过；隐私扫描零泄露；仓库无 `>5 MiB` 文件残留。 |
| **3. 真实 Guest 运行** | `executed` | 瞬时克隆成功加载原生 ARM64 ACE（`ACE-CORE10405/20405` `Running`，外部 `Stop-Process` 返回 `Access is denied`）与 WHQL `viogpu3d v100.6.101.58000`；双次实测均点亮进入游戏界面（全屏游戏界面 / 窗口创角输入名字界面），精准定位 `neptune_umd` SwapChain Resize 渲染线程死锁（帧 `[861]` / `[132]`）；证实 `DXVK 2.5.3 → WHQL vulkan_virtio (Venus)` 在 `d3d11_probe` 上 `0 LSB` 跑通，而官方启动器会在启动游戏前静默清除游戏目录内第三方 `d3d11.dll`/`dxgi.dll`。 |
| **4. 厂商 VM 准入与支持** | `unknown` | 双份原生 ARM64 核心驱动 `Running` 但 `ACE-GAME.sys`（`0x8664`）被报 `Event 7000 / 1275`；官方未对 VM 准入背书。 |
| **5. 受保护大厅与对局** | `not_verified` | 新号创角界面因鼠标不可见且调整窗口触发 `neptune_umd` Resize 冻结，尚未完成大厅/靶场/对局稳定游玩。 |

---

## 2. 关键实测数据摘要

1. **Venus 替代路径预检（`d3d11_probe.exe` x86_64，1280×720 16-Draw `gpu-complete`）**：
   - 原生 `neptune_umd`：`Red Hat VirtIO GPU 3D controller`（`FL 11_1`）、`143.823 FPS`（`6.953 ms`）、**`0 LSB`**；
   - **`DXVK 2.5.3 → WHQL vulkan_virtio.dll (Venus 26.0.99 / API 1.4.340) → Apple M4 KosmicKrisp`**：`Virtio-GPU Venus (Apple M4)`（`FL 11_0`、上报 **`16384 MiB` `DEVICE_LOCAL` 显存**）、**`62.438 FPS`**（`16.016 ms`）、**`0 LSB`**（`byte_exact_match: true`）。
2. **`target-cn` 双轮实测对比**：
   - **Run 1（原生 `neptune_umd`，默认全屏 `5120×2160`）**：DXGI 正确上报 **`8192 MB` 专用显存**（证伪 `AdapterRAM=0` 拒载假说）；因 `virtio-ramfb-gl` 桌面 `1024×768` 与全屏 `5120×2160` 反复震荡，以 ~110 FPS 推进超 1,800 帧点亮全屏界面后，于 `11:34:24` 冻结在帧 **`[861]`**（宿主机 `QEMURenderServer` CPU `0.0%`）。
   - **Run 2（固定 `1280×720` 窗口化 + 目录放置 `DXVK 2.5.3`）**：官方启动链在启动前**自动清除** `ShooterGame\Binaries\Win64\` 中第三方 `d3d11.dll` / `dxgi.dll` 并回落原生 `neptune_umd`；窗口化成功点亮并进入创角输入名字界面（WorkingSet `1434.16 MB`），但不显示鼠标光标，用户拖拽调整窗口触发 SwapChain Resize 后立即冻结在帧 **`[132]`**（`QEMURenderServer` CPU `2.47%`）。
3. **母盘与冷备零漂移复核**：
   - `ephemeral-p7a-valorant.utm` 已彻底销毁；
   - `golden-win11-arm64-v1.utm`（`sealed_readonly: true`）与冷备 `vm-a` 全盘 SHA-256 校验全部 **`zero_drift: true`**，外部游戏缓存盘大小与 mtime 未变。

---

## 3. 交付物清单

- `handoff/module-f/valorant-phase7-runs/real-run-report.json`
- `handoff/module-f/valorant-phase7-runs/blackscreen-root-cause.md`
- `handoff/phase-7/evidence/p7-a/report.md`
- `handoff/phase-7/evidence/p7-a/interface-proposal.md`
- `handoff/phase-7/evidence/p7-a/venus-preflight-probe.json`
- `handoff/phase-7/evidence/p7-a/zero-drift-proof.json`
- `graphics-lab/p7_valorant_analyzer.py`
- `graphics-lab/p7_valorant_session.py`
- `graphics-lab/p7_valorant_venus_probe.py`
- `graphics-lab/test_p7_valorant_analyzer.py`
