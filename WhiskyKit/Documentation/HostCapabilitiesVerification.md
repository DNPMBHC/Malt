# 宿主能力与资源策略验收记录

验收日期：2026-11-22（Asia/Shanghai）。首批 Apple 来源访问于 2026-11-21，补充来源访问于 2026-11-22；逐项日期保存在来源清单中。路径统一使用 /workspace/my-project、HostKit 和 SDK_ROOT 代称。

本次实现静态能力缓存、动态状态通知和可恢复的专用队列策略，并完成真实 SHA256 消费者与 MetalFX 合成 GPU A/B。完整包测试 85 项通过；宿主 15 个 Swift 文件 strict lint 为 0 违规。当前轻量合成场景中，MetalFX 比 nearest 更慢。没有游戏性能或能耗改善结论；当前标准 App Debug 构建通过。

## 范围与任务 05 对接

新增 9 个独立宿主源码、4 个 XCTest 文件、2 个诊断工具及本目录证据。共享 RuntimeHostSnapshot 的字段、签名和原采集入口归任务 05；本任务未接线 UI、启动入口、Wine、guest 或生产渲染器，未提交、未推送。

- HostCapabilityProvider.current() 在进程内仅初始化一次静态系统事实及 Metal 设备清单；按 registryID/name/isLowPower 缓存选定设备的 spatial/temporal 支持查询。热状态和低电量模式每次读系统当前值。合成报告不写设备名称和 registry ID。
- HostResourceStateMonitor 注册前读取状态，注册后补一次刷新；默认通知中心接收 thermalStateDidChangeNotification、NSProcessInfoPowerStateDidChange，workspace 通知中心接收 didWakeNotification。同一主队列轮次合并通知，仅变化时发布，无固定轮询或反复 GPU 初始化。
- stop 注销观察者并丢弃尚未开始的排队刷新；已经开始的读取或回调可能继续完成。HostResourceController 通过代次校验拒绝停止前的旧回调，防止恢复基线后重新施策。
- 静态设备清单按进程生命周期缓存。任务 05/03 仍需定义外接 GPU 热插拔、设备失效和实际渲染设备选择的生命周期接线；缓存支持值不能证明旧设备仍可执行。
- gpuDeveloperToolsAvailable 仅表示 xcrun 可执行；完整工具链和 SDK 以独立命令及头文件证据为准。

任务 05 可将共享快照采集入口接到 HostCapabilityProvider.current()，持有 HostResourceStateMonitor，并统一设计声明、激活、支持、创建、执行与效果字段。当前共享入口保持原实现，不能声称全部现有入口已经使用新缓存。

任务 02/03 可将可推迟的宿主工作提交到可选队列。生产渲染器仍须检查选定设备、factory 返回值、输入合同和 command 执行错误，并保留原路径。以下回退只有实验消费者已经执行；生产渲染／guest 回退仍待各自接线。

## 实际系统与 SDK

HostMachineEvidence.json 保存脱敏命令值及初始头文件哈希；AppleCapabilitySources.json 保存 33 个 Apple 官方来源、15 行能力矩阵和 13 个 SDK 头文件证据。

| 证据 | 实际观察 |
| --- | --- |
| sw_vers | ProductVersion 27.2.1；BuildVersion 26B131 |
| xcodebuild -version | Xcode 27.0；build 27A266a |
| xcrun --sdk macosx --show-sdk-version | 27.0 |
| SDKSettings.json | Version=27.0；CanonicalName=macosx27.0 |
| 本包部署下限 | macOS 14；未在真实旧系统执行 |

这些字符串是本机命令观察，不用于推断官方发行状态，也不证明任一功能已经激活。

## 逐项公开能力核验

以下为本任务选定的资源与图形能力，非 macOS 27 所有游戏 API 的完整清单。来源 ID 对应下方索引及 JSON 清单；后者逐项记录硬件、输入、API、作用进程、测试方法、URL、访问日期和获取内容 SHA256。“未要求专门 entitlement”仅限所查 API 资料，不推导任意应用所需的其他权限。

