# 窗口 4A → 窗口 4D 路由与打包升级提案：`KosmicKrisp` ICD 锁定与 `DXMT` MetalFX Spatial 策略

日期：2026-11-23  
提出方：窗口 4A（`my-project` Wine 图形天花板升级）  
接收方：窗口 4D（统筹 `Whisky/`、`WhiskyCmd/`、`Wine.swift`、`BottleSettings.swift`、`runtime-manifest.json` 与 `.app` → `.dmg` 打包）  
署名：`@DNPMBHC`  
状态：窗口 4A 四路实测（24 组 / 21,600 帧）、DXMT MetalFX Spatial 档位对照（18 组 / 16,200 帧）及 Swift 策略模型与单元测试已全部通过。

---

## 1. 五维状态分离与实测口径边界

| 维度 | 状态 | 边界与说明 |
| --- | --- | --- |
| 代码实现 | 已完成 | 新增 `HostWineVulkanICD.swift`、`HostDXMTMetalFXPolicy.swift`、`HostWineKosmicKrispAndMetalFXTests.swift` 及 `graphics-lab/wine_kosmickrisp_benchmark.py`。 |
| 本地合成与单测 | 已通过 | `swift test --filter Host`、Strict SwiftLint、`graphics-lab` 全部 Python 单测（含 `test_metalfx_sdk_compile.py`）与防外挂静态门禁全部通过。 |
| 宿主机真实 Wine 实测 | **已实测（42 组 / 37,800 帧）** | Apple M4 / macOS 27.2.1 (`26B131`)，自研 PE32+ `d3d11_probe.exe`（`1280×720`、`120` 预热 + `900` 测量 × 3 轮冷/热），完整原始 CSV 与逐字节 SHA-256 归档于 `handoff/phase-4/evidence/p4-a/`。 |
| Windows Guest / VM | 不在窗口 4A 范围 | 全程未触碰 `vm-a` 或任何虚拟机。 |
| 商业游戏与反作弊厂商 | **未测试（严禁外推）** | 仅覆盖自有确定性 D3D11 探针场景，不代表未测商业游戏帧率或反作弊兼容性。 |

---

## 2. 关键实测结论与底层架构发现

### 2.1 四路同口径配对实测（`wine-four-way-benchmark/manifest.json`，SHA-256 `a2cecf9217e9fa6bb6292907da0441cf3116ee652f976aec523e579e1e8dbf56`）

相同宿主机、相同 `wine-11.0-ge1cd80458f5`（`x86_64` via Rosetta 2）、相同 `d3d11_probe.exe`（SHA-256 `09bb190bf5d763f9749345300b937728db886a4ec26c32c361a920c565cf1bee`）、3 轮轮换执行顺序 + 独立临时 `WINEPREFIX` 与独立缓存目录：

| 引擎（3 轮均值，1280×720） | 缓存态 | Feature Level | 平均 FPS | 帧间隔 Mean / P50 / P95 / P99 (ms) | D3D11 GPU 均值 (覆盖率) | Probe Init (ms) | Warm-up (ms) | DXGI 显存 (MiB) |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **DXMT v0.80** (`MetalFX=off`) | cold / hot | `11_1` | 520.61 / **552.71** | 1.932 / 1.508 / 5.466 / 8.744<br>**1.812 / 1.476 / 4.388 / 7.980** | 1.750 ms (99.8%)<br>1.623 ms (99.9%) | 420.6 / **336.5** | 573.9 / 572.0 | 20.08 / **19.85** |
| **DXVK 1.10.3 + KosmicKrisp** | cold / hot | `11_0` | **390.84** / 378.46 | 2.679 / **1.393** / 8.892 / 10.647<br>2.842 / 1.707 / 9.631 / 11.589 | **0.508 ms** (100%)<br>**0.647 ms** (100%) | 1354.1 / 1208.5 | **375.2 / 324.8** | 350.47 / 349.44 |
| **DXVK 1.10.3 + MoltenVK 1.2.1** | cold / hot | `11_0` | 274.01 / 365.30 | 3.759 / 2.930 / 8.256 / 11.718<br>3.032 / 2.381 / 7.278 / 11.372 | 1.384 ms (100%)<br>1.005 ms (100%) | 301.9 / 245.8 | 594.4 / 497.5 | 223.72 / 223.72 |
| **D3DMetal (GPTK 4.0-1)** | cold / hot | `11_1` | 366.31 / 265.57 | 3.061 / 1.989 / 8.031 / 9.066<br>3.789 / 2.261 / 7.750 / 8.274 | N/A (0%)* | 1062.3 / 502.6 | 609.3 / 606.0 | 67.34 / 67.35 |

