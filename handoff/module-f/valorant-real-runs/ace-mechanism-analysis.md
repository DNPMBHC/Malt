署名：@DNPMBHC。状态：双端实验、合法归因与五路正式压力基线已封存；双端视觉失败，在线校验、主游戏自然退出与厂商准入仍保留证据缺口。

本轮实测已经观察到 ACE 原生 ARM64 内核驱动。不能继续用历史备份中的三份 AMD64 SYS 推断最新运行保护链仍全部不支持 ARM64。官方启动器安装、人工登录、客户端路径识别和点击“进入游戏”之后，Program Files 下新落地两份 ACE SYS；文件创建时间均为 2026-11-24 02:36:04 UTC，与本轮进程和 7045 事件时间吻合。Get-AuthenticodeSignature、WinVerifyTrust、SCM 和 PSAPI 已加载映像关联给出如下结果：

| 样本 | PE Machine | 文件版本 | SHA-256 | 签名与实际加载 |
| --- | --- | --- | --- | --- |
| 原生组件 1 | 0xaa64 | 0.6.6.6 | abf69136be347884d8de4aae6860a10b698b0bfdd92cf0555bf6c581b8ed50ee | WHQL Authenticode Valid；SCM Running；映像已加载 |
| 原生组件 2 | 0xaa64 | 21.0.2506.56 | 47e61a173c6505c8c68767ad99ce8bc8cd3f446ade1144ad978396285fd1c4bf | WHQL Authenticode Valid；SCM Running；映像已加载 |

关联证据为 after-kernel-inventory.json 中 driver-332、driver-333，new-native-driver-attribution.json 中公开产品元数据 Anti-Cheat Expert，以及 native-ace-origin.json 的落地时间。未读取或转储内核映像内容。客户端备份的三个 AMD64 SYS 仍具有有效 WHQL 签名，且本轮采样时未加载；额外保护运行目录也保留了一份 AMD64 SYS。可见不同目录与不同组件存在架构差异，必须同时巡检客户端和运行时保护目录。

五维状态分离：代码工具已实现；本地全部 220 项 unittest 通过（0 失败、0 错误、0 跳过），127 源码与 6 反例安全自检通过；新增生命周期采集器通过 Guest PowerShell AST 语法检查；真实 Guest 已确认原生图形和上述两个 ACE 驱动加载；厂商对 VM 的正式允许与支持仍 unknown；真实受保护大厅与对局未验证。游戏启动后出现黑屏、空白与显示尺寸变化，不能当成游戏成功，也不能仅凭视觉失败认定是 ACE 拒绝。

| 正交因素 | 本轮事实 | 结论边界 |
| --- | --- | --- |
| CPU 与内核架构 | Guest 为 Win11 24H2 ARM64；备份 SYS 为 AMD64，两份运行时 ACE SYS 为 ARM64且已加载。 | AMD64 SYS不能靠 Prism 用户态模拟在 ARM64 内核执行。原生组件已分发和加载是本轮事实；保护链其他组件是否齐备仍需逐一验证。 |
| Windows 安全前置 | Secure Boot=true、Test Signing=false、WHQL viogpu3d 100.6.101.58000 已加载；TPM 2.0 enabled/activated/owned/initialized。 | TPM Ready For Attestation=false、缺 EK certificate。VBSStatus=0、SecurityServicesRunning=[0]；CI policy enforcement 位不能解释为 HVCI 正在运行。不能说厂商所有安全前置均满足。 |
| 厂商虚拟化策略 | 两份 ACE原生驱动在本环境加载，官方启动器允许创建客户端进程。 | 加载成功不等于厂商允许 VM 或保护初始化完成。尚未独立观察到明确虚拟化政策提示，也未证明该策略通过。 |

