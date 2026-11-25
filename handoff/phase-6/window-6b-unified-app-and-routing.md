# 窗口 6B 任务书：宿主机全成果合龙、默认路由调优与统一集成版单 `.app` 发行验收（P0）

署名：`@DNPMBHC`  
启动前提：**全程宿主机，不依赖 VM，可立即启动**（若窗口 5C 仍在收尾，先完成路由调优与清单整合，待 5C 最终封版后再合入 5C 最终接口）  
请先阅读：`handoff/phase-6/README.md`、`handoff/phase-5/evidence/p5-d/report.md`、`handoff/phase-5/evidence/p5-a/real3d-baseline-report.md`、`handoff/phase-5/evidence/p5-c/interface-proposal.md`

---

## 1. 独占可写路径（严格互斥）

- `Whisky/Whisky/`
- `Whisky/WhiskyCmd/`
- `Whisky/Whisky.xcodeproj/`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Whisky/`
- `Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/Runtime*.swift`
- `handoff/task-07/`
- `handoff/phase-6/evidence/p6-b/`（新建）

严禁修改 `Whisky/Modules/guest-golden/`、`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/GuestSurface*.swift`、`UTM*.swift`、`Host*.swift` 与 `graphics-lab/`。

---

## 2. 核心任务拆解

把 Phase 4–5 宿主机侧全部已验证能力收口到一个**策略最优、版本统一、开箱即用**的集成发行版单 `.app` / `.dmg`：

### 任务 6B-1（P0）：依据 5A 16,384 Draw 实测数据调优 Wine 默认图形路由与 UI 文案
1. 窗口 5A 的 16,384 Draw 高压力实测证实：
   - `D3DMetal`（`372.8 FPS`）、`DXVK + MoltenVK`（`370.3 FPS`）、`DXMT v0.80`（`339.5 FPS`）显著快于当前版本的 `DXVK + KosmicKrisp`（`115.9 FPS`）；
2. 在 `BottleSettings.swift`、`BottleGraphicsRouting.swift` 与三语 UI（`ConfigView.swift` / `SettingsView.swift` / `Localizable.xcstrings`）中收口默认策略：
   - 保持 **DX11 默认 `DXMT`、DX12 默认 `D3DMetal`**；
   - 在 `DXVK` 路径下将默认 `dxvkPreferKosmicKrisp` 调整为 **`false`（默认优先 `MoltenVK` 保高 Draw 稳定吞吐）**，同时保留 `KosmicKrisp (Vulkan 1.4)` 一键可选开关，并在三语提示中如实说明两者取舍（Vulkan 1.4 特性 vs 当前高 Draw 吞吐），绝不误导用户；
   - 保持 `DXMT MetalFX Spatial` 默认 `.off` 及热压力自动回退。

### 任务 6B-2（P0）：整合 5C 最终稳定接口、4C 优化器与 6A 黄金镜像清单状态展示
1. 在确认窗口 5C 封版后，按 `handoff/phase-5/evidence/p5-c/interface-proposal.md` 完成最小化、零越权的主 App / CLI 接线（如未满足前置真实 scanout/HID 条件，保持生产实验开关显式可见与安全受控）；
2. 在 `WhiskyCmd` 与设置诊断页中接入对 `golden-guest-manifest.json`（窗口 6A 产出，缺失时优雅显示未初始化提示）与本地运行时锁定指纹（`runtime-manifest.json`）的统一自检摘要，让用户/测试者一眼确认当前宿主机运行时与黄金 Guest 基线完全对齐。

### 任务 6B-3（P0）：重打全集成版 Release + Hardened Runtime `.app` → `.dmg` 与全绿验收
1. 运行 `handoff/task-07/package_release_dmg.sh` 生成最新统一集成版 `.app` 与 `.dmg`（输出至仓库外临时目录，严禁在仓库内留存 `>5 MiB` 产物）；
2. 运行 `./handoff/task-07/dev_restart.sh` 完成开发期自动重建 → 杀旧实例 → 重启验证闭环；
3. 重跑 `handoff/task-07/artifact_perf_gate.py` 确认集成版产物四路后端无退化，并汇总 `handoff/task-07/report.md` 与 `handoff/phase-6/evidence/p6-b/report.md`。

---

## 3. 验收标准与交付物

1. `swift test --package-path Whisky/WhiskyKit` 全部通过（含路由默认策略调整后的回归测试）；
2. Strict SwiftLint **0 违规**、`format_check.py` 全绿、`audit_anticheat_hardening.py --self-test` 全绿、`compile_compatibility_matrix.py --self-test` 全绿；
3. `./handoff/task-07/dev_restart.sh` 自动重建重启实测通过；
4. `handoff/phase-6/evidence/p6-b/report.md`、`release-package-manifest.json` 与 `artifact-gate-report.json` 全部落盘、零隐私泄露。
