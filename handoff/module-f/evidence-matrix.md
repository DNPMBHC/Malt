# 任务 06：官方支持与兼容证据矩阵

访问日期：2026-11-22（Asia/Shanghai）。本次为当前官方公开资料快照（含 Phase 2 窗口 B 补齐的国服一手来源）；`evidence.json` 本身仅记录公开官方文档证据（未把本地客户端静态取证、驱动或账号测试混入官方文档快照；工作区国服安装器只读静态取证独立记录于 `engineering-input.md` 与 `handoff/phase-2/evidence/window-b/valorant-cn-installer-static.json`）。

数据文件 SHA-256：`e554fb57615c2cd3407bbff001306e2a0f169d98a3113e28624b5fa563a44857`。本表与 `evidence.json` 同源；工程建议与安装器静态取证输入见 `engineering-input.md`。

## 对象、版本及范围

| 中性标识 | 公开研究对象 | 最新可见公开补丁／版本参考 | 安装客户端／驱动版本 |
| --- | --- | --- | --- |
| target-a (Riot) | VALORANT Windows PC (国际) | 13.10（2026-11-10）[S-A05](#s-a05)、[S-A03](#s-a03) | 未采集／未知 |
| target-a (CN) | VALORANT《无畏契约》Windows PC (国服) | 游戏版本 13.09；登录器 2.17.4（2026-10-28）[S-A08](#s-a08)、[S-A06](#s-a06) | 外层安装器 `2.17.4.510` 静态只读已核；落地客户端／内核驱动未安装未知 |
| target-b (Riot) | League of Legends Windows PC (国际) | 26.23（2026-11-17 UTC）[S-B03](#s-b03)、[S-B02](#s-b02) | 未采集／未知 |
| target-b (CN) | 英雄联盟 Windows PC (国服) | Ver 26.23（2026-11-18 公告／11-19 停机发布）[S-B11](#s-b11)、[S-B12](#s-b12) | 未采集／未知 |
| target-c (Steam) | THE FINALS Windows PC (国际) | 12.4.0（2026-11-19）[S-C06](#s-c06)、[S-C05](#s-c05) | 未采集／未知 |
| target-c (CN) | 《终极角逐》THE FINALS 国服 | S3 太空主题赛季（在线运营）[S-C08](#s-c08)、[S-C10](#s-c10) | 未采集／未知 |

“最新可见”仅指当日官方索引、配置接口与对应公告可见内容，不是安装清单，不保证各区域同步。全球站不自动覆盖中国发行；中国发行（`a-cn-win`、`b-cn-win`、`c-cn-win`）均由独立一手官方来源支撑；target-b 原生 macOS 单独处理。

## VM 的四类独立结论

发行方立场另拆许可或条款的“允许／禁止”与官方“支持／不支持”。VAN 9100 描述了该版本 Vanguard 的软件运行拒绝；腾讯游戏安全中心 [S-T01](#s-t01) 描述了异常/风险环境下开启 BIOS CPU 虚拟化及关闭 Windows Hyper-V/VBS/HVCI/虚拟机监控程序占用的排障要求。上述文档均独立保留，不自动等同许可禁止或本机实测失败。

| 范围 | 发行方许可 | 发行方支持 | 驱动加载 | 游戏启动 | 受保护在线会话 | 依据 |
| --- | --- | --- | --- | --- | --- | --- |
| a-riot-win | 未知 | 不支持 | 未实测／未知 | 未实测／未知 | 未实测／未知 | A-VM |
| a-cn-win | 未知 | 未知 | 未实测／未知 | 未实测／未知 | 未实测／未知 | A-CN、A-CN-SEC |
| b-riot-win | 未知 | 不支持 | 未实测／未知 | 未实测／未知 | 未实测／未知 | B-VM |
| b-cn-win | 未知 | 未知 | 未实测／未知 | 未实测／未知 | 未实测／未知 | B-CN |
| c-steam-win | 禁止 | 未知 | 未实测／未知 | 未实测／未知 | 未实测／未知 | C-VM |
| c-jp-win | 未知 | 不支持 | 未实测／未知 | 未实测／未知 | 未实测／未知 | C-JP |
| c-cn-win | 未知 | 未知 | 未实测／未知 | 未实测／未知 | 未实测／未知 | C-CN |

target-c 日本 FAQ 的“虚拟 OS 无法连接”只用于支持／连接限制，不提升为许可禁止。国际支持页则明确禁止 VM。中国发行的三项记录均不从国际服外推，继续保持 `unknown`。

## 驱动架构与系统要求

| 范围 | 已证实执行层级／安全指引 | 二进制 Machine／版本／签名 | 公开最低系统要点 | 证据 |
| --- | --- | --- | --- | --- |
| target-a / Riot Windows | Vanguard 客户端 + 内核模式驱动 | 未知；未检查文件 | Win10 x64 或 Win11 x64；i3-540 / Athlon 200GE；SSE4.2 或 AVX；4GB；DX11；Win11 的 TPM2 / UEFI Secure Boot；ARM 不支持 | A-REQ、A-BUILD、A-KERNEL、A-BIN |
| target-a / 中国 Windows | 腾讯游戏安全中心 CPU 虚拟化与 Hyper-V/VBS/HVCI 冲突排查指引 | 内核驱动二进制未知（外层安装引导器为 32 位 x86 NSIS `2.17.4.510`，不代表内核驱动架构） | 主下载页：Win10/11 64位、i3-540 / Athlon 200GE、SSE4.2 或 AVX、4GB RAM、HD 4000 / R5 200、1GB 显存（旧 aclos 页仍列 Win7-11 与 E8400）；ARM 未声明 | A-CN、A-CN-REQ、A-CN-VER、A-CN-SEC |
| target-b / Riot Windows | Vanguard 客户端 + 内核模式驱动 | 未知；未检查文件 | Win10 x64 19041+ / Win11 x64；i3-530 / FX-4100；SSE4.2；2GB；16GB HDD；DX11 11_0；Win11 TPM2；ARM、Enterprise、Server 不支持 | B-REQ、B-KERNEL、B-BIN |
| target-b / 中国 Windows | 2024 历史 FAQ 排除中国；腾讯游戏安全中心通用指引 | 未知；未检查文件 | 官方配置图片：64位、i5-4460（SSE2）、GTX 750 Ti、1GB 显存、30GB HDD、4G 内存（同图“系统：win10”与“操作系统版本：Win10\Win11”、推荐内存 16G 与 4G 存在行间矛盾）；ARM 未声明 | B-CN、B-CN-REQ、B-CN-VER |
| target-c / 国际 Windows | Steam 标注内核级 Denuvo；Embark 排障仍提 EAC | 完整组件组合与各驱动 Machine 均未知 | Win10 64位+ 且更新；i5-6600K / Ryzen5 1600；12GB；GTX1050Ti / RX580；DX12；ARM 未证实 | C-REQ、C-KERNEL、C-BIN |
| target-c / 中国 Windows | 《终极角逐》安全站在线封禁公示；具体驱动栈未公开 | 未知；未检查文件 | 官网提供客户端下载器、WeGame 入口与 START 云游戏，未刊载本地 PC 硬件最低配置表 | C-CN |

## 公开合作入口与接口边界

| 对象 | 已证实公开入口 | 不得推定的能力 | 状态依据 |
| --- | --- | --- | --- |
| target-a | Riot Developer Portal，产品登记／生产 key／RSO／游戏数据 API | VM allowlist、驱动 ABI、Wine 与 guest 跨域保护 SDK | A-API 已证实；A-XBOUND 未知 |
| target-b | REST、Game Client API、League Client API 文档；后者有官方支持限制 | 本机客户端 API 不是内核保护或跨 guest 认证协议 | B-API 已证实；B-XBOUND 未知 |
| target-c | 官方创作者素材及联系入口；漏洞披露／赏金入口 | 素材、联系或漏洞入口不是反作弊工程集成 SDK | C-API 已证实；C-XBOUND 未知 |

## 区域、平台与未解决问题

| 项目 | 保留结论 | 工程影响 |
| --- | --- | --- |
| A-BUILD | 同页 Win10 表格 19041+，正文 10904+；尚未核清 | 不能宣布唯一官方最低构建已确认；候选筛选采用更高门槛也不消除来源矛盾 |
| A-CN-REQ | 国服主下载页 Win10/11 + i3-540（SSE4.2/AVX）与站内旧 aclos 专题页 Win7-11 + E8400 不一致 | 以主下载页更高门槛做工程预检，但保留官方站内页面冲突记录 |
| B-MAC | 页面 Intel-only 开头，与 M1／macOS12 表格及 Apple Silicon 附注冲突 | macOS CPU 支持细节未知；原生客户端不证明 Windows VM／Wine 可用 |
| B-CN-REQ | 国服下载页配置图片内“win10”与“Win10\Win11”、推荐内存“16G”与“4G”行间矛盾 | 已读取官方图片一手数据，保留行间矛盾，不自行篡改官方数字 |
| C-KERNEL | 当前 Steam Denuvo，与支持／日本 FAQ 中 EAC 的关系未知 | 可能并存、分阶段或文档不同步，当前没有证据选择解释 |
| A-CN / B-CN / C-CN | 国服官网、版本与安全站已核实，但内核驱动二进制、独立 VM 条款与跨域接口未公开 | 驱动 PE Machine 与 VM 实际运行结果须待真实 Windows Guest 授权采样 |

## 逐条证据矩阵

下列摘录均为中文释义。confirmed 指所述官方事实获得证据，不表示游戏兼容通过。unknown 项的引用标明已审阅资料范围，不能证明全网不存在该能力。所有条目更新时间均为 2026-11-22。

| Claim | 发行／平台范围 | 状态 | 结论 | 一手依据与定位／释义 | 限制 |
| --- | --- | --- | --- | --- | --- |
| A-REQ | a-riot-win | confirmed | 公开 PC 要求为 x64；ARM 不支持。Windows 10 构建号有内部冲突，不能视为已核清。 | [S-A01](#s-a01) specification table; Windows Requirements：表格给出 x64、CPU、内存和 DX11；Win11 要求 TPM2 与 Secure Boot。 | 公开资料结论，不代表本机实测。 |
| A-BUILD | a-riot-win | conflict | 同一页面表格 19041+ 与正文 10904+ 不一致；候选环境可先按更高表格门槛筛选，但该筛选不等于官方冲突已解决。 | [S-A01](#s-a01) OS row versus Windows 10 paragraph：两处构建号并不一致。 | 公开资料结论，不代表本机实测。 |
| A-KERNEL | a-riot-win | confirmed | Vanguard 由客户端与内核模式驱动组成。 | [S-R01](#s-r01) opening definition; reinstall paragraph：官方说明内核驱动，并列举两款产品使用 Vanguard。 | 公开资料结论，不代表本机实测。 |
| A-BIN | a-riot-win | unknown | 未取得具体商业驱动的 PE Machine、版本、哈希、签名链或游戏二进制检查结果。 | [S-R01](#s-r01) kernel driver description：只描述执行层级，没有具体二进制属性。 | x64 系统要求不能替代驱动 Machine 证据；本任务未下载安装商业组件。 |
| A-MODE | a-riot-win | confirmed | 通常随开机启动；符合 Pre-Check 条件的设备可按需运行，实际模式未知。 | [S-R01](#s-r01) tray status and startup explanation：当前 FAQ 承认通常开机与可选按需两种路径。；[S-R02](#s-r02) Requirements：按需模式要求 Win11 25H2+ 及列出的安全特性。 | Pre-Check 条件不是所有设备的一般最低配置；VBS 不等于允许 VM guest。 |
| B-KERNEL | b-riot-win | confirmed | Vanguard 由客户端与内核模式驱动组成。 | [S-R01](#s-r01) opening definition; reinstall paragraph：官方说明内核驱动，并列举两款产品使用 Vanguard。 | 公开资料结论，不代表本机实测。 |
| B-BIN | b-riot-win | unknown | 未取得具体商业驱动的 PE Machine、版本、哈希、签名链或游戏二进制检查结果。 | [S-R01](#s-r01) kernel driver description：只描述执行层级，没有具体二进制属性。 | x64 系统要求不能替代驱动 Machine 证据；本任务未下载安装商业组件。 |
| B-MODE | b-riot-win | confirmed | 通常随开机启动；符合 Pre-Check 条件的设备可按需运行，实际模式未知。 | [S-R01](#s-r01) tray status and startup explanation：当前 FAQ 承认通常开机与可选按需两种路径。；[S-R02](#s-r02) Requirements：按需模式要求 Win11 25H2+ 及列出的安全特性。 | Pre-Check 条件不是所有设备的一般最低配置；VBS 不等于允许 VM guest。 |
| A-VM | a-riot-win | confirmed | 规格页明确不支持 VM 与云游戏；通用 VAN 9100 文档另描述该版本 Vanguard 的 VM 运行拒绝，均非本机实测。 | [S-A01](#s-a01) Please Note：规格页明确排除虚拟机和云游戏。；[S-R03](#s-r03) opening error description; Resolution：错误描述称该版本不允许在 VM 或不受支持的虚拟化环境中运行；解决说明称 VM 不受支持，改用物理 Windows 环境。 | 发行方许可字段指许可或条款立场，保持未知；软件文档的运行拒绝不自动作为许可禁止，也不证明具体驱动加载、游戏启动或在线会话结果。 |
| A-API | a-riot-win | confirmed | 存在开发者产品登记、数据与身份接口。 | [S-A02](#s-a02) Registration; RSO Integration; Official APIs：公开门户提供游戏数据和身份合作入口。 | 未申请 key，未提交任何产品或联系厂商。 |
| A-XBOUND | a-riot-win | unknown | 所查公开文档未证实 Wine 游戏与 guest 驱动之间的保护或认证接口。 | [S-A02](#s-a02) reviewed portal interface surface：已公开接口不能作为反作弊驱动桥接授权或 SDK 的证据。 | 仅为已审阅文档中的证据缺口，不声称接口绝对不存在。 |
| A-VER | a-riot-win | confirmed | 访问时官方更新列表最新可见补丁参考为 13.10；本地和区域部署版本未知。 | [S-A05](#s-a05) newest visible patch item：索引首个补丁条目为 13.10。；[S-A03](#s-a03) title and publication date：补丁公告为 13.10，日期 2026-11-10。 | 公开资料结论，不代表本机实测。 |
| A-CN | a-cn-win | unknown | 国服官网、下载页配置要求（A-CN-REQ）、官方下载中心版本接口（A-CN-VER）及腾讯游戏安全中心虚拟化冲突指引（A-CN-SEC）已核实；但国服反作弊内核驱动具体二进制属性、独立 VM 许可/支持条款与跨域接口仍未知。 | [S-A04](#s-a04) homepage navigation and version topic link：国服官网主页正常可读，提供新闻、赛事与当前版本专题入口。；[S-A06](#s-a06) 电脑配置需求; 官方独立安装包：官方下载页列出三档 64 位配置要求并提供官方登录器与 WeGame 下载入口，但未声明虚拟机支持政策或内核驱动架构。 | 系统配置与公开版本已单独建项；未经真实 Guest 安装采样，不得将外层 x86 安装引导器推断为内核驱动架构，也不得外推 VM 允许或支持状态。 |
| B-REQ | b-riot-win | confirmed | Windows 行要求 x64、SSE4.2，ARM 不支持；Enterprise 和 Server 不支持。 | [S-B01](#s-b01) Windows System Requirements table：最低 CPU 为 i3-530 / FX-4100；Win10 19041+，Win11 启用 TPM2。 | 公开资料结论，不代表本机实测。 |
| B-VM | b-riot-win | confirmed | 通用 VAN 9100 文档描述该版本 Vanguard 的 VM 运行拒绝，并称 VM 不受支持；非本机失败实测。 | [S-R03](#s-r03) opening error description; Resolution：错误描述称该版本不允许在 VM 或不受支持的虚拟化环境中运行；解决说明称 VM 不受支持，改用物理 Windows 环境。 | 发行方许可字段指许可或条款立场，保持未知；软件文档的运行拒绝不自动作为许可禁止，也不证明具体驱动加载、游戏启动或在线会话结果。 |
| B-API | b-riot-win | confirmed | 存在游戏数据和客户端接口，但支持级别不同，不能统称为驱动 SDK。 | [S-B05](#s-b05) Game Client API; League Client API：公开本机游戏数据接口；League Client API 文档明确不受开发者支持团队官方支持。 | 本机 HTTPS / 客户端 API 不是内核保护 ABI 或跨 guest 认证协议。 |
| B-XBOUND | b-riot-win | unknown | 已审阅公开开发者文档未证实跨 Wine / guest 的商业反作弊接口。 | [S-B05](#s-b05) reviewed API surface：数据 API 不包含已证实的跨执行域反作弊保护协议。 | 公开资料结论，不代表本机实测。 |
| B-VER | b-riot-win | confirmed | 官方索引最新可见为 26.23；公告源时间 2026-11-17 19:00 UTC，对应上海 11-18 03:00。实际安装与驱动版本未知。 | [S-B03](#s-b03) first patch entry：最新可见条目为 26.23，日期 2026-11-17。；[S-B02](#s-b02) article heading：独立补丁页确认 26.23。 | 公开资料结论，不代表本机实测。 |
| B-MAC | b-native-mac | conflict | 当前要求页的 Intel-only 开头与 Apple Silicon 表格、附注互相矛盾；保持 CPU 支持细节未知。 | [S-B01](#s-b01) intro; macOS System Requirements; closing note：同一页的开头与 macOS 表格和附注不一致。 | 原生 macOS 是独立客户端，不可用于证明 Windows ARM、VM 或 Wine 可用。 |
| B-MAC-AC | b-native-mac | unknown | 2024 官方曾解释 Mac 与 Windows Vanguard 路线不同；未将历史材料视为 2026 当前实现证据。 | [S-B06](#s-b06) platform discussion：历史开发文说明当时 Mac 不部署 Windows Vanguard。 | 公开资料结论，不代表本机实测。 |
| B-CN | b-cn-win | unknown | 国服下载页配置要求图片（B-CN-REQ）与 26.23 版本动态配置及公告（B-CN-VER）已读取核实；2024 历史 FAQ 曾将中国排除在当时的 Vanguard 计划外，当前国服实际反作弊驱动二进制、独立 VM 政策及合作接口仍未知。 | [S-B07](#s-b07) Vanguard will be released with patch 14.9：2024 历史 FAQ 记载除中国以外的 Vanguard 部署计划，不代表 2026 国服现行反作弊实现。；[S-B09](#s-b09) game download; specification image link and OfficialWebsiteCfg script：下载页通过脚本加载当前版本号并引用配置图片，未列出虚拟机支持条款或反作弊驱动架构。；[S-T01](#s-t01) 安全学院 > 公告：关于解决“未开启或有其他软件占用CPU虚拟化功能”弹框的设置指引：腾讯游戏安全中心提供通用 CPU 虚拟化与 Hyper-V/VBS/HVCI 占用排查指引，未单独规定《英雄联盟》国服 VM 许可状态。 | 不从国际服 Vanguard 政策或腾讯通用排障文章外推国服 VM 许可、支持或驱动加载状态。 |
| C-REQ | c-steam-win | confirmed | 国际 PC 要求 64 位 Windows10+、12GB 与 DX12；64 位不等于已证实驱动 AMD64。 | [S-C02](#s-c02) Minimum：官方最低配置列出 OS、CPU、GPU、内存和 DX12。；[S-C01](#s-c01) System Requirements：Steam 同样列出 64 位 Windows 及上述最低 CPU 型号，不作为具体驱动 ISA 的证据。 | 当前所开要求页和 Steam 要求段未列存储容量；不沿用旧 22GB。ARM 支持与二进制 Machine 保持未知。 |
| C-KERNEL | c-steam-win | confirmed | 当前 Steam 标注内核级 Denuvo；Embark 排障文仍提 EAC，完整现行组件组合未知。 | [S-C01](#s-c01) third-party anti-cheat disclosure：商店标注内核级 Denuvo 且需手工卸载。；[S-C03](#s-c03) antivirus exceptions：官方排障仍列 Easy Anti-Cheat。 | 可以并存、分阶段或文档滞后；没有证据选择其中一种解释，不宣布 EAC 已移除。 |
| C-BIN | c-steam-win | unknown | 未取得当前商业驱动具体 Machine、版本、哈希、签名链与实际加载结果。 | [S-C01](#s-c01) kernel anti-cheat disclosure：商店只标注内核级产品，没有驱动二进制属性。 | 公开资料结论，不代表本机实测。 |
| C-VM | c-steam-win | confirmed | 国际支持页明确禁止 VM，记录为发行方许可层面的禁止。 | [S-C03](#s-c03) VM error-code section: TFAV11014, TFAV10014, TFAV9004, TFAV8004, TFAV7004, TFAV6004, TFAV5004, TFAV4004, TFAV3004, TFAV2004, TFAV1004, TFAV0004：官方称 VM 被明确禁止，并列出相应完整性错误码。 | 没有在本机触发这些代码，不记录为实测错误或自动推定封禁结果。 |
| C-SEC | c-steam-win | confirmed | 完整性排障页要求检查系统安全设置；不能将所有可能安全项改写成统一最低规格。 | [S-C03](#s-c03) Check your system security Settings：列出内核隔离、内存完整性与可用时 Secure Boot。 | 公开资料结论，不代表本机实测。 |
| C-JP | c-jp-win | confirmed | 日本官方 FAQ 写有包含 EAC 的多重系统，并称无法从虚拟 OS 连接。 | [S-C04](#s-c04) アンチチートシステム：日本 FAQ 同时说明多系统、EAC 与虚拟 OS 连接限制。 | FAQ 未见更新日期；不得据此判定所有区域的当前完整驱动组合。 |
| C-API | c-steam-win | confirmed | 存在创作者素材及联系入口、公开安全漏洞披露入口；均不是已证实的反作弊集成 SDK。 | [S-C07](#s-c07) Content Creator kit / Need to get in touch：页面提供创作者素材包、品牌素材及联系入口，没有核准正式技术合作计划。；[S-C09](#s-c09) Security researcher / Security Bug Bounty Program hosted by Intigriti：官方引导研究者使用公开漏洞赏金入口；提交需注册，没有提供已证实的跨域保护 SDK。 | 未联系任何公开渠道；创作者合作不等于内核驱动技术合作。 |
| C-XBOUND | c-steam-win | unknown | 已审阅官方产品、支持和合作页面未提供已证实的跨 Wine / guest 保护接口。 | [S-C07](#s-c07) reviewed partnership surface：公开合作页面不能证明工程接口存在。；[S-C09](#s-c09) Security Bug Bounty Program hosted by Intigriti：公开技术合作入口为漏洞披露，不提供已证实的跨域保护集成接口。 | 未找到不等于不存在；通用 EAC SDK 或其他游戏兼容性不能替代本产品授权。 |
| C-VER | c-steam-win | confirmed | 官方首页最新可见更新参考为 12.4.0；精确客户端和驱动 build 未采集。 | [S-C06](#s-c06) latest update tile：首页顶部最新更新为 12.4.0。；[S-C05](#s-c05) heading and date：独立公告显示 12.4.0 / 2026.11.19。 | 公开资料结论，不代表本机实测。 |
| C-CN | c-cn-win | unknown | 已通过 Nexon 官方公告内嵌链接核实腾讯运营的国服《终极角逐》官网（当前为 S3 太空主题赛季，提供官网下载器、WeGame 入口与腾讯 START 云游戏入口）及《终极角逐》安全站；但公开页面未列出 PC 最低硬件配置表、具体反作弊驱动二进制或本地 VM 政策。 | [S-C08](#s-c08) Official announcement body; Official website link to thefinals.qq.com：Nexon 2025-10-30 英文公告宣布与腾讯合作于 11 月 18 日在中国开启公测，并给出 thefinals.qq.com 官方网站链接。；[S-C10](#s-c10) navigation bar; 官网下载; WeGame下载; 云游戏体验; 安全站：国服《终极角逐》官网当前展示 S3 太空主题赛季，提供官网客户端下载器、WeGame 商店页及腾讯 START 云游戏链接，未刊载本地 PC 硬件最低配置表。；[S-C11](#s-c11) 《终极角逐》安全站：累计封禁10年作弊账号 / 账号状态 / 处罚情况：官方安全站展示封禁处罚公示与举报查询功能，未公开具体内核反作弊驱动名称、PE 架构或本地虚拟机策略。 | 已确认国服《终极角逐》在线运营及安全站存在，但本地 PC 最低配置、驱动二进制架构及 VM 许可/支持状态仍无官方公开文档证实，继续保持未知。 |
| P-ARM | platform-arm | confirmed | 微软明确 ARM Windows 的内核驱动须为原生 Arm64；用户态 x64 转译不能证明驱动可运行。 | [S-P01](#s-p01) Limitations / drivers and gaming：驱动须为 Arm64；依赖未适配反作弊驱动的游戏可能不能运行。 | 这是平台约束；没有据此为三款产品臆造具体驱动 Machine 或 ARM 支持状态。 |
| B-HIST-API | b-riot-win | confirmed | 2024 历史 FAQ 明确不提供 Vanguard allowlist；这不证明 2026 私有合作接口不存在。 | [S-B07](#s-b07) Can I have a Vanguard allowlist?：官方历史回答为没有 allowlist。 | 历史规则仅用于澄清公开入口，不能覆盖当前个别合作；跨执行域接口继续未知。 |
| P-PDARM | platform-parallels-arm | confirmed | Parallels 的 ARM guest 限制页列出无嵌套虚拟化、VBS 和 DX12；这只是该路径的平台约束。 | [S-P02](#s-p02) Limitations; nested virtualization and DirectX 12：官方平台页分别列出嵌套虚拟化相关安全功能及 DX12 限制。 | 不从这些平台资料赋予任何游戏许可或实测状态；也不外推到其他 provider 或 x86 预览模式。 |
| P-PDX86 | platform-parallels-x86 | confirmed | Parallels 另有 x86 早期预览仿真，文档限制单 vCPU、8GB 和无嵌套虚拟化；不能概括为 Apple silicon 永远不能启动 x86 guest。 | [S-P03](#s-p03) Supported guest OS; limitations; enable nested virtualization：官方列 Windows11/Server2022 x86 预览路径及资源、安全功能限制。 | 这是另一条 CPU 仿真路径，不等于厂商反作弊支持；未安装该后端、未启动 guest、未做性能测量。 |
| A-SEC | a-riot-win | confirmed | Vanguard 通用安全页按设备适用性列出安全特性；不满足适用条件可能导致受限或阻止启动，但并非所有设备统一要求全部特性。 | [S-R04](#s-r04) Requirements Overview; Compatibility note; Why Vanguard Has These Requirements：按适用设备列出 Secure Boot、TPM2、IOMMU、VBS、HVCI；部分较旧配置不要求每项特性。 | 该共享 Vanguard 指引与 Pre-Check 按需模式门槛分开；具体设备、二进制版本和运行结果未知，不适用到中国发行。 |
| B-SEC | b-riot-win | confirmed | Vanguard 通用安全页按设备适用性列出安全特性；不满足适用条件可能导致受限或阻止启动，但并非所有设备统一要求全部特性。 | [S-R04](#s-r04) Requirements Overview; Compatibility note; Why Vanguard Has These Requirements：按适用设备列出 Secure Boot、TPM2、IOMMU、VBS、HVCI；部分较旧配置不要求每项特性。 | 该共享 Vanguard 指引与 Pre-Check 按需模式门槛分开；具体设备、二进制版本和运行结果未知，不适用到中国发行。 |
| A-CN-REQ | a-cn-win | conflict | 国服主下载页要求 Win10/11 64位、i3-540 / Athlon 200GE、SSE4.2 或 AVX、4GB 内存及 1GB 显存；但站内旧 aclos 专题页仍显示 Win7/8/10/11 与 Core 2 Duo E8400，两页未同步。 | [S-A06](#s-a06) 电脑配置需求 table (最低配置 / 推荐配置 / 高等配置 / 其他需求)：主下载页列出 Win10、11 64位，最低 i3-540 / Athlon 200GE，要求 CPU 支持 SSE4.2 指令集或打开 AVX Support 设置。；[S-A07](#s-a07) 最低配置 / 中等配置 / 推荐配置 table：aclos 专题页仍列出 Win 7、8、10、11 64位及最低 Intel Core 2 Dou E8400。 | 官方主下载页已收敛至 Win10/11 64位，但因同站专题页存在旧表格，按 conflict 记录；两页均未声明 Windows ARM 支持状态。 |
| A-CN-VER | a-cn-win | confirmed | 国服官方下载中心接口返回当前公开游戏版本 13.09、登录器版本 2.17.4（更新日期 2026.10.28）及官方独立安装包 VALORANT_CN_installer_v2.17.4.510.exe。 | [S-A08](#s-a08) JSON fields: game_version, aclos_download_center.verNum, verDate, verUrl：官方接口返回 game_version=13.09，verNum=2.17.4，verDate=2026.10.28，下载链接指向 VALORANT_CN_installer_v2.17.4.510.exe。；[S-A06](#s-a06) inline script $.get('https://api.val.qq.com/go/agame/resource/kv?key=aclos_download_center')：主下载页通过该接口动态渲染游戏版本、登录器版本、更新时间与下载按钮链接。 | 公开接口版本与安装包文件名已核实（与工作区静态取证样本一致），但未在 Guest 中执行安装，实际落地游戏客户端 build 与内核反作弊驱动版本仍为 null。 |
| A-CN-SEC | a-cn-win | confirmed | 腾讯游戏安全中心官方指引说明：针对可能存在异常登录环境或风险的账号会弹窗要求在 BIOS 开启 VT-x/VT-d 或 SVM/IOMMU，并在冲突时关闭 Windows HVCI、VBS、Hyper-V、沙盒、WSL2 或虚拟机监控程序。 | [S-T01](#s-t01) Part1 BIOS VT-X/VT-D/SVM/IOMMU; Part2 情况一 HVCI / 情况二 VBS / 情况三 HYPERV; Part3 Q&A：官方文章说明该功能由腾讯游戏安全团队与微软合作开启系统硬件安全特性；若 BIOS 开启后仍弹窗，需关闭 HVCI、VBS（hypervisorlaunchtype off）及 Hyper-V / 虚拟机监控程序。 | 该指引证明腾讯安全组件会检测并接管宿主 CPU 虚拟化特性且与 Hyper-V/VBS/虚拟机监控程序冲突，但属于通用安全排障文档，不自动等同于发行方许可条款或本机 Guest 实测失败。 |
| B-CN-REQ | b-cn-win | conflict | 国服下载页官方配置表图片列出 64 位系统、最低 i5-4460（SSE2）/ GTX 750 Ti / 1GB 显存 / 30GB HDD；但同一张表格内部“系统（win10）”与“操作系统版本（Win10\Win11）”、推荐档“内存（16G）”与“内存RAM（4G）”存在行间矛盾。 | [S-B09](#s-b09) specification image reference //ossweb-img.qq.com/images/lol/down/pic-down.jpg：国服官网下载页通过图片提供电脑配置要求。；[S-B10](#s-b10) 最低配置（可用） vs 推荐配置（流畅） rows：官方图片给出 CPU、SSE2/SSE4、GPU、30GB 存储与 64 位架构，但系统行与操作系统版本行、推荐内存 16G 行与 4G 行不一致。 | 官方配置图片已直接读取并如实记录行间不一致；图片未提及 ARM 支持或虚拟机政策。 |
| B-CN-VER | b-cn-win | confirmed | 国服官网 CMS 配置脚本与版本更新公告确认当前公开版本为 Ver 26.23（公告发布于 2026-11-18 18:51:48，定于 11 月 19 日凌晨停机更新）。 | [S-B11](#s-b11) OfficialWebsiteCfg.button.version and button.href：动态配置脚本返回 version='Ver 26.23' 及版本公告链接。；[S-B12](#s-b12) heading '26.23版本更新公告'; timestamp '2026-11-18 18:51:48'; opening maintenance notice：国服官方公告确认 11 月 19 日凌晨 1 点全区停机发布 26.23 版本。 | 公开版本参考不等于实际安装客户端 build 或反作弊内核驱动版本。 |
| P-WOA-PRISM | platform-arm | confirmed | Windows 11 24H2+ 的 Prism 转译器在用户态支持 x86/x64 及 AVX、AVX2、BMI、FMA、F16C 等指令集扩展（64位默认暴露，32位 x86 可通过“Show newer emulated CPU features”开启）；但内核态无任何转译，内核驱动必须编译为原生 Arm64。 | [S-P04](#s-p04) Prism; How emulation works; Detecting emulation：Windows 11 24H2 引入 Prism 转译 x86（WOW64）与 x64（Arm64X）；官方明确指出转译仅支持用户态代码，不支持驱动，任何内核态组件必须编译为 Arm64。；[S-P05](#s-p05) Hide newer emulated CPU features; Show newer emulated CPU features：Windows 11 24H2+ 中 Prism 新增支持 AVX、AVX2、BMI、FMA、F16C 等指令集扩展；32位 x86 应用默认不暴露这些新特性，可通过勾选 Show newer emulated CPU features 开启。；[S-P06](#s-p06) Emulation on Arm-based devices for x86 or x64 Windows apps：内核不包含转译，内核驱动须构建为原生 Arm64，该限制直接影响虚拟化与底层驱动场景。 | Prism 解决了用户态 SSE4.2/AVX/AVX2 游戏与登录器的指令集门槛，但不能替反作弊厂商生成原生 Arm64 内核驱动，也不消除反作弊对 Hypervisor/VM 的策略拦截。 |
| A-WOA-SPLIT | a-riot-win | confirmed | 国际服 VALORANT（Vanguard / On-Demand）在 ARM64 下必须拆分为两个正交维度：（1）裸金属 WoA 驱动可用性：Prism 已满足用户态 SSE4.2/AVX，但公开规格页仍标 ARM 不支持，On-Demand 模式是否已分发原生 ARM64 驱动二进制待实测核查；（2）虚拟化 ARM64 Guest 策略：VAN 9100 明确拒绝 VM，且 On-Demand 要求 IOMMU/VBS/HVCI 硬件信任根，与“有无 ARM64 驱动”属不同层级的独立阻塞。 | [S-A01](#s-a01) Windows Requirements: SSE4.2 / AVX; ARM not supported; Please Note: VM excluded：规格页同时列出 CPU 指令集要求、ARM 不支持与 VM 不支持，需在工程诊断中解耦。；[S-R02](#s-r02) Vanguard Pre-Check Requirements (Win11 25H2+, Secure Boot, TPM 2.0, IOMMU, VBS, HVCI)：On-Demand 按需模式要求 Win11 25H2+ 及完整硬件虚拟化安全信任根。；[S-R03](#s-r03) VAN 9100 error description and resolution：VAN 9100 专门针对虚拟机或不受支持的虚拟化环境拒绝运行。；[S-P05](#s-p05) Hide newer emulated CPU features (AVX/AVX2 in Windows 11 24H2+)：Windows 11 24H2+ Prism 已在用户态提供 AVX/AVX2 转译，排除纯用户态 SSE4.2/AVX 指令集缺失问题。 | 随着 Windows on ARM 生态（如 Snapdragon X 及 NVIDIA N1/N1X 平台）演进，即使未来裸金属 WoA 获得原生 ARM64 Vanguard 驱动，虚拟化 ARM64 Guest 仍受 VAN 9100 与 vTPM/IOMMU/VBS 策略独立限制，二者严禁混为一谈。 |
| A-CN-WOA-SPLIT | a-cn-win | confirmed | 国服《无畏契约》（腾讯 ACE）在 ARM64 下同样必须拆分为两个正交维度：（1）裸金属 WoA 驱动可用性：国服下载页要求 64 位 Win10/11 与 SSE4.2/AVX（未明文禁止 ARM），外层 32 位 x86 安装器可经 WOW64/Prism 运行，实际释放的 ACE 内核驱动是否含原生 ARM64 二进制待动态采样；（2）虚拟化 ARM64 Guest 策略：腾讯安全中心明确检测并排斥 Hyper-V、VBS 及虚拟机监控程序占用 CPU 虚拟化功能。 | [S-A06](#s-a06) 电脑配置需求：Win10、11 64位；其他需求：CPU需要支持SSE4.2指令集 或 打开AVX Support设置：国服配置表仅规定 64 位系统与 SSE4.2/AVX 指令集，未显式列明 ARM 架构限制。；[S-T01](#s-t01) Part1 BIOS VT-X/VT-D/SVM/IOMMU; Part2 情况一 HVCI / 情况二 VBS / 情况三 HYPERV 与虚拟机监控程序：腾讯游戏安全中心针对异常/风险环境要求独占开启硬件虚拟化，并要求关闭 Hyper-V、VBS（hypervisorlaunchtype off）及虚拟机监控程序。；[S-P04](#s-p04) How emulation works: WOW64 for x86, Arm64X for x64, native Arm64 required for kernel drivers：外层 32 位 x86 安装器与 64 位用户态组件可由 WOW64/Prism 转译，但 ACE 内核驱动必须具有原生 Arm64 二进制才能在 Arm 内核加载。；[S-P05](#s-p05) Show newer emulated CPU features for 32-bit x86 apps：若 32 位 x86 启动器/安装器检测 AVX，可在 Windows 11 24H2+ Prism 设置中为 32 位应用显式开启新 CPU 特性暴露。 | 在阶段 B2 真实 Windows 11 ARM64 Guest 动态采样中，必须根据实际产物与错误码严格区分“ACE 未释放 ARM64 驱动 / 驱动 PE Machine 为 AMD64 无法加载”与“ACE 检测到 Hypervisor/虚拟化占用而弹窗拒绝”。 |

## 一手来源目录

页面日期类型：publication=明确公告日期；last_updated=页面明确最后更新；page_display=页面显示日期但未猜测发布／更新；not_displayed=未见可核验日期。来源时区未显示的保持未知。成功访问日期按来源逐项列出；S-B04 保留 2026-11-21。访问时区均为 Asia/Shanghai。

### S-A01

- 标题：Minimum & Recommended PC Specs
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://support.riotgames.com/en-us/valorant/support-tools/minimum-recommended-pc-specs
- 页面日期：2026-05-21；类型：page_display；来源时区：未知
- 适用发行／平台：Riot VALORANT Windows PC; China not inferred
- 结构化适用范围：a-riot-win
- 版本范围：Current public page; not bound to an installed binary build
- 访问结果：opened

### S-R01

- 标题：What is Vanguard?
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://support.riotgames.com/en-us/riot/performance/what-is-vanguard
- 页面日期：2026-06-02；类型：page_display；来源时区：未知
- 适用发行／平台：Riot Vanguard; names both target-a and target-b
- 结构化适用范围：a-riot-win, b-riot-win
- 版本范围：Current public page; not bound to an installed binary build
- 访问结果：opened

### S-R02

- 标题：Vanguard Pre-Check
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://support.riotgames.com/en-us/riot/performance/vanguard-pre-check
- 页面日期：2026-06-24；类型：page_display；来源时区：未知
- 适用发行／平台：Riot Vanguard optional on-demand mode
- 结构化适用范围：a-riot-win, b-riot-win
- 版本范围：Windows 11 25H2+ mode eligibility; not general game minimum
- 访问结果：opened

### S-R03

- 标题：VAN 9100
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://support.riotgames.com/en-us/riot/client/error-van-9100
- 页面日期：2026-07-16；类型：page_display；来源时区：未知
- 适用发行／平台：Riot client / Vanguard VM rejection; China not inferred
- 结构化适用范围：a-riot-win, b-riot-win
- 版本范围：Current public page; not bound to an installed binary build
- 访问结果：opened

### S-A02

- 标题：Riot Developer Portal - VALORANT
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://developer.riotgames.com/docs/valorant
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：Riot public developer documentation; no regional deployment guarantee
- 结构化适用范围：a-riot-win
- 版本范围：Current public page; not bound to an installed binary build
- 访问结果：opened

### S-A03

- 标题：VALORANT Patch Notes 13.10
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://playvalorant.com/en-us/news/game-updates/valorant-patch-notes-13-10/
- 页面日期：2026-11-10；类型：publication；来源时区：UTC
- 适用发行／平台：Riot English public patch announcement
- 结构化适用范围：a-riot-win
- 版本范围：13.10; publication timestamp 2026-11-10T14:00:00Z
- 访问结果：opened

### S-A04

- 标题：VALORANT《无畏契约》官方网站-腾讯游戏
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://val.qq.com/main.html
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：China mainland official product site
- 结构化适用范围：a-cn-win
- 版本范围：Current public homepage linking to 2026-10-28 version topic page; not an installed binary build
- 访问结果：opened

### S-A05

- 标题：Game Updates - VALORANT
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://playvalorant.com/en-us/news/game-updates/
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：Riot English announcement index
- 结构化适用范围：a-riot-win
- 版本范围：Newest visible patch on access: 13.10
- 访问结果：opened

### S-B01

- 标题：Minimum and Recommended System Requirements (League of Legends)
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://support.riotgames.com/en-us/league-of-legends/performance/minimum-and-recommended-system-requirements-league-of-legends
- 页面日期：2026-09-22；类型：page_display；来源时区：未知
- 适用发行／平台：Riot Windows and native macOS requirements; China not inferred
- 结构化适用范围：b-riot-win, b-native-mac
- 版本范围：Current public page; not bound to an installed binary build
- 访问结果：opened

### S-B02

- 标题：League of Legends Patch 26.23 Notes
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://www.leagueoflegends.com/en-us/news/game-updates/league-of-legends-patch-26-23-notes/
- 页面日期：2026-11-17；类型：publication；来源时区：UTC
- 适用发行／平台：Riot English public patch announcement
- 结构化适用范围：b-riot-win
- 版本范围：26.23; publication timestamp 2026-11-17T19:00:00Z; Asia/Shanghai 2026-11-18 03:00; not installed build
- 访问结果：opened

### S-B03

- 标题：Patch Notes - League of Legends
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://www.leagueoflegends.com/en-us/news/tags/patch-notes/
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：Riot English patch index
- 结构化适用范围：b-riot-win
- 版本范围：Newest visible patch on access: 26.23
- 访问结果：opened

### S-B04

- 标题：Vanguard is live on League of Legends
- 成功读取日期：2026-11-21（Asia/Shanghai）
- 公开 URL：https://www.riotgames.com/en/DevRel/vanguard-is-live-on-league-of-legends
- 页面日期：2024-04-30；类型：publication；来源时区：未知
- 适用发行／平台：Historical Riot deployment explicitly excluding China
- 结构化适用范围：b-riot-win, b-cn-win
- 版本范围：14.9 rollout; historical only
- 访问结果：opened

### S-B05

- 标题：Riot Developer Portal - League of Legends
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://developer.riotgames.com/docs/lol
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：Riot developer APIs; client APIs have separate support caveats
- 结构化适用范围：b-riot-win
- 版本范围：Current public page; not bound to an installed binary build
- 访问结果：opened

### S-B06

- 标题：/dev: Vanguard x LoL
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://www.leagueoflegends.com/en-us/news/dev/dev-vanguard-x-lol/
- 页面日期：2024-04-11；类型：publication；来源时区：UTC
- 适用发行／平台：Historical Windows / native Mac distinction
- 结构化适用范围：b-riot-win, b-native-mac
- 版本范围：Historical 2024 explanation; timestamp 2024-04-11T17:00:00Z; not current native Mac protection proof
- 访问结果：opened

### S-C01

- 标题：THE FINALS on Steam
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://store.steampowered.com/app/2073850/THE_FINALS/
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：Publisher-managed international Steam PC product listing
- 结构化适用范围：c-steam-win
- 版本范围：Live store snapshot; original release date is not requirements update date
- 访问结果：opened

### S-C02

- 标题：System Requirements - PC
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://id.embark.games/the-finals/support/faq/25-system-requirements---pc
- 页面日期：2026-02-12；类型：last_updated；来源时区：未知
- 适用发行／平台：Embark international PC support
- 结构化适用范围：c-steam-win
- 版本范围：Current public page; not bound to an installed binary build
- 访问结果：opened

### S-C03

- 标题：System Integrity Violation
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://id.embark.games/the-finals/support/faq/78-system-integrity-violation
- 页面日期：2026-02-16；类型：last_updated；来源时区：未知
- 适用发行／平台：Embark international PC security support
- 结构化适用范围：c-steam-win
- 版本范围：Current public page; not bound to an installed binary build
- 访问结果：opened

### S-C04

- 标题：セキュリティ | THE FINALS 公式サイト
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://thefinals-jp.nexon.com/support/faq/security
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：Nexon Japan official PC security FAQ
- 结构化适用范围：c-jp-win
- 版本范围：Current public page; not bound to an installed binary build
- 访问结果：opened

### S-C05

- 标题：Update 12.4.0
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://www.reachthefinals.com/patchnotes/12-40
- 页面日期：2026-11-19；类型：publication；来源时区：未知
- 适用发行／平台：Embark international public patch announcement
- 结构化适用范围：c-steam-win
- 版本范围：12.4.0
- 访问结果：opened

### S-C06

- 标题：THE FINALS official home
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://www.reachthefinals.com/home
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：Embark international official announcement index
- 结构化适用范围：c-steam-win
- 版本范围：Newest visible update on access: 12.4.0
- 访问结果：opened

### S-C07

- 标题：Content Creators - THE FINALS
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://www.reachthefinals.com/content-creators
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：Official content-creator contact and asset kit; not an anti-cheat engineering SDK
- 结构化适用范围：c-steam-win
- 版本范围：Current public page; not bound to an installed binary build
- 访问结果：opened

### S-C08

- 标题：Nexon Announces November 18 Open Beta of THE FINALS® in China
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://www.nexon.co.jp/en/news/detail/?id=20251030-efa85af8
- 页面日期：2025-10-30；类型：publication；来源时区：未知
- 适用发行／平台：Historical announcement of a separate China edition
- 结构化适用范围：c-cn-win
- 版本范围：Official 2025-10-30 announcement linking to Tencent China official site thefinals.qq.com
- 访问结果：opened

### S-P01

- 标题：Windows Arm-based PCs FAQ
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://support.microsoft.com/en-us/windows/windows-arm-based-pcs-faq-477f51df-2e3b-f68f-31b0-06f5e4f8ebb5
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：Microsoft Windows 10/11 Arm platform documentation
- 结构化适用范围：platform-arm
- 版本范围：Native Arm64 driver requirement; not a game support statement
- 访问结果：opened

### S-C09

- 标题：Security - Embark Studios
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://www.embark-studios.com/security
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：Responsible vulnerability disclosure and bug-bounty entry; not a game integration SDK
- 结构化适用范围：c-steam-win
- 版本范围：Current public disclosure policy; no game build binding
- 访问结果：opened

### S-B07

- 标题：Vanguard FAQ for Third Party Applications
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://www.riotgames.com/en/DevRel/vanguard-faq
- 页面日期：2024-04-01；类型：page_display；来源时区：未知
- 适用发行／平台：Historical Riot third-party FAQ; includes a China exclusion in the planned rollout
- 结构化适用范围：b-riot-win, b-cn-win
- 版本范围：Page displays Apr 1 but body includes Apr 16 information; not a verified last-update date; planned patch 14.9 rollout
- 访问结果：opened

### S-B08

- 标题：英雄联盟官方网站—腾讯游戏
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://lol.qq.com/main.shtml
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：China mainland official homepage; navigation and placeholder version only
- 结构化适用范围：b-cn-win
- 版本范围：Static HTML uses version placeholder ***; live version populated via S-B11 OfficialWebsiteCfg
- 访问结果：opened_partial

### S-B09

- 标题：游戏下载-英雄联盟官方网站-腾讯游戏
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://lol.qq.com/download.shtml?ADTAG=lolweb.v3
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：China mainland official download page; requirements are linked as an image
- 结构化适用范围：b-cn-win
- 版本范围：Body and inline OfficialWebsiteCfg script opened; linked requirements image S-B10 read on 2026-11-22
- 访问结果：opened

### S-P02

- 标题：Limitations of Windows 11 on Apple silicon Macs
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://kb.parallels.com/129497
- 页面日期：2025-08-07；类型：page_display；来源时区：未知
- 适用发行／平台：Parallels Desktop for Mac / Windows 11 Arm on Apple silicon; platform constraints only
- 结构化适用范围：platform-parallels-arm
- 版本范围：Page labels All versions; Last Review 2025-08-07, not a game or installed provider version
- 访问结果：opened

### S-P03

- 标题：Parallels Desktop x86 emulator: general information and limitations
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://kb.parallels.com/en/130217
- 页面日期：2025-12-17；类型：page_display；来源时区：未知
- 适用发行／平台：Parallels x86 emulator on Apple silicon; early technology preview, not normal Arm guest mode
- 结构化适用范围：platform-parallels-x86
- 版本范围：Introduced in Desktop 20.2.0; page labels All versions; Last Review 2025-12-17; no game qualification
- 访问结果：opened

### S-R04

- 标题：Vanguard Security Requirements
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://support.riotgames.com/en-us/riot/performance/vanguard-security-requirements
- 页面日期：2026-06-22；类型：page_display；来源时区：未知
- 适用发行／平台：Riot Vanguard security requirements; device-dependent conditions; China not inferred
- 结构化适用范围：a-riot-win, b-riot-win
- 版本范围：Current shared Vanguard guidance; no exact game or driver build; not Pre-Check mode requirements
- 访问结果：opened

### S-A06

- 标题：游戏下载-VALORANT《无畏契约》官方网站-腾讯游戏
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://val.qq.com/download.html
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：China mainland official download and PC system requirements page
- 结构化适用范围：a-cn-win
- 版本范围：Current public download page; fetches live installer metadata from S-A08
- 访问结果：opened

### S-A07

- 标题：无畏契约官方网站-腾讯游戏 (aclos 专题下载页)
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://val.qq.com/act/a20230708aclos/index.html
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：China mainland official aclos launcher download page with legacy spec table
- 结构化适用范围：a-cn-win
- 版本范围：Displays legacy game version 7.0.0 and older Win7/8/10/11 table; conflicts with S-A06
- 访问结果：opened

### S-A08

- 标题：无畏契约官方下载中心版本与安装包元数据接口 (aclos_download_center)
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://api.val.qq.com/go/agame/resource/kv?key=aclos_download_center
- 页面日期：2026-10-28；类型：page_display；来源时区：Asia/Shanghai
- 适用发行／平台：China mainland official download metadata endpoint consumed by S-A06
- 结构化适用范围：a-cn-win
- 版本范围：game_version 13.09; launcher verNum 2.17.4; installer VALORANT_CN_installer_v2.17.4.510.exe; verDate 2026.10.28
- 访问结果：opened

### S-T01

- 标题：关于解决“未开启或有其他软件占用CPU虚拟化功能”弹框的设置指引 - 腾讯游戏安全中心
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://gamesafe.qq.com/article/1181.shtml
- 页面日期：2026-01-04；类型：publication；来源时区：Asia/Shanghai
- 适用发行／平台：Tencent Game Security Center official CPU virtualization and Hyper-V/VBS/HVCI conflict troubleshooting guide
- 结构化适用范围：a-cn-win, b-cn-win, c-cn-win
- 版本范围：Published 2026-01-04 11:24:18; shared Tencent Game Security guidance, not a per-game VM license grant
- 访问结果：opened

### S-B10

- 标题：英雄联盟国服官网下载页配置要求表 (pic-down.jpg)
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://ossweb-img.qq.com/images/lol/down/pic-down.jpg
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：China mainland official system requirements table image embedded by S-B09
- 结构化适用范围：b-cn-win
- 版本范围：Current public image on lol.qq.com/download.shtml; contains internal row discrepancies
- 访问结果：opened

### S-B11

- 标题：英雄联盟国服官网版本与下载配置脚本 (website_cfg.js)
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://lol.qq.com/act/AutoCMS/publish/LOLWeb/OfficialWebsite/website_cfg.js
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：China mainland official CMS configuration script consumed by S-B08 and S-B09
- 结构化适用范围：b-cn-win
- 版本范围：Populates current version Ver 26.23 and patch announcement link S-B12
- 访问结果：opened

### S-B12

- 标题：26.23版本更新公告 - 英雄联盟官方网站-腾讯游戏
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://lol.qq.com/gicp/news/410/37102797.html
- 页面日期：2026-11-18；类型：publication；来源时区：Asia/Shanghai
- 适用发行／平台：China mainland official patch 26.23 release notes
- 结构化适用范围：b-cn-win
- 版本范围：Patch 26.23; published 2026-11-18 18:51:48 Asia/Shanghai for 2026-11-19 01:00 maintenance rollout
- 访问结果：opened

### S-C10

- 标题：银河大师赛！《终极角逐》S3太空主题赛季正式上线-腾讯游戏
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://thefinals.qq.com/cp/web20250814/index.html
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：China mainland official THE FINALS (终极角逐) website operated by Tencent
- 结构化适用范围：c-cn-win
- 版本范围：Current live S3 season official site; provides official downloader, WeGame store link, and START cloud gaming link
- 访问结果：opened

### S-C11

- 标题：《终极角逐》安全站
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://thefinals.qq.com/cp/a20251111anquan/
- 页面日期：未知；类型：not_displayed；来源时区：未知
- 适用发行／平台：China mainland official THE FINALS (终极角逐) anti-cheat and security center page
- 结构化适用范围：c-cn-win
- 版本范围：Current public security portal showing 10-year ban enforcement notices and report tools; no driver binary or VM policy table
- 访问结果：opened

### S-P04

- 标题：How emulation works on Arm | Microsoft Learn
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation
- 页面日期：2025-11-06；类型：page_display；来源时区：UTC
- 适用发行／平台：Microsoft official Windows 11 24H2+ Prism user-mode emulation and kernel-mode Arm64 driver boundary documentation
- 结构化适用范围：platform-arm, a-riot-win, a-cn-win, b-riot-win, b-cn-win, c-steam-win, c-cn-win
- 版本范围：Windows 11 24H2+ Prism; ms.date 2025-11-06; applies to all supported Windows 11 on Arm devices
- 访问结果：opened

### S-P05

- 标题：Adjust Emulation Settings on Arm | Microsoft Learn
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-program-compat-troubleshooter
- 页面日期：2025-12-05；类型：page_display；来源时区：UTC
- 适用发行／平台：Microsoft official Prism CPU feature emulation documentation (AVX, AVX2, BMI, FMA, F16C for x64 and 32-bit x86 toggle)
- 结构化适用范围：platform-arm, a-riot-win, a-cn-win, b-riot-win, b-cn-win, c-steam-win, c-cn-win
- 版本范围：Windows 11 24H2 and newer; ms.date 2025-12-05
- 访问结果：opened

### S-P06

- 标题：Add support Arm devices to your Windows app | Microsoft Learn
- 成功读取日期：2026-11-22（Asia/Shanghai）
- 公开 URL：https://learn.microsoft.com/en-us/windows/arm/add-arm-support
- 页面日期：2025-11-06；类型：page_display；来源时区：UTC
- 适用发行／平台：Microsoft official developer guide on native Arm64 kernel driver requirement and virtualization scenarios
- 结构化适用范围：platform-arm, a-riot-win, a-cn-win
- 版本范围：ms.date 2025-11-06; covers Visual Studio 2022 Arm64 and WDK Arm64 driver requirements
- 访问结果：opened

## 验证和交付边界

本目录的数据与说明独立交付给任务 01、02 及 Phase 2 各窗口；没有修改共享模型、UI、guest provider 或其他模块。校验包含唯一 ID、引用完整性、官方域名、日期、区域归属、驱动未知值、政策与实测分离；反例测试防止状态自动升级。
