# module-b M0 / M1 验收记录

署名：@DNPMBHC

窗口 A 任务范围内的实现与真实验收已完成。交互式执行使用真实登录桌面会话，参数通过有界二进制编码传递；会话身份绑定请求、目标 PID、创建时间和 Windows 会话。进程树完成、根进程退出和取消终态分别记录。

| 验收项 | 实测结果 | 证据别名 |
| --- | --- | --- |
| 真实 GUI 与 DXGI | 窗口可见，交换链创建及 Present 成功；真实目标与控制进程 PID 不同，退出码 42 | real-m0-gui.json |
| 参数与输出 | 空参数、空格、引号、特殊符号、Unicode 和环境变量逐项一致；stdout 与 stderr 标记均捕获 | real-m0-gui.json |
| 普通取消 | 重复 cancel 幂等，真实目标退出，会话返回 1223 | real-m0-cancel.json |
| 父子进程树 | 根进程先 exit 0，子进程继续运行；自然结束后树为空，取消后保留 rootExitCode=0 并返回会话 1223 | real-m0-process-tree.json |
| 强制清理 | UUID 与真实句柄认证后终止 Job；两次 force-cancel 均确认根退出且活跃目标数为零；强制输出声明截断 | real-m0-force-cancel.json |
| 启动前取消 | 持久取消屏障阻止随后相同请求启动目标 | real-m0-prelaunch-cancel.json |
| 安装器式窗口 | 自有安装器式窗口可见，正常退出 0 | real-m0-installer.json |
| 提权边界 | 当前已提权登录 token 的自有探针成功；自动批准 UAC 仍为 false | real-m0-elevation-boundary.json |
| 显式宿主委托 | 五案例真实回包与宿主逐项一致，全部目标 Job 清空 | real-m1.json |

M1 成功案例把 Guest 自有探针的整数数组交给宿主执行 scale=3、bias=-7 的计算，回传值为 [-7, -4, -10, 6442450934, -6442450948]。Guest 独立复算，并与宿主核对 requestID、真实目标/会话身份、数值、摘要、状态和错误。五案例退出码分别为成功 0、宿主拒绝 22、算术溢出 22、超时 20、取消 21。取消在确认宿主计算仍活跃后触发；超时要求 Guest 收到 deadlineExceeded 回包。每案例都确认连接、计算及真实目标树回收。

宿主自动化具有底层期限及取消处理，会终止并回收本次自动化进程。交互清理按请求 UUID 执行，正常取消失败后使用认证 Job 的强制清理；cleanupUnconfirmed 保持失败。并发取消等待同一任务，传输恢复后可以重试。较早的 running 快照不会覆盖已经提交的 exited 终态。launch 尚未返回 PID 的清理也通过持久请求身份完成。

普通本地门禁：175 项计数，165 项通过、10 项 XCTSkip 显式跳过、零失败。10 项包括本阶段 7 个真机用例、先前 VM 生命周期用例和 2 个宿主 GPU 选择性用例。独占真实门禁：7 项执行、7 项通过、零跳过、零失败；其中 M1 用例含五种实际请求。原生退出解析的 7 项生产共用逻辑回归通过；清理工具的 30 项隔离检查通过。16 个授权 Swift 文件严格格式检查及范围空白检查通过，依赖锁文件未改变。

最终门禁 build/real-complete-bound.json 与 real-m1.json 绑定同一次运行。real-cleanup-audit.json 的 accepted=true 同时要求本次成功门禁、五个唯一案例、Guest 终态及原生 Job 活跃数为零、宿主连接/计算清理，以及自有目录进程清点为零。目录清点与 Job 证据分别记录。guest-benchmark-handoff.json 已标记 released=true、next_owner=C、guest_jobs_clean=true；A 此后暂停 Guest 操作。

所有 PE 产物为 x64，在 ARM64 Guest 中仿真运行。当前已提权 token 的结果不能推导 medium-token UAC 路径；自有安装器式窗口也不构成商业安装器验收。M1 仅验证显式计算委托接口，不宣称透明 PE 迁移、GPU 加速、性能提升或商业兼容性。

共享模型需求已写入 interface-proposal.md。源码及产物指纹分别记录在 source-fingerprints.json 与 artifact-fingerprints.json。所有写入限于窗口 A 的授权范围；未执行 git commit 或 push。