| 能力／最低 macOS | 硬件、声明或 entitlement | API、作用进程及本次验证 | 来源 ID |
| --- | --- | --- | --- |
| Game Mode 系统功能：14+ | Apple silicon、原生全屏游戏；所查资料未要求专门 entitlement | 系统管理被识别游戏；用目标应用系统 UI/HUD 观测。平台资格已测，激活 unknown，Wine/guest 收益 unmeasured | game-mode、macos-26-notes、metal-hud |
| LSSupportsGameMode：当前 metadata 为 26+ | Info.plist Bool，YES 支持、NO 退出；不是 entitlement | 声明所在应用 bundle；源码 plist、build settings 及 unsigned Debug 产物均缺此项；未冒充最终签名 bundle 证据 | ls-game-mode |
| GCSupportsGameMode：无 macOS 平台项 | 当前 metadata 仅 iOS/iPadOS 18.0，18.6 弃用 | 旧声明独立记录，不能作为 macOS 14/15 声明依据；官方指向 LSSupportsGameMode | gc-game-mode、ls-game-mode |
| MetalFX spatial：13+ | 选定设备 supportsDevice=true；所查资料未要求专门 entitlement | supportsDevice / makeSpatialScaler / encode，作用于调用进程。合成创建、GPU 执行、输出与 A/B 已测 | spatial-support、spatial-descriptor、spatial-output |
| MetalFX temporal：13+；scale 查询 14+ | 独立 supportsDevice；有效 color/depth/motion、jitter/history 和 private 输出 | supportsDevice / makeTemporalScaler / min/max scale / encode；同进程多帧合成已执行。所查资料未要求专门 entitlement | temporal-support、temporal-descriptor、temporal-min-scale、temporal-max-scale、temporal-output |
| 热状态／通知：10.10.3+ | 所查 API 无更细机型或专门 entitlement 要求 | ProcessInfo.thermalState 与通知；当前进程调整自身工作。注入变化已测，真实热压力未测 | thermal-state、thermal-notification |
| Low Power Mode／通知：12+ | 低电量模式与电池百分比不同；所查 API 无专门 entitlement 要求 | isLowPowerModeEnabled / NSProcessInfoPowerStateDidChange；当前进程读取后调整工作。注入开关已测，真实系统切换未测 | low-power-mode、power-notification |
| OperationQueue QoS：10.10+ | 所查 API 无专门硬件／entitlement 要求 | qualityOfService 是该队列 operation 的默认 QoS；明确 operation QoS/underlying queue 可覆盖。真实 SHA256 队列已测 | operation-qos |
| Sustained Execution Mode：15+ | com.apple.developer.sustained-execution=true；所查资料未列全机型或公开支持查询 | 签名目标应用生命周期；系统限制 burst 以维持持续性能。未声明、未测，无跨进程继承结论 | sustained-execution |
| Metal 4 core：26+ | Apple silicon，选定设备 supportsFamily(.metal4)；所查资料未要求专门 entitlement | MTL4CommandQueue/CommandBuffer/Compiler，当前渲染进程；本机 family=true，创建和执行未测 | metal-support、metal4-family、metal4-core |
| macOS 27 选定扩展：27+ | 仍需底层设备支持及正确输入；所查资料未要求专门 entitlement | output-resolution/jittered motion vectors、content/output offsets、reactive mask、插值 distortion/previous-color 控制；当前进程需提供对应数据，未开启和测试效果 | temporal27-output-motion、temporal27-jitter-motion、frame27-distortion、frame27-previous-color |
| Metal4FX spatial：26+ | Apple silicon；独立 spatial supportsMetal4FX=true；所查资料未要求专门 entitlement | compiler factory 创建 MTL4FXSpatialScaler，可 nil；MTL4CommandBuffer，有效 color/private 输出。本机只测支持 | metal4fx-spatial、metal4-core |
| Metal4FX temporal：26+ | Apple silicon；独立 temporal supportsMetal4FX=true；所查资料未要求专门 entitlement | compiler factory 创建 MTL4FXTemporalScaler，可 nil；Metal4 command buffer，正确时域输入。本机只测支持 | metal4fx-temporal、metal4-core |
| 普通 frame interpolation：26+ | 选定设备 supportsDevice=true；所查资料未建立更细机型或专门 entitlement 要求 | makeFrameInterpolator(device:) / MTLFXFrameInterpolator，普通 MTLCommandBuffer；需前后帧、深度、运动、history 和 private 输出。本机只测支持 | frame-interpolator、frame-support |
| Metal4FX frame interpolation：26+ | Apple silicon；独立 supportsMetal4FX=true；所查资料未要求专门 entitlement | compiler factory / MTL4FXFrameInterpolator / MTL4CommandBuffer；本机只测支持，失败应回经独立验证的普通路线或关闭插值 | frame-interpolator、frame-metal4-support、metal4-core |

Metal4FX/插帧不能复用普通 MetalFX 的支持结论；每项独立查询。HostExtendedGraphicsSupport.json 中扩展支持值及 Metal4 family 均为 true，但 actualFeatureUse 为 not-tested。插值本身始于 macOS 26；macOS 27 的 requiresPrevColorTexture 默认 true，仅设为 false 才由插值器内部维护 previous color。没有执行插值，不能宣称帧率或输入响应改善。