*\*D3DMetal 显式日志 `Unsupported: D3D11 timestamp query`，未估算替代。*

**核心实证发现（指导路由与打包门禁）**：
1. **`DXMT v0.80` 保持 DX11 第一默认引擎**：热态 `552.71 FPS`、最低 P95/P99 尾延迟（`4.388 / 7.980 ms`）、最低显存（`19.85 MiB`）与 `FL 11_1`。
2. **`DXVK + KosmicKrisp` 相比 `DXVK + MoltenVK` 具备显著 GPU 效率与代际优势**：
   - D3D11 GPU 耗时降至 **`0.508–0.647 ms`**（比 MoltenVK 快 `1.6×–2.7×`）；冷态 FPS 提升 **`+42.6%`**（`390.84` vs `274.01`），中位帧间隔 P50 降低 **28%–52%**，Warm-up 加快 ~`35%`；
   - 原生提供 **Vulkan `1.4.368`（CTS `1.4.6.2`）**、`VK_EXT_robustness2`（`robustBufferAccess2=1`、`nullDescriptor=1`）、`VK_KHR_timeline_semaphore=1` 与 `tessellationShader=1`。
   - **必须明确披露的打包前置门槛**：
     - 官方 LunarG Vulkan SDK `1.4.363.1` 自带的 `libvulkan_kosmickrisp.dylib`（SHA-256 `45fd5cb16d4f5e77bbb6eb232ec141e6e6a77876e7bad3fb90615f6c92e34504`）**仅含 `arm64` 切片**且 `geometryShader = false`，**不能**直接被当前 `x86_64` Rosetta 2 Wine + `DXVK` 加载；
     - 上游 Mesa `main`（commit `bb986060e01093a611b962b32fcc90b8d961b706`）已实现 `.geometryShader = true`，但尚未声明 `.fillModeNonSolid = true`；本次实测使用 Mesa `main` 交叉编译零第三方动态库依赖的 `x86_64` 切片 + 归档的最小评估补丁 `kosmickrisp-fillmode-eval.patch`（映射 Metal 原生 `MTLTriangleFillModeFill` / `MTLTriangleFillModeLines`，SHA-256 `f6b5a8347384646da4fe1a9ee515866dd7172165da1768e4b1488ef2809efc64`）。
     - **对窗口 4D 的打包要求**：在单 App 打包内，若集成 `KosmicKrisp` 驱动当前 `x86_64` Wine，必须打包包含 `x86_64` 切片且支持 `geometryShader + fillModeNonSolid` 的 `libvulkan_kosmickrisp.dylib` 与 universal `libvulkan.1.dylib`；若缺失或任一前置不满足，路由层自动安全回退 `MoltenVK`。

### 2.2 `DXMT v0.80` MetalFX Spatial 档位对照实测（`dxmt-metalfx-ab/manifest.json`，SHA-256 `61c8d0e12d8fa11184eaebe2469b88b4f398cfb68c24370790c0de4955c950dd`）

