# 任务 07 综合集成验收报告（Phase 2 终版全绿 3/3 基线刷新 · 2026-11-23，北京时间，@DNPMBHC）

## Phase 2 终版全绿总验收摘要（五维状态分离）

本次总验收刷新对齐全绿 `3/3` 实证基线：`phase2_evidence.py`（v2 真实字节 SHA-256 核验）实现窗口 A / B / C **`3/3` 全满贯通过**，`integration.py` 全部 10 个集成阶段通过（含防外挂静态安全门禁、兼容矩阵编译与 `graphics-lab` 152 项单测），SwiftPM **183 项（173 通过 / 10 显式跳过 / 0 失败）**，Strict SwiftLint **125 文件 0 违规**，`RemotePhysicsBackend` 保持冻结并持续通过既有单测。整体真实商业游戏闭环状态仍诚实保持 `incomplete`（严格遵循五维状态分离，不虚报商业游戏或厂商许可通过）。

| 维度 | 当前状态 | 证据与真实范围 |
| --- | --- | --- |
| **1. 代码实现** | `passed` | SwiftPM **183 项总数 / 173 通过 / 10 显式跳过**（真机 VM 与可选 MetalFX GPU A/B 均显式跳过）/ **0 失败**；Strict SwiftLint **125 文件 0 违规**；Xcode Debug/arm64 无签名构建通过；6 份 guest/storage 文件严格 `swift-format` 通过；`globalGitUnchanged=true`、`lockfilesUnchanged=true`、`sourcesStableDuringRun=true`（见 `evidence/phase2-review-closure/build.json`）。 |
| **2. 本机合成与隔离验证** | `passed` | ① 审查收口 7 项 P1/P2 清零（首次免责声明→依赖安装连续流、`RemotePhysics` 持久化/入口/未探活态/端口统一并已冻结、`RuntimeIntegrityReport` Schema `1.1.0` 受信锚点拆分、窗口 A `interactiveDesktop`/`rootExitCode`/`.cancelled` 共享契约）；② `cli_smoke.py`（`task-07-cli-v2`）6 项解析与完整性诊断 + 4 项存储预检 + 7 项 CLI `run` 隔离端到端分支全通；③ `integration.py`（`evidence/integration-p4-baseline/integration.json`）10/10 阶段全绿（含 `anticheat-hardening-audit`、`compatibility-matrix-compile`、`vendor-evidence` 42 来源 / 45 声明、`graphics-lab` 152 项单测、`driver-abi` CTest 1/1）及 `phase2_evidence.py` v2 `3/3` 全通过；④ `dev_restart.sh` 重建与停旧启新闭环通过。 |
| **3. 真实 Guest / Wine 验证** | `passed_on_self_owned_probes`（`phase2_evidence.py` **`3/3` 全满贯通过**；真实商业驱动/游戏见维度 4–5） | **窗口 A（`real_evidence_validated`，14 项真机实证 / 17 项证据文件逐字节 SHA-256 核验通过）**：外接卷 `<EXTERNAL_VOLUME>` 部署真实 Win11 24H2 ARM64 (`Build 10.0.26100.1`) + QGA，完成 A2 全链路及 M0/M1 交互式桌面探针验证。<br>**窗口 B（`real_evidence_validated`，2 项原生 ARM64 驱动全周期实证 + 商业安装器双轴动态采样终结论）**：实证自有 ARM64 (`0xaa64`) 内核探针全周期（加载→重启前后→卸载）并恢复 Secure Boot 干净基线；在授权测试账号下对 `target-cn`（`2.17.4.510`）执行交互式安装与启动采样，实锤其落地的 3 个 WHQL 内核驱动全部为 `0x8664`（AMD64），导致 ARM64 内核下零厂商驱动加载（`observed_amd64_only_in_sample`），并已完成商业残留清理与 Secure Boot 恢复验证。<br>**窗口 C（`real_evidence_validated`，15 项实证 / 144 项证据文件逐字节 SHA-256 核验通过）**：① 宿主机 Wine 三引擎 1280×720 实测 **18 组 / 16,200 测量帧**（`335–367 FPS`，其中 `DXMT v0.80` 显存仅 `19.9 MiB`）；② 跨 VM **M2 三模式 9 轮配对终实测**（`run-20261122-140047-utc`）：真实 Metal 16-Draw 命令重放像素误差 `0–1 LSB`、带宽压缩 `1,611×`（缓存帧仅 `88 B`）、宿主 Apple M4 Metal GPU 渲染仅 `0.881 ms`、吞吐 **`18.847 FPS`**（反超直出 `15.673 FPS` 与像素回读 `7.096 FPS`），并定位剩余 ~`52 ms` 瓶颈在同步阻塞 TCP 往返。 |
| **4. 厂商支持** | `blocked_arch (axis 1)` / `unknown (axis 2 CN)` / `not_supported (Riot global VM)` | `module-f` 保持 **42 来源 / 45 声明 / 11 范围 / 7 兼容矩阵行**（WoA/VM 双轴拆分）；`target-cn` 轴 1（WoA ARM64 驱动架构）已由窗口 B 实证确凿阻塞（3 个 WHQL 驱动均为 `0x8664`），轴 2（虚拟化许可立场）保持 `unknown`；Riot 国际版明确 VM 与 ARM 均不支持。 |
| **5. 真实游戏验证** | `not_tested_or_blocked` | `target-cn` 在 ARM64 Guest 下因无原生 ARM64 反作弊驱动被拦截，未达成受保护在线会话；功耗、温度、真实游戏利用率与物理输入到光子延迟保持缺测。 |

