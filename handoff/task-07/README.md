本轮最终快照使用MTL_DEBUG_LAYER=1运行existing门禁；该环境变量只作用于测试子进程。可选GPU A/B默认跳过，不能从普通门禁通过推定该分支执行；最终测试总数、实际通过与跳过分别记录。

任务 07 提供依赖、编译、行为、证据与性能检查入口。最终结论见 report.md 与 evidence/；本机检查通过不能代替真实 Windows 驱动或游戏验收。

在工作区根目录执行：

```sh
./handoff/task-07/verify.sh --cache-mode existing --output handoff/task-07/evidence/check-cached --timeout 300
./handoff/task-07/verify.sh --cache-mode fresh --output handoff/task-07/evidence/check-fresh --timeout 300
python3 -B handoff/task-07/integration.py
python3 -B handoff/task-07/cli_smoke.py
python3 -B handoff/task-07/audit_evidence.py --rewrite
```

验证脚本动态发现唯一应用工程、本地 Package 和共享 scheme。existing 模式使用已有缓存并跳过更新；fresh 模式为 Swift 和 Xcode 分别建立独立临时缓存及构建目录，结束后清理。两者均强制使用已锁定的依赖版本。Git 的 SSH 到 HTTPS 重写仅追加到子进程环境，保留父进程已有配置，不写入全局 Git 文件。

网络失败时可另存传输协议对照：添加 --git-http-version HTTP/1.1（或 HTTP/2）。它继续追加进程级配置，具体协议与结果写入报告；一次成功或失败只代表该次环境，需保留失败记录。

构建先校验任务目录内 SwiftLint 0.65.1；首次获取的归档 SHA-256 固定为 c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0。二进制位于被忽略的 .tools/，每次复用前核对摘要，不进行全局安装。Xcode 构建仍执行工程原有严格 lint，使用 Debug/arm64，关闭本地代码签名。此结果只证明本机编译，不证明签名、分发、驱动加载或游戏可用。

每次门禁保留脱敏日志、有效 XCTest XML、工具链、锁文件摘要及构建输入摘要。依赖失败后相应测试或构建标为 skipped；超时返回 124 并清理该阶段进程组。只有全部阶段成功、实际执行过至少一项测试、没有失败/错误、全局 Git 与锁文件未变、构建输入在运行前后稳定时，build.json 的 passed 才为 true。并发任务修改源码时应待修改结束再重跑。

integration.py 检查性能/采集工具、图形工具、厂商证据语义与可移植驱动 ABI。它不启动 Windows 内核或商业驱动。真实驱动、保护范围、在线会话和游戏性能在 integration.json 中单独保持未验证。六项新增行为测试覆盖 15 组能力组合、拒绝启动无副作用、请求与异常转发、8 组热/低电量策略、缺少运行环境以及文件名匹配；与模块自身生命周期、进程和探针测试一起由 Swift 门禁执行。

runtimeEnvironment 单列 environment_not_verified，不把缺少 UTM 或 guest 算作本地功能测试失败。只记录 utmctl 是否在 PATH，不枚举个人 VM，不推定应用已安装或未安装；guest 配置与执行均未验证。本地门禁通过不证明存储映射、安装器或游戏可以在真实 guest 中运行。

cli_smoke.py 在构建完成后动态发现本机 Debug CLI，检查顶层与 run 帮助、具体未知选项诊断，以及空覆盖布尔选项拒绝带值的诊断，记录二进制摘要。诊断检查使用隔离临时目录中的不存在路径补齐位置参数，并断言不能被缺参错误掩盖。当前命令声明采用默认 .remaining 参数数组策略；两项诊断均在解析阶段停止，不加载 bottle 或启动程序。它只证明帮助公开和对应解析拒绝，显式空数组如何覆盖保存参数、取消和退出码的完整入口行为仍未验证。

性能输入使用 performance-sample-v1。metadata 必须包含 host 的匿名 machineId、chip、os、sdk、architecture，guest 的 os、architecture，以及 vm、backend、driver、gameVersionRegion 的 version/region、resolution 的 width/height、quality 和 scene。无 guest/驱动/游戏的合成实验明确填写 not_applicable，禁止填入身份标识。每次 run 包含 startup（cold/hot）、startupMs、frameTimesMs、inputLatencyMs、cpuPercent、gpuPercent、memoryMiB、powerW、thermalState；缺测填 null，并在 missing 中记录原因。数值须有限且非负，帧时间须大于零，每种出现的启动模式至少重复三次。

```sh
python3 -B handoff/task-07/performance.py validate sample.json
python3 -B handoff/task-07/performance.py compare baseline.json candidate.json
```

对照要求两侧元数据完全一致、每种启动模式的次数相同，适用于同配置前后回归；不同 VM 或后端的探索应分别报告，不能直接通过该严格对照入口。工具按冷/热分别给出每次 P50/P95/P99、启动时长、缺测覆盖，以及跨次 median/min/max/总体标准差；不混合冷/热数据。分位数使用线性插值，缺失任一侧数据时不给该指标的改善结论。CPU/GPU 百分比及输入延迟须由采集者说明归一化和时间端点，不能把软件回包时延写成物理输入到光子时延。

audit_evidence.py 以结构化方式重新脱敏 JSON/XML，检查已知本地标识、导出环境和当前敏感环境值，且不保留命中的原文。分享前执行最后一条命令并检查 privacy.json。扫描只覆盖任务交付文本；原始二进制与忽略缓存不属于分享材料。

本轮没有执行提交或推送，也没有通过重置、清理或覆盖来恢复工作树。功能缺陷和源文件 lint 问题反馈各任务维护；本目录拥有集成验证、工具与结果记录。
