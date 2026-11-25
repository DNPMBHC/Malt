# 窗口 B：诊断探针唯一真源治理与 B2 实测复核

复核日期：2026-11-22（Asia/Shanghai）。本报告使用中性来源别名，不包含真实本地路径、仓库名称或个人标识。

## 当前结论

探针保持一个物理源码目录和一个相对符号链接兼容入口。当前 9 个源文件的 SHA-256 与 `b2-source-manifest.json` 逐项一致；源码归档 SHA-256 为 `a09b18e4f84ba8617129238ce513adf935086bbda8ce641ce8affcacb7fa7e4d`。

在真实 Windows 11 24H2 ARM64 Guest（Build 26100）内，诊断驱动和采集端已完成 ARM64 编译、有效测试签名及三段生命周期实测。证据覆盖驱动加载、设备控制、调用进程身份、子进程创建/退出通知、卸载、缺失映像的启动失败，以及真实重启后需求启动服务保持停止。自有诊断结果不扩展为商业反作弊或受保护游戏会话结论。

## B1 历史治理与当前引用

治理前的双副本比对属于历史记录：构建配置、客户端、驱动工程、驱动源码、共享协议和 ABI 测试相同；说明文档与生命周期脚本有更新差异。治理时保留更新后的物理真源，移除重复物理副本并建立相对符号链接，兼容入口现在解析到同一个源码目录。

旧报告中的 8 文件清单、固定行号及旧构建输入快照仅代表当时基线。新增脚本自测及后续协议/生命周期修复已纳入当前 9 文件清单。本次实时引用扫描确认 `integration.py` 有 3 个探针目录引用，`verify.py` 有 0 个直接探针目录引用；不以历史固定行号说明当前脚本行为。

## 当前源码指纹

来源编号顺序与 `b2-source-manifest.json` 一致。

| 中性来源编号 | 文件作用 | 当前 SHA-256 |
| --- | --- | --- |
| `source-001` | 构建配置 | `5f1374fe56bd9cd2a37f116dd217763f0e4216fe99fef554c28590069a769b2f` |
| `source-002` | 说明文档 | `eed4c51e0069f59632b1aae9fdedc4effcd5a6d2d83f075dca6ec5f8fd14974a` |
| `source-003` | 采集端源码 | `c7f5afaceedb8c769ae2a173521d0153ff0f311f02849be18fc6130dce8dfd97` |
| `source-004` | 驱动工程 | `3c98ab0967c2adc8a40a98989bd47997f50c0bf883813b8b98de4a7408d9cc09` |
| `source-005` | 驱动源码 | `7fc2edb891b474ba0d5cb28ffc84b33785d045b0adc988e744d5e430ba3d79ca` |
| `source-006` | 共享协议 | `db8bb97e5b78753a31519b09791c1eff5495e5b07c90174461dcf038c7482c58` |
| `source-007` | 协议 ABI 测试 | `fe13b19ced6c27813ac5f5ec8298cc09da3c0b78ebc0cb45171096d4ed161f38` |
| `source-008` | 生命周期脚本自测 | `5c278765ec645910458132d357c3aeda9851809c184b38caa5459da5094ee2a6` |
| `source-009` | 生命周期实测脚本 | `fa4ea000db5d3c1c201e0631e3fde57fea59fdf5a81f1aa1e80b93585464d46c` |

## 验证证据与结果边界

| 验证项 | 结果 | 证据与含义 |
| --- | --- | --- |
| 可移植协议 ABI | `passed` | CTest 1/1；验证共享协议的结构大小、布局及版本约束 |
| 本机探针相关 Swift 测试 | `passed` | 30/30；含全新隔离构建目录验证，复用已有依赖缓存并禁用自动依赖解析 |
| 生命周期脚本自测 | `passed` | `b2-lifecycle-selftest-retry-result.json`；检查报文类型、身份、路径、重启及失败分支，旧失败结果保留为历史排障证据 |
| 真实 ARM64 构建 | `passed` | `b2-build-native-result.json`；驱动与采集端均为 `0xaa64 ARM64`，本机构建退出码 0 |
| 测试签名 | `passed` | `b2-owned-test-signing-result.json`；两份二进制签名均为 `Valid`，使用自有测试证书；测试签名环境与后续商业采样环境分别记录 |
| cycle | `passed` | `b2-lifecycle-cycle-result.json`；传输退出码 0，加载与通知断言通过；卸载后打开设备返回 error 2；缺失映像服务启动也返回原生 error 2 |
| before-reboot | `passed` | `b2-lifecycle-before-reboot-result.json`；加载/卸载通过，需求启动服务停止且为 Manual，保存启动时间及签名后哈希基线 |
| after-reboot | `passed` | `b2-lifecycle-after-reboot-result.json`；`actualRebootObserved=true`、`artifactsUnchanged=true`，需求启动服务仍停止，重新加载与卸载通过 |
| 自有测试环境清理 | `passed` | `b2-cleanup-owned-signing-result.json`；自有服务/证书移除，测试签名恢复到原先未设置的状态 |
| 安全环境恢复 | `passed` | `b2-restored-security-result.json`；真实重启后 Secure Boot 开启、TPM 2.0 启用、Hypervisor 存在，VBS/HVCI 未运行 |
| 证据工具回归 | `passed` | `b2-evidence-tools.py validate --self-test`：22 项回归通过 |
| 当前观测文件与附件 | `passed` | `b2-evidence-tools.py validate --verify-files b2-local-observations.json`：当前 12 个附件的文件完整性通过；该报告仍为 `in_progress` |

三个加载阶段均返回 schema/protocol 2 与 32 字节有效载荷，ARM64 候选映像/采集端/已加载驱动一致，nonce、服务映像身份、进程对象、请求进程上下文/PID 与子进程绑定/退出清理断言均通过。卸载后的 `notLoaded` 和打开设备 error 2 是预期否定检查。

签名后驱动 SHA-256：`d301f2f26cf1ae93c419e094d83e0a308439527edd55db3d824e567ece90b353`。

签名后采集端 SHA-256：`9f96cf668c9e2e30909ac287878b4f740773829268b6f49753e1a3474e57b008`。

## 五维状态声明

| 维度 | 状态 | 结论范围 |
| --- | --- | --- |
| 代码实现 | `passed` | 唯一物理真源、共享协议、驱动/采集端与生命周期脚本实现已完成 |
| 本机合成验证 | `passed` | ABI、相关 Swift 测试及生命周期脚本自测通过 |
| 真实 Guest 验证 | `passed` | 仅指 Windows 11 24H2 ARM64 内的自有诊断驱动编译、测试签名与三段生命周期 |
| 厂商支持 | `unknown` | 自有诊断探针不提供厂商对 Guest、ARM64 或商业驱动的支持证据 |
| 真实游戏验证 | `not_tested` | 未由本报告验证受保护游戏启动或在线会话 |

商业安装动态采样、释放驱动的架构/签名/实际加载及官方拒绝，应以 `real-windows-probe-report.json` 和商业证据集的最新记录为准。当前自有诊断已闭合，商业采样结论仍由主任务独立核验。
