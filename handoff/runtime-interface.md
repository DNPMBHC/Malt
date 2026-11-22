# 任务 05 共享运行接口

程序按钮、列表、固定项、文件打开、CLI、Shift 终端及快捷方式共用以下接口。宿主程序配置由 Program.runtimeRequest 转为请求。此表是任务 05 的冻结基线。

| 接口 | 约定 |
| --- | --- |
| RuntimeCoordinator.plan | 输入程序 URL、档案选择、可选后端和宿主快照。返回解析到的档案、所选后端、各项状态与阻塞原因。此调用不启动程序。 |
| RuntimeCoordinator.validate / start / launch | validate 校验文件、参数、环境及后端要求。start 在通过校验后返回会话。launch 等待会话并将非零退出码、终止信号和调用方取消作为错误报告。 |
| RuntimeLaunchRequest | 带本地文件 URL、可选容器、原样参数数组、环境键值表、档案选择、宿主快照、可选后端和 guest 配置。调度器重新解析档案并校验本地文件。 |
| Program.runtimeRequest | 参数为 nil 时解析保存值。传入数组时完全覆盖保存值，包括空数组和含空字符串的数组。环境由程序配置生成，组装时保留键和值。 |
| RuntimeGuestConfiguration | 标识符、guest 架构、宿主目录至 guest 目录的映射和就绪超时。provider 负责校验配置、解析 guest 路径、完成握手和处理超时。 |
| WindowsGuestProvider | availability 分为未配置、不可用和已就绪。实现 start 接收已解析的请求并返回 RuntimeSession。旧的 launch 接口允许接入现有实现，其完成结果标为 unreported。 |
| RuntimeSession | UUID 标识会话。wait 返回真实退出码、终止信号或未报告的旧 provider 结果。cancel 取消本次启动或运行会话。provider 负责保证重复取消无副作用、等待最终能结束。 |
| RuntimeLaunchError | 使用类型化原因、能力阻塞、进程退出码和信号。外部 provider 可以返回自身错误。应用与 CLI 使用共用本地化文本。 |

后端就绪只描述能否请求该后端。RuntimeEvidence 独立传递内核诊断、厂商支持和游戏实测。集成方按后端和游戏档案传入证据。自有驱动探针通过时可以报告 selfProbeVerified。未录入的厂商证据显示未知，未记录的游戏结果显示未实测。当前默认 guest provider 显示未配置并立即返回可读错误。

自动识别比对当前文件名及符号链接目标的文件名，不追踪后续启动的子进程。脚本、批处理和已知通用启动器会要求明确选择游戏档案或通用 Windows 程序。用户选择与精确文件匹配冲突时，调度返回原因。文件打开面板的选择只影响本次运行。程序设置中的选择随程序保存，CLI 和快捷方式每次运行时重读。

程序设置先归一化文件路径，符号链接和实际路径共享档案。程序扫描以真实目标合并列表项，显式文件打开与 CLI 保留传入的启动路径。容器内按相对路径保存，容器外按绝对路径区分。旧版按文件名保存的参数、环境和区域选项可沿用，保存后归入各自文件。参数字段支持成组引号、空参数和转义。CLI 直接取 argv。run 保留按容器名选择的方式，也支持 --bottle-path。--profile 可指定 auto、ordinary 或档案 ID。程序参数放在 -- 之后。省略参数会读取保存值，单独使用 --ignore-saved-arguments 会传入空数组。Shift 终端使用随应用分发的 CLI，快捷方式启动时也调用 CLI。Windows 批处理仍按 Windows 命令解释器规则执行。

旧快捷方式迁移从对应程序的快捷方式菜单发起。选中旧快捷方式后核对容器和目标文件，再替换入口。新入口每次从当前应用执行能力检查。迁移校验拒绝不匹配的旧入口。迁移后执行当前程序档案，同样适用启动预检。

