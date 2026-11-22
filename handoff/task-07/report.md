# 任务 07 综合集成验收报告（Phase 2 收口更新 · 2026-11-22，北京时间）

## Phase 2 总验收摘要（五维状态分离）

本次 Phase 2 收口汇总窗口 A（真实 UTM Guest）、窗口 B（`module-a` 去重与国服取证）、窗口 C（真实 Wine DXVK vs D3DMetal 与资源策略 A/B）与窗口 D（核心调度收口、跨窗口提案合入与门禁升级）的实测与验证结果。整体真实商业游戏闭环状态保持 `incomplete`（不因本地构建或 Wine 基准通过而虚报 Guest OS / 商业游戏通过）。

| 维度 | 当前状态 | 证据与真实范围 |
| --- | --- | --- |
| **1. 代码实现** | `passed` | SwiftPM 108 项总数 / 107 通过 / 1 跳过（可选 MetalFX GPU A/B）/ 0 失败；Strict SwiftLint 103 文件 0 违规；Xcode Debug/arm64 无签名构建通过；6 份 guest/storage 文件严格 `swift-format` 通过；`globalGitUnchanged=true`、`lockfilesUnchanged=true`、`sourcesStableDuringRun=true`（见 `evidence/phase2-integrated/build.json`）。 |
| **2. 本机合成与隔离验证** | `passed` | 窗口 D 修复 `RuntimeStorageTargetSelector` 零估算容量排序缺陷（新增 5 项边界单测）；合入 `06` 提案的 12 项中性元数据字段与三语 `localizedNotes`；合入窗口 B `module-a` 唯一真源收敛与窗口 C `HostResourcePolicy` 真实消费者接线；`cli_smoke.py`（`task-07-cli-v2`）全部 5 项解析 + 4 项存储预检 + 7 项 CLI `run` 隔离端到端分支（含 `--ignore-saved-arguments` 空覆盖、非零退出 `42`、`SIGTERM` `143`、`SIGKILL` `137`、`SIGINT` 取消 `130` 与子进程清理）全部通过（`evidence/cli/cli.json`）；`integration.py` 8 阶段（含 `performance-tools` 41 项、`graphics-tools`含 `test_metalfx_sdk_compile.py`、`vendor-evidence`、`driver-abi` CTest 1/1）及 `dev_restart.sh` 停旧启新闭环通过。 |
| **3. 真实 Guest / Wine 验证** | `partial`（Wine 实测通过；UTM 外壳周期通过；Guest OS 内部待镜像） | **Wine（窗口 C，已通过 `phase2_evidence.py` SHA-256 强制校验）**：本机 Apple M4 / macOS 27.2.1 完成真实 `d3d11_probe.exe` 3 轮冷/热启动 + 900 帧对比（`handoff/phase-2/evidence/window-c/wine-dxvk-vs-d3dmetal/manifest.json`）：D3DMetal 冷/热启动 `4310.55 / 3804.89 ms`、衍生 FPS `309.55 / 353.63`、热态 P50/P95/P99 `2.57 / 7.20 / 9.70 ms`、设备内存 `67.34 MiB`；DXVK 冷/热启动 `4121.92 / 4375.94 ms`、衍生 FPS `324.12 / 335.31`、热态 P50/P95/P99 `2.70 / 6.93 / 9.94 ms`、设备内存 `223.72 MiB`；`metal_host` 策略 A/B 实测（`baseline-off` 119.98 FPS → `balanced-60fps` 51.26 FPS → `conserve-30fps` 26.93 FPS → `fallback-off` 120.01 FPS）均已绑定不可变源码与二进制 SHA-256。<br>**UTM Guest（窗口 A）**：真实 `UTM.app 5.0.9` + 外接卷 QEMU `aarch64` VM（`B107A021-E60C-426B-BB62-626122CE44BE`）修复 5 项真实契约缺陷并实测 `inspect`（`186.89 ms`）、冷启动（`3224.76 ms`）与强停回收（`563.42 ms`）；因缺 Windows 11 ARM64 ISO/VHDX，Guest OS 内部 QGA 执行与 WDK 驱动编译加载（窗口 B）仍处于 `awaiting_windows11_arm64_os_image` / `blocked_by_guest_os_and_wdk_provisioning`。 |
| **4. 厂商支持** | `unknown` / `not_supported` | Riot 国际版 Windows 明确 VM 不支持；中国区（`a-cn-win`）已完成官方资料补录与 `VALORANT_CN_installer_v2.17.4.510.exe` 只读 PE32 / Authenticode 静态取证（32 位 x86 NSIS 引导器，Tencent 合法签名），但外层安装器架构不等于内核驱动架构，厂商 VM 许可与支持立场仍保持 `unknown`。 |
| **5. 真实游戏验证** | `not_tested` | 尚未在真实 Windows Guest 中执行任何受保护商业游戏安装、内核驱动加载或受保护在线会话；功耗、温度、真实游戏利用率及物理输入到光子延迟保持缺测。 |

