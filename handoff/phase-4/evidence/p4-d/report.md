# Phase 4 窗口 4D 交付报告：单 App 易用性打包 + 产物级性能一致性门禁 + 总验收刷新

日期：2026-11-23  
署名：`@DNPMBHC`  
范围：窗口 4D 独占路径（未触碰 `Host*.swift`、`UTM*.swift`、`WindowsGuest*.swift`、`Wine.swift`、`graphics-lab/` 及任何 VM）

---

## 1. 核心交付成果

### 1.1 总验收报告全绿 `3/3` 基线刷新（任务 D1）
- 已更新 `handoff/task-07/report.md`、`handoff/task-07/evidence/gate-status.json` 与 `handoff/phase-2/evidence/window-d/gate-summary.json`，对齐最新 `3/3` 全绿实证基线（窗口 A A2+M0/M1、窗口 B 原生 ARM64 驱动全周期与 `target-cn` `observed_amd64_only_in_sample` 动态采样及 Secure Boot 恢复、窗口 C Wine 三引擎 18 组与 M2 9 轮跨 VM `18.847` vs `15.673` vs `7.096 FPS` / `88 B` 缓存帧 / `0.881 ms` Metal GPU）。
- `RemotePhysicsBackend` 保持冻结状态（仅保既有单测全绿，未扩展新串流功能）。

### 1.2 运行时锁版清单、外接卷存放引导与防静默降级 UX（任务 D2）
- **版本锁死清单**：新增并随单 `.app` 打包 `Resources/runtime-manifest.json`（Schema `1.0.0`，锁死 `Wine Core`、`DXMT v0.80`、`D3DMetal Apple GPTK 4.0-1`、`DXVK 1.10.3 + MoltenVK 1.2.1` 共 10 个核心二进制的实验室实测 SHA-256，并预留 `kosmicKrisp` 槽位供窗口 4A 提案合入）；在 `WhiskyKit/Sources/WhiskyKit/WhiskyWine/RuntimeManifest.swift` 实现基于 `CryptoKit.SHA256` 的真实字节校验器（`verified` / `mismatch` / `missing` / `reserved`）与 `RuntimeManifestTests.swift` 单测。
- **外接卷 `<EXTERNAL_VOLUME>` 一键存放引导**：升级 `WhiskyWineInstaller.swift` 支持动态运行时路径（环境变量 `WHISKY_RUNTIME_ROOT` + `UserDefaults` 持久化 + 仅清理 `Libraries` 保护自定义根目录）、可用空间计算与可写外接卷枚举；在设置页与初始化引导中展示可用空间并提供一键切换至外接卷，缓解内置系统盘空间紧张痛点。
- **防静默降级 UX**：新增三语（英/简中/繁中）`GraphicsFallbackWarningBanner` 与设置页锁版指纹状态区，当图形路由发生降级（`usedFallback == true`）、引擎缺失或 SHA-256 指纹不一致时显式告警。

### 1.3 Release + Hardened Runtime 单 `.app` → `.dmg` 打包与产物级性能一致性门禁（任务 D3）
- **自动化打包流水线（`handoff/task-07/package_release_dmg.sh`）**：
  - 强制 `Release / arm64`、`ENABLE_HARDENED_RUNTIME=YES`、`CODE_SIGNING_ALLOWED=NO`（本地无签名可复现构建），输出至仓库外临时目录（严禁将 `> 5 MiB` 的 `.app`/`.dmg` 留存仓库内）。
  - 产物纯洁性门禁成功捕获并修复了一处上游工程遗留缺陷：`PBXResourcesBuildPhase` 此前误将整个 `WhiskyKit` 源码与 `.build` 目录拷入 `.app/Contents/Resources/`；移除该错误项后，`.dmg` 体积从 **250 MiB** 瘦身 96.7% 至 **8.28 MiB**（`8,679,684` 字节，`release-package-manifest.json` 记录全部 SHA-256），且严格通过 `compatibility-matrix.json` / `runtime-manifest.json` 完整性与零开发文件泄露校验。
- **产物级性能一致性门禁（`handoff/task-07/artifact_perf_gate.py`）**：
  - 直接驱动刚刚打包产出的 Release + Hardened Runtime 单 `.app` 内嵌生产 CLI，在隔离 `CFFIXED_USER_HOME`（自动选用高剩余空间外接卷做沙盒并在单引擎测完后即时清理）与零拷贝挂载的锁定三引擎运行时下，真实拉起 `d3d11_probe.exe`（1280×720，60 预热 + 180 测量帧）。
  - 首轮实测主动暴露并修复了 `BottleGraphicsRouting.swift` 未为独立目录布局的 `D3DMetal` / `DXVK` 自动注入 `WINEDLLPATH`、`WINE_GPTK_LIBD3DSHARED_PATH`、`DYLD_FRAMEWORK_PATH`、`WINE_SONAME_LIBVULKAN` 与 Bottle 级 `DXVK_STATE_CACHE_PATH` 的生产短板；修复重打包后三引擎全绿通过（详见 `artifact-gate-report.json`）：

| 引擎 | 打包产物实测 FPS | 实验室冷态基线 FPS | 比值 | 打包产物显存 | 实验室基线显存 | 环境注入与锁版校验 |
| :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| **DXMT v0.80** | `408.75 FPS`（P50 `0.933 ms`） | `366.98 FPS` | `1.11×` | `20.75 MiB` | `20.15 MiB` | `DXMT_SHADER_CACHE=1`、`dxmt_shader_cache`、`WINEDLLPATH` 全生效，GPU 时间戳 `100%` |
| **D3DMetal (GPTK 4.0-1)** | `789.12 FPS`（P50 `0.497 ms`） | `309.55 FPS` | `2.55×` | `67.55 MiB` | `67.34 MiB` | `WINE_GPTK_LIBD3DSHARED_PATH`、`DYLD_FRAMEWORK_PATH`、`WINEDLLPATH` 全生效 |
| **DXVK 1.10.3 + MoltenVK** | `396.46 FPS`（P50 `1.489 ms`） | `324.12 FPS` | `1.22×` | `223.70 MiB` | `223.72 MiB` | `WINE_SONAME_LIBVULKAN`、`DXVK_STATE_CACHE_PATH`、`WINEDLLPATH` 全生效，GPU 时间戳 `100%` |

---

## 2. 合规与边界说明

- 全部门禁验证均基于自有合成探针 `d3d11_probe.exe` 与生产打包 `.app`/CLI，**不声称任何受保护商业游戏或反作弊会话已通过**。
- 防外挂静态安全门禁（`audit_anticheat_hardening.py --self-test`）、兼容矩阵编译校验（`compile_compatibility_matrix.py --self-test`）、Strict SwiftLint、SwiftPM、开发期自动重建重启脚本 `./handoff/task-07/dev_restart.sh` 与隐私脱敏审计均已验证通过。