回归测试和隔离运行使用合成程序及替身后端。最终构建已点验详情运行按钮、列表运行项、固定卡片双击及 Finder 文件打开。两个文件同时打开时，第一个失败会显示退出结果，原确认面板恢复运行按钮，重试成功后才显示第二个文件。控制器验证另覆盖取消和同一容器去重。CLI 和快捷方式验证覆盖退出码、参数覆盖、特殊参数原样保留、guest 未配置、取消及旧快捷方式迁移。

存储预检接入前的隔离基线：SwiftPM 共 85 项，83 项通过，2 项需要主机 Metal 测试配置而跳过。Xcode 应用构建成功，SwiftLint 无违规。Shift 终端已验证 CLI 参数传递及生成的 AppleScript 编译，实际 Terminal 交互待点验。真实 guest、厂商支持和商业游戏实测另行记录。

共享接口的字段或语义变更由提出方先记录字段名、类型、默认与未知值的含义、生产和消费模块，以及对旧数据和测试的影响。任务 05 在接口说明、模型、调用方和回归测试中一并落地。任务 06 提出的发行区域、系统架构与证据版本字段仍在其工程输入中，等待明确适用范围后再纳入运行接口。

存储预检接口（任务 05 冻结）：

| 字段或入口 | 类型、默认与语义 |
| --- | --- |
| BottleSettings.runtimeStorageDirectory | 可选本机目录 URL，旧设置默认无目标。为同一容器生产和读取。预检接受单次显式目录覆盖；保存后每次启动重新读取并检查。 |
| BottleSettings.runtimeStorageGuestConfiguration | 可选 RuntimeGuestConfiguration，沿用任务 02 的配置 JSON。单次显式 guest 配置优先，其次容器保存值，其次后端已有配置。导入仅用于存储检查，不会启用 guest 后端。 |
| WindowsGuestProvider.storageGuestConfiguration | 可选 RuntimeGuestConfiguration，现有 provider 默认返回 nil。任务 02 provider 提供其已有配置，让同一调度的预览和执行使用一致的映射。 |
| RuntimeStoragePreflight | 目标、当前可写性、卷可用字节、安装器字节、预留字节、映射状态及总结果。所需空间为文件大小加 4 GiB 预留；未知字节为 nil，无法比较时为 notChecked。可写性用宿主目录中的临时文件验证，正常检查结束会移除探针。 |
| RuntimeCoordinator.storagePreflight / Program.runtimeStoragePreflight | 查询与 RuntimeCoordinator.validate 共用存储规则；查询不写入配置或启动后端。已有目标时在交给后端前按最新文件系统状态重查。无保存目标时不额外阻塞原有启动。 |
| RuntimePlan.storagePreflight / RuntimeLaunchError.storagePreflight | 分别携带已通过的检查或阻塞当前启动的检查。旧调用可继续只使用计划中的能力。 |

程序详情和 Finder 文件打开确认共用预检区域，支持选目录、导入映射、重查和清除，文案覆盖英、简中、繁中。CLI 的 storage-preflight 使用同一结果，输出版本 1 的单行 JSON，省略路径。未就绪返回非零退出码，损坏的设置报错并保留原文件。CLI run、Shift 终端及新旧快捷方式通过同一启动调度；迁移后的快捷方式每次读取当前容器设置。预检描述选定目标的当前状态，不会搬移文件或更改安装目的地。

任务 02 复用 RuntimeStoragePreflightChecker 和 RuntimeGuestConfiguration。宿主声明的映射最多为 configured；任务 02 的 provider 在 guest 内确认待执行文件可见后才记录 verified。provider 另区分宿主目录已存在、可创建及不可写；任务 05 的手动选址对应已存在目录。上述状态不改变后端就绪、内核诊断、厂商支持或游戏实测状态。