### Phase 2 门禁工具链新增能力

- `verify.py`：明确区分 `locked-cache-fast-gate`（`existing`）与 `process-scoped-cold-cache-probe`（`fresh`），新增 `failureClassification` 自动区分网络/依赖拉取超时（`curl 28 / exit 74 / exit 124`）与代码/编译错误，并增加无 `rg` 环境的纯 Python 源码快照回退与缺失工具 `exit 127` 处理。
- `phase2_evidence.py`（已接入 `integration.py`）：强制要求每份声明真实运行/性能实测的 Phase 2 证据绑定不可变源码与二进制 64 位 SHA-256 摘要，同时校验脱敏边界与各窗口 `interface-proposal.md`。
- `dev_restart.sh`：提供“增量 Debug/arm64 构建 → 安全终止旧实例 → 重启新产物 → 输出日志位置”的一键开发验证闭环，已通过实机两次连续重启 PID 切换实测；GUI 原生文件选择器、Finder 错误弹窗与 Shift 终端交互的桌面实点清单记录于 `handoff/phase-2/evidence/window-d/dev-restart-and-gui-checklist.md`。
- `integration.py`：已切换至唯一物理真源 `my-project/Modules/module-a/WindowsProbe` 并校验顶层 `Modules/module-a` 符号链接一致性（`moduleACanonicalSymlinkConsistent=true`），支持自动定位本机 Homebrew `cmake`/`ctest`。

---

## Phase 1 历史冻结基线（2026-11-22 01:57，北京时间，保留作对照）

任务 07 最终集成验证（2026-11-22，北京时间）

冻结快照的本地门禁通过；真实驱动、保护范围、guest、安装器、游戏会话和游戏性能尚未验收，整体状态保持incomplete。此次门禁采集于01:57:25，证据总索引为 evidence/collection.json，完整组合见 evidence/matrix.json。

| 类别 | 当前结果 | 证据与范围 |
| --- | --- | --- |
| 编译 | 锁定依赖、91项总数/90通过/1跳过、严格lint及Xcode构建通过 | final-integrated/build.json；100个Swift文件0违规；无签名Debug/arm64 |
| 格式 | 六份guest/session/storage源文件与测试严格swift-format通过 | format-final/format.json；显式文件清单，不作全仓格式通过声明 |
| 新入口 | 五项CLI帮助/解析、四项隔离存储预检分支通过 | cli/cli.json；容量ready、文件目标notWritable、缺少安装器notChecked、无效guest配置专属诊断 |
| 驱动 | 可移植ABI CTest 1/1及报告校验通过 | integration-final/integration.json；不含WDK驱动/客户端编译、签名或Windows内核加载 |
| 保护范围 | 合成能力、拒绝启动、报告语义检查通过 | 未证明真实驱动对游戏进程、内存的可见性或保护生效 |
| guest/安装/游戏会话 | environment_not_verified；0次真实执行 | 本机无已配置UTM/Parallels guest，未安装或启动真实安装器与游戏 |
| 性能 | 原生合成回环、资源队列和MetalFX独立证据复核保留 | 无D3D/Wine/guest或游戏提速结论；功耗等缺测如实保留 |