Intel/x86_64 VM 与 Apple Silicon ARM64 VM 的第一项区别是 Guest 内核指令集。x64 Windows 满足执行 0x8664 内核驱动的架构必要条件；ARM64 Windows 需要原生 ARM64 内核驱动。Intel VM 或 Intel Mac PD 没有在本轮实测，不能声称其中的安全链、虚拟化政策和受保护对局必定通过。本轮发现的原生 ACE 组件也意味着“必须等待任何 ARM64 ACE出现”已经过时，应改为验证已分发原生组件是否覆盖完整保护链，以及厂商是否支持该组合。

PE Machine 与文件角色、ABI要分开。微软 ARM64EC 文档说明最终 ARM64EC EXE/DLL 也可使用 IMAGE_FILE_MACHINE_AMD64（0x8664）；raw DLL 的 0x8664 不能全部归为纯 x64 ABI。这个用户态规则不会让 AMD64 SYS 可以在 ARM64 内核执行。巡检工具把 SYS 的 0xaa64记为原生候选，可信签名和真实加载分别验证。

本轮进程轨迹观察到客户端主进程和多个辅助进程创建，其中一个辅助进程退出码 6，另一个为 0；尚未获得主游戏自然退出码。一个辅助图形进程已经加载 dxgi.dll、d3d11.dll、neptune_umd.dll 与 neptune_umd_ec.DLL，证明触及真实图形库加载，不能证明大厅呈现。启动时 SCM出现 7045 与7030，关联到新增用户态服务。广域 RecordID 窗口内的 7000/1275 与 CI记录多发生于之前冷启或其他阶段，不能冒充本次保护加载失败码。原始事件中的身份和路径不导出；数值错误码也不独立建立厂商归因。

合规路径是保持原生 WHQL图形、Secure Boot和已初始化 TPM，逐一核实厂商下发的完整原生保护组件和正式安全/VM准入要求。TPM证明缺口、HVCI未运行、游戏图形与保护初始化失败阶段分别保留。方案 B 的图形零拷贝可以改善性能，但不会提供厂商准入，也不能替代未覆盖组件的原生架构适配。厂商允许的原生 Windows 硬件环境是另一条合规路径。本轮未作任何反作弊修改、Hook、虚拟化隐藏或硬件伪造。

宿主隔离 Wine 已真实运行官方安装器和启动器，用户亲自安装至 R:，安装器自然退出码 0。用户直接确认 DXMT 启动器为空白或黑屏。317 份 DLL 的字节 SHA 与 Guest 已验签清单全部匹配，raw Machine 为 201 份 AMD64 与 116 份 I386，Get-AuthenticodeSignature 均 Valid；Wine 本身没有由该关联获得 Windows 内核加载证据。D3DMetal 在同一 Bottle 中仅替换自有 system32 图形实现后复验，官方引导进程自然退出码 0，用户直接确认该路线也仍为空白或黑屏。日志中的 0xc0000005 first-chance SEH 尚不能证明进程崩溃；没有 Unhandled exception 或导入 DLL 错误标记。当前未观察 ACE 厂商弹窗，也没有真实游戏或保护内核加载证据。

bench_real3d_ace_arch_watch.py默认 30秒预算，只读扫描显式 SYS目录，可选择包含 DLL；Windows使用 Get-AuthenticodeSignature，非 Windows明确标注 not_verified_platform。父进程截止监督涵盖阻塞扫描。目录缺失、读取失败、未解析 SYS、数量上限或超时均不能形成“完整 AMD64-only”结论。需分别扫描客户端与运行时保护目录，避免只扫描备份漏掉已落地的原生组件；路径只作为本地输入，不写入公开证据。

可复现巡检命令：

```text
python bench_real3d_ace_arch_watch.py "<client-directory>" --budget-seconds 30 --json-out "<evidence-directory>/client-ace-inventory.json"
python bench_real3d_ace_arch_watch.py "<runtime-protection-directory>" --budget-seconds 30 --json-out "<evidence-directory>/runtime-ace-inventory.json"
```

