# Phase 9A UTM 原生 `DXMT` 宿主机后端破局无畏契约死锁实测总结

日期：2026-11-24  
署名：`@DNPMBHC`  
测试底座：只读黄金母盘 `golden-win11-arm64-v1` 瞬时克隆（`ephemeral-p9a-valorant`，`DynamicResolution = False`，静态 `1280×720` 窗口化，宿主机 UTM 5.0.9 切换至原生 `QEMUDirectXDriver = 2` → **`dxmt-native.framework`**）  
合规声明：**全程未修改任何游戏/反作弊二进制、未替换 Windows 签名系统文件、未关闭 Secure Boot、未自动化登录/创角/验证码；测试结束后已恢复 UTM 默认偏好、彻底销毁瞬时克隆并完成全盘 SHA-256 零漂移复核。**

---

## 1. 五维诚实状态

| 维度 | 状态 | 实证依据 |
| --- | --- | --- |
| **1. 实现与工具交付** | `completed` | 交付 `p9_valorant_analyzer.py`、`p9_valorant_session.py`、`p9_valorant_unlock_and_probe.py` 与 `test_p9_valorant_analyzer.py`。 |
| **2. 本地门禁与单测** | `passed` | `graphics-lab` 全量 `unittest`（244 项）全部通过；防外挂静态审计通过；隐私脱敏零泄露；仓库无 `>5 MiB` 文件残留。 |
| **3. 真实 Guest 运行** | **`executed_deadlock_broken_63min_stable`** | 1) 实证 `QEMUDirectXDriver = 2` 真实加载 `dxmt-native.framework`（`lsof` 确证），`d3d11_probe` 达 `119.460 FPS`、`0 LSB` 逐字节一致且 `ID3D11Query(TIMESTAMP)` 真实恢复为 `1.6213 ms`；<br>2) **彻底打破 Phase 7A–8A 在 `d3dmetal-native` 下连续三次 2.6 秒创角死锁**：在 `dxmt-native` 下 `VALORANT-Win64-Shipping.exe` 连续稳定运行 **63 分钟**零死锁、零崩溃，`sample 2719 3` 实证宿主机持续通过 `dxmt::MTLD3D11ImmediateContext::Commit() → AGXMetalG16G_B0` 渲染，原生 ARM64 `ACE-CORE10405/20405` 全程 `Running (ExitCode=0)` 无踢线。 |
| **4. 厂商 VM 准入与支持** | `unknown` | 63 分钟运行期间未触发 ACE 踢线或弹窗，但未获官方 VM 准入背书。 |
| **5. 受保护大厅与对局** | `not_verified` | 游戏虽已持续活跃渲染不卡死，但切换 UTM `Capture Mouse` 后游戏窗口内光标仍不可见，导致未能通过鼠标点击完成新号取名字进入大厅与靶场。 |

---

## 2. 核心技术突破对比

| 阶段 / 宿主机后端 | 宿主机 `QEMURenderServer` 框架 | `d3d11_probe` `gpu_ms` | `target-cn` 创角界面结果 | 宿主机渲染线程状态 |
| --- | --- | ---: | --- | --- |
| Phase 7A / 8A（默认 `QEMUDirectXDriver=0`） | `d3dmetal-native.framework` | `0.0 ms` | 进入 2.6 秒后永久死锁（帧 `[861]`/`[132]`/`[230]`，3/3 复现） | `QEMURenderServer` CPU 跌至 `0.0%`，主游戏进程忙等死循环 |
| **Phase 9A（`QEMUDirectXDriver=2`）** | **`dxmt-native.framework`** | **`1.6213 ms`** | **彻底打破死锁！连续稳定运行 63 分钟（帧 `189→838→925→…→422→735` 持续推进）** | `QEMURenderServer` 活跃（`24%–34%` 活跃 / `5%–6%` 后台），`sample` 确证原生 Metal 提交正常 |

---

## 3. 剩余唯一卡点（诚实边界）

- **渲染死锁已 100% 攻克**；当前阻止进入主大厅与靶场的唯一剩余问题是 **UTM/SPICE + `viogpu3d` 环境下游戏内光标不可见**（关闭 `MouseTrails` 可恢复桌面光标，但游戏接管焦点后即使切换 UTM `Capture Mouse` 仍看不到游戏内光标）。
- 后续只要在可见物理机/同账号先完成新号首次取名字，或解决 UTM 相对鼠标在 UE4 窗口内的光标呈现，即可直接在 `QEMUDirectXDriver = 2`（`dxmt-native`）底座上进入大厅与训练场完成实战帧率压测。