完整构建的171项输入、锁文件和全局Git在运行前后稳定。组装时源码仍与该快照匹配。顺序XCTest的91个唯一started/completed用例与最终汇总一致；MTL_DEBUG_LAYER=1仅用于测试子进程，未启用opt-in A/B。原生JUnit未生成，交付XML由真实日志派生并标记provenance；1项跳过不计入90项通过。05此前独立配置为91总数/89通过/2跳过；阶段转述的“91通过”不采用为最终计数。

集成工具31项、图形工具8项通过。SDK测试test_experiment_sources_typecheck_against_active_macos_sdk实际执行且未跳过，使用当前SDK完整typecheck三份MetalFX Swift源码，并执行诊断脱敏回归。26项集成输入包含真实Swift编译输入及CLI采集工具，前后稳定且组装时匹配。厂商资料24来源、32声明、9范围、7条VM记录及9项反向语义检查通过；这些资料不替代真实运行。

CLI先验证CFFIXED_USER_HOME的Foundation隔离，再以临时合成registry、容器、惰性安装器及暂存目录调用生产入口。registry使用各target构建设置及源码fallback的bundle标识候选，不导出标识；URL由原生PropertyListEncoder编码，生产查找成功定位合成容器。首两轮错误fixture返回容器缺失，保存在cli-fixture-initial及cli-fixture-registry；最终四分支各自断言完整JSON或guest配置专属诊断，避免容器缺失造成假阳性。合成registry、容器元数据和惰性安装器摘要不变，未创建Program Settings或持久暂存文件，未读取/改动真实registry或真实安装器，也未执行安装器。保存参数空覆盖、取消/信号/退出码的完整运行入口仍不属于本次CLI验收。

外接候选卷阶段容量约59.9 GiB（约64 GB），用户确认足够；暂存文件与工作区安装器逐字节相同为协调方阶段证据。容量足够、文件一致、配置映射和guest内实际文件可见性分开报告；本轮CLI只验证临时本地预检，没有推定真实映射、安装或启动成功。自动选卷排序仍有缺口，当前GUI、CLI、文件打开和快捷方式均未消费该选择器，保留后续功能项。

冷缓存依赖获取仍不稳定：final-fresh中的Swift获取及历史77项测试通过，但Xcode获取curl 28/exit 74失败；fresh-http1中两次解析均约300秒超时/exit 124。未将HTTP/1.1称为修复，未在最终快照盲目重复网络尝试。当前通过的是锁定版本的缓存门禁。

性能原始证据来自固定640×360、相同场景和参数的三次本机回环，每次20帧预热、90帧测量，帧间隔89个有效样本。百分位使用线性插值，标准差使用总体口径。吞吐为回环应用协议字节率，排除握手、预热和TCP/IP头部，不能当作链路带宽。

| 轮次 | P50 / P95 / P99 ms | 平均间隔 ms | 协议吞吐 MiB/s |
| --- | --- | --- | --- |
| 1 | 10.614 / 64.796 / 66.369 | 27.225 | 34.253 |
| 2 | 10.946 / 65.932 / 66.461 | 24.378 | 38.449 |
| 3 | 8.681 / 64.366 / 67.957 | 23.989 | 39.642 |

帧间波动较大。每轮后台负载、刷新率、热状态、电源及缓存控制未完整记录，不能据此解释波动成因。CPU进程时间、Metal命令缓冲时间和逐次标准差见 evidence/native-synthetic-review.json；它们不是CPU/GPU利用率。Metal命令缓冲均值约0.155–0.181 ms。发送端峰值RSS为30.3–34.7 MiB，宿主常驻峰值83.5–84.5 MiB，二者采样口径不同。纹理占用3,686,400字节是尺寸估算，不能作为VRAM实测。

