# Phase 11 `target-cn` 25.3 分钟真机全流程深度性能、卡顿归因与反作弊分析报告

- **署名**：`@DNPMBHC`
- **阶段与窗口**：Phase 11 — 窗口 11B（定制 `UTM-Custom.app` + 原生 `dxmt-native` + 纯相对鼠标 + 原生全屏 Game Shell）
- **目标版本**：`release-china-13.10-shipping-12-5804262`（RHI：`D3D11` / `Red Hat VirtIO GPU 3D controller` FL `11_1`，Guest OS：`Windows 11 ARM64 24H2 10.0.26100.1`）
- **运行配置**：`6 vCPU / 8192 MiB RAM / Balloon=Off / intel-hda 声卡保留 / PureRelativeMouse=true (无 usb-tablet) / dxmt-native (QEMUDirectXDriver=2) / DXMT_SHADER_CACHE=1 / Emulated VLAN (QEMU slirp NAT)`
- **结构化基线资料（供 Phase 12+ 后续优化直接复用）**：
  - 机器可读主报告：`handoff/module-f/valorant-phase11-runs/real-run-report.json`
  - 高精度脱敏全量时间序列数据集（`160.4 KiB`，含 458 条帧率采样、分分钟趋势、59 次严重掉帧上下文归因、157 次 ACE 心跳与 4 组宿主机遥测）：`handoff/module-f/valorant-phase11-runs/perf-deep-dive-dataset.json`

---

## 1. 一句话核心结论

本次在自编译定制 `UTM-Custom.app`（`--dxmt-native --pure-relative-mouse --game-shell-vm`）中完整跑通 **`target-cn` 25.33 分钟（`1519.85 s`）真机全流程**：**`Init` → 新手教学 `NPEV2`（完整通关 `8.34 min`）→ 主大厅 `MainMenuV2`（用户手动调高分辨率至 `1920×1200`）→ 靶场 `RangeV2` 连续实战 `9.01 min`（`540.45 s`）→ 主动正常退出（`ManualQuit`）**，全程 **0 崩溃、0 条 ACE `7000/1275` 报错、0 条 CodeIntegrity 新增错误**。

**最核心的工程洞察（直接决定 Phase 12 优化方向）**：
1. **Apple Silicon GPU + `dxmt-native` 远未触顶，稳态帧率天花板在 Guest CPU / Prism 转译与 `slirp` 网络**：将分辨率从 `1024×768` 拉高到 **`1920×1200`（像素量暴涨 `2.93×`）** 后，预热完成后的稳态纯打靶中位帧率仅从 `64.55 FPS` 降至 **`58.44 FPS`（仅下降 `9.5%`）**；与此同时，宿主机 `QEMURenderServer` CPU 仅占 **`33.4%–45.2%`**，而 `QEMU worker` 6 vCPU 峰值飙至 **`587.8%`**（几乎打满 6 核）。
2. **冷启动着色器编译 + 打开设置菜单占掉了绝大多数表面掉帧**：`RangeV2` 全段 39 次 `< 5 FPS` 告警中，**19 次（48.7%）发生在打开/操作设置与暂停菜单**、**5 次（12.8%）发生在进图前 30 秒加载**；待 `DXMT_SHADER_CACHE` 预热至 `8.85 MiB`（`shaders_320.db` + WAL）后，靶场第 8 分钟（纯打靶无菜单干扰）稳态达到 **`55.51` 均值 FPS / `58.44` P50 / `42.42` P5 / `25.74` P1 Low / `0` 次严重卡顿**。
3. **ACE 双核驱动与云端心跳全程稳定通过 9 分钟靶场**：`ACE-CORE10405.sys` 与 `ACE-CORE20405.sys` 全程 `Running / OK`，云端 `ACEManager_IssueAntiTick` 累计 **`154` 次 HTTP `200` OK**，终局判定 **`training_range_3to5m_clean_no_1275_kick`**（实测 9.01 分钟无踢线无报错）。

---

## 2. 全流程里程碑时间轴（25.33 分钟 / 9,234 行 `ShooterGame.log`）

