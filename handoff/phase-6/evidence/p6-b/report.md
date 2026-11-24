# Phase 6 窗口 6B 最终验收报告：宿主机全成果合龙、默认路由调优与统一集成版单 `.app` 发行

日期：2026-11-24  
署名：`@DNPMBHC`  
状态：**全部任务（6B-1、6B-2、6B-3）全绿验收通过。**

---

## 1. 核心交付与文件写入锁遵守情况

### 任务 6B-1：依据 5A 16,384 Draw 实测调优默认图形路由与三语文案
- 依据窗口 5A 16,384 Draw 高压力实测结论（`D3DMetal` 372.8 FPS、`DXVK + MoltenVK` 370.3 FPS、`DXMT` 339.5 FPS vs `DXVK + KosmicKrisp` 115.9 FPS）：
  - 保持 **DX11 默认 `DXMT`、DX12 默认 `D3DMetal`**、`DXMT MetalFX Spatial` 默认 `.off` 及热压力回退不变；
  - 在 `Whisky/WhiskyKit/Sources/WhiskyKit/Whisky/BottleSettings.swift` 与 `Whisky/Whisky/Views/Settings/SettingsView.swift` 将 `dxvkPreferKosmicKrisp` 及 `runtime.defaultPreferVulkanDriver` 默认值调整为 `false`（DXVK 路径默认优先 `MoltenVK` 保高 Draw 吞吐，保留 `KosmicKrisp (Vulkan 1.4)` 一键开关）；
  - 更新 `Whisky/Whisky/Localizable.xcstrings` 英/简中/繁中三语文案，如实说明 MoltenVK 高 Draw 吞吐与 KosmicKrisp Vulkan 1.4 特性取舍；
  - 更新 `Whisky/WhiskyKit/Tests/WhiskyKitTests/RuntimeDefaultGraphicsSettingsTests.swift` 回归测试。

### 任务 6B-2：5C 最小安全接线与统一基线自检摘要
- 新增 `Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/GoldenGuestManifestSummary.swift` 与 `Whisky/WhiskyKit/Tests/WhiskyKitTests/RuntimeGoldenGuestManifestTests.swift`：
  - 统一输出 `runtime-manifest.json` 锁版 SHA-256 指纹与各引擎组件校验状态；
  - 接入 `golden-guest-manifest.json`（窗口 6A 产出）读取与指纹校验，当前未初始化时优雅返回 `uninitialized` 状态提示；
  - 依据 `handoff/phase-5/evidence/p5-c/interface-proposal.md` 展示 5C `GuestSurface` 契约前置门禁状态（`Contract Rev 2 / Snapshot 4`、`supportsRealGuestScanout=false`、`supportsVirtualHIDSink=false`、`supportsSignedWindowsVZBoot=false`、`gameShellEntryEnabled=false` 受控关闭）。
- 在 `Whisky/Whisky/Views/Settings/SettingsView.swift`（`SettingsRuntimeManifestSection`）及 `Whisky/WhiskyCmd/`（`baseline-report` 子命令）接入三语诊断展示与 JSON 自检输出。

---

## 2. 统一集成版打包与四路产物性能一致性门禁（任务 6B-3）

1. **Release + Hardened Runtime 单 `.app` → `.dmg` 打包**（`handoff/task-07/release-package-manifest.json` / `handoff/phase-6/evidence/p6-b/release-package-manifest.json`）：
   - 产物均输出至仓库外临时目录，仓库内无新增 `>5 MiB` 产物；
   - `.dmg` 大小 `13652553` 字节（13.02 MiB），SHA-256 `addfc678135c7dab40ffc18ec937d87e2b82b01f66277975afc7882d8b3f3574`；
   - `hardenedRuntimeVerification.passed = true`、`bundlePurityPassed = true`、`requiredResourcesVerified = true`、`vulkanBackend.bundled = true`（实测 `geometryShader = true`、`fillModeNonSolid = true`）。
2. **四路后端（五条件）产物级性能一致性门禁**（`handoff/phase-6/evidence/p6-b/artifact-gate-report.json`，1280×720、120 预热、1800 测量帧、三轮算术均值）：
   - `dxmt`：**通过**（冷缓存吞吐比 `0.904` / 热缓存吞吐比 `0.9322`）
   - `dxmt_metalfx_quality`：**通过**（冷缓存吞吐比 `0.9291` / 热缓存吞吐比 `0.9875`）
   - `d3dMetal`：**通过**（冷缓存吞吐比 `0.9933` / 热缓存吞吐比 `1.002`）
   - `dxvk_backend-k`（KosmicKrisp）：**通过**（冷缓存吞吐比 `1.004` / 热缓存吞吐比 `1.0055`）
   - `dxvk_moltenvk`：**通过**（冷缓存吞吐比 `0.9194` / 热缓存吞吐比 `0.9217`）
   - `passed = true`、`backendCoverageComplete = true`、`allLockedComponentsVerified = true`、`releaseManifestMatchesArtifacts = true`。

---

## 3. 全套静态与运行时门禁复核

| 验证项 | 命令 | 结果 |
| --- | --- | --- |
| SwiftPM 单测 | `swift test --package-path Whisky/WhiskyKit` | **256 项（246 通过 / 10 显式跳过 / 0 失败）** |
| Strict SwiftLint | `swiftlint lint --strict --quiet` | **0 违规** |
| 格式门禁 | `python3 handoff/task-07/format_check.py` | **6/6 通过** |
| 防外挂静态审计 | `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` | **131 源码 + 6 反例通过** |
| 兼容矩阵自检 | `python3 handoff/phase-3/evidence/p3-b/compile_compatibility_matrix.py --self-test` | **7 条记录通过** |
| 自动重建重启闭环 | `./handoff/task-07/dev_restart.sh` | **通过** |
| 产物级性能门禁 | `python3 handoff/task-07/artifact_perf_gate.py --frames 1800` | **5/5 条件全绿通过** |

验收范围为同机同锁版运行时的合成 D3D11 探针与宿主静态/打包门禁，不据此宣称任何商业游戏通过；严格遵守文件写入锁，未触碰任何 VM 或禁止修改文件，未执行 `git commit / push / reset`。
