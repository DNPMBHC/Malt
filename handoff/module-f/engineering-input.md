# 任务 01、02 工程输入（Phase 2 窗口 B 更新版：含裸金属 WoA 与虚拟化 ARM64 Guest 正交拆分）

证据快照：2026-11-22（Asia/Shanghai）。事实和出处以 `evidence.json` 的 claim / source ID 及 `handoff/phase-2/evidence/window-b/valorant-cn-installer-static.json` 为准。来源成功读取日逐项保留；所有路径示例只使用合成标识（`<workspace>`），不代表当前机器私有路径配置。

## 当前决策

| 范围 | 官方环境输入 | 任务 01 / 窗口 B | 任务 02 / 窗口 A |
| --- | --- | --- | --- |
| target-a / Riot Windows (`a-riot-win`) | VM 不支持；公开规格页标 ARM 不支持；Win10 构建号有官方内部矛盾；Vanguard On-Demand（Pre-Check）针对 Win11 25H2+ 提供按需启动（A-REQ、A-BUILD、A-MODE、A-VM、A-WOA-SPLIT） | 拆分「裸金属 WoA 驱动可用性（On-Demand 是否分发原生 ARM64 驱动待核）」与「虚拟化 ARM64 Guest 策略（VAN 9100 拒绝 VM + On-Demand 要求 IOMMU/VBS/HVCI）」；不能标记适配成功 | 普通 guest 仍可用于自有诊断；VM 就绪不升级官方支持。按表格 19041+ 做候选筛选只是保守工程选择，矛盾仍未解决 |
| target-a / 中国 Windows (`a-cn-win`) | 主下载页要求 Win10/11 64位、i3-540 / Athlon 200GE、SSE4.2 或 AVX、4GB RAM（未在规格表明文写死 ARM 不支持；旧 aclos 页仍列 Win7-11 与 E8400）；公开游戏版本 13.09、登录器 2.17.4；腾讯游戏安全中心提供 BIOS VT-x/VT-d/SVM/IOMMU 开启及关闭 Hyper-V/VBS/HVCI/虚拟机监控程序冲突排障指引（A-CN、A-CN-REQ、A-CN-VER、A-CN-SEC、A-CN-WOA-SPLIT） | 已完成官方安装包 `VALORANT_CN_installer_v2.17.4.510.exe` 只读 PE/Authenticode 静态取证（外层为 32 位 x86 NSIS 引导器）；拆分「裸金属 WoA 驱动可用性（ACE 是否释放原生 ARM64 `.sys`）」与「虚拟化 Guest 策略（Hyper-V/VBS/虚拟机监控程序占用拦截）」 | 国服独立 VM 许可与支持状态在公开文档中仍为 `unknown`；宿主虚拟化冲突指引表明商业反作弊对 Hyper-V/VBS/虚拟机环境存在硬件虚拟化占用检测，不得预判 Guest 可通过 |
| target-b / Riot Windows (`b-riot-win`) | x64、Win10 19041+ 或 Win11；ARM 不支持；VM 不支持（B-REQ、B-VM） | 依正规安装和诊断路径采集；Pre-Check 与通常开机模式分别记录 | OS 版本、架构、发行版资格独立检查；Enterprise / Server 不符合公开要求 |
| target-b / 中国 Windows (`b-cn-win`) | 下载页官方配置图片要求 64位、i5-4460（SSE2）、GTX 750 Ti、1GB 显存、30GB HDD、4G 内存（图片内“win10”与“Win10\Win11”、推荐内存 16G 与 4G 存在行间矛盾）；当前公开版本 Ver 26.23（B-CN、B-CN-REQ、B-CN-VER） | 2024 历史 FAQ 曾将中国排除在当时的 Vanguard 计划外；当前国服内核反作弊驱动二进制、签名与加载状态未知 | 不继承国际系统要求或允许状态；最低存储按国服图片 30GB 预检（高于国际服 16GB） |
| target-c / 国际 Windows (`c-steam-win`) | 64 位 Win10+、DX12；VM 明确禁止（C-REQ、C-VM） | 完整反作弊组合及商业驱动 Machine 未知；不得仅凭 Steam 或 EAC 名称推定加载结果 | 记录发行方许可阻塞；不把该禁止改写成本机已观测到技术失败 |
| target-c / 日本 FAQ (`c-jp-win`) | 官方声明虚拟 OS 无法连接（C-JP） | 属官方连接限制，不是本机测试 | 支持状态不支持；单凭该日文句子不推定许可条款禁止 |
| target-c / 中国 Windows (`c-cn-win`) | 腾讯运营国服《终极角逐》S3 赛季官网与官方安全站在线运行（S-C08、S-C10、S-C11、C-CN） | 官方安全站展示 10 年封禁处罚公示，但未公开内核反作弊驱动名称或 PE 架构 | 官网提供客户端下载器、WeGame 入口与腾讯 START 云游戏入口，未公开本地 PC 硬件最低配置表或 VM 政策，保持 `unknown` |