本轮 SwiftPM 共 91 项，89 项通过，2 项因 Metal 测试配置跳过，0 失败；严格 SwiftLint 检查 100 个文件，0 违规；无签名 Xcode Debug 构建通过。最终构建的合成 CLI 验证覆盖无路径 JSON、缺失目标、映射声明、损坏配置保留，以及普通启动与快捷方式同样拦截、修复后重试。隔离 APFS 验证了空间充足、空间不足、只读挂载、未配置映射和未知文件大小；测试卷已卸载。任务 02 的 6 份明确 guest 文件通过严格 swift-format，详见 task-07/evidence/format-manifest.json。

本轮 GUI 和 Finder 验证了预检展示、重查和清除；原生选择器能打开，实际选择目录及导入 JSON 的自动化未稳定完成。Finder 错误弹窗及实际 Terminal 交互未完整点验。自动选卷的容量排序仍可能在两个卷的估算值同为零时选错较大的卷；当前产品入口使用显式或保存的目录，未调用该选择器。本轮未执行真实 guest、安装器或游戏。

任务 05 源码已冻结。任务 07 准备快照之后发生变化的输入为 CLI 预检、任务 02 provider 及其测试。任务 01 三个受保护文件与本轮起点摘要相比有一个驱动源文件存在漂移；任务 05 未编辑或恢复这三个文件，保留共享工作区现状。快照及检查范围见 task-07/evidence/reported-task05-freeze.json；任务 07 的独立最终门禁另行执行。

任务07最终冻结门禁（2026-11-22 01:57，北京时间）：SwiftPM为91项总数、90项通过、1项可选A/B跳过，失败/错误为0；仅测试子进程设置MTL_DEBUG_LAYER=1，未启用可选A/B采集。严格SwiftLint为100文件、0违规；无签名Debug/arm64应用构建通过。此前05独立轮次91项总数、89项通过、2项跳过采用不同主机测试配置，作为独立历史记录保留。当前证据见task-07/evidence/final-integrated/build.json。存储CLI新增帮助与四个隔离合成执行分支通过；真实guest/安装器/游戏均未执行，环境为environment_not_verified。自动选卷排序仍有缺口，当前GUI、CLI、文件打开和快捷方式不调用该选择器。

---

## Phase 2 窗口 D 共享接口演进与收口

### 1. 自动选卷容量排序修复（RuntimeStorageTargetSelector）

`RuntimeStorageTargetSelector.preferredTarget` 保持公开签名不变，容量解析改为逐级回退：`volumeAvailableCapacityForImportantUsage`（仅 `> 0` 时采纳）→ `volumeAvailableCapacity`（`> 0` 时采纳）→ `FileManager.attributesOfFileSystem[.systemFreeSize]`（`> 0` 时采纳）→ 明确为 `0` 的真实满盘值 → `nil`。排序规则固定为全序：外接可写卷优先于内置卷；已知容量优先于未知并按降序排列；容量相同时按标准化路径字典序稳定排序，消除两卷估算值同为 `0` 时选错较大卷或依赖入参顺序的缺陷。

### 2. 兼容元数据字段合入（来源：任务 06 `module-f` 工程输入）

所有新增字段均以可选值、默认 `nil`（未知/未采样）合入，保留旧构造器签名与旧 JSON/Plist 解码 100% 向后兼容；不修改既有内置档案的兼容判断，也不会自动升级厂商支持或游戏验证结论。

