# 窗口 8B 任务书：宿主机诊断同步、静态显示引导与单 `.app` 同步验收（🟡 中等难度 · 推荐 `Hydrogen Medium`）

署名：`@DNPMBHC`  
难度与模型建议：**🟡 中等难度 — 推荐 `Hydrogen Medium`**（常规 Swift/UI/打包门禁收口，无需高阶额度）  
启动前提：**全程宿主机，不依赖 VM，可与 8A 并行或待 8A 出具 `interface-proposal.md` 后收口**  
请先阅读：`handoff/phase-8/README.md`、`handoff/phase-7/evidence/p7-b/report.md`、`handoff/phase-7/evidence/p7-a/interface-proposal.md`

---

## 1. 独占可写路径（严格互斥）

- `Whisky/Whisky/`
- `Whisky/WhiskyCmd/`
- `Whisky/Whisky.xcodeproj/`
- `Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/Runtime*.swift`
- `handoff/task-07/`
- `handoff/phase-8/evidence/p8-b/`（新建）

严禁修改 `Whisky/Modules/`、`graphics-lab/`、窗口 8A 独占路径及任何 VM。

---

## 2. 核心任务拆解

1. **同步 8A 最新实证状态与显示/指针引导**：
   - 接入窗口 8A 的 `handoff/phase-8/evidence/p8-a/interface-proposal.md`，将 `target-cn` 在黄金母盘上的最新实测结论（大厅/靶场可进入性、真实 FPS、`ACE-GAME.sys` 实际准入状态、静态分辨率与指针模式推荐配置）同步到 `WhiskyCmd baseline-report` 与设置页只读诊断展示（三语本地化）；
2. **发行级单 `.app` → `.dmg` 重打包与全门禁复核**：
   - 运行 `package_release_dmg.sh` 生成最新 Release + Hardened Runtime `.app` → `.dmg`（输出至仓库外临时目录，仓库内 zero `>5 MiB` 文件）；
   - 运行 `./handoff/task-07/dev_restart.sh` 完成自动重建重启验证闭环，并确保 `swift test`、Strict SwiftLint（0 违规）、`format_check.py`、`audit_anticheat_hardening.py --self-test` 与 `compile_compatibility_matrix.py --self-test` 全绿。

---

## 3. 验收标准与交付物

1. `swift test --package-path Whisky/WhiskyKit` 全绿、Strict SwiftLint **0 违规**、`format_check.py` 全绿；
2. `audit_anticheat_hardening.py --self-test` & `compile_compatibility_matrix.py --self-test` 全绿、`./handoff/task-07/dev_restart.sh` 通过；
3. `handoff/phase-8/evidence/p8-b/report.md` 与 `release-package-manifest.json` 落盘、零隐私泄露。
