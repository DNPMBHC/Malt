# Phase 3-C 任务书：合规物理机串流兜底后端 `RemotePhysicsBackend`（可立即启动）

日期：2026-11-22
启动前提：**无需等待 Windows 11 镜像，基于 Phase 2 冻结的 `RuntimeCoordinator` 架构可立即开工**。
请先阅读：`handoff/phase-3/README.md`、`handoff/runtime-interface.md`、`handoff/module-f/engineering-input.md`

---

## 1. 背景与第一性原理定位

根据 Phase 2 `module-f` 的一手实证：
- 现代顶级强内核反作弊（如国际服 Riot Vanguard `VAN 9100`、高严格模式 EAC v2、高防 DMA 策略下的 ACE）正在转向 **物理硬件信任根（物理 TPM 2.0 EK 证书 + Secure Boot + 禁止 Hypervisor）**。
- 在合法合规前提下，任何跑在 macOS 之上的本地虚拟机都无法伪造物理 TPM 芯片或绕过 Hypervisor 禁止策略。
- 因此，为了让 `Whisky_new` 作为统一 Mac 游戏调度器真正覆盖 100% 游戏场景而不诱导用户冒险作弊/封号，需要在统一调度架构中新增第三类合规后端：**`RemotePhysicsBackend`**——无缝调度用户自己拥有的局域网 x86 物理副机或合规物理云主机（如基于开源 Sunshine / Moonlight 协议），让游戏和反作弊运行在 100% 合规的真实物理 Windows 硬件上。

---

## 2. 核心设计目标（KISS 原则，绝不过度造轮子）

1. **定义 `RemotePhysicsProvider` 协议与配置模型**（对齐 `WindowsGuestProvider` 风格）：
   - 文件独占路径：`Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/RemotePhysicsBackend.swift`（新建）与对应测试 `RemotePhysicsBackendTests.swift`。
   - 配置字段（严格脱敏，不保存明文密码/凭据进明文 JSON）：主机标识、传输协议类型（如 `moonlightClient` / 通用外部串流客户端命令）、目标应用标识、连接超时、分辨率/帧率/码率偏好（可消费 `HostResourcePolicy` 的热状态/低电量降码率建议）。
   - `availability` 清晰分为：`unconfigured`、`clientMissing`、`hostUnreachable`、`ready`。
2. **复用成熟开源串流客户端（绝不重复造音视频编解码轮子）**：
   - 优先对接本机已安装的开源 `Moonlight.app` CLI/URL Scheme（或标准外部客户端进程），通过 `RuntimeSession` 统一管理拉起、退出码、取消与超时；
   - 严禁通过拼接任意 shell 字符串传参。
3. **严格守住反作弊防滥用与五维状态红线**：
   - 串流后端仅作为合规远程显示与物理输入客户端，**严禁**加入截帧识别、自动键鼠宏脚本或任何辅助作弊能力；
   - 明确记录运行环境为 `remote_physical_windows`，绝不与本地 Wine 或本地 Windows Guest 混淆。
4. **跨窗口接口提案**：
   - 如需在 `RuntimeCoordinator` / `RuntimeBackendKind` / GUI 中增加 `.remotePhysics` 分流入口，写入 `handoff/phase-3/evidence/p3-c/interface-proposal.md`，经总控审核后统一合入。

---

## 3. 验收标准

- 完成 `RemotePhysicsProvider` 模型、配置校验、生命周期会话管理、不可用/超时/取消错误处理与单元测试（SwiftPM 0 失败、Strict SwiftLint 0 违规）。
- 若本机已安装 Moonlight 与可用局域网物理机，采集真实延迟与连接恢复实测数据（脱敏）；若未配置物理机，清晰标为 `unconfigured` / `environment_not_verified`，绝不伪造真机通过。
- 未获明确指令不执行 `git commit / push`。