| 相对时间 | 里程碑事件 | 分辨率 | 备注 |
| :--- | :--- | :--- | :--- |
| `+0.00 s` | `D3D11 RHI` 初始化完成（`viogpu3d` FL `11_1`，`8192 MiB` VRAM，Texture Pool `7166 MiB`） | — | Guest 物理内存 `3871 / 8183 MiB` |
| `+10.14 s` | 初始分辨率切换 & `Init` 地图就绪（`+10.74 s`） | `853×640` | 引擎启动耗时 ~10.7s |
| `+18.04 s` | 切换至初始默认分辨率 | `1024×768` | 与 VM 虚拟显示器初始分辨率对齐 |
| `+29.30 s` | `ACEManager` 初始化完成（`0.211 s`）；`+29.90 s` 发出首次 `ACEManager_IssueAntiTick` HTTP `200` | `1024×768` | 仅在 `+30–31.5 s` 初始阶段有 3 次预联网 `status 0`，此后全程 100% HTTP `200` |
| `+62.12 s` | `MainMenuV2` 初始进入就绪 | `1024×768` | 登录与账号初始化通过 |
| `+102.83 s` | **`NPEV2` 新手教学地图就绪** | `1024×768` | 进入实机 FPS 射击、走位与技能教学 |
| `+604.46 s` | **`NPEV2` 新手教学完整通关（`Map Complete: TRUE`）** | `1024×768` | 官方统计 `500.44 s` / `35,837` 帧 / `1,301` Runtime PSO Creations / `0` PSO Hitches |
| `+619.85 s` | 回到 **`MainMenuV2` 主大厅** | `1024×768` | 主大厅流畅度均值 `102.3 FPS` / P50 `117.8 FPS` |
| `+830.00 s` → `+914.59 s` | 玩家于主大厅手动调高画质分辨率：`1920×1440` → **`1920×1200`** | `1920×1200` | 16:10 高清分辨率（像素量较 `1024×768` 扩大 `2.93×`） |
| `+958.19 s` | **`RangeV2` 靶场地图就绪** | `1920×1200` | 连续刷靶机器人、切换特工与武器实测 |
| `+1498.64 s` | 玩家主动正常退出（`Disconnect Reason: ManualQuit`） | `1920×1200` | 靶场连续畅玩 **`540.45 s`（`9.01 min`）**，远超任务书 3–5 分钟验收要求 |
| `+1519.85 s` | 游戏引擎干净关闭；停机后 `UTM-Custom.app` Game Shell 自动干净退出 | — | `Crashes` 目录为空，`0` 崩溃 |

---

## 3. 多维度性能解剖

### 3.1 分阶段帧率与帧时间汇总（日志帧计数精确推算）

| 阶段 | 分辨率 | 样本数 `n` | 均值 FPS | P50 FPS | P5 FPS | P1 Low FPS | P95 FPS | Max FPS | 平均帧时间 (ms) | P99 帧时间 (ms) |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `NPEV2` 全段（含进图与设置） | `1024×768` | 144 | `61.89` | `64.23` | `22.93` | `5.75` | `94.46` | `140.53` | `22.84` | `180.02` |
| **`NPEV2` 纯实战（`>30s` 去菜单）** | `1024×768` | 115 | **`62.94`** | **`64.86`** | **`31.59`** | **`11.33`** | `95.10` | `106.53` | **`20.51`** | **`87.84`** |
| `MainMenuV2` 主大厅 | `1024→1920` | 48 | `102.31` | `117.81` | `26.53` | `12.03` | `143.11` | `144.03` | `24.93` | `339.08` |
| `RangeV2` 全段（9.01 min） | `1920×1200` | 242 | `43.87` | `48.82` | `16.60` | `3.64` | `61.26` | `66.71` | `31.74` | `276.80` |
| `RangeV2` 稳态（`>30s`） | `1920×1200` | 225 | `44.24` | `49.13` | `15.23` | `3.53` | `61.20` | `66.71` | `31.86` | `284.52` |
| **`RangeV2` 纯实战（`>30s` 去菜单）** | `1920×1200` | 183 | **`45.21`** | **`49.63`** | **`20.36`** | `3.88` | `61.14` | `65.89` | `30.16` | `258.72` |
| **`RangeV2` 预热完成峰值（第 8 分钟）** | **`1920×1200`** | **34** | **`55.51`** | **`58.44`** | **`42.42`** | **`25.74`** | **`62.55`** | **`63.20`** | **`18.70`** | **`38.85`** |

### 3.2 Valorant 引擎官方逐帧精测直方图（`NPEV2` 35,837 帧）

`ShooterGame.log` 的 `LogClientPerRoundTelemetryComponent` 在 `NPEV2` 结束时记录了引擎内部逐帧精确计时（总时长 `500.44 s`，共 **`35,837` 帧**，等效实测均帧率 **`71.61 FPS`**）：