软件请求到回包均值23.719–27.462 ms不包含显示扫描和物理输入。连接/预热不能充当冷/热启动。功耗、温度、真正冷/热启动、CPU/GPU利用率和物理输入延迟均保持缺测。

三次基线测量帧共266,619,600字节，每帧987,480字节。320×180资源更新对照的流量从17,776,800降至13,975,712字节，减少21.382%；每种条件仅一次，不能证明提速。

390个旧测量帧的宿主ACK字段只记32字节，客户端实际收到56字节；总量按完整客户端计数。新增smoke核对56=32+24字节，旧原始证据未改写。封存清单24项哈希与大小通过，25个证据文件隐私检查通过；原五组测量文件均未变化。新增缓存实验含5帧预热、60帧测量、59个有效间隔，均值8.360093 ms、协议流量13,960,864字节，逐帧客户端与宿主计数一致。命令仅校验并保留，没有执行重放；它与旧资源对照并非配对实验，不能归因计时改善。原始性能数据未绑定当时源码或可执行文件的不可变摘要；本轮独立编译摘要只代表当前源码。

任务04的独立复核见 evidence/module-d-review.json，记录8份证据、9份选取源码的当前摘要；9份源码未变，3类结果材料的后续漂移及旧摘要分别保留。参考资料为33个来源、15项能力、13份SDK头，13份头的当前摘要匹配。该模块独立采集日志记录85项通过、无skip标记，显式A/B耗时2.041秒；此日志与主门禁85项总数、84项通过、1项跳过分开报告。资源队列实验共12轮、192个真实计算任务，热状态与低电量状态均为注入。control、nominal、serious三种处理的墙钟中位数为4.144、8.444、43.022 ms；它验证专用诊断队列的并发限制、暂停与恢复，不证明节能或游戏提速。

两份MetalFX报告分别开启与关闭API验证层，各含288条计时样本，每个比较的每臂48条。路线实际执行标记、交替顺序及中位数已复核；两种仪器配置分开报告。关闭验证层时，nearest/spatial GPU中位数为0.02767/0.10958 ms，nearest/temporal为0.02775/0.31160 ms；该小型静态场景中重建增加成本。较新GPU能力查询只证明支持查询结果，实际功能使用标为未测试。Game Mode实际激活仍为unknown，没有系统UI观察，Wine与guest收益未测量。这两份GPU报告也未绑定采集时间、当时源码或二进制不可变摘要；当前摘要只确认复核时内容。

后续缺口分别归属：01/02的WDK、签名、真实Windows执行；01/06的同域保护与厂商接口；02的真实guest生命周期和映射；03的D3D/Wine/guest对照；03/04的启动、利用率、功耗、温度及物理输入延迟；05的自动选卷排序及完整运行入口验收。厂商拒绝或无匹配驱动不得写成普通配置错误。

可复现命令见README.md及format_check.py。旧构建、网络失败、阶段转述、fixture失败和独立GPU采集保留，各自对应原快照。状态文档当前计数及历史范围已核对，见evidence/status-documents.json。

未提交、推送、重置或修改全局Git配置，保留已有工作区改动。初始脱敏基线117条存在资产名碰撞且并行任务获授权编辑，因此保留检查不能证明所有原始字节不变；当前门禁输入已按碰撞独立后缀保留全部171项。

隐私边界：落盘交付文本单独审计；此前辅助lint异常和一次补丁校验错误曾向工具输出暴露原始路径，另一次源码查看留下未完全脱敏的上游标识，这些既有输出无法撤回且不在落盘扫描范围。最终不作“所有历史工具输出均已脱敏”的声明。
