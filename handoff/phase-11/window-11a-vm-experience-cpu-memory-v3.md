# Phase 11 窗口 11A 任务书：虚拟机体验完善 v3 与大场景游戏 CPU / 内存深度优化

- **窗口角色**：Phase 11 窗口 11A
- **难度评级**：🟡 中等（建议模型：**`Hydrogen Medium`**）
- **署名**：`@DNPMBHC`
- **母盘基线**：`golden-win11-arm64-v1`（只读不可变，所有修改仅作用于派生克隆或持久化工作 VM）

---

## 1. 任务目标

一次性解决 Phase 10A 实测暴露的 4 项基础体验缺陷，并对**大场景高负载游戏的 CPU 运行效率与内存占用**完成系统性优化与真机量化验证：

### 任务 11A-1：修复声卡裁剪、新增持久化日常游玩 VM 与硬件资源调优
修改 `graphics-lab/golden_guest_manager.py` 与 `graphics-lab/test_golden_guest_manager.py`：
1. **声卡默认保留**：重构 `--trim-hardware`，默认**保留标准 `intel-hda` + `hda-duplex` 声卡**（仅裁剪摄像头、共享目录、剪贴板同步、多余串口/TPM 冗余外设等无用组件）；新增显式可选开关 `--no-sound` 供纯无头基准使用。
2. **持久化日常游玩模式**：在保留 `spawn-ephemeral` / `destroy-ephemeral`（零漂移洁净实验模式）的同时，新增 `create-playable` / `launch-playable`（在 `<EXTERNAL_VOLUME>` 通过 APFS CoW 创建可持久保存 `C:` 启动器注册表、中文环境与着色器缓存的日常工作 VM，支持安全重置回母盘，避免每次打开游戏重跑官方安装器）。
3. **大场景 CPU 与内存拓扑优化参数**：
   - 新增可配置硬件调优参数：`--ram-mb <MiB>`（大场景默认推荐 `8192`，支持 `6144/8192/10240/12288`）、`--vcpu <N>`（基于 Apple Silicon P-Core 数量合理配置，避免跨 E-Core 调度抖动，默认匹配宿主机性能核数或 `6`/`8`）、`--disable-balloon`（验证关闭 VirtIO Memory Balloon 后台回收对大场景帧时间毛刺的影响）、`--pure-relative-mouse`（预留配置开关，配合 11B 定制 UTM 移除 `usb-tablet`）。

### 任务 11A-2：升级 `guest-optimizer` 至 v3（体验完善 + 大场景 CPU/内存调优）
升级 `Whisky/Modules/guest-optimizer/`（profile、`apply-optimizer.ps1`、`rollback-optimizer.ps1`、`tests/test_guest_optimizer.py`）：
1. **解决 10A 暴露的 3 项 Guest 体验缺陷**：
   - **默认中文环境与输入法**：利用母盘已预装的 `zh-CN` 语言包，提供幂等配置将默认显示语言切为 `zh-CN`，输入法列表设为 `zh-Hans-CN`（微软拼音）优先 + `en-US` 备用（支持回滚）。
   - **游戏期阻断后台更新抢占**：安全暂停并设为手动启动 `wuauserv`、`UsoSvc`、`BITS` 及 `TrustedInstaller` 后台偷跑任务，防止游戏运行期间突然下载安装补丁（如 10A 捕获的 `KB5036908`）导致 CPU 飙升与掉帧（同样支持完整回滚）。
   - **固定页面文件消除 `Event 26`**：预分配固定大小页面文件（例如 `InitialSize = 8192 MiB, MaximumSize = 12288 MiB`）并保留可回滚的自动管理恢复逻辑，彻底消除 `System Event 26 (Virtual Memory Minimum Too Low)`。
2. **大场景 CPU 运行效率与内存优化（合法、零反作弊风险）**：
   - **CPU 调度与优先级**：启用高响应电源策略（`High Performance` / 关闭 CPU 核心停泊 `Core Parking` 与 USB 选择性挂起）、优化前台游戏进程量子配额（`Win32PrioritySeparation = 0x26`，短固定前台优先）、禁用后台非必要遥测/索引/SysMain 内存预读抖动；
   - **内存效率优化**：评估并对比 `Disable-MMAgent -MemoryCompression` vs 保留内存压缩在大场景峰值下的 Guest Commit Charge、宿主机 QEMU RSS 与 1% Low 帧时间，择优固化到 v3 Profile；
   - **ACE 白名单铁律**：继续硬编码保护 `ACE-CORE10405`、`ACE-CORE20405`、`ACE-BASE`、`AntiCheatExpert` 等服务与驱动，严禁触碰任何安全中心/Secure Boot/TPM 策略。

### 任务 11A-3：大场景 CPU 效率与内存优化实机量化基准
新增 `graphics-lab/p11_vm_perf_benchmark.py` 与 `graphics-lab/test_p11_vm_perf_benchmark.py`：
1. 在派生瞬时克隆上完成 **v2 基线 vs v3 优化态** 的同场景量化对比，覆盖：
   - **高 Draw-Call / 大场景负载**（例如复用已有 `16384-Draw` / 多对象高 CPU 提交负载或等效 D3D11 大场景基准 + `d3d11_probe`）；
   - 记录指标：`FPS`（均值 / P50 / **P1 Low** / **P0.1 Low**）、**CPU 帧提交耗时（ms）**、**宿主机 QEMU Worker CPU% 与 `QEMURenderServer` CPU%**、**宿主机总 RSS（MiB）与峰值**、**Guest 内存可用量 / Commit / PageFaults & `Event 26` 计数（目标 = 0）**、**声卡就绪（`intel-hda` 检测 OK）**、**中文输入法就绪**、**`rollback_consistent = true`**。
2. 销毁全部临时克隆，产出 `handoff/phase-11/evidence/p11-a/zero-drift-proof.json`，确保母盘 `golden-win11-arm64-v1` 与 `vm-a` 全盘 SHA-256 `zero_drift = true`。

---

## 2. 独占写入范围（严禁越界）

- 允许写入：
  - `Whisky/Modules/guest-optimizer/**`
  - `graphics-lab/golden_guest_manager.py`
  - `graphics-lab/test_golden_guest_manager.py`
  - `graphics-lab/p11_vm_perf_benchmark.py`
  - `graphics-lab/test_p11_vm_perf_benchmark.py`
  - `handoff/phase-11/evidence/p11-a/**`
- 严禁触碰：`Whisky/Modules/utm-custom/`、`Whisky/Whisky/`、`Whisky/WhiskyKit/`、`handoff/task-07/`、窗口 11B 独占文件、只读黄金母盘与冷备 `vm-a`。

---

## 3. 验收门禁与交付物

1. `handoff/phase-11/evidence/p11-a/vm-v3-cpu-memory-benchmark.json`（v2 vs v3 大场景 CPU/内存量化对照，含声卡、中文、无更新偷跑、`Event 26 = 0` 与回滚一致性实证）
2. `handoff/phase-11/evidence/p11-a/zero-drift-proof.json`
3. `handoff/phase-11/evidence/p11-a/report.md`
4. 必须全绿：
   - `(cd Whisky/Modules/guest-optimizer && python3 -B -m unittest discover -s tests -v)`
   - `(cd graphics-lab && python3 -B -m unittest discover -v)`
   - `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test`
   - 零 `> 5 MiB` 新增文件、零隐私路径泄漏、零 git 操作。