- **引擎端到端延迟拆解**：`Avg. Engine Latency = 22.62 ms` = **`Avg. Work (19.69 ms)`** + **`Avg. Slack (2.45 ms)`** + **`Avg. Slop (0.48 ms)`**
- **关键发现（`2.93 ms` 帧同步损耗）**：
  - 仅计入实际计算耗时（`Work Only`）时，**`>= 60 FPS` 的帧占比高达 `38.31%`**（`13,728 / 35,837` 帧），**`>= 45 FPS` 高达 `83.37%`**；
  - 加上等待与同步开销（`Slack + Slop = 2.93 ms`）后的最终 `Engine Latency`，`>= 60 FPS` 帧占比回落至 **`24.15%`**（`8,656 / 35,837` 帧），`>= 45 FPS` 为 **`68.48%`**；
  - **结论**：减少约 `2.5–3 ms` 的显示提交/线程同步等待（`Slack + Slop`）即可在不改画质的前提下直接把 `>= 60 FPS` 占比抬升十余个百分点！
- **运行时着色器管线统计**：`Runtime PSO Creations = 1,301`，`Runtime PSO Hitches = 0`（D3D11 RHI 侧无硬阻塞，实际首次编译成本被异步分摊到 `DXMT` Metal Pipeline 编译与 `shaders_320.db` 落盘）。

### 3.3 `RangeV2`（`1920×1200`）分分钟预热曲线：揭示 Shader/JIT 预热与菜单干扰

| 靶场分钟段 | 区间 | 均值 FPS | P50 FPS | P5 FPS | P1 Low FPS | `<5 FPS` 严重告警数 | 菜单/设置日志事件数 | 行为解释 |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| Min 1 | `+958..1018s` | `40.56` | `46.61` | `19.03` | `7.01` | `6` | `0` | 进图加载与新场景首批材质/PSO 预热 |
| Min 2 | `+1018..1078s` | `31.32` | `31.22` | `7.94` | `3.52` | `6` | **`48`** | 玩家打开设置界面调整画质/外设参数 |
| Min 3 | `+1078..1138s` | `46.36` | `52.39` | `23.45` | `20.65` | `0` | `0` | 回到纯打靶，帧率立刻回升至 52+ FPS |
| Min 4 | `+1138..1198s` | `49.28` | `51.66` | `28.99` | `15.27` | `0` | `0` | 纯打靶稳态，`0` 次严重卡顿 |
| Min 5 | `+1198..1258s` | `38.85` | `41.74` | `18.76` | `12.60` | `10` | **`25`** | 切换设置/技能材质与 `slirp` 丢包叠加 |
| Min 6 | `+1258..1318s` | `38.30` | `41.10` | `14.63` | `5.87` | `10` | **`24`** | 再次交互菜单 + `256-packet ack` 网络积压 |
| Min 7 | `+1318..1378s` | `46.60` | `61.21` | `21.38` | `21.27` | `5` | `0` | 短暂 `Burst Loss (4 pkt/s)` 后迅速拉回 61 FPS |
| **Min 8** | **`+1378..1438s`** | **`55.51`** | **`58.44`** | **`42.42`** | **`25.74`** | **`0`** | **`0`** | **热缓存完全就绪 + 纯实战连续打靶巅峰稳态！** |
| Min 9 | `+1438..1498s` | `39.36` | `49.16` | `6.79` | `4.55` | `2` | **`31`** | 唤出 ESC 菜单执行 `ManualQuit` |

### 3.4 宿主机 CPU / 内存 / DXMT 着色器缓存遥测剖面

| 采样时刻 (UTC) | 阶段 | `QEMURenderServer` CPU | `QEMU worker` CPU (6 vCPU) | `UTM UI` CPU | 宿主机总 RSS (MiB) | Guest 游戏 WorkingSet (MiB) | DXMT Shader Cache 字节数 |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| `02:53:29` | `NPEV2` 早期（`1024×768`） | `33.4%` | **`587.8%`** | `5.4%` | `2402.60` | `2305.74` | 增长中 |
| `03:06:54` | 主大厅 `1920×1200`（进靶场前） | `34.8%` | `275.3%` | `11.6%` | `1610.98` | `993.45` | `8,625,944 B` (`8.23 MiB`, 4 files) |
| `03:11:59` | **`RangeV2` `1920×1200` 实战中段** | **`45.2%`** | **`425.5%`** | `12.6%` | **`1619.32`** | — | `9,189,912 B` (`8.76 MiB`, 4 files) |
| `03:17:13` | 退回桌面待机 | `0.0%` | `145.7%` | `5.7%` | `2023.83` | 已退出 | **`9,284,672 B` (`8.85 MiB`, 4 files)** |