---

## 核心架构拆分：裸金属 Windows on ARM 驱动可用性 vs 虚拟化 ARM64 Guest 策略（VALORANT 首要焦点）

结合微软官方 Prism 转译文档（`S-P04`、`S-P05`、`S-P06`，对应 `P-WOA-PRISM`）及 Windows on ARM 游戏硬件生态（Snapdragon X 与 NVIDIA N1/N1X 平台推动主流反作弊原生 ARM64 驱动普及），本工程输入严格禁止将“ARM 架构驱动问题”与“虚拟机 Hypervisor/vTPM 拒绝”混为一谈，必须按以下两个正交轴独立建档与诊断：

| 诊断维度 | 国际服 VALORANT（Riot Vanguard / On-Demand，`A-WOA-SPLIT`） | 国服 VALORANT《无畏契约》（腾讯 ACE，`A-CN-WOA-SPLIT`） |
| --- | --- | --- |
| **用户态指令集（Prism 转译层）** | 要求 SSE4.2 或 AVX（`A-REQ`）。Windows 11 24H2+ 的 **Prism** 已在用户态原生支持 x64 AVX/AVX2/BMI/FMA/F16C 转译（`S-P05`），用户态指令集不再构成硬阻塞。 | 主下载页要求 `Win10、11 (64位)` 及 `SSE4.2 或 打开AVX Support设置`（`S-A06`）。外层 32 位 x86 安装引导器（`2.17.4.510`）通过 WOW64 运行；注意 Prism 对 32 位 x86 应用默认隐藏 AVX/AVX2，必要时可在属性中开启 `Show newer emulated CPU features`（`S-P05`）。 |
| **轴 1：裸金属 Windows on ARM 内核驱动可用性** | 内核无转译，驱动须为原生 `ARM64`（`0xaa64`，`P-ARM` / `P-WOA-PRISM`）。虽然 `S-A01` 公开页面仍写 `ARM: Not Supported`，但需在 Windows 11 24H2/25H2+ ARM64 下核查 Vanguard On-Demand（`S-R02`）分发通道是否已包含原生 `ARM64` 驱动二进制。 | 国服公开规格表未明文禁止 ARM。外层安装器为 32 位 x86 引导器，内嵌或下载释放的腾讯 ACE 内核驱动是否已随 WoA / NVIDIA N1/N1X 生态包含原生 `ARM64`（`0xaa64`）驱动二进制，须在阶段 B2 授权安装时直接检查 `.sys` 的 PE Machine。 |
| **轴 2：虚拟化 ARM64 Guest 策略（Hypervisor / vTPM 硬件信任根）** | 即使存在或未来推出裸金属 `ARM64` 驱动，`S-R03`（`VAN 9100`）明确拒绝 VM 环境；且 On-Demand（`S-R02`）与安全页（`S-R04`）要求 `Secure Boot + TPM 2.0 + IOMMU + VBS + HVCI`。Apple Silicon 上的 ARM64 VM（UTM QEMU / Parallels）暴露 Hypervisor 且缺乏嵌套虚拟化/VBS/Guest IOMMU（`P-PDARM`）。 | 腾讯游戏安全中心（`S-T01`）明确要求开启物理主板 BIOS `VT-x/VT-d` 或 `SVM/IOMMU`，并在检测到 Windows `HVCI`、`VBS`（要求 `bcdedit /set hypervisorlaunchtype off`）、`Hyper-V` 或虚拟机监控程序（Hypervisor）占用时弹窗阻断。在 ARM64 Guest VM 中，Hypervisor 标志天然存在且硬件虚拟化由宿主机独占。 |
| **阶段 B2 动态采样错误归因准则** | 若驱动文件 PE Machine 为 `0x8664 (AMD64)` 或加载报 `ERROR_BAD_EXE_FORMAT (193)` → 归因于 **轴 1（无原生 ARM64 驱动二进制）**；<br>原生 `0xaa64 (ARM64)` 只证明该采样文件的架构；只有独立实测 `VAN 9100` / TPM / IOMMU / VBS 等明确拒绝证据，才记录 **轴 2（Guest 策略或硬件信任根要求）**。 | 若采样释放的 `.sys` 为 `0x8664 (AMD64)`，记录该文件不适用于 ARM64 内核；另有实际加载错误 `193` 时可关联 **轴 1（该采样二进制架构不兼容）**，不能外推所有渠道均无 ARM64 分发；<br>若安装/启动报“未开启或有其他软件占用CPU虚拟化功能”或 Hypervisor 冲突 → 归因于 **轴 2（虚拟化 Guest Hypervisor 占用策略拒绝）**。 |

