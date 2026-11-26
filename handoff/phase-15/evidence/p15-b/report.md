# 启动崩溃修复验收

署名：@DNPMBHC  
验收时间：2026-11-26T08:48:44.478607+08:00

已完成方案 1。demo-app 的两处 Swift 更新组件保持 canImport(Sparkle) 条件编译，工程已移除更新框架链接、远程包和锁文件条目。主程序加载表及完整应用包均无 Sparkle.framework；原更新入口不会编入此次发行版。

发行版显式使用 ad-hoc 签名，保留 Hardened Runtime。安装版 CodeDirectory flags 为 0x10002，CS_RUNTIME 位 0x10000 已置位；未设置 disable-library-validation 或 get-task-allow。签名检查使用数值位解析，兼容 adhoc,runtime 组合标志。

打包门禁默认观察完整 4 秒，提前正常退出和异常退出均失败，同时检查加载、签名错误与旧框架残留，并在退出检查后回收冒烟进程。

| 验证 | 本次结果 |
| --- | --- |
| Debug 构建与 dev_restart | 通过，重启后存活 3 秒 |
| Release 内嵌运行时打包 | 通过，ad-hoc，DMG 334.979 MiB |
| 包内启动门禁 | 完整 4 秒存活，0 dyld 错误 |
| DMG 安装启动 | 从该 DMG 复制安装，主程序与 CLI 哈希一致 |
| 安装版真实启动 | LaunchServices 打开后存活 10.005 秒，1 个可见窗口，0 dyld 错误，0 新崩溃报告 |
| 签名与安全权限 | codesign --verify --deep --strict 通过；Hardened Runtime 保留；未禁用 Library Validation |
| Swift 全量测试 | 267 项：257 通过、10 跳过、0 失败 |
| 启动门禁回归测试 | 8/8 通过 |
| Strict SwiftLint | 0 violations |
| 格式检查 | 6/6 输入稳定 |
| 审计自检 | 143 个源文件，6/6 负向自检通过 |
| 工作区与隐私 | diff 检查通过，新增跟踪文件无超过 5 MiB 项；本次证据脱敏 |

10 项跳过分别需要显式启用 GPU 基准测试（1）、Metal 验证环境（1）和真实 Guest 配置（8）。本次确认的是主应用启动与发行包完整性；内嵌运行时和游戏路径未进行新的端到端验收。

旧安装版本已在临时恢复目录保留副本。最终运行实例来自已安装的 Release 应用。未提交或推送任何 Git 更改。

主要证据：embedded-dmg-manifest.json、installed-release-verification.json、verification-summary.json、gate-results.json、launch-gate-tests.json、app-restart-verification.json、workspace-check.json。此前阶段报告保存在 prior-phase-report.md。

DMG SHA-256：4452d5ee6aa482eb1c37d3b8d5a2a0a80999c998c1e1d9b6b7160a325ab09c62
