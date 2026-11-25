# 窗口 7B 任务书：宿主机诊断一体化集成与发行级单 `.app` 同步（🟡 中等难度 · 推荐 `Hydrogen Medium`）

署名：`@DNPMBHC`  
难度与模型建议：**🟡 中等难度 — 推荐 `Hydrogen Medium`**（路径清晰的标准 Swift/UI/CLI 工程，无需高阶额度）  
启动前提：**全程宿主机，不依赖 VM，可立即启动**  
请先阅读：`handoff/phase-7/README.md`、`handoff/phase-6/evidence/p6-b/report.md`、`handoff/phase-6/evidence/p6-a/golden-guest-manifest.json`

---

## 1. 独占可写路径（严格互斥）

- `Whisky/Whisky/`
- `Whisky/WhiskyCmd/`
- `Whisky/Whisky.xcodeproj/`
- `Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/Runtime*.swift`
- `handoff/task-07/`
- `handoff/phase-7/evidence/p7-b/`（新建）

严禁修改 `Whisky/Modules/guest-golden/`、`graphics-lab/`、窗口 7A 独占路径及任何 VM。

---

## 2. 核心任务拆解

在窗口 7A 独占黄金克隆攻关无畏契约黑屏的同时，窗口 7B 在宿主机端完成诊断一体化与用户易用性收口：

### 任务 7B-1（P0）：`WhiskyCmd` 与设置页一体化诊断升级
1. 完善 `WhiskyCmd baseline-report` 与设置页诊断视图，支持一键输出并展示：
   - 宿主机运行时锁版清单校验（`runtime-manifest.json`）；
   - 黄金 Guest 母盘状态（`golden-guest-manifest.json` 是否存在、WHQL `viogpu3d` 版本、`4C` 优化与安全不变量）；
   - 只读兼容矩阵对 `target-cn` 的最新实证摘要（已确认原生 ARM64 ACE `0xaa64` 加载、黑屏/点亮状态仍以 7A 最新结果为准，保持诚实边界）。
2. 为 `WhiskyCmd` 提供标准只读子命令包装或引导提示，方便用户/开发者快速核对外部卷 `<EXTERNAL_VOLUME>` 存储空间、运行时指纹与黄金母盘状态。

### 任务 7B-2（P1）：按窗口 7A `interface-proposal.md` 评估接纳最小化更新
1. 若窗口 7A 在完成前输出 `handoff/phase-7/evidence/p7-a/interface-proposal.md`（如新增诊断字段、只读兼容提示文案或参数展示），评估后按最小增量安全接入并补齐三语本地化与单测；若 7A 仍在运行，则保持 7B 主线独立闭环不阻塞。

### 任务 7B-3（P0）：统一集成版 Release + Hardened Runtime `.app` → `.dmg` 重打包与全门禁复核
1. 运行 `handoff/task-07/package_release_dmg.sh` 产出最新 `.app` → `.dmg`（输出到仓库外临时目录，仓库内绝不留存 `>5 MiB` 文件）；
2. 运行 `./handoff/task-07/dev_restart.sh` 完成重建 → 杀旧实例 → 自动重启验证；
3. 复跑 `artifact_perf_gate.py`（或快速产物完整性/五条件核验）、`swift test`、Strict SwiftLint（0 违规）、`format_check.py`、`audit_anticheat_hardening.py --self-test` 与 `compile_compatibility_matrix.py --self-test`。

---

## 3. 验收标准与交付物

1. `swift test --package-path Whisky/WhiskyKit` 全绿、Strict SwiftLint **0 违规**、`format_check.py` 全绿；
2. `audit_anticheat_hardening.py --self-test` & `compile_compatibility_matrix.py --self-test` 全绿；
3. `./handoff/task-07/dev_restart.sh` 自动重建重启实测通过；
4. `handoff/phase-7/evidence/p7-b/report.md`、`release-package-manifest.json` 落盘，零隐私泄露且无大文件残留。