### Phase 2 / 4 门禁工具链能力

- `verify.py`：区分 `locked-cache-fast-gate`（`existing`）与 `process-scoped-cold-cache-probe`（`fresh`），自动分类网络超时与代码/编译错误，提供无 `rg` 环境的纯 Python 源码快照回退。
- `phase2_evidence.py`（`task-07-phase2-evidence-v2`，已接入 `integration.py`）：真正读取声明文件原始字节重算 SHA-256 与 manifest 核对（单字节篡改或缺失数据文件必败，8 项 `unittest` 覆盖），已验证窗口 A/B/C **`3/3` 全满贯通过**。
- `dev_restart.sh`：提供“增量 Debug/arm64 构建 → 安全终止旧实例 → 重启新产物 → 输出日志位置”的一键开发验证闭环。
- `integration.py`：校验唯一物理真源 `my-project/Modules/module-a/WindowsProbe` 符号链接一致性，串联 `performance-tools`、`graphics-tools`（152 项单测）、`vendor-evidence`、`anticheat-hardening-audit`、`compatibility-matrix-compile`、`driver-abi` CTest 与 `phase2_evidence.py`。

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

---

## Phase 6B 整合更新（2026-11-24，@DNPMBHC）

- **默认图形路由调优**：依据 16,384 Draw 实测，保持 DX11 默认 `DXMT`、DX12 默认 `D3DMetal`、MetalFX 默认 `.off`，将 DXVK 默认 `dxvkPreferKosmicKrisp` 调整为 `false`（默认 `MoltenVK` 保高 Draw 吞吐，保留 `KosmicKrisp` 一键可选开关与三语取舍提示）。
- **统一基线自检与 5C 安全门禁**：新增 `GoldenGuestManifestSummary.swift`、`WhiskyCmd baseline-report` 与设置页统一诊断摘要，展示 `runtime-manifest.json` 锁版指纹、`golden-guest-manifest.json` 状态（未初始化时优雅提示）及 5C `GuestSurface` 受控关闭门禁（`gameShellEntryEnabled=false`）。
- **Release 打包与五条件产物门禁**：重打 Hardened Runtime `.app` → `.dmg`（13,652,553 字节，SHA-256 `addfc678135c7dab40ffc18ec937d87e2b82b01f66277975afc7882d8b3f3574`，仓库外输出）；1800 帧三轮 `artifact_perf_gate.py` 五条件全绿通过（`dxmt` 0.904/0.9322、`dxmt_metalfx_quality` 0.9291/0.9875、`d3dMetal` 0.9933/1.002、`dxvk_backend-k` 1.004/1.0055、`dxvk_moltenvk` 0.9194/0.9217），详见 `handoff/phase-6/evidence/p6-b/report.md`。