| 类型 / 字段 | Swift 类型与 JSON 键名 | 默认与未知语义 | 生产与消费模块 |
| --- | --- | --- | --- |
| `RuntimeSecurityFeatureState` | `enum`: `absent` / `present_disabled` / `enabled` / `unknown` | 明确区分安全特性（TPM2/Secure Boot/IOMMU/VBS/HVCI）四态 | 生产：01/02/06；消费：05/07 |
| `GameProfileMetadata`（挂于 `GameCompatibilityProfile.metadata`） | `distributionID` (`distribution_id`), `clientPlatform` (`client_platform`), `sourceSnapshotID` (`source_snapshot_id`) | 整体默认 `nil`，字段默认 `nil` 表示未声明或未知 | 生产：05/06；消费：UI/CLI/07 |
| `GameCompatibilityProfile.localizedNotes(in:)` | `String`（键 `runtime.profile.<id>`，回退 `notes`） | 缺失翻译时回退英文 `notes` | 消费：App/CLI 共用三语说明 |
| `RuntimeEvidence` | 新增 `Codable` 与 `metadata: RuntimeEvidenceMetadata?` | 缺省解码时分别回退 `.unknown` / `.untested` / `nil` | 生产：01/02/06；消费：05/07 |
| `RuntimeEvidenceMetadata` | 全部 12 项中性字段：`distribution_id`、`client_platform`、`host_cpu_architecture`、`guest_cpu_architecture`、`guest_os_build`、`guest_os_edition`、`security_capabilities`、`security_enabled_state`、`installed_client_build`、`driver_binary_machine`、`driver_file_version`、`source_snapshot_id` | 全部可选、默认 `nil`（未采样/未知）；`security_capabilities` 与 `security_enabled_state` 为 `[String: RuntimeSecurityFeatureState]?` | 生产：窗口 A/B（01/02/06）；消费：窗口 D（05/07） |

### 3. 本地化与旧 `Process.runStream` 日志隐私边界审计

- 本地化核查：`Whisky/Whisky/Localizable.xcstrings` 中全部 `runtime.*` 键（含 3 个档案说明 `runtime.profile.*`、19 个 `runtime.issue.*`、存储预检与 CLI 诊断）均具备英文 / 简体中文 / 繁体中文三语条目；`ProgramView` 已统一改为调用 `profile.localizedNotes()`。
- 日志边界审计：当前调度主路径 `Wine.startProgramInWine` 使用 `Process.startRuntimeSession()`，不调用旧 `Process.runStream`；旧辅助路径（`Wine.runWineProcess` / `Wine.runWineserverProcess`）经 `Process.runStream` 仍会在本机 `~/Library/Logs/<bundleId>/` 与 `Logger.wineKit` 中记录原始路径、参数与环境变量。这些原始本机日志禁止作为可分享证据落盘，并由 `handoff/task-07/audit_evidence.py` 持续守卫。

### 4. 响应窗口 B / 窗口 C 跨窗口接口提案合入

- **响应窗口 B 提案（`window-b/interface-proposal.md`）**：
  - `handoff/task-07/integration.py` 已将可移植 ABI 路径切换为优先消费唯一物理真源 `Whisky/Modules/module-a/WindowsProbe`，并校验顶层 `Modules/module-a` 符号链接解析一致性（`moduleACanonicalSymlinkConsistent`）。
  - 字段语义红线明确：国服安装器外层 PE32（`I386`）仅代表用户态引导程序架构，**不得自动提升为内核驱动架构 `driverBinaryMachine`**，在真实 Windows Guest 完成动态采样前保持 `nil` / `unknown`。
- **响应窗口 C 提案（`window-c/interface-proposal.md`）**：
  - `BottleSettings.adaptiveResourcePolicyEnabled`（默认 `false`，兼容旧 Bottle plist 解码）已接入 `ConfigView`（含英/简中/繁中三语说明），并在 `WineRuntimeBackend.resolvedRequest(for:)` 与 `BottleSettings.environmentVariables(wineEnv:)` 中真实消费窗口 C 的 `HostWineLaunchPolicy`：仅在启用且使用 DXVK 时非破坏性注入 `DXVK_FRAME_RATE` 与 `DXVK_NUM_COMPILER_THREADS`（不覆盖用户手动设置），D3DMetal 不注入未文档化变量；`RuntimePlan` 透出 `wineResourcePolicy(dxvk:enabled:)` 与 `guestResourcePolicy(enabled:)` 供诊断读取。
  - 注：受总控文件写入锁约束，`Wine.swift`（非窗口 D 独占目录）中的 `process.qualityOfService = .userInitiated` 暂保持未修改，待统一放开 `Wine/` 后可一行同步 `winePolicy.processQualityOfService`。
