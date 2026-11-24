# Phase 3-B 跨窗口接口与门禁接入提案（致总控 / 07 门禁）

日期：2026-11-22（Asia/Shanghai）
提案方：Phase 3-B（防外挂安全加固、免责声明与单 App 产品化整合）

---

## 1. 静态防外挂安全门禁与兼容矩阵编译脚本接入 `handoff/task-07/integration.py`

Phase 3-B 已在独占目录 `handoff/phase-3/evidence/p3-b/` 下交付两项零外部依赖、带 `--self-test` 负向变异反例自检的静态门禁脚本：

1. **防外挂安全加固与零作弊原语审计**：
   - 脚本路径：`<workspace>/handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py`
   - 建议接入命令：
     ```python
     ('anticheat-hardening-audit', [sys.executable, '-B', 'audit_anticheat_hardening.py', '--self-test'], root / 'handoff/phase-3/evidence/p3-b')
     ```
   - 覆盖范围：断言 `Whisky`、`WhiskyCmd`、`WhiskyThumbnail` 全部启用 `ENABLE_HARDENED_RUNTIME = YES`，所有 `.entitlements` 严禁开启 `get-task-allow` / `allow-dyld-environment-variables` / `disable-library-validation` / `allow-unsigned-executable-memory` / `allow-jit`，并扫描 100 份生产源码确保 0 跨进程内存读写/注入原语、0 虚拟化/硬件伪造参数、0 调试端口与合成键鼠宏注入接口（含 6 项负向变异自检）。
2. **兼容规则库单源编译校验**：
   - 脚本路径：`<workspace>/handoff/phase-3/evidence/p3-b/compile_compatibility_matrix.py`
   - 建议接入命令：
     ```python
     ('compatibility-matrix-compile', [sys.executable, '-B', 'compile_compatibility_matrix.py', '--self-test'], root / 'handoff/phase-3/evidence/p3-b')
     ```
   - 覆盖范围：从 `<workspace>/handoff/module-f/evidence.json` 单源编译生成 `<workspace>/Whisky/Whisky/Resources/compatibility-matrix.json`，保留 `source_snapshot_id`、VALORANT 国服/国际服 WoA 与 VM 双轴正交拆分及 7 条区域记录的五维状态。

---

## 2. `WhiskyCmd` CLI 免责声明与完整性诊断子命令可选接线建议

Phase 3-B 已在 `WhiskyKit`（位于独占路径 `Whisky/WhiskyKit/Sources/WhiskyKit/WhiskyWine/`）中暴露以下公开 API：
- `RuntimeIntegrityAttestor.currentReport() -> RuntimeIntegrityReport`
- `BundledCompatibilityMatrix.load(from:bundle:) -> BundledCompatibilityMatrix`
- `WhiskyWineInstaller.runtimeEnginesSummary(fileManager:libraryFolder:rosettaInstalled:) -> RuntimeEnginesStatusSummary`

总控在合入 `WhiskyCmd/Main.swift` 时，可按需在 CLI 顶层 `CommandConfiguration.discussion` 或 `integrity-report` 子命令中直接调用 `RuntimeIntegrityAttestor.currentReport()` 输出宿主机 SIP、代码签名与 Hardened Runtime 的诚实诊断 JSON。