公开一手依据的 URL、检索时间和响应哈希见 ../../phase-5/evidence/p5-a/primary-source-retrieval.json，包括 Microsoft Apps on Arm x86/x64 emulation、Building ARM64 drivers、ARM64EC、Get-AuthenticodeSignature，以及厂商公开保护说明。厂商一般说明不能扩张成 VM 准入保证。本轮官方路径识别已证实，但完整在线文件校验完成日志未取得。第一次游戏的黑屏截止与受控停机已保存，主游戏自然退出码保持 null；第二次生命周期采集失败 HRESULT=0x80070057，未采到事件，之后 VM 停止原因未知。正式五路重压基线已完成并通过 CSV 与 SHA 复算：15 轮、13,500 测量帧。独立 Guest 克隆已删除，主源全部 SHA 与 mtime 一致，租约 released；此前 Wine 观察已封存且自有 prefix 已关闭，本轮新增 host-only 复验另行记录；最终 runtime 删除与主源完整指纹复核以 vm-cleanup-proof.json 为准。

标准 --disable-gpu 参数诊断也已由用户确认仍为空白或黑屏。参数是否被启动器采纳、是否实际软件绘制均未验证；它只用于记录一次标准参数诊断，不算 3D 加速成功；本次未关闭 sandbox、未修改官方启动器字节、未触碰认证。三路共同黑屏不能单独定位为 GPU、Wine 组件或 ACE 的确切原因。日志已脱敏封存，主启动器自然退出码保持 null，受控关闭不冒充自然退出。


宿主追加复验：新 Bottle 的普通官方安装由用户确认完成，但只显示图标，无法打开窗口。新目录 317 份 DLL 与此前 Windows 已验签样本逐字节 SHA 匹配，0 份 SYS。同一 AMD64 主启动器以 --enable-logging=stderr --v=1 标准参数运行 60 秒；调用未自然退出，子进程自然退出码未验证。日志中 36 条 OLE 与 2 条 D3D 错误，后者为 wined3d_check_gl_call / GL_INVALID_ENUM。记录尚未绑定到主启动器运行时 PID，错误严重性、是否导致无窗口及 ACE 拒绝均未证明；不可将它们写成厂商拦截码。没有关闭 sandbox、修改官方字节或自动化认证。详细结构化记录见 wine-fresh-chromium-log-summary.json 与 wine-fresh-d3d-diagnostic-functions.json。

本轮全量门禁已通过 220 项，0 失败、0 错误、0 跳过；源码漂移导致的先前失败单独保存，未跳过或伪造源绑定。五路基线的 15 份 CSV 与摘要已再核验，未重测或改动正式性能数据。最终清理状态以 vm-cleanup-proof.json 为准。

官方启动器架构补证：只读解包 32 份 EXE 中有 25 份 AMD64、7 份 I386。安装器为 I386；两份历史实际启动器的 SHA 分别为 b2b65ed5ee470a8c9a6a3ef96ed9f6def220226472dee58fb50d445805860538 和 250f619fd0f004d6cdb606dda3dede142d13da4730da8c9cf78a9df9d415233a，与包内 AMD64 EXE 完全匹配。不能以安装器 32 位解释启动器无窗口。Wine builtin/native 标签不是后端字节证明，日志 context 也不是已绑定 PID。证据见 wine-official-package-exe-architectures.json 和 wine-render-route-readonly-audit.json。

本轮最终收尾：自有 Wine 的 server wait=0、隔离 prefix 无打开句柄；只关闭自有 Bottle。原始私有诊断日志随整个 host-only runtime 删除，仅保留允许字段的结构化摘要和源字节 SHA，原始日志不可取回。独立克隆已删除，主源八份文件的完整 SHA、大小及 mtime 与基线一致，主源 stopped；原备份完整 SHA、大小及 mtime 本轮复核一致，租约保持原 released 时间。最终证据见 vm-cleanup-proof.json、client-backup-final-proof.json 和 wine-fresh-final-log-manifest.json。