> **辅助对照试金石（阶段 B2 可选补充）**：在不分散 VALORANT 首要焦点的前提下，可在同一 Windows 11 24H2+ ARM64 Guest 中辅以 1 款已提供官方原生 ARM64 驱动且不封杀 VM 的组件样本，用于验证「Prism x64 用户态 + 原生 ARM64 内核驱动」基础链路正常，从而将 Guest 环境配置问题与 VALORANT 反作弊策略/架构阻塞彻底隔离。

---

## 国服安装包（`VALORANT_CN_installer_v2.17.4.510.exe`）只读静态取证工程输入

详细结构化报告见 `handoff/phase-2/evidence/window-b/valorant-cn-installer-static.json` 与 `valorant-cn-installer-static.md`。

1. **官方出处与文件指纹**：
   - 官方来源：`S-A06` (`val.qq.com/download.html`) 调用 `S-A08` (`api.val.qq.com/go/agame/resource/kv?key=aclos_download_center`) 下发的官方独立安装包（对应国服公开游戏版本 `13.09`、登录器版本 `2.17.4`、发布日期 `2026.10.28`）。
   - 文件大小：`491,792,264` 字节（约 `469.01 MiB`）。
   - 全文件 SHA-256：`686ee838411863d2eccdbe8a0596129e509819ae46626408760588ae8b0c800e`（只读采样前后二次校验完全一致）。
2. **PE 架构、资源与封装器特征**：
   - 外层 PE 格式：`PE32 (32-bit)`，COFF `Machine = 0x014c` (`IMAGE_FILE_MACHINE_I386`)，`Subsystem = 2` (`IMAGE_SUBSYSTEM_WINDOWS_GUI`)。
   - 封装器类型：`Nullsoft Install System v2.46.5-Unicode`（含 `.ndata` 节；PE 节表原始数据结束于 `58,880` 字节，偏移 `58,880` 至 `491,781,744` 共 `491,722,864` 字节为 NSIS Overlay 封装负载区）。
   - 版本资源（`VS_VERSION_INFO`）：`CompanyName = "腾讯科技（深圳）有限公司"`，`ProductName / FileDescription = "无畏契约"`，`FileVersion / ProductVersion = "2.17.4.510"`，`InternalName = "aclos-launcher.exe"`。
   - 清单权限（`RT_MANIFEST`）：`requestedExecutionLevel = "asInvoker"`（`uiAccess = "false"`），外层引导器以当前调用者权限启动。