| DXMT MetalFX 档位（1280×720 输入） | 环境变量 | 缓存态 | 平均 FPS | 帧间隔 P50 / P95 (ms) | Probe Init (ms) | Warm-up (ms) | DXGI 显存 (MiB) |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| `off`（默认） | `DXMT_METALFX_SPATIAL_SWAPCHAIN=0` | cold / hot | 562.23 / 507.65 | 1.400 / 4.090<br>1.866 / 4.755 | 423.9 / **348.6** | 543.7 / 565.3 | **20.10 / 19.83** |
| `quality` (`1.5×`) | `DXMT_METALFX_SPATIAL_SWAPCHAIN=1`<br>`DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.5` | cold / hot | 609.46 / 586.69 | 1.319 / 3.342<br>1.312 / 3.996 | 527.2 / 379.1 | 632.8 / 528.0 | 49.48 / 49.48 (`+2.5×`) |
| `performance` (`2.0×`) | `DXMT_METALFX_SPATIAL_SWAPCHAIN=1`<br>`DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=2.0` | cold / hot | 385.70 / 514.28 | 2.176 / 7.063<br>1.472 / 5.194 | 674.2 / 498.6 | 821.8 / 673.5 | 80.97 / 80.97 (`+4.0×`) |

**策略依据**：
- `1.5×` 与 `2.0×` 档位会带来 **2.5× 至 4.0× 显存增长** 及明显更长的冷初始化耗时（`2.0×` 冷态 FPS 显著回落至 `385.70 FPS`、P95 增至 `7.063 ms`）；
- 因此 `DXMT` MetalFX Spatial **默认必须保持 `.off`**，并设置输出高度门槛（默认 `< 1080px` 自动保持关闭，除非用户显式强制开启），同时在热压力（`.balanced` / `.conserveEnergy`）下强制输出 `DXMT_METALFX_SPATIAL_SWAPCHAIN=0` 回退关闭。

---

## 3. `runtime-manifest.json` 版本与 SHA-256 锁定规范（供窗口 4D 集成）

建议窗口 4D 在 `runtime-manifest.json` 中新增 `vulkan_icd` 与 `graphics_backends` 不可变校验条目，启动前校验 SHA-256，校验失败立即降级并向 UI 暴露可读降级原因：

```json
{
  "vulkan_icd": {
    "vulkan_loader": {
      "version": "1.4.363.1",
      "source": "LunarG Vulkan SDK 1.4.363.1 (vulkansdk-macos-1.4.363.1.zip sha256=a65c707cf0a32bf8c2ca6b9af1985b7af61dbadfc19b352dae51a323f3a547a6)",
      "architectures": ["x86_64", "arm64"],
      "bundle_relpath": "Contents/Frameworks/libvulkan.1.dylib",
      "sha256": "0bcd62c6b3bcba4ef7c82344da3eb058892bb00b56b75ac6a6e7c8765a208c85"
    },
    "kosmickrisp": {
      "version": "mesa-27.0.0-devel-git-bb986060e0+fillmode-eval",
      "upstream_commit": "bb986060e01093a611b962b32fcc90b8d961b706",
      "eval_patch_relpath": "handoff/phase-4/evidence/p4-a/kosmickrisp-fillmode-eval.patch",
      "eval_patch_sha256": "f6b5a8347384646da4fe1a9ee515866dd7172165da1768e4b1488ef2809efc64",
      "architectures": ["x86_64"],
      "requires_macos_major": 26,
      "requires_apple_silicon": true,
      "bundle_relpath": "Contents/Frameworks/libvulkan_kosmickrisp.dylib",
      "sha256": "ed4615a26f74c7bece748cfb6bb3930fee379a2dcf3a634ca4e57c59a4bfdf63",
      "icd_manifest_relpath": "Contents/Resources/vulkan/icd.d/kosmickrisp_icd.json",
      "icd_manifest_sha256": "071ed10b672d291ee4dc6e9e81b444cb8608153bb4a84f9eff377e2818130336"
    },
    "moltenvk_fallback": {
      "version": "MoltenVK-v1.2.1",
      "architectures": ["x86_64"],
      "bundle_relpath": "Contents/Frameworks/libMoltenVK.dylib",
      "sha256": "952ef0be316e7a8694781ac8d68d4dccca403ef0710854c608414449e317de6e"
    }
  }
}
```