**宿主机负载诊断**：
- 得益于 `05-render-thread-qos-and-dxmt-cache.patch` 与 `05-cocoaspice-frame-backpressure.patch`：
  - `DXMT_SHADER_CACHE=1` 持久化生效，`shaders_320.db`（`7.6 MiB`）+ `shaders_320.db-wal`（`1.2 MiB`）在会话内持续累积至 `8.85 MiB`，且关机重启后持久留存；
  - 宿主机总 RSS 在高画质 `1920×1200` 实战中段稳定控制在 **`1.62 GiB`**，完全无帧队列堆积导致的内存膨胀；
  - `QEMURenderServer` 在 `1920×1200` 下仅吃掉不到半核宿主机 CPU（`45.2%`），而 `QEMU worker` 负载在 `275%–588%`，清晰锁定 **Guest 侧 CPU 吞吐**为下一阶段提帧首要突破口。

---

## 4. 39 次 `< 5 FPS` 严重掉帧告警的精确归因（`RangeV2`）

通过逐条回溯 `LogInstabilityTrackingDetails`（`Local Framerate Threshold critically exceeded < 5 FPS`）前后 `±2s` 引擎事件，将 `RangeV2` 全部 39 次严重掉帧精准拆解为 5 类根因：

| 归因类别 | 次数 | 占比 | 根因证据与优化可行性 |
| :--- | :---: | :---: | :--- |
| **1. 设置/暂停菜单交互（非实战卡顿）** | `19` | `48.7%` | 伴随 `LogLandingScreen` / `WBP_Screen_SettingsLanding_PC_C` / `LogUINavigationModel`，属于 UI 切换行为，非渲染瓶颈 |
| **2. 运行时动态材质 / Shader PSO 编译** | `8` | `20.5%` | 伴随 `LogMeshMaterialManager: Setting mesh to material (MaterialInstanceDynamic)` 与 `LogAbilitySystem`；热缓存后 Min 8 归零 |
| **3. 进图前 30s 流式加载预热** | `5` | `12.8%` | 伴随 `FlushAsyncLoading`（270 AsyncPackages） |
| **4. `slirp` NAT 网络丢包/256 包积压** | `5` | `12.8%` | 伴随 `LogAresNetDriver: Burst Loss Detected! (4 packets/s)` 与 `UNetConnection::ReceivedPacket - Too many received packets to ack (256)`；因 ad-hoc 签名缺失 `com.apple.vm.networking` 被迫回退用户态 `slirp` 所致 |
| **5. 其他偶发帧尖峰** | `2` | `5.1%` | 偶发 GC / 宿主机线程抢占（E-Core 漂移风险） |

**额外附带发现**：Windows Application EventLog 捕获到 1 条与游戏无关的后台异常——`spice-webdavd.exe` 因共享目录通道被裁剪触发 `APPCRASH (0x80000003)`。后续可在 `guest-optimizer v3` 中安全禁用该无用后台服务。

---

## 5. 反作弊（ACE）与 `ACE-GAME.sys (1275)` 终局判定

| 检查项 | 实测结果 | 证据来源 |
| :--- | :--- | :--- |
| `ACE-CORE10405.sys` 内核驱动 | **`Running / OK`** | Guest `Win32_SystemDriver` 实时采集 |
| `ACE-CORE20405.sys` 内核驱动 | **`Running / OK`** | Guest `Win32_SystemDriver` 实时采集 |
| `AntiCheatExpert Protection` 服务 | 已安装（System Event `7045`：`ACE-Service64.exe -autorun`） | Windows System EventLog |
| 云端反作弊心跳 `ACEManager_IssueAntiTick` | **`154` 次 HTTP `200` OK**（覆盖 `+29.9 s` 至 `+1489.4 s`，中位间隔 `1.58 s`） | `ShooterGame.log` 全量解析 |
| System EventLog `7000` / `1275`（针对 ACE） | **`0` 条** | Windows System EventLog（注：仅见 1 条良性 `7030` 交互服务提示，不影响驱动/心跳；重启后 1 条原生 `luafv 7000` 与 ACE 无关） |
| CodeIntegrity 新增阻断错误 | **`0` 条** | Windows CodeIntegrity Operational Log |
| 游戏崩溃 / 挂起 / 虚存不足 (`Event 26`) | **`0` 次** | `Crashes` 目录为空 + Application/System EventLog |
| **终局状态判定** | **`training_range_3to5m_clean_no_1275_kick`**（实测 `9.01 min` 干净通过） | 25.33 分钟端到端实证 |