3. **Authenticode 数字签名验证**：
   - Security Data Directory 位于文件偏移 `491,781,744`，大小 `10,520` 字节（PKCS#7 `SignedData`）。
   - 签名者（Signer）：`CN=Tencent Technology (Shenzhen) Company Limited, O=Tencent Technology (Shenzhen) Company Limited, L=Shenzhen, ST=Guangdong Province, C=CN`（序列号 `0b:ca:73:6e:dd:e7:f8:99:25:91:c3:07:6a:dc:fb:6e`，有效期 `2026-04-08` 至 `2027-04-07`），由 `DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1` 签发，根证书为 `DigiCert Trusted Root G4`。
   - 时间戳签名：由 `DigiCert SHA256 RSA4096 Timestamp Responder 2026 1` 于 `2026-10-27T04:03:50Z`（北京时间 `2026-10-27 12:03:50`）签署。
   - 密码学摘要一致性：按 Authenticode 规范计算的 PE Image SHA-256（`9ad0a0c98edc3dbcd786bad74b1f3decfc4228bcca06dfffff1b295f0388b248`）与 PKCS#7 `SpcIndirectDataContent` 内嵌摘要 100% 吻合。
4. **架构与状态红线**：
   - 外层安装器 `IMAGE_FILE_MACHINE_I386` 仅代表 32 位用户态 NSIS 安装引导器（在 Windows 10/11 x64 或 ARM64 上通过 WOW64 运行），**绝不代表内嵌或安装后释放的内核反作弊驱动（`.sys`）的 PE Machine**。
   - 在未进入真实 Windows Guest 完成授权安装采样前，`a-cn-win` 的内核驱动二进制属性、`driver_load`、`game_start`、`protected_session` 必须保持 `unknown`。

---

## 任务 01：所需独立采样

1. 记录发行区域、发行渠道、公开补丁参考、实际客户端 build、Vanguard / 腾讯 ACE 等厂商组件版本与实际启动模式。公告号不能替代 build。
2. 记录 host / guest / 游戏 executable / 驱动四种架构，明确 CPU 指令执行域；驱动单独采集 PE Machine、文件版本、SHA-256、合法签名和签名验证结果。
3. 使用自有、合法签名、无侵入功能的诊断驱动（唯一真源 `<workspace>/module-x/Modules/module-x/WindowsProbe`）验证正常加载、请求响应、退出、重启和失败路径；报告只能证明该执行环境。
4. 保护范围必须证明驱动看到的是实际运行测试负载的进程及其执行域。服务 running、设备句柄打开或安装完成均不足以证明保护有效。
5. 商业组件只能沿厂商正常安装和诊断路径采样，记录真实拒绝和原始错误（精确区分“无 ARM64 驱动”与“Hypervisor / vTPM 拒绝”）。此交付不授权规避已知 VM 禁止，不伪造环境或完整性状态。
6. 四类状态分别附证据：发行方立场、实际驱动加载、实际游戏启动、实际受保护在线会话。一个成功结果不能补写其他结果。

---

## 任务 02：环境资格与可观测结果

建议交给任务 05 / 窗口 D 落地的兼容性元数据字段：`distribution_id`、`client_platform`、`host_cpu_architecture`、`guest_cpu_architecture`、`guest_os_build`、`guest_os_edition`、`security_capabilities`、`security_enabled_state`、`installed_client_build`、`driver_binary_machine`、`driver_file_version`、`source_snapshot_id`。

