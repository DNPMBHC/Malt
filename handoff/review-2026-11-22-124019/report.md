# my-project 当前工作审查

本次为只读源码与证据审查。保留全部现有改动，未修改生产源码、重新构建、启动虚拟机或执行游戏安装器。新建本报告与审查指纹供下一阶段对接；不提交或推送。

## 已核实的进展

- 最新门禁是 `handoff/task-07/evidence/phase2-integrated/build.json`：128 项总数、127 通过、1 跳过、0 失败。187 项当前输入摘要及两个锁文件与证据一致。原始 Xcode 日志显示 Strict SwiftLint 检查 115 文件、零违规，Debug 构建成功。此次核对已有证据，没有重新运行构建。
- `window-a/e2e-verification.json` 的 11:55 记录比旧环境报告更新：Win11 24H2 ARM64、QGA、文件推送与可见性、后台程序参数/环境、退出和取消、用户态自有探针取回已有真实执行记录；七项关联源码摘要与当前文件一致。本次宿主只读查询亦确认 UTM 已安装、一个 VM 处于 started 状态，未改变其运行状态。
- 真实内核适配仍未达到验收：用户态探针明确返回 driverLoadState=notLoaded、failureStage=open、Win32 错误 2。没有发现真实 WDK 编译、正式签名自有 .sys 加载、商业反作弊驱动或受保护游戏会话通过证据。
- Wine 三引擎基准已有 18 组 / 16,200 帧记录。Windows guest C3 新增 6 组 / 1,800 帧；原始六份 CSV、三份宿主 JSONL 与六项源码/二进制摘要均已逐项核对，按现有分析器重算的汇总一致。
- 宿主实际为 macOS 27.2.1。现有 Game Mode 记录仍将激活状态写为 unknown、Wine 子进程收益写为 unmeasured；不能由平台版本推导游戏提速。

## 优先修复的问题

| 优先级 | 问题与定位 | 影响及下一步 |
| --- | --- | --- |
| P1 | 生产 guest 执行仍走 QGA Session 0。`UTMWindowsGuestProvider.swift:89`、`WindowsGuestTransport.swift:153`；C3 `architecture-review.md:32` 已记录 Session 0 下交换链创建失败，交互式 Session 2 才跑通。 | 目前后台程序执行通过不证明 GUI 安装器或启动器能显示到登录桌面。应增加明确的交互式用户会话执行路径，并跟踪真实桌面进程的退出/取消，而非仅跟踪启动包装进程。 |
| P1 | `ContentView.swift:99` 与 `:131`：首次未接受声明且运行时未安装时，仅展示声明；接受回调只置标记，关闭后只处理文件队列。 | 首次使用被截断，必须重开应用才进入依赖安装。应由统一启动流程在声明关闭后继续检查并安装缺失依赖。 |
| P1 | 远端后端虽已接入调度器，生产 GUI/CLI/程序请求仍使用默认构造；未加载远端配置或显式选择该后端。`Program+Extensions.swift:26`、`:42`、`:46`。 | 新后端目前不能从正常用户入口使用。下一阶段需补配置持久化、选择入口及真实客户端/主机校验；实际远端串流未验证。 |
| P2 | `RemotePhysicsRuntimeBackend.swift:24` 以配置有效性直接缓存 ready。 | 客户端缺失或主机不可达仍可能报告就绪。应使用异步可用性检查的真实缓存，检查前保持未知/未验证。 |
| P2 | `RemotePhysicsBackend.swift:225`、`RemotePhysicsModels.swift:106`：controlPort 用于 TCP 探测，却未传到实际 Moonlight 连接参数。 | 非默认端口的预检目标与连接目标可能不一致。应按真实客户端协议统一端口语义，并验证实际参数。 |
| P2 | `RuntimeIntegrityReport.swift:124` 将任意有效 Team 签名加 Hardened Runtime 认作官方构建，无受信发行者锚点。 | 当前完整源码的只读反例中，非官方 Team、SIP disabled 仍 isOfficialBuild=true。UI 尚未直接显示该字段，但后续证明协议不能采用此结果。有效签名、官方发行、宿主完整性应分开表达。 |
| P2 | `phase2_evidence.py:121` 只检查 SHA 字段格式与文件存在，没有计算/比对文件摘要；也未识别窗口 A 嵌套真实执行 schema。 | 自动真实证据门禁的可信度和状态失真。本次人工摘要核对通过，但机器门禁仍需真正核验并识别最新 A/C3 数据。 |

## 性能结论与架构顺序

C3 的自有 D3D11 基准为 1280×720：guest 直出 11.35 FPS，像素 TCP 卸载 6.19 FPS；guest 软件渲染约 73–91 ms，回读/传输/同步呈现约 99.48 ms，宿主 Metal GPU 呈现仅 0.168 ms。它验证了跨 VM 像素传送链，尚未把 guest 的 D3D 渲染移到宿主 GPU。单独改为共享内存传像素不能消除软件光栅瓶颈；这些数字不能推广为商业游戏帧率或游戏提速结论。

建议衔接顺序：

1. 先跑通交互式 guest 启动，以自有 GUI 程序验收可见性、参数、退出和取消，再衔接安装器与下载目标验证。
2. 在现有干净 ARM64 guest 内完成自有驱动的 WDK 构建、匹配架构和合法签名加载验证；分别记录厂商支持和商业游戏结果。
3. Windows 图形主线评估标准 WDDM/VirtIO 3D 设备及宿主 GPU 命令执行，先以小型真实 3D 工作负载证明消除软件光栅，再开展 guest 裁剪。Wine 三引擎路线用于适用的软件。
4. 远端物理 Windows 路线完善正常入口和真实串流验收；它依赖另一个 Windows 主机，不等同于单台 Mac 的本地混合内核方案。
5. 刷新当前状态索引并保留历史证据。

## 需要刷新而非覆盖的记录

- `handoff/task-07/evidence/gate-status.json:25`、`:32` 仍引用旧环境状态和旧构建。
- `handoff/phase-2/evidence/window-d/gate-summary.json:63` 仍将窗口 A 标为等待真实证据，且该汇总早于 C3 数据。
- 窗口 B 的 11:00 无 guest 快照已被窗口 A 的 11:55 新记录更新；其 WDK/驱动缺口仍未发现完成证据。
- `UTMGuestStoragePreflightTests.swift:136` 在缺少真实 VM 环境变量时直接返回成功。普通全量计数中的这项通过不代表真实执行，建议显式跳过并单列真实验收。
- task-07 报告中的 91/90/1 已明确标为 Phase 1 历史冻结基线，无需删除。

审查不判定各文件的具体作者，以上结论针对当前工作区内容。文件标识均为脱敏相对名；实测来自已有记录，本次没有重新运行 guest 或商业游戏。