关键 SDK 证据是 MetalFX.framework/Headers 下的 MTLFXSpatialScaler.h、MTLFXTemporalScaler.h、MTLFXFrameInterpolator.h 和三个 MTL4FX 协议头，以及 Foundation.framework/Headers/NSProcessInfo.h、NSOperation.h。精确行号、声明和 SHA256 见 sdk.headers；Metal4FX encode 接受 MTL4CommandBuffer，普通插值接受 MTLCommandBuffer。

## 资源策略：真实消费者与回退

| 策略 | 已执行消费者与行为 | 恢复及限制 |
| --- | --- | --- |
| nominal/fair | HostResourceExperiment 专用 SHA256 OperationQueue：utility，至多并发 2 | 不提高消费者已有显式并发上限；保持原有暂停状态 |
| serious | 同一队列：background，至多并发 1 | 正常状态恢复对应计划；不强制中断已运行操作 |
| Low Power Mode 或 critical | 暂停同一队列尚未开始的可选工作 | 状态恢复后继续；stopMonitoringAndRestore、restoreBaseline 或销毁恢复接管前 QoS、并发及暂停状态 |
| MetalFX 不支持／factory nil／GPU 失败 | HostMetalFXBenchmark 回退 nearest；GPU 无法建立时执行 CPU reference | 分开记录 requestedRoute/executedRoute、请求完成、实际完成及 fallbackReason；回退完成不算 MetalFX 启用成功 |
| Game Mode／Metal4／插帧／Sustained | 无生产执行消费者；只有资格、支持或声明证据 | 不发布优化开关、不改变 guest 环境、不宣称生效；由 02/03/05 接线 |

可选队列不得承接启动必需、取消清理或用户交互工作；队列策略不调整系统总资源或其他进程优先级。监视继续时，手动 restoreBaseline 仍可能被后续更新覆盖；完全退出策略应使用 stopMonitoringAndRestore。

HostResourceAB.json 固定 16 job/轮，每 job 对 16 KiB 输入执行 128 次 SHA256；预热 3 轮后，control/nominal/serious 交替共 12 轮。逐操作校验值、等待/工作时间、观测 QoS，以及逐轮 wall time/峰值并发均保留。状态来源为 injected。

| 组 | 4 轮 wall time 中位数 | 峰值并发 |
| --- | ---: | ---: |
| control，utility/4 | 4.1437915 ms | 4 |
| nominal，utility/2 | 8.444312 ms | 2 |
| serious，background/1 | 43.0218335 ms | 1 |

Low Power Mode、critical 暂停期间各完成 0 个操作，恢复后各完成 4 个，均返回原基线。这证明调度限制和恢复，未证明节能、降温或游戏 FPS 改善。

## MetalFX 合成 A/B

用户本轮选择先完成合成负载 A/B。HostMetalFXBenchmarkTests 真实执行 GPU：同一静态场景，512×512 native 与 256×256→512×512 的 nearest/spatial/temporal。每条路径预热 8 帧，每对 12 轮、每侧每轮 4 帧，AB/BA 交替。输入、private 输出 usage、blit 读回、CPU 独立图像 oracle 和逐帧时间均有证据。Temporal 使用 Halton jitter、零运动、固定深度和持续历史，不能代表运动或遮挡画质。

| 同一报告内比较 | 基线 GPU 中位数 | 候选 GPU 中位数 |
| --- | ---: | ---: |
| native → nearest | 0.056854 ms | 0.028979 ms |
| nearest → spatial | 0.027667 ms | 0.109583 ms |
| nearest → temporal | 0.027750 ms | 0.311604 ms |

上表来自关闭 API Validation 的 host-metalfx-ab-performance.json。Spatial、temporal 的能力、factory、GPU 执行分别成功，无回退；native 对独立 CPU oracle 的 MAE=0。当前轻量负载中两种 MetalFX 均更慢。Native 着色像素是其他路径的 4 倍，native/nearest 差值不能全部归于 MetalFX。

开启验证层的 host-metalfx-ab.json 用于 API 合同检查，日志包含 Metal API Validation Enabled；不能将开关验证层的两份报告直接作为性能 A/B。GPU 时间含场景和重建，不含另一个 command buffer 的读回；CPU 时间仅含分配、编码和提交，不含等待、初始化或 factory。完整参数和字段见 host-metalfx-ab-experiment.md。

实验未测真实游戏、屏幕呈现、FPS、输入/显示延迟、功耗或温度稳态。无设备回退是注入测试，没有物理移除 GPU。