A-SEC / B-SEC 的通用 Vanguard 安全页按设备适用性列出 Secure Boot、TPM2、IOMMU、VBS、HVCI；A-CN-SEC（`S-T01`）的腾讯游戏安全中心指引则描述在异常/风险环境下要求 BIOS 开启 VT-x/VT-d 或 SVM/IOMMU，并在冲突时要求关闭 Windows HVCI、VBS（`hypervisorlaunchtype off`）、Hyper-V、Windows 沙盒、WSL2 与虚拟机监控程序。注意两套反作弊体系对 VBS/HVCI 的态度截然相反（Vanguard Pre-Check/安全页倾向启用 VBS/HVCI，而腾讯游戏安全中心排障指引在虚拟化冲突时要求关闭 HVCI/VBS/Hyper-V），工程预检时必须按 `scope_id` 严格区分，绝不可混用！

TPM、Secure Boot、IOMMU、VBS、HVCI 应分别记录“不存在／存在未启用／已启用／未知”，并注明属于一般配置、设备限制、按需模式或故障排查。

---

## 两条路径的门槛

路径 A：游戏逻辑与商业反作弊在同一 Windows 执行域。当前 Riot 国际范围存在官方 VM 不支持结论，`c-steam-win` 国际范围存在 VM 禁止结论，中国发行（`a-cn-win`、`b-cn-win`、`c-cn-win`）虽无单独的 VM 许可条款页，但 `S-T01` 已显示腾讯反作弊对 CPU 硬件虚拟化与 Hyper-V/虚拟机监控程序占用存在冲突检测；因此没有一款可仅凭本证据集宣布 VM 商业集成通过。自有诊断实验单独报告。

路径 B：Wine 游戏与 guest 驱动跨执行域。A-XBOUND、B-XBOUND、C-XBOUND 及国服跨域接口均未知。只有获得适用发行版本的公开或经授权厂商接口及支持证据后，才有商业组件集成依据；此前只交付自有程序实验和依赖缺口。

---

## 未解决项与待授权沟通问题

| 问题 | 影响 | 当前状态 |
| --- | --- | --- |
| target-a 国际服 Win10 构建号 19041+ / 10904+ 哪个正确？ | 最低 OS 资格 | A-BUILD conflict |
| target-a 国服主下载页 Win10/11 + i3-540 与旧 aclos 页 Win7-11 + E8400 哪个为准？ | 国服最低 OS/CPU 资格 | A-CN-REQ conflict（工程预检优先采用主下载页 Win10/11 + SSE4.2/AVX） |
| target-a 国际服 Vanguard On-Demand 与国服 ACE 是否已分发原生 ARM64 内核驱动二进制？ | 裸金属 WoA 驱动可用性（轴 1） | A-WOA-SPLIT / A-CN-WOA-SPLIT unknown_pending_sampling |
| target-b 原生 Mac 的 Intel-only 开头与 Apple Silicon 表格如何解释？ | 原生 Mac 平台边界 | B-MAC conflict；不影响已明确的 Windows 行 |
| target-b 国服配置图片内“win10”与“Win10\Win11”、推荐内存“16G”与“4G”哪个为准？ | 国服推荐内存与 Win11 标注 | B-CN-REQ conflict |
| 各区域当前内核反作弊驱动（`.sys`）的确切名称、PE Machine、签名及版本？ | 驱动兼容 | A-BIN、B-BIN、C-BIN 及国服内核驱动均 unknown（国服外层安装引导器 x86 PE32 已完成只读静态采样） |
| target-c 国际服 Denuvo 与 EAC、国服《终极角逐》反作弊当前怎样组合？ | 组件身份和诊断路径 | C-KERNEL `complete_current_stack=null`；C-CN 驱动栈 unknown |
| 中国发行的独立 VM 许可条款与公开合作接口？ | 区域覆盖 | A-CN、B-CN、C-CN 的 `vm_policy` 与 `public_interface` unknown |
| 是否存在有明确授权、适用于两执行域的反作弊合作接口？ | 路径 B | XBOUND unknown |

