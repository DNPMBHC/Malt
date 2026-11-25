# UTM 5.0.9 原生宿主机 3D 渲染能力实证清单（供窗口 9B 固化参考）

日期：2026-11-24  
署名：`@DNPMBHC`  
来源：窗口 9A（基于 `/Applications/UTM.app` 5.0.9 实机验证）

---

## 1. 已真机验真的 `QEMUDirectXDriver` 偏好枚举

配置文件路径（macOS 沙盒容器内）：  
`~/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist`

> **重要实证**：`QEMUDirectXDriver` 在 UTM 5.0.9 中为 **整数枚举（`-int`）**，写入字符串 `"dxmt"` 无效（仍回落默认 `0`）。修改后需重启 `UTM`（并 `killall cfprefsd` 刷新缓存）生效。

| `QEMUDirectXDriver` (`-int`) | 实际映射宿主机框架（`lsof` 实证） | `d3d11_probe` FPS (1280×720) | `ID3D11Query(TIMESTAMP)` `gpu_ms` | 逐像素校验 (vs WARP) | 实测对 `target-cn` 稳定性 |
| :---: | :---: | ---: | ---: | :---: | --- |
| `0`（默认） | `d3dmetal-native.framework` | `129.938 FPS` | `0.0 ms`（未上报） | `0 LSB` | 进入创角界面 2.6 秒永久死锁（3/3 复现） |
| `1` | `none_detected`（软件回落） | `18.431 FPS` | `44.9016 ms` | — | 不适合 3D 游戏 |
| **`2`（推荐）** | **`dxmt-native.framework`** | **`119.460 FPS`** | **`1.6213 ms`（真实恢复！）** | **`0 LSB`** | **彻底打破 2.6 秒死锁，连续稳定运行 63 分钟零冻结、零崩溃** |

---

## 2. 宿主机 `virglrenderer.1.framework` 原生内置控制项

只读审计确认 UTM 5.0.9 内置以下宿主机 Neptune/Virgl 控制变量与偏好键：
- **UTM 用户偏好键**：`QEMUDirectXDriver`（int `0/1/2`）、`QEMUVulkanDriver`、`QEMURendererBackend`、`QEMURendererFPSLimit`；
- **`virglrenderer.1` 环境变量**：`NPT_BACKEND`（`dxmt` / `d3dmetal`）、`NPT_DEBUG`、`NPT_WA_FLAGS`（`workaround_flags=0x%08x`）、`NPT_PROFILE_PERIOD_MS`、`NPT_CAPSET_CAPS`、`NPT_CAPSET_D3D12`。

---

## 3. 给窗口 9B 的黄金配置固化建议

1. **宿主机 3D 后端推荐**：在黄金配置文档与宿主机诊断建议中明确推荐 **`QEMUDirectXDriver = 2` (`dxmt-native.framework`)**，无需改动任何 Windows 内核/Guest 驱动即可彻底消除 `d3dmetal-native` 下的 `target-cn` 2.6 秒死锁，并恢复真实的 `ID3D11Query(TIMESTAMP)` GPU 耗时统计；
2. **显示与输入注意点**：
   - 保持 `Display[0].DynamicResolution = False` 避免触发不必要的分辨率震荡；
   - **切勿在 Guest 内开启 Windows `MouseTrails`（保持 `MouseTrails = 0`）**：开启指针轨迹会导致 SPICE 客户端隐藏宿主机光标，进而使鼠标一进入虚拟机桌面即不可见；
   - 当前 `viogpu3d` 在全屏/窗口化游戏中仍存在游戏接管焦点后隐藏系统光标、且切换 UTM `Capture Mouse` 后游戏内光标仍不可见的限制，建议在文档中诚实保留为已知输入边界。
