# 窗口 4A 任务书：Wine 图形天花板升级（开源 `KosmicKrisp` + `DXMT` MetalFX）（P0）

署名：`@DNPMBHC`  
启动前提：**无需等待 VM，可立即启动**  
请先阅读：`handoff/phase-4/README.md`、`graphics-lab/results.md`、`handoff/phase-2/evidence/window-c/interface-proposal.md`

---

## 1. 核心目标（借力社区开源成果，不造轮子）

1. **引入 Mesa 上游 `KosmicKrisp`（Vulkan 1.4 → Metal 4 原生驱动）**：
   - 当前 `DXVK` 兜底路径依赖旧版 `MoltenVK`（`DX11 → Vulkan → MoltenVK → Metal`，显存占 `223.7 MiB`、仅 `FL 11_0`）。
   - 调研并落地由官方 LunarG Vulkan SDK / Mesa 上游分发的开源 `KosmicKrisp` ICD，在同机器（Apple M4 / macOS 27.2.1）与同口径（`1280×720`、`120` 预热 + `900` 测量 × 3 轮冷/热）下完成**四路配对实测**：
     - `DXMT v0.80`（DX11 直译 Metal）
     - `D3DMetal (GPTK 4.0-1)`（DX12 主力 / DX11 候选）
     - **`DXVK + KosmicKrisp`（新：Vulkan 1.4 → Metal 4）**
     - `DXVK + MoltenVK`（旧基线对照）
   - 若本机尚未安装含 `KosmicKrisp` 的 LunarG Vulkan SDK / Mesa ICD，先给出最小化、可复现的获取/校验步骤（含 SHA-256 绑定），待确认后再执行实测，严禁伪造数据。
2. **将 `3Shain/dxmt` 开源的 MetalFX Spatial 策略推进到可控模式**：
   - 在 `HostResourcePolicy.swift` 与 `HostWineBackendRouter.swift` 中，结合实测数据设计：
     - 何时在 `DXVK` 路径优先选择 `KosmicKrisp` ICD（如检测到 macOS 26/27 + Apple Silicon + ICD 就绪，缺失时自动回退 `MoltenVK`）；
     - 面向高分辨率/高负载场景的可选 `DXMT_METALFX_SPATIAL_SWAPCHAIN` 控制策略（明确标注默认关闭或按用户画质策略开启，绝不破坏低分辨率小场景性能）。

---

## 2. 独占可写路径（严禁越界）

- `graphics-lab/wine_kosmickrisp_*`（新建测试脚本与对照工具）
- `graphics-lab/test_wine_kosmickrisp_*`（新建单元测试）
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/Host*.swift`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/Host*.swift`
- `handoff/phase-4/evidence/p4-a/`（新建，存放四路实测清单、SHA-256 绑定与给窗口 4D 的 `interface-proposal.md`）

> 严禁修改 `graphics-lab/d3d11_probe.cpp`、`metal_host.swift`（避免与 4B 冲突）或 `Whisky/Whisky/`、`BottleSettings.swift`、`Wine.swift`（统一通过 `handoff/phase-4/evidence/p4-a/interface-proposal.md` 交窗口 4D 合入）。

---

## 3. 验收标准与交付物

1. **四路同口径实测数据**：`handoff/phase-4/evidence/p4-a/wine-four-way-benchmark/manifest.json`（强制绑定全部源码、`d3d11_probe.exe`、`KosmicKrisp` ICD 二进制与缓存隔离 SHA-256，支持 `phase2_evidence.py` 逐字节校验）。
2. **代码与门禁全绿**：
   - `swift test --package-path Whisky/WhiskyKit --filter Host`（0 失败）
   - Strict SwiftLint 0 违规
   - `cd graphics-lab && python3 -B -m unittest discover -v`（含 `test_metalfx_sdk_compile.py` 未跳过）
   - `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` 通过
3. **跨窗口提案**：`handoff/phase-4/evidence/p4-a/interface-proposal.md`（明确 `runtime-manifest.json` 中 `KosmicKrisp` 的版本/SHA-256 锁定要求与 ICD 环境变量注入规范，供窗口 4D 集成进单 App 打包）。
4. 全部输出保持中性占位符与隐私脱敏，署名 `@DNPMBHC`，不执行 `git commit / push`。