## Game Mode 三层证据

HostGameModeObservation.json 分别记录声明、平台资格、激活和子进程收益。源码 plist 与 build settings 均缺少两项 Game Mode 声明，应用类别 utilities；所查 entitlement 文件无专用 Game Mode key。最终 unsigned Debug app 的产物 Info.plist 也确认两项声明缺失，已分别记录；未验证最终签名 bundle 的 entitlement。

HostGameModeEvidence 仅接受真实 plist Bool；人工观察需绑定仍存在的目标进程，确认原生全屏、平台资格及 120 秒内有效时间。错误目标、无效/过期/未来观察保持 unknown；该关联是人工证据，PID 重用仍是限制，工具不输出 PID 或应用身份。

本次没有可用的全屏 Game Mode 合成 app，MetalFX 命令行实验也不是全屏游戏。因此实际激活 unknown，Wine-child 和 Windows-guest 均 unmeasured；未做 Game Mode on/off 性能 A/B。所查公开 SDK 未找到受支持的自动激活查询或主动启用 API；未使用 Kernel 私有声明或无关的 deprecated GLUT fullscreen API。

HostGameModeAB.md 提供复现协议：正常应用启动、原生全屏、逐次在目标应用系统 UI 确认实际 On/Off；相同场景按 off/on/off 采样，host、Wine、guest 分别记录帧时间和执行域。macOS 26 官方 release notes 指出 Terminal 直接 spawn 游戏二进制不会激活，建议正常 open 启动。父进程声明或 UI 状态不能代替子进程收益测量。

## 边界覆盖与未验证项

| 场景 | 已验证 | 真实环境边界 |
| --- | --- | --- |
| 低电量／热状态 | 注入 normal/serious/critical、Low Power Mode；队列限制、暂停、恢复及原基线保护 | 未改变系统电源设置、未制造实际热压力 |
| 休眠唤醒 | 独立 workspace 通知中心注入 didWake，重读动态状态 | 未请求真实休眠，未接收真实唤醒通知 |
| 高频通知 | 同一主队列轮次 300 条热/电/唤醒通知合并一次刷新，相同状态不发布 | 不推导任意持续风暴均只有一次刷新 |
| 无 Metal／不支持／factory 失败 | 无设备 CPU reference、设备不支持 nearest、factory nil nearest，结果分层 | 未在物理无 GPU 机器运行，未人为诱发真实 GPU 执行故障 |
| 旧系统 | Game Mode 13/14 和硬件资格边界；扩展 API 的 #available 门控及无设备结果 | 包部署下限 14，未在真实旧系统执行 |
| 缓存并发／停止 | 同一设备键 64 路只加载一次；原有暂停和并发 1 不被放宽；控制器代次拒绝旧回调 | GPU 热插拔和生产生命周期接线仍待完成 |

Tools/host-state-observer.swift 实际自然观察 2 秒，见 HostStateObservation.jsonl：nominal、lowPower=false，thermal/power/wake 通知各 0。仅证明观察器运行，零事件不算真实切换验收。HostGameModeEvidenceChecks 通过 Swift 6 独立编译，6 组边界检查通过；观察工具也验证拒绝无效参数。

## 复现命令及门禁

在脱敏目录 /workspace/my-project/HostKit 执行：

~~~sh
MTL_DEBUG_LAYER=1 HOST_RUN_METALFX_AB=1 HOST_WRITE_GRAPHICS_SUPPORT=1 HOST_WRITE_RESOURCE_AB=1 swift test
MTL_DEBUG_LAYER=0 HOST_RUN_METALFX_AB=1 HOST_METALFX_AB_REPORT=Documentation/host-metalfx-ab-performance.json swift test --filter HostMetalFXBenchmarkTests
HOST_WRITE_RESOURCE_AB=1 swift test --filter HostResourceExperimentTests
~~~

第一条生成报告时实测 84 项通过；随后其他任务增加测试和修改共享代码，终检当前工作区另用 MTL_DEBUG_LAYER=1 HOST_RUN_METALFX_AB=1 HOST_METALFX_AB_REPORT=/tmp/host-task04-metalfx-current.json swift test，85 项通过、0 失败、0 跳过，运行期间源码哈希未变化。该次输出写临时文件，保留本目录原始 A/B 报告；日志日期为本机 2026-11-22，资源报告 UTC 为 2026-11-21T16:00:09Z，来源各自访问日期保持原值。HOST_* 变量仅控制实验执行和报告写出，均有明确消费者，不是游戏优化开关。

