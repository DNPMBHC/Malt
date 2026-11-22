# MetalFX 可复现实验

实验入口是 HostMetalFXBenchmark，独立 XCTest 是真实消费者。它编译并执行 Metal compute shader、创建所选 scaler、提交 command buffer，等待完成后把 private 输出 blit 到 shared staging 并同步读取。它不改变共享宿主接口、游戏渲染管线或 guest 参数。

在 my-project/HostKit 中执行：

~~~sh
MTL_DEBUG_LAYER=1 HOST_RUN_METALFX_AB=1 swift test --filter HostMetalFXBenchmarkTests
MTL_DEBUG_LAYER=0 HOST_RUN_METALFX_AB=1 HOST_METALFX_AB_REPORT=Documentation/host-metalfx-ab-performance.json swift test --filter HostMetalFXBenchmarkTests
~~~

第一条默认写入 Documentation/host-metalfx-ab.json，第二条写入独立性能报告。报告由测试直接生成；只有设定 HOST_RUN_METALFX_AB=1 才运行完整实验。常规测试仍执行小尺寸的无设备、强制不支持、scaler 返回 nil 和配置校验测试。

HOST_METALFX_AB_REPORT 是输出文件参数，实际控制 JSON 写入目的地；它不作为资源优化开关。JSON 不记录该路径、设备名称、设备 registry ID、进程名称或个人标识。覆盖已有报告时，保留一份本次实验独立文件即可避免混淆不同轮次。

## 固定配置与路径

默认输出为 512×512，低分辨率为 256×256。四条路径使用相同的静态平面 shader，每像素计算渐变、棋盘和 24 次 sin 迭代。

| 路径 | 输入/输出 | 重建操作 |
| --- | --- | --- |
| native | 512×512 / 512×512 | 直接写输出 |
| nearest | 256×256 / 512×512 | 独立 compute 最近邻采样 |
| spatial | 256×256 / 512×512 | MetalFX spatial，linear color processing |
| temporal | 256×256 / 512×512 | MetalFX temporal，持续历史 |

Metal blit 不执行尺寸缩放，因此普通低分辨率基线用最简单的最近邻 compute 重采样。所有 MetalFX 输出均为 private，输入/输出 usage 与 scaler 返回需求取并集，输出在实验前通过 staging blit 清零，防止未写显存造成非零假阳性。

每路径先预热 8 帧。随后分别比较 native/nearest、nearest/spatial、nearest/temporal；每对 12 轮，每侧每轮 4 帧，依次采用 AB、BA、AB、BA。逐帧保留轮次和顺序，避免只有一个汇总值而无法核查采样设计。时序采用串行提交和等待；该实验不覆盖多帧并发、呈现或游戏帧管线。

Temporal 的深度输入为全平面标准深度 0.5，非反转 Z。静态场景运动向量为零，单位为输入像素，scale X/Y=1。每帧颜色采样使用 32 周期 Halton(2,3) jitter，同一采样偏移写入 scaler jitterOffsetX/Y；运动向量不包含 jitter。首次编码 reset=true，其后保留历史；自动曝光启用，preExposure=1。没有运动物体、透明遮挡、disocclusion 或相机切换，无法据此评价真实游戏运动画质。

## 报告字段与结论边界

- capabilitySupported：对所选设备独立查询 spatial 或 temporal supportsDevice；无设备时缺省。
- scalerCreationSucceeded：仅在 MetalFX 设备支持时记录创建结果；不支持或普通路径时缺省。
- requestedRoute / executedRoute：请求路径和实际执行路径。
- requestedGPUEncodingCompleted：请求路径实际完成；回退 nearest 完成不会把它变成 true。
- gpuEncodingCompleted：实际 GPU 路径完成，包含正常回退。
- fallbackReason：无 Metal、设备不支持、scaler 创建失败、scaler command 失败或 GPU setup/command 失败。无 Metal 或 GPU 无法建立时，执行相同合成场景的 CPU reference，GPU completion 为 false。
- shadedPixelsPerFrame：native 为 262144，其他正常路径为 65536。像素工作量不同，不能把 native 与低分辨率时间差直接解释为 MetalFX 优化收益。
- gpuMilliseconds：完成后 gpuEndTime - gpuStartTime，包含场景计算和所选重建，不含另一个 command buffer 的 staging 读回。时间戳不可用时缺省。
- cpuEncodeAndCommitMilliseconds：command buffer 分配、编码和 commit 的 wall-clock 时间；不含等待 GPU 完成、预先初始化、创建 scaler 或读回。它不是总 CPU frame time，也不是纯 commit 函数耗时。
- comparisons：逐帧 GPU/CPU 数据与两侧中位数；每样本还记录实际执行路径，运行中发生回退时可识别。
- outputChecksum / opaqueOutput / nonzeroColorOutput：同步读回的完整性证据。
- meanAbsoluteErrorAgainstNative：RGB 归一化 MAE，相对于 native GPU 图像。
- meanAbsoluteErrorAgainstCPUReference：相对于独立 CPU 同算法输出的 RGB 归一化 MAE；native 测试阈值为 0.002。该值与图像完整性验证不等于艺术质量评分。

开启 API Validation 的报告用于合同检查。关闭 Validation 的报告用于减少验证层开销；两轮之间的数值变化不能直接用来证明任何优化。性能比较应在同一份报告同一对样本中解释。轻量合成场景中，MetalFX 重建成本可能高于普通 nearest，此时应如实报告该结果。

该实验没有创建游戏全屏窗口或启用 Game Mode；没有测量真实游戏、guest/Wine 子进程、FPS、显示延迟、帧节奏、温度稳态或功耗。Game Mode 声明、实际激活和子进程受益仍需单独的可控游戏实验。