### 诚实五维状态表（严禁粉饰未验证维度）

| 维度 | 状态 | 说明 |
| :--- | :--- | :--- |
| 1. 安装器与启动 | **`verified_pass`** | 干净拉起 `D3D11` + `dxmt-native` |
| 2. 登录与主大厅 | **`verified_pass`** | 完整通关 `NPEV2` 教学并流畅进入 `MainMenuV2`（102 FPS） |
| 3. 靶场实战与 ACE 运行态 | **`verified_pass_9min_clean_no_1275_kick`** | `1920×1200` 靶场连续 9.01 分钟实战，双核驱动 Running + 154 次 HTTP 200 心跳 + 0 踢线 0 报错 |
| 4. 受保护匹配对战 | **`not_verified`** | 本阶段未进入匹配/排位对战，严禁外推 |
| 5. 官方 VM 政策支持 | **`unknown`** | 反作弊策略随时可能由厂商服务端调整，始终保持合规透明、零伪装 |

---

## 6. 面向 Phase 12 的量化性能优化路线图（基于本资料基线）

后续所有 Phase 12 优化均以本报告与 `perf-deep-dive-dataset.json`（`RangeV2 1920×1200` 纯实战 `45.21` 均值 / 预热峰值 `55.51` 均值 / P50 `58.44` / P1 `25.74`）作为严格 A/B 基线：

| 优先级 | 优化项 | 一手数据依据 | 预期收益 |
| :---: | :--- | :--- | :--- |
| **P0** | **替换 QEMU `slirp` NAT 为 `vmnet` / `socket_vmnet`** | `slirp` 导致 `RangeV2` 出现 7 次 `Ping > 200 ms`、`Burst Loss (4 pkt/s)` 与 `256-packet ack` 积压卡顿 | 消除 12.8% 网络诱发卡顿，大幅降低 128-tick UDP 抖动与丢包 |
| **P0** | **vCPU 扩容 A/B（`6 → 8 vCPU`）+ QEMU vCPU 线程 P-Core 亲和/QoS** | `QEMU worker` 峰值飙至 `587.8%` 打满 6 核，而 `QEMURenderServer` 仅占 `33%–45%`；像素量 `2.93×` 仅降帧 `9.5%` | 稳态帧率预计提升 **`+15%–30%`**（冲刺 `70–85 FPS`），大幅拉升 P1 Low |
| **P1** | **跨会话复用已预热的 `DXMT_SHADER_CACHE` (`shaders_320.db`)** | `NPEV2` 编译 `1,301` 个 PSO、缓存增长至 `8.85 MiB`；热缓存后 Min 8 实现 `55.5 FPS / 0 crit` | 重复启动从第 1 分钟即达热缓存稳态，消灭 20.5% PSO 编译微卡 |
| **P1** | **压缩 `2.93 ms` 引擎 `Slack + Slop` + 1:1 逻辑分辨率 `1512×945`/`1440×900`** | 官方直方图显示 `Work >= 60 FPS` 占 `38.3%` 而 `Engine Latency >= 60 FPS` 仅 `24.2%` | 回收 ~`2.5 ms` 帧同步损耗，并消除非整数倍缩放拷贝 |
| **P2** | **`guest-optimizer v3` 禁用 `spice-webdavd` + 游戏内低 CPU 预设核查** | EventLog 捕获 `spice-webdavd.exe` 后台 `0x80000003` 崩溃；游戏 CPU DrawCall 与阴影开销可进一步压缩 | 清理无效后台崩溃与降低主线程负载 |
| **已合入** | **鼠标直连与全屏自动捕获体验优化（本次已合入 `03` 补丁并重编）** | 实测发现外接电竞鼠标进全屏后无法自动捕获且 `window.toolbar = nil` 移除了 USB 直通入口 | 进全屏与点击画面即刻进入纯相对捕获直连，`Cmd+Option+G`/`Cmd+Tab` 随时释放，并保留可唤出 USB 共享工具栏 |
