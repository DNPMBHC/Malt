# 窗口 4D 任务书：单 App 易用性打包 + 产物级性能一致性门禁 + 总验收刷新（P0）

署名：`@DNPMBHC`  
启动前提：**不依赖 VM，可立即启动**  
请先阅读：`handoff/phase-4/README.md`、`handoff/task-07/report.md`、`handoff/phase-3/anti-cheat-abuse-hardening-and-packaging.md`

---

## 1. 核心目标

聚焦用户最核心的交付诉求：**“打包后的便捷性、易用性，以及确保打包产物和实验室成果性能 100% 一致”**，同时完成 Phase 2 终版全绿总报告刷新。

---

## 2. 具体实施任务

### 任务 D1：刷新 Phase 2 终版全绿总报告（立即执行）
1. 运行最新全量 `handoff/task-07/integration.py`（当前 `phase2_evidence.py` 已 `3/3` 全满贯通过），更新：
   - `handoff/task-07/report.md`：正式收录窗口 B 的商业安装器双轴动态采样终结论（`observed_amd64_only_in_sample` + 基线恢复）、窗口 C 的 M2 三模式 9 轮跨 VM 实测终数据（`18.847` vs `15.673` vs `7.096 FPS`，`88 B` 缓存帧、`0.881 ms` Metal GPU）与 `3/3` 全绿门禁；
   - 刷新 `handoff/task-07/evidence/gate-status.json` 与 `handoff/phase-2/evidence/window-d/gate-summary.json`。
2. 保持 `RemotePhysicsBackend` 冻结状态（不再扩展新串流功能，确保既有单测持续通过）。

### 任务 D2：三引擎运行时版本锁死、外接盘存放引导与防静默降级 UX
1. **运行时版本锁死清单（`Whisky/Whisky/Resources/runtime-manifest.json`）**：
   - 以结构化 JSON 锁死实验室实测通过的引擎版本与 SHA-256 指纹（`DXMT v0.80`、`D3DMetal GPTK 4.0-1`、`DXVK 1.10.3`，并预留 `KosmicKrisp` 槽位待合入窗口 4A 提案）；
   - 提供运行时指纹校验工具类（放于 `WhiskyKit/Sources/WhiskyKit/WhiskyWine/`），启动与设置页可校验本机已安装引擎是否与推荐锁定版本匹配。
2. **外接盘存放与零门槛易用性优化**：
   - 在运行时/容器设置中支持用户一键选择将重型运行时与容器存放到外接卷（解决 Mac 内置 SSD 空间紧张痛点），配合已有的 `RuntimeStoragePreflight` 展示剩余空间；
   - **杜绝静默降级吃性能**：当 `HostWineBackendRouter` 因缺少 `DXMT` 或 `D3DMetal` 触发 `usedFallback == true` 回落至低效引擎时，在 UI 展示清晰的三语提示（英/简中/繁中）与一键补齐引导。

### 任务 D3：自动化 `.app` → `.dmg` 打包流水线 + **产物级性能一致性门禁**（核心！）
1. **自动化打包脚本（`handoff/task-07/package_release_dmg.sh`）**：
   - 支持无签名本地 Release/Debug `.app` 构建（强制启用 `ENABLE_HARDENED_RUNTIME = YES`，打包验证 `Contents/Resources/compatibility-matrix.json` 与 `runtime-manifest.json` 完整存在，不打包任何 `graphics-lab/`、`Modules/module-a/` 或开发日志），输出干净的 `.dmg` 安装镜像与 SHA-256 清单。
   - 同时保留并验证开发期自动重建重启脚本 `./handoff/task-07/dev_restart.sh`。
2. **产物级性能一致性门禁（`handoff/task-07/artifact_perf_gate.py`）**：
   - 绝不只测开发期源码！直接指向**刚刚打包产出的最终 `.app` 内的生产 CLI 二进制**，在隔离 `CFFIXED_USER_HOME` 沙盒中拉起真实 `d3d11_probe.exe`（短跑验证轮，如 60 预热 + 180 测量帧），强制断言：
     1. 最终打包产物在开启 `Hardened Runtime` 下无任何引擎动态库加载失败；
     2. 实际生效的图形路由、环境变量（`WINEDLLPATH`、`DXMT_SHADER_CACHE=1`、Bottle 级缓存路径）与 `HostResourcePolicy` 100% 生效；
     3. 实测帧率与 DXGI 显存占用落在实验室三引擎基线的合理阈值区间内（并输出脱敏对比 JSON 报告绑定 `.app` 二进制与引擎 SHA-256）。
3. **跨窗口提案响应**：待窗口 4A 提交 `KosmicKrisp` 接入提案后，统一审阅并合入 `runtime-manifest.json`、`WhiskyWineInstaller` 与 `Wine.swift`。

---

## 3. 独占可写路径（严禁越界）

- `Whisky/Whisky/`
- `Whisky/WhiskyCmd/`
- `Whisky/Whisky.xcodeproj/`
- `Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/Runtime*.swift`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Whisky/`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/Runtime*.swift`
- `handoff/runtime-interface.md`
- `handoff/task-07/`
- `handoff/phase-4/evidence/p4-d/`（新建）

---

## 4. 验收标准与交付物

1. 刷新后的 `handoff/task-07/report.md`、`gate-status.json`（`3/3` 全绿真实证据状态）。
2. `runtime-manifest.json`、运行时校验与防静默降级 UI（英/简中/繁中三语）及对应单元测试。
3. `package_release_dmg.sh` 与 `artifact_perf_gate.py` 实跑通过的脱敏验收报告（`handoff/phase-4/evidence/p4-d/artifact-gate-report.json`，输出 `.dmg` 构建在临时输出目录且不进入 Git 跟踪）。
4. 全量门禁保持 0 退化：SwiftPM 全通（0 失败）、Strict SwiftLint 0 违规、`format_check.py` 6/6、`audit_anticheat_hardening.py --self-test` 通过、`compile_compatibility_matrix.py --self-test` 通过、`dev_restart.sh` 重建重启通过。
5. 保持中性占位符，署名 `@DNPMBHC`，不执行 `git commit / push`。