> **Bundle 内 ICD JSON 相对路径规范**：打包入 `.app` 后，`Contents/Resources/vulkan/icd.d/kosmickrisp_icd.json` 中的 `library_path` 应设为 `../../../Frameworks/libvulkan_kosmickrisp.dylib`（无硬编码绝对路径，支持任意磁盘或 `<EXTERNAL_VOLUME>` 移动运行），并在打包脚本中重新计算最终 `kosmickrisp_icd.json` 的 SHA-256 写入发行版 `runtime-manifest.json`。

---

## 4. 窗口 4A 已落地公共 Swift API 与窗口 4D 最小化接线指南

以下公共 API 已位于窗口 4A 独占文件并 100% 向后兼容既有调用方：

1. **`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/HostWineVulkanICD.swift`**：
   - `HostVulkanICD`（`.kosmicKrisp` / `.moltenVK`）
   - `HostVulkanICDAvailability`（校验 ICD 存在性、进程架构切片匹配、DXVK 必需特性 `geometryShader` / `fillModeNonSolid` 及库路径）
   - `HostWineBackendRouter.routeVulkanICD(hostSnapshot:available:preferKosmicKrisp:) -> HostVulkanICDRoute`
2. **`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/HostDXMTMetalFXPolicy.swift`**：
   - `HostDXMTMetalFXPreset`（`.off` / `.ultraQuality` `1.3` / `.quality` `1.5` / `.balanced` `1.7` / `.performance` `2.0`）
   - `HostDXMTMetalFXOptions`（默认 `.disabled`，内置 `< 1080px` 低分辨率保护）
   - `HostDXMTMetalFXPolicy`（解析实际生效档位、回退原因与真实消费者环境变量）
   - `HostWineLaunchPolicy.configured(snapshot:graphicsBackend:enabled:options:)`（兼容旧 3 参数 `init`，合并热节流与 MetalFX / Vulkan ICD 绑定）

### 建议窗口 4D 实施的接线步骤
1. **`Wine.swift`（ICD 环境变量注入规范）**：
   - 启动前先清理宿主机遗留的 `VK_DRIVER_FILES`、`VK_ICD_FILENAMES`、`WINE_SONAME_LIBVULKAN`，防止跨引擎串扰。
   - 当 `HostWineBackendRouter.route(...)` 选中 `.dxvk` 时，调用 `HostWineBackendRouter.routeVulkanICD(...)`：
     - 选中 `.kosmicKrisp`：注入 `WINE_SONAME_LIBVULKAN=<libvulkan.1.dylib>`、`VK_DRIVER_FILES=<kosmickrisp_icd.json>`、`VK_ICD_FILENAMES=<kosmickrisp_icd.json>`；
     - 回退 `.moltenVK`：注入 `WINE_SONAME_LIBVULKAN=<libMoltenVK.dylib>`，并**不设置** `VK_DRIVER_FILES` / `VK_ICD_FILENAMES`；同时在运行日志与 UI 状态栏记录 `icdRoute.reason`。
2. **`BottleSettings.swift` 与 UI（DXMT MetalFX 档位与 ICD 偏好）**：
   - 新增可选持久化字段（向后兼容旧 Bottle plist）：
     - `dxmtMetalFXPreset: HostDXMTMetalFXPreset = .off`（默认关闭）
     - `dxvkPreferKosmicKrisp: Bool = true`（仅在路由选中 DXVK 且满足 macOS 26+ Apple Silicon + ICD 完整性校验时生效，否则自动静默/显式提示回退 MoltenVK）
   - 通过 `HostWineLaunchPolicy.configured(...)` 构造启动策略，并使用 `applyingNonDestructively(to:)` 保留用户手动环境变量优先级。
3. **开发期重启验证**：窗口 4D 合入接线后，请运行 `./handoff/task-07/dev_restart.sh` 重建并重启 `Whisky.app` / `WhiskyCmd`，并执行产物级一致性门禁复核。