项目原配置及官方 SwiftLint 0.65.1 对 9 个宿主源码、4 个测试、2 个工具执行 strict lint，15 文件 0 违规。工具临时放于 /tmp/host-task04-tools，未全局安装、未修改 lint 配置。

终检当前标准 App Debug scheme 使用 CODE_SIGNING_ALLOWED=NO 构建，xcodebuild 返回 0，日志明确 BUILD SUCCEEDED；运行期间宿主包源码哈希未变化。临时 SwiftLint 同时加入进程及构建 PATH，原全仓 strict lint 阶段实际执行，未绕过门禁或修改其他任务文件。该结果是 unsigned Debug 构建，不代表最终签名／分发验证。HostCapabilitiesBuild.log 保存脱敏命令模板及成功摘要，HostCapabilitiesTests.log、HostCapabilitiesLint.log 保存最新脱敏包测试和宿主 lint 完整日志。

最终静态检查：git diff --check 退出码 0；宿主新增文件及本目录证据的尾随空白、私人根路径和文档项目标识扫描为 0 发现；全部 JSON/JSONL 可解析，来源 ID 关联与证据数量一致。

## Apple 官方来源索引

AppleCapabilitySources.json 逐项保存日期、metadata、获取内容 SHA256 和测试方法；来源只有 Apple 官方 HTTPS，SDK 路径均以 SDK_ROOT 表示。

| 来源 ID | 访问日期 | 官方 URL |
| --- | --- | --- |
| game-mode | 2026-11-21 | https://support.apple.com/en-us/105118 |
| metal-support | 2026-11-21 | https://support.apple.com/en-us/102894 |
| ls-game-mode | 2026-11-21 | https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode |
| gc-game-mode | 2026-11-21 | https://developer.apple.com/documentation/bundleresources/information-property-list/gcsupportsgamemode |
| macos-26-notes | 2026-11-21 | https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes |
| macos-27-notes | 2026-11-21 | https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes |
| sustained-execution | 2026-11-21 | https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.sustained-execution |
| metal4-family | 2026-11-21 | https://developer.apple.com/documentation/metal/mtlgpufamily/metal4 |
| metal4-core | 2026-11-21 | https://developer.apple.com/documentation/metal/understanding-the-metal-4-core-api |
| spatial-support | 2026-11-21 | https://developer.apple.com/documentation/metalfx/mtlfxspatialscalerdescriptor/supportsdevice(_:) |
| temporal-support | 2026-11-21 | https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor/supportsdevice(_:) |
| spatial-descriptor | 2026-11-21 | https://developer.apple.com/documentation/metalfx/mtlfxspatialscalerdescriptor |
| temporal-descriptor | 2026-11-21 | https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor |
| spatial-output | 2026-11-21 | https://developer.apple.com/documentation/metalfx/mtlfxspatialscalerbase/outputtexture |
| temporal-output | 2026-11-21 | https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerbase/outputtexture |
| thermal-state | 2026-11-21 | https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property |
| thermal-notification | 2026-11-21 | https://developer.apple.com/documentation/foundation/processinfo/thermalstatedidchangenotification |
| low-power-mode | 2026-11-21 | https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled |
| power-notification | 2026-11-21 | https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/nsprocessinfopowerstatedidchange |
| operation-qos | 2026-11-21 | https://developer.apple.com/documentation/foundation/operationqueue/qualityofservice |
| metal-hud | 2026-11-21 | https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance |
| metal-hud-metrics | 2026-11-21 | https://developer.apple.com/documentation/xcode/understanding-metal-performance-hud-metrics |
| temporal27-output-motion | 2026-11-21 | https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor/isoutputresolutionmotionvectorsenabled |
| temporal27-jitter-motion | 2026-11-21 | https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor/isjitteredmotionvectorsenabled |
| frame27-distortion | 2026-11-21 | https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatordescriptor/isdistortiontextureenabled |
| frame27-previous-color | 2026-11-21 | https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatordescriptor/requiresprevcolortexture |
| temporal-min-scale | 2026-11-21 | https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor/supportedinputcontentminscale(device:) |
| temporal-max-scale | 2026-11-21 | https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor/supportedinputcontentmaxscale(device:) |
| metal4fx-spatial | 2026-11-22 | https://developer.apple.com/documentation/metalfx/mtlfxspatialscalerdescriptor/supportsmetal4fx(_:) |
| metal4fx-temporal | 2026-11-22 | https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor/supportsmetal4fx(_:) |
| frame-interpolator | 2026-11-22 | https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatordescriptor |
| frame-support | 2026-11-22 | https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatordescriptor/supportsdevice(_:) |
| frame-metal4-support | 2026-11-22 | https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatordescriptor/supportsmetal4fx(_:) |
