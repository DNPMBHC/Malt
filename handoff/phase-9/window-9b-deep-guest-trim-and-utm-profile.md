# 窗口 9B 任务书：UTM 虚拟硬件精简规范与 Windows 11 深度安全裁剪优化器 v2（🟡 中等难度 · 推荐 `Hydrogen Medium`）

署名：`@DNPMBHC`  
难度与模型建议：**🟡 中等难度 — 推荐 `Hydrogen Medium`**（路径清晰的配置裁剪、PowerShell/Python 声明式优化与单元测试，无需高阶额度）  
启动前提：**脚本升级、白名单单测与 UTM 配置分析可立即启动；涉及真机对比实测需等待窗口 9A 释放 VM 租约后在瞬时克隆上执行**  
请先阅读：`handoff/phase-9/README.md`、`Whisky/Modules/guest-optimizer/profiles/anticheat-minimal-win11-arm64.json`、`Whisky/Modules/guest-golden/profiles/golden-win11-arm64-v1.json`、`handoff/phase-4/evidence/p4-c/optimizer-benchmark.json`

---

## 1. 独占可写路径（严格互斥）

- `Whisky/Modules/guest-optimizer/`
- `Whisky/Modules/guest-golden/`
- `graphics-lab/golden_guest_*`
- `graphics-lab/test_golden_guest_*`
- `handoff/phase-9/evidence/p9-b/`（新建）

严禁修改 `Whisky/Whisky/`、`Whisky/WhiskyKit/`、`Whisky/.swiftlint.yml`、`handoff/task-07/`、窗口 9A 独占路径、已封存的 `golden-win11-arm64-v1` 母盘与冷备 `vm-a`。

---

## 2. 核心任务拆解

围绕“研究 UTM 自带功能 + 进一步精简系统无用组件”，在**100% 保证安全链、Prism、WHQL 3D 驱动、ACE/反作弊依赖与一键回滚**的前提下，打造更轻、更低干扰的 Guest 运行时配置 v2：

### 任务 9B-1（P0）：UTM 自带虚拟硬件与显示/输入配置深度裁剪规范
1. 审计当前 `golden-win11-arm64-v1` 的 UTM `config.plist` 与实际 QEMU 启动命令行，梳理并裁剪**无用或产生额外背景开销的虚拟设备**：
   - 关闭未使用的 `usb-redir`（3 路 SPICE USB 重定向通道）、移除多余空 CD-ROM 挂载槽位；
   - 锁定 `Display[0].DynamicResolution = false`、评估 `QEMURendererFPSLimit`、`Sharing`（剪贴板/目录共享保持关闭）、`virtio-balloon` 与音频/网络最小化配置；
   - 预留对接窗口 9A 验真的 `QEMUDirectXDriver`（`DXMT` vs `D3DMetal`）原生配置开关至 `Whisky/Modules/guest-golden/` 规格与 `golden_guest_manager.py`（支持在派生瞬时克隆时按参数指定后端，不修改只读母盘！）。

### 任务 9B-2（P0）：Windows 11 24H2 ARM64 极简优化器 v2（严格白名单 + 一键回滚）
1. 在 4C 优化器 v1（已砍 14 服务 / 23 进程 / 降 167.8 MiB RSS）基础上，通过只读盘点识别仍可安全精简的**纯无用后台组件**，升级 `anticheat-minimal-win11-arm64.json` 与 `apply-optimizer.ps1` / `rollback-optimizer.ps1`：
   - 例如：Edge 后台预启动与 StartupBoost 注册表项、Widgets/WebExperience/Copilot/GameBar/GameDVR 录屏覆盖（避免与 D3D11/Neptune 合成冲突）、非安全遥测/诊断计划任务、后台应用权限与冗余 UWP 预装、非必要视觉动画与透明效果；
   - **绝对不可触碰的硬白名单（单元测试强制校验）**：
     - Prism x64 转译链（`xtajit.dll`、`xtajit64.dll`、`wow64.dll`、`wow64win.dll`）；
     - 安全信任链（Secure Boot、TPM 2.0 / `TBS`、Code Integrity、Windows Defender/SecurityHealth、`CryptSvc`、`EventLog`）；
     - 图形与基础系统（WHQL `viogpu3d`、`DWM`、`Winmgmt`、`RpcSs`、`QEMU-GA`、音频、网络、`VCLibs`/`DirectX` 运行库）；
     - 全部主流反作弊服务白名单（`ACE-BASE`、`ACE-GAME`、`ACE-CORE*`、`AntiCheatExpert*`、`vgc`/`vgk`、`EasyAntiCheat*`、`BEService`）。
2. 所有新增优化项必须支持 **100% 幂等应用 + 一键完整回滚**，并在 `test_guest_optimizer.py` 与 `test_golden_guest_manager.py` 补齐白名单冲突拒绝与回滚一致性单元测试。

### 任务 9B-3（P0）：瞬时克隆真机前后对比实测（待 9A 释放 VM 后执行）
1. 基于 `golden-win11-arm64-v1` 派生一次性克隆，实测应用 **UTM 硬件裁剪 + 优化器 v2** 前后的：
   - 宿主机总 RSS（QEMU + `QEMURenderServer` + `swtpm`）、空载 QEMU CPU %、Guest 进程数、运行中服务数、冷启耗时、`d3d11_probe.exe` 3D 帧率；
   - 验证一键回滚 `rollback_consistent: true` 与全部安全不变量 `passed: true`；
   - 测完彻底销毁瞬时克隆并复核 `golden_zero_drift: true` & `primary_zero_drift: true`。

---

## 3. 验收标准与交付物

1. `python3 -B -m unittest discover -s Whisky/Modules/guest-optimizer/tests -v` 与 `(cd graphics-lab && python3 -B -m unittest discover -v)` 全部通过；
2. Strict SwiftLint **0 违规**、`audit_anticheat_hardening.py --self-test` 全绿；
3. `handoff/phase-9/evidence/p9-b/report.md`、`utm-trim-and-optimizer-v2-benchmark.json` 与 `zero-drift-proof.json` 落盘、零隐私泄露且无大文件残留。
