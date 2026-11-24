# Phase 3-B 任务书：防外挂安全加固、免责声明与单 App 产品化整合（可立即启动）

日期：2026-11-22
启动前提：**无需等待 Windows 11 镜像，基于 Phase 2 收口基线可立即开工**。
请先阅读：`handoff/phase-3/README.md`、`handoff/runtime-interface.md`、`handoff/task-07/report.md`

---

## 1. 核心目标

在不影响普通游戏体验与反作弊合规验证的前提下，完成三项产品化与安全底线工程：
1. **防外挂安全加固**：确保官方签名的 `Whisky_new.app` 及辅助进程从构建配置与架构层封死“被直接用于寄生做外挂”的攻击面；
2. **法律与合规免责声明落盘**：在仓库 `README`、App 首次启动确认/设置关于页与 CLI 帮助中落地完整三语免责声明与反作弊合规说明；
3. **单 App 产品化整合**：将 Phase 2 已验证的 **DXMT + D3DMetal + DXVK 三引擎运行时管理**、兼容规则库内置打包与开发环境自动重启体验整合为干净统一的 `Whisky_new.app`。

---

## 2. 具体实施任务

### 任务 B1：防外挂安全加固与静态安全门禁
1. **macOS Hardened Runtime 与 Entitlements 加固审计**：
   - 核查 `Whisky.xcodeproj` 与所有 Target（`Whisky`、`WhiskyCmd`、`WhiskyThumbnail` 及未来助手进程）的 Release/正式分发构建配置：
     - 启用 `ENABLE_HARDENED_RUNTIME = YES`；
     - 确认 Release 配置严禁开启 `com.apple.security.get-task-allow`、`com.apple.security.cs.allow-dyld-environment-variables`、`com.apple.security.cs.disable-library-validation`；
     - 保留 Debug 开发配置可本地调试，但在门禁脚本中明确分离 Debug 与 Release 安全断言。
2. **零作弊原语静态审计规则（接入 `handoff/task-07/` 校验）**：
   - 编写静态审计测试，确保生产代码库中不存在：
     - 针对目标游戏进程的内存读写/附加调试 API（如 `task_for_pid`、`mach_vm_read`、`mach_vm_write`、`OpenProcess(PROCESS_VM_WRITE)`、`WriteProcessMemory`）；
     - 伪造硬件/隐藏虚拟化标志参数（如 QEMU `kvm=off`、`hv_vendor_id` 伪装、SMBIOS 篡改）；
     - 生产态 QMP/GDB 监听端口或合成键鼠宏注入接口。
3. **诚实身份与远程证明（Attestation）接口预留**：
   - 设计只读、结构化的 `RuntimeIntegrityReport` 模型（记录当前宿主 `SIP` 可观测状态、应用代码签名/Team ID 状态、是否为官方构建标记、以及是否运行在真实/虚拟环境），仅用于本地诚实诊断与未来厂商合规对接预留，绝不伪造。

### 任务 B2：免责声明与合规告知落地
1. 更新 `Whisky/README.md`：加入清晰的中文/英文项目定位、架构说明、**反作弊防滥用声明**与完整 **免责声明**（直接对齐 `handoff/phase-3/README.md` 第 3 节）。
2. 在 SwiftUI 应用层落地免责声明界面（英 / 简中 / 繁中三语 `Localizable.xcstrings`）：
   - 首次启动欢迎页 / 设置页「合规与免责声明」板块展示完整声明；
   - 当用户尝试对受强反作弊保护的游戏启用实验性 Guest 路径时，清晰展示五维状态与合规提醒，禁止误导为“已支持在线游玩”。

### 任务 B3：单 App 产品化整合与三引擎运行时管理
1. **三引擎运行时状态面板与检测整合**：
   - 在 App 设置/运行时管理视图中直观展示本机 `DXMT`、`D3DMetal`、`DXVK` 的安装状态、版本指纹与自动路由状态（复用窗口 D 已合入的 `WhiskyWineInstaller.availableGraphicsBackends` 与 `HostWineBackendRouter`）。
2. **兼容规则库内置打包方案**：
   - 编写构建期只读转换脚本，将 `handoff/module-f/evidence.json` 裁剪编译为轻量只读资源 `compatibility-matrix.json` 供 App 消费（保留来源更新时间、WoA/VM 双轴拆分与五维状态），保持单源维护、不手工重复维护两份兼容表。
3. **开发环境自动重建与重启**：
   - 每次修改 `Whisky` App 或 `WhiskyCmd` 代码后，必须执行 `./handoff/task-07/dev_restart.sh` 重建并自动重启应用完成实机验证。

---

## 3. 验收标准

- Strict SwiftLint 0 违规；SwiftPM 全量测试 0 失败（含新增安全基线与免责声明/规则库解析单测）；Xcode Debug/arm64 构建通过。
- 新增静态防外挂原语审计与 Release Hardened Runtime 配置审计脚本通过。
- 所有新增文档与报告保持 100% 脱敏；未获明确指令不执行 `git commit / push`。
