# 窗口 4C 任务书：反作弊专用极简 Guest 优化器（Phase 3-A）与 `x86_64` ACE 轴 2 预研（P1）

署名：`@DNPMBHC`  
启动前提：**脚本设计与代码实现可立即启动；涉及 Guest 实测部分必须在独立克隆快照上执行（与 4B 错开 VM 运行时段）**  
请先阅读：`handoff/phase-4/README.md`、`handoff/phase-3/guest-minimal-optimizer.md`、`handoff/phase-2/evidence/window-a/summary.md`、`handoff/module-f/guest-dynamic-observations.json`

---

## 1. 核心目标

### 任务 C1：落地「反作弊专用极简 Windows 11 24H2 ARM64 优化器」（Phase 3-A）
基于窗口 A 已测出的干净官方基线（Windows 11 24H2 ARM64 `Build 26100.1`：冷启 `3.22 s`，桌面空载宿主 RSS `UTM 46.2 MiB + QEMU 1029.4 MiB`），复用微软官方 `DISM` 与 PowerShell 服务管理能力，构建声明式、幂等、可一键回滚的极简优化器：
1. **目录位置**：`Whisky/Modules/guest-optimizer/`（新建）：
   - `profiles/anticheat-minimal-win11-arm64.json`：声明式白名单（严禁裁剪）与黑名单（可裁剪）配置；
   - `scripts/apply-optimizer.ps1`：执行前自动导出初始服务/任务/特性快照，幂等应用裁剪，输出脱敏 JSON 报告；
   - `scripts/rollback-optimizer.ps1`：根据初始快照一键恢复所有被关闭的服务与配置；
   - `tests/`：离线 JSON Schema 校验、白名单冲突拦截单元测试（防止有人把核心组件误写进黑名单）。
2. **强制保留白名单（严禁裁剪，写入代码级强断言）**：
   - Windows 内核、HAL、代码完整性（CI / CryptSvc / 根证书链）；
   - **Windows 11 24H2+ `Prism`（AVX/AVX2）转译引擎与 `Arm64X / Arm64EC` 用户态兼容运行时**；
   - 安全与完整性链路（Secure Boot、TPM 2.0、关键安全服务）；
   - D3D / Visual C++ / 音频 / 网络协议栈、QEMU Guest Agent 与共享目录映射通道。
3. **最大化裁剪黑名单（反作弊与游戏不需要的内容）**：
   - 预装消费级 UWP 应用（Widgets、Copilot、OneDrive、Teams、非必要娱乐/办公预装）；
   - 重型后台服务（Windows Search 索引、SysMain、Spooler 打印、蓝牙、地理定位、遥测诊断 DiagTrack、会话期后台更新暂停）；
   - 桌面透明/动画/冗余视觉特效。
4. **独立克隆快照量化对比（严禁直接修改主干净 `vm-a`）**：
   - 在基于主 `vm-a` 克隆的独立测试快照上执行优化器，与干净基线配对记录：**磁盘占用（GiB）、冷/热启动耗时（s）、桌面空载宿主 RSS（MiB）、空载 CPU（%）、`SFC`/完整性状态、以及一键回滚后恢复一致性**。

### 任务 C2：低成本 `x86_64` ACE 轴 2 探测 Go/No-Go 预研（只出评估，不盲目重投入）
鉴于窗口 B 已实锤 `target-cn`（`2.17.4.510`）当前 3 个 WHQL 驱动均为 `0x8664`（轴 1 阻塞，轴 2 仍为 `unknown`）：
- 结合 QEMU `x86_64` TCG 多核 JIT 与 Apple Silicon 硬件约束，出具一份客观、数据驱动的 Go/No-Go 预研文档（`handoff/phase-4/evidence/p4-c/x86-ace-axis2-assessment.md`）：
  - 评估“临时建最小 `x86_64` Guest 仅用于探测腾讯 ACE 轴 2（Hypervisor / 虚拟化占用弹窗）”的磁盘成本（外接卷 `<EXTERNAL_VOLUME>` 当前余量约 `27 GiB`）、耗时与实际工程价值；
  - 明确结论：若投入产出比过低，建议直接等待 NVIDIA RTX Spark / WoA 推动腾讯 ACE 下发原生 ARM64 驱动，而不重投入纯软件仿真 `x86_64` 路线。

---

## 2. 独占可写路径（严禁越界）

- `Whisky/Modules/guest-optimizer/`（新建）
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/UTM*.swift`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/WindowsGuest*.swift`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/UTM*.swift`
- `handoff/phase-4/evidence/p4-c/`（新建）

---

## 3. 验收标准与交付物

1. `Whisky/Modules/guest-optimizer/` 完整可复现 Profile、幂等优化与回滚脚本及离线白名单保护单测。
2. `handoff/phase-4/evidence/p4-c/optimizer-benchmark.json` 与 `summary.md`（绑定源码 SHA-256 的前后量化对比与一键回滚验收证明）。
3. `handoff/phase-4/evidence/p4-c/x86-ace-axis2-assessment.md`（客观 Go/No-Go 预研）。
4. 门禁全绿：Strict SwiftLint 0 违规、`python3 handoff/task-07/format_check.py` 通过、SwiftPM 全量 0 失败、`audit_anticheat_hardening.py --self-test` 通过、0 隐私路径泄露。
5. 保持中性占位符，署名 `@DNPMBHC`，不执行 `git commit / push`。
