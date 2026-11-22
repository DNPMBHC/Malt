# 窗口 B：`module-a` 双副本去重与唯一真源治理报告

采集日期：2026-11-22（Asia/Shanghai）
唯一真源路径：`<workspace>/Whisky/Modules/module-a/`
兼容映射路径：`<workspace>/Modules/module-a -> ../Whisky/Modules/module-a`（相对符号链接）

---

## 1. 治理前双副本差异核查

在执行去重前，对 `<workspace>/Modules/module-a` 与 `<workspace>/Whisky/Modules/module-a` 进行了完整非构建产物 `diff -ru` 及 SHA-256 逐文件比对：

| 相对路径 | 顶层 `Modules/module-a` SHA-256 | `Whisky/Modules/module-a` SHA-256 | 差异说明 |
| --- | --- | --- | --- |
| `WindowsProbe/CMakeLists.txt` | `5f1374fe56bd9cd2a37f116dd217763f0e4216fe99fef554c28590069a769b2f` | `5f1374fe56bd9cd2a37f116dd217763f0e4216fe99fef554c28590069a769b2f` | 完全一致 |
| `WindowsProbe/client/probe.c` | `c7f5afaceedb8c769ae2a173521d0153ff0f311f02849be18fc6130dce8dfd97` | `c7f5afaceedb8c769ae2a173521d0153ff0f311f02849be18fc6130dce8dfd97` | 完全一致 |
| `WindowsProbe/driver/ModuleAProbe.vcxproj` | `3c98ab0967c2adc8a40a98989bd47997f50c0bf883813b8b98de4a7408d9cc09` | `3c98ab0967c2adc8a40a98989bd47997f50c0bf883813b8b98de4a7408d9cc09` | 完全一致 |
| `WindowsProbe/driver/module_a_driver.c` | `7fc2edb891b474ba0d5cb28ffc84b33785d045b0adc988e744d5e430ba3d79ca` | `7fc2edb891b474ba0d5cb28ffc84b33785d045b0adc988e744d5e430ba3d79ca` | 完全一致 |
| `WindowsProbe/shared/module_a_protocol.h` | `fcbb0f25265753d98b25c6b835a35fdc5009eb43dedfe7c35c4c67947cdd92a6` | `fcbb0f25265753d98b25c6b835a35fdc5009eb43dedfe7c35c4c67947cdd92a6` | 完全一致 |
| `WindowsProbe/tests/protocol_abi_test.c` | `fe13b19ced6c27813ac5f5ec8298cc09da3c0b78ebc0cb45171096d4ed161f38` | `fe13b19ced6c27813ac5f5ec8298cc09da3c0b78ebc0cb45171096d4ed161f38` | 完全一致 |
| `WindowsProbe/README.md` | `d338b87082af3219869d4eb0681a6c75766a41e601c8897e5b59d563ed6a34a9` | `8f2e17458d6f13f986135391ea89a8d1d2a2184eed6e2f79b271c7014d23c86a` | `Whisky/Modules/module-a` 更新（补充了生命周期脚本失败阶段保留已采集 JSON 证据的说明） |
| `WindowsProbe/tests/verify-lifecycle.ps1` | `f30d3371a460a328b403c26ef54116d73ef4990a91db1cf27831ebb22a0ef592` | `639ad94c0ba1ff52a84250a28daef0025633658a5db1e8919c3701513ef4840a` | `Whisky/Modules/module-a` 更新（外层增加 `try/catch`，在异常抛出前输出 `$script:Events` JSON） |
| `WindowsProbe/.gitignore` | `3ced942715e487f66e90c7c393d69d88b95a90f23325bfab9b4033123562ad16` | （未单独存在，由子仓库根 `.gitignore` 管控） | 保持 `Whisky/` 子仓库 171 项构建输入快照稳定 |

---

## 2. 全仓脚本引用核查与去重执行

1. **引用扫描**：
   - `handoff/task-07/verify.py` 的 `source_snapshot()` 扫描 `<workspace>/Whisky/` 子仓库，记录其下的 `Modules/module-a/WindowsProbe/*` 共 8 份源文件（属于 171 项构建输入基线）。
   - `handoff/task-07/integration.py` 第 43 行与第 108 行引用 `<workspace>/Modules/module-a/WindowsProbe`。
2. **去重措施**：
   - 清理两侧残留的 `WindowsProbe/.build` 本地 CMake 缓存目录。
   - 确认以 `<workspace>/Whisky/Modules/module-a` 为唯一物理真源。
   - 移除顶层重复物理副本 `<workspace>/Modules/module-a`，并在原路径建立相对符号链接 `Modules/module-a -> ../Whisky/Modules/module-a`。
   - 效果：彻底消除双副本物理漂移，同时保证窗口 D 维护的 `handoff/task-07/integration.py` 在合入路径切换提案前零中断通过；`diff -ru Modules/module-a Whisky/Modules/module-a` 差异为 0。

---

## 3. 重建与回归测试记录

遵循“终止残留测试进程 → 全新编译 → 运行新产物”的验证流程：

1. **可移植协议 ABI 测试（CTest）**：
   - 命令：`cmake -S Whisky/Modules/module-a/WindowsProbe -B <temp-build> && cmake --build <temp-build> && ctest --test-dir <temp-build> --output-on-failure -V`
   - 结果：`1/1 Test #1: protocol_abi ... Passed (100% tests passed, 0 failures)`。
2. **SwiftPM 反作弊探针测试（`AntiCheatProbeTests`）**：
   - 命令：`swift test --package-path Whisky/WhiskyKit --filter AntiCheatProbeTests`
   - 结果：`Executed 30 tests, with 0 failures (0 unexpected)`。

---

## 4. 五维状态声明

| 维度 | 状态 | 说明 |
| --- | --- | --- |
| 代码实现 | `passed` | `Whisky/Modules/module-a` 唯一真源治理完成，v2 协议 ABI、驱动/客户端源码与生命周期脚本齐备 |
| 本机合成验证 | `passed` | 本机 CTest `1/1` 与 SwiftPM `AntiCheatProbeTests` `30/30` 全部通过 |
| 真实 Guest/Wine 验证 | `not_tested` | 待窗口 A Windows Guest 就绪后，在 Guest 内执行 WDK 编译、测试签名与 `verify-lifecycle.ps1` |
| 厂商支持 | `unknown` | 自有探针仅用于诊断 Guest 内核执行环境，不代表任何厂商立场 |
| 真实游戏验证 | `not_tested` | 自有探针通过不等于商业反作弊驱动加载或受保护在线会话可用 |
