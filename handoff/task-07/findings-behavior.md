# 行为验证复核

复核日期：2026-11-21。本记录反映当前共享工作区接口与测试源码，执行结果以任务 07 统一构建门禁为准；本次没有运行 Swift 构建或测试。

## 早期问题已经有实现与回归测试

- 任务 05 的保存参数不再按空白直接拆分。Program.runtimeRequest 使用 RuntimeArguments.parse；RuntimeProcessTests 覆盖带空格、引号、空参数、转义与未闭合输入。早期参数拆分问题不再作为当前缺陷。
- CLI 已增加 --ignore-saved-arguments，并按 args.isEmpty && !ignoreSavedArguments 决定是否回退保存参数，因此已能显式覆盖为空数组。该实现仍需由 CLI 入口测试证明选项解析与调度一致。
- 任务 05 已引入 RuntimeSession、退出结果和取消接口。RuntimeCoordinator.launch 将非零退出映射为 processExit，将信号终止映射为 processSignal；Wine 启动已改用等待程序完成的会话路径。RuntimeProcessTests 覆盖本机子进程退出码、下一次尝试和取消，RuntimeTests 覆盖 Guest 非零退出。早期“启动消费循环丢弃非零结果”不再适用于当前协调器路径。
- WindowsGuestRuntimeBackend.start 现在使用 request.host 进行能力判断，原先忽略请求快照的接口一致性风险已消除。

## 当前六项集成边界测试

任务 07 在 IntegrationBoundaryTests.swift 中保留六项边界测试：

1. 3 种 Provider 可用性乘以 5 种兼容状态，共 15 组；分别断言后端、兼容状态、readiness、具体 issue 和是否允许启动。
2. 拒绝启动时检查 blocked 的标题与 issue，并确保 Provider 从未被调用。
3. 普通合成档案处于 ready/unknown 时，检查可执行文件、空参数、空格、引号、Unicode、环境和 host 的原样转发；同时检查 Provider 异常传播。
4. 4 种热状态乘以 2 种低电量状态，共 8 组资源策略。
5. 缺少 bottle 时断言 issue(.bottleUnavailable)，与当前冻结错误接口一致。
6. 合成档案的大小写匹配和相似前后缀拒绝。

这些测试使用假 Provider。ready/unknown 的可启动结果只适用于未声明反作弊需求的合成档案，不能推出真实驱动、厂商支持或在线游戏可用性。旧版 Provider 的默认 start 桥接返回 unreported 结果，也不能作为真实程序退出状态证明。

## Guest 生命周期：已有模拟验证，真实 VM 尚待实测

任务 02 已提供 UTMWindowsGuestProvider 与模拟传输测试。当前测试涵盖配置校验、架构不匹配、后端限制、启动与映射、参数和环境、完整退出码、重复取消、取消失败、运行中崩溃、Agent 就绪超时、停止、重复停止、请求配置下停止以及失败后的清理入口。

这些覆盖不能写成“Guest 生命周期完全没有接口或测试”。同时，模拟传输没有启动真实 Windows guest；实际 VM 启停、Agent 权限、文件传输、崩溃恢复与子进程清理是否与模拟一致，仍须按宿主/guest/架构组合分别实测。

## 当前仍存在的证据缺口与归属

- 任务 01：自有探针的报告解析和失败阶段已有回归测试，但 self probe 不等于真实反作弊驱动或游戏保护。真实签名、guest/驱动架构、进程与内存可见性、保护生效、厂商支持和真实游戏会话需独立证据。
- 任务 02：需要真实 VM 与 Agent 的端到端会话证据；测试替身通过不等于 VM 实测通过。
- 任务 05：建议补充 CLI --ignore-saved-arguments 的完整入口回归，并验证取消、信号和非零结果经 CLI 映射后的退出码。任务 07 只验证该布尔选项拒绝带值及帮助公开，没有进入覆盖保存参数的运行分支。
- 任务 05：旧 Process.runStream 路径仍会记录参数、环境与路径。不要将原始运行日志直接作为可分享证据；任务 07 的采集结果需继续脱敏。此条与已修复的当前启动会话路径分开评价。
- 任务 07：测试源码存在及静态复核不等于已通过。构建、驱动、保护范围、游戏会话与性能结果继续分开报告。

实际测试数量以统一门禁的脱敏 XCTest XML 与 build.json 为准；矩阵循环组合不额外计为测试方法。
