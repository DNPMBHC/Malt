# 窗口 5D 任务书：单 App 实战冲刺 — `KosmicKrisp` 正式入包 + UI 策略暴露 + 四路产物级门禁（P0）

署名：`@DNPMBHC`  
启动前提：**全程宿主机，不依赖 VM，可立即启动**  
请先阅读：`handoff/phase-5/README.md`、`handoff/phase-4/evidence/p4-a/interface-proposal.md`、`handoff/phase-4/evidence/p4-d/report.md`、`handoff/phase-4/evidence/p4-d/artifact-gate-report.json`

---

## 1. 独占可写路径（严格互斥）

- `Whisky/Whisky/`
- `Whisky/WhiskyCmd/`
- `Whisky/Whisky.xcodeproj/`
- `Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Whisky/`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/Runtime*.swift`
- `handoff/task-07/`
- `handoff/phase-5/evidence/p5-d/`（新建）

严禁修改 `Host*.swift`、`UTM*.swift`、`GuestSurface*.swift`、`Whisky/Modules/` 与 `graphics-lab/`。

---

## 2. 核心任务拆解

Phase 4 已完成 `8.28 MiB` Release `.dmg` 瘦身、`BottleSettings`/`BottleGraphicsRouting` 的 `KosmicKrisp` & `DXMT MetalFX` 底层合龙，以及三引擎产物级性能一致性门禁。窗口 5D 本阶段把宿主机 Wine 单 App 打磨到**真正可面向日常 3D 游戏实战的发行级水准**：

### 任务 D1（P0）：`KosmicKrisp` 正式纳入 `runtime-manifest.json` 与 `.app` → `.dmg` 打包流水线
1. 依据窗口 4A 的 `handoff/phase-4/evidence/p4-a/interface-proposal.md`：
   - 升级 `Whisky/Whisky/Resources/runtime-manifest.json`（从 `pending-p4-a-proposal` / `reserved` 升级为正式锁版条目，锁死 `libvulkan.1.dylib`、`libvulkan_kosmickrisp.dylib`（`x86_64` 切片）与相对路径 `kosmickrisp_icd.json` 的真实 SHA-256）；
   - 确保 `kosmickrisp_icd.json` 使用相对路径（无硬编码绝对路径），可随 `.app` 任意移动或存放于 `<EXTERNAL_VOLUME>` 正常运行；
   - 更新 `handoff/task-07/package_release_dmg.sh`：验证打包后的 Release + Hardened Runtime `.app` 与 `.dmg` 依然保持轻量洁净（无源码/缓存泄露），并在校验缺失或不满足 macOS 26+ Apple Silicon 时自动显式回退 `MoltenVK`（绝不静默失效）。

### 任务 D2（P0）：App UI 正式暴露 `DXMT MetalFX Spatial` 与 `KosmicKrisp` 开关 + 防静默降级闭环
1. 在 `Whisky/Whisky/Views/Bottle/ConfigView.swift` 与 `SettingsView.swift` 中：
   - 暴露 **`DXMT MetalFX Spatial` 档位选择器**（默认 `Off`、可选 `Ultra Quality 1.3×` / `Quality 1.5×` / `Balanced 1.7×` / `Performance 2.0×`，并附简洁提示说明显存增长与 `<1080p` / 热压力自动关闭保护）；
   - 暴露 **`DXVK` 后端优先使用 `KosmicKrisp`（Vulkan 1.4 → Metal 4）** 开关与当前实际命中 ICD 状态（`KosmicKrisp` 命中 vs 回退 `MoltenVK` 原因可见）；
   - 补齐三语本地化（英 / 简中 / 繁中 `Localizable.xcstrings`）。
2. **强制执行开发期自动重启闭环**：每次修改 App 源码后，必须运行 `./handoff/task-07/dev_restart.sh` 验证重建 → 杀旧实例 → 自动重启最新 `.app` 正常启动且无崩溃。

### 任务 D3（P0）：四路产物级性能一致性门禁升级 + 评估接纳 5C 接口提案
1. 升级 `handoff/task-07/artifact_perf_gate.py`：
   - 直接驱动最新打包的 Release + Hardened Runtime `.app` 内嵌 CLI，实跑**四路后端**（`DXMT v0.80` / `D3DMetal` / **`DXVK + KosmicKrisp`** / `DXVK + MoltenVK`）+ `DXMT MetalFX` 显式开关校验；
   - 验证打包产物在 `DXVK + KosmicKrisp` 路径下确实加载了锁版 ICD（非静默退回 MoltenVK），GPU 耗时与吞吐与窗口 4A 实验室基线一致；
   - 若窗口 5A 产出新的高压力 3D 探针二进制，顺手在门禁中增加一条高压力场景产物对拍。
2. 如窗口 5C 交付了 `handoff/phase-5/evidence/p5-c/interface-proposal.md`，在门禁全绿前提下评估其最小化 UI 接入（若 5C 尚未完成则先封版 D1–D3，不阻塞主线）。

---

## 3. 验收标准与交付物

1. `WhiskyKit` SwiftPM 全部通过（含 `RuntimeManifestTests`、`RuntimeGraphicsRoutingTests` 等新增测试）；
2. Strict SwiftLint **0 违规**、`format_check.py` 全绿、`audit_anticheat_hardening.py --self-test` 全绿、`compile_compatibility_matrix.py --self-test` 全绿；
3. `./handoff/task-07/dev_restart.sh` 自动重建重启实测通过；
4. `handoff/phase-5/evidence/p5-d/report.md`、`artifact-gate-report.json`、`release-package-manifest.json`（含四路真机实跑数据、`.dmg` 体积与 SHA-256，且仓库内绝不留存 `>5 MiB` 的 `.app`/`.dmg`）。