上述仅列公开资料缺口，未联系厂商、提交申请或进入账号。自有 Guest 探针实测已完成；正规安装器动态采样已获授权，当前按共享 Guest 独占排程推进。国际版按需模式公开资格为 Windows 11 25H2+，本次 24H2 Guest 不满足该前提，其分发实测单独保持未测试，不能由自有诊断或国服采样代替。


## B2 真实诊断实验进度

本地实测以 `handoff/phase-2/evidence/window-b/real-windows-probe-report.json` 及 `handoff/module-f/guest-dynamic-observations.json` 为准；它们属于脱敏 Guest 观察，与官方公开资料声明（`evidence.json`）严格分别保存（维护署名：`@DNPMBHC`）。

- **自有 ARM64 诊断探针**：真实 Guest 内核与自有驱动、采集器均为 ARM64，二进制 Machine 为 `0xaa64`。WDK 构建、拥有者测试证书签名，以及 `cycle`、`before-reboot`、真实重启后的 `after-reboot` 全部通过。服务镜像路径、进程对象、子进程创建/退出通知、退出回收、卸载和重启前后哈希均有独立断言。
- **安全基线恢复**：仅在用户明确授权的自有实验阶段临时关闭 Secure Boot。实验结束已清理服务、证书及测试签名配置，真实重启后验证 Secure Boot 开启、TPM 2.0 保持启用、Hypervisor 仍可见、VBS/HVCI 未运行。
- **商业安装器与启动路径动态采样（`target-cn` / `installer-x.exe` `2.17.4.510`，在恢复后的干净安全基线下执行）**：
  1. **未登录安装器与登录器阶段**：官方 32 位 x86 引导器顺利完成安装，释放 64 位 x64 用户态登录器与安全 SDK 组件，在 Windows 11 24H2 ARM64 Prism 转译层下可正常拉起并渲染官方登录界面；此阶段 `b2-inventory-after-prelogin-evidence.json` 证实释放 `0` 个第三方 `.sys` 内核驱动、注册 `0` 个第三方内核服务。
  2. **授权非个人测试账号下载与启动阶段（轴 1 确凿阻塞）**：在独立临时数据盘完成官方客户端包下载后，实测落地的 3 个商业内核驱动二进制（`driver-330` `v1.0.2603.17210`、`driver-331` `v29.8.2609.445`、`driver-332` `v0.1.2610.620`）**PE Machine 全部为 `0x8664`（AMD64）**，均带有有效 WHQL Authenticode 嵌入签名（`WinVerifyTrust = 0x00000000`）。点击启动游戏后，SCM（Event `7045`）注册用户态保护服务与两次内核驱动注册，随后在 ARM64 内核下**无任何商业内核驱动成功加载**（`kernel_load = not_loaded`），触发提示并导致游戏退出（`actual_driver_load = not_loaded`、`actual_game_start = rejected`、`actual_protected_online_session = not_tested`）。
  3. **正交双轴归因**：**轴 1 归因为 `observed_amd64_only_in_sample`**（仅限本次采样渠道与版本，不外推所有渠道）；由于游戏在 ARM64 内核驱动加载阶段即退出、未独立捕获到明确的 Hypervisor/vTPM 策略拒绝弹窗，**轴 2（`axis_2_guest_policy`）保持 `unknown`**，不与轴 1 混为一谈。
  4. **清理与基线复测**：采样结束后已清理系统盘商业组件与临时服务、分离临时数据盘并重启复测（`b2-post-commercial-security-result.json`），确认 Secure Boot 开启、测试签名关闭、TPM 2.0 正常，Guest 已释放。
- **国际服按需模式边界**：国际版按需模式公开资格为 Windows 11 25H2+，本次 24H2 Guest 不满足该前提，其分发实测单独保持未测试，不能由自有诊断或国服采样代替。
