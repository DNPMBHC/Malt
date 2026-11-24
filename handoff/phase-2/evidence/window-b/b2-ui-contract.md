# B2 交互式 UIAutomation 取证工具

本地准备日期：2026-11-22（Asia/Shanghai）。工具只为已授权的正规安装路径取证。生成阶段未操作 Guest、运行商业程序或点击按钮。本机无 PowerShell，当前完成 31 项静态与合成模型检查，结果保存在 `b2-ui-local-validation.json`；合成模型未执行 PowerShell。主代理须先在 Guest 中用 PowerShell Parser 解析两份脚本，再执行真实取证。

## 文件与调用关系

- `b2-ui-dispatch.ps1`：由已有 QGA/session0 调用，通过 TaskScheduler 的 InteractiveToken/Highest 在已有登录会话调度 worker。无需账号口令，不创建新账号。
- `b2-ui-worker.ps1`：在同一交互桌面使用文档化 UIAutomation API。`launch` 通过 Process.Start 无参数启动已核验的官方安装器；`capture` 只枚举该安装器的进程树窗口；`invoke`、`toggle`、`select` 仅操作已观察的控件。

两文件须放在同一中性 Guest 工具目录。调用路径通过已有程序发现/映射取得，不在报告输出真实路径。

## 调用参数

| 请求 | 需要的参数 | 结果 |
| --- | --- | --- |
| `launch` | `ExecutablePath`、`ExpectedSha256`、建议 `PrivateTokensPath` | 核对文件 SHA-256 和 Authenticode Valid 后，无静默参数启动并捕获当前窗口 |
| `capture` | 建议 `PrivateTokensPath` | 新 `capture.generation`、中性 `window_index`、`control_index`、可见标题/文字及可用动作 |
| `invoke` | 最近捕获的 `Generation`、`ControlIndex` | 文档化 InvokePattern 调用，随后重新捕获 |
| `toggle` | 最近捕获的 `Generation`、`ControlIndex`、`DesiredToggleState=On/Off` | 最多一次 Toggle；若目标态需再次改变，重新观察后显式请求 |
| `select` | 最近捕获的 `Generation`、`ControlIndex` | 文档化 SelectionItemPattern.Select，随后重新捕获 |

可通过 `StateDirectory` 选择中性私有 Guest 目录；默认位于 ProgramData 的中性子目录。`TimeoutSeconds` 默认 25，允许 2–45，调用方 QGA 超时应至少比该值多留 12 秒，以覆盖调度和停止确认。`PrivateTokensPath` 应是 Guest 私有 JSON 字符串数组，包含主机侧已发现的私有项目/模块/账户标识；文件与 token 本身不进入报告。

调度输出结构是 `status`、`task_registration_removed`、`observation`。实际 UI 状态在 `observation.status`，窗口在 `observation.capture.windows`。worker 返回失败时 dispatch 也返回非零；完成调度不冒充安装完成。

## 行为与隐私边界

- worker 只查找安装器根进程及同一会话的后代；启动时核对 Process.Start 返回对象与 CIM 的创建时间，CIM 微秒精度容差最多九个 100ns tick，身份不可核实时保留已尝试启动标记并失败。root 退出后只保留创建时间已绑定且仍存活的已知进程，再扩展它们的后代；新增后代的创建时间须不早于本次启动和其存活父进程，不凭已退出 root PID 推导任何新子树。不会枚举其他程序的控件、读取进程内存、注入代码或模拟反作弊协议。
- 输入框和 Password 控件的值不读取，其公开文本固定为 `[input-field]`，也不会放入可操作私有映射。没有 ValuePattern、键盘输入、账号读取或自动登录能力。
- 标题和文本在 Guest 内替换已知私有 token、路径、邮箱、GUID、有效 IPv4、URL、MAC/SID 和长数字标识；四段含有大于 255 的项时保留版本文字，例如 `2.17.4.510`。主机取回后仍必须使用现有 host 脱敏及证据校验器二次检查。
- PID、RuntimeId、原生窗口句柄和创建时间只存于 Guest 私有映射，独立 worker 身份文件同样保留 PID 与创建时间供退出核对；公开结果只使用中性 index。原始控件 Name 不写入私有映射，仅保存名称摘要用于过期验证。
- 私有目录 ACL 仅允许 SYSTEM、本地 Administrators 和当前交互用户；请求、响应及映射不放入共享公开证据目录。
- 执行动作前验证 capture generation、RuntimeId、进程创建时间、控件类型、名称摘要和 enabled/offscreen 状态。过期元素必须重新捕获，不能按旧编号猜测按钮。失败响应的 `launch_attempted`、`ui_action_attempted` 标记可能已发出动作，不能自动重复点击或启动。
- 没有默认按钮、自动同意条款或自动点击操作。安装器遇登录要求或官方拒绝时，主代理应保留该边界并停止相应路径。
- UIAutomation 看不到的安全桌面、图像绘制或不可访问控件会缺失/失败；`capture_complete` 和 `skipped_controls` 如实记录，空窗口结果不会标记完整，文字范围固定为可见且可访问的控件，不从空结果推定没有弹窗。
- 每次调度使用独立的中性任务 URI；launch 与 capture/invoke 任务完全分开。launch 的应用运行时限为无限，避免 TaskScheduler 的两分钟限额终止正规安装。正常完成后仅在核实 worker 已退出后删除调度注册，不停止官方安装器。超时的非 launch 任务只停止本次 worker，复核私有 PID+创建时间后才注销；无法确认退出则保留恢复引用。launch 超时保留私有任务供恢复，不自动终止官方程序。调度/停止在 Guest 的实际行为仍须真实验收。
- 调度有独占文件锁，忙碌时拒绝新操作，不覆盖活动请求。恢复已有活动记录时，无论任务注册是否仍存在，都须确认原 worker 已退出；身份未知时不覆盖请求。进程范围已有登记时拒绝第二次 launch；若需要重试，先现场确认该范围内无存活应用，再明确清理私有 context/map 并重新请求。
- 取证结束后明确清理 Guest 私有请求、结果、context/map 和临时调度注册；不要把这些文件推送到宿主证据目录。

## 建议的 Guest 预检

通过已有 Guest 传输分别读取两文件，调用 `[System.Management.Automation.Language.Parser]::ParseInput`，只返回错误数量和中性文件别名。若解析失败，不运行 worker；错误对象可能带真实文件路径，不能原样输出。

实际 UIAutomation 加载、TaskScheduler token 类型、进程树可观测性和中文控件文本均需要本轮 Guest 实测，本地静态准备不宣称它们已通过。
