# Phase 3-C 交付验收报告：合规物理机串流兜底后端 `RemotePhysicsBackend`

日期：2026-11-22  
对应任务书：`handoff/phase-3/remote-physics-backend.md`  
执行范围：独占实现 `RemotePhysicsModels.swift`、`RemotePhysicsBackend.swift`、`RemotePhysicsBackendTests.swift` 及跨窗口接线提案 `interface-proposal.md`。

---

## 1. 五维状态总览（严格分离，禁止混淆）

| 维度 | 当前状态 | 事实依据 |
| --- | --- | --- |
| **代码实现** | 已完成 | `RemotePhysicsModels.swift` 与 `RemotePhysicsBackend.swift` 严格落于 Phase 3-C 独占路径，未触碰任何共享文件。 |
| **本机合成与进程验证** | 全部通过 | 10 项 `RemotePhysics` 单元测试（含真实进程退出码 `0`/`1`、真实 `sleep` 进程取消与重复取消幂等、真实 `NWConnection` 回环闭合端口非阻塞探测）及全仓 SwiftPM 测试 0 失败；Strict SwiftLint 0 违规。 |
| **真实远程物理主机验证** | `environment_not_verified`（`unconfigured` / `clientMissing`） | 本机未安装 `Moonlight.app` 且无已配置局域网物理 Windows 主机，见 `environment-check.json`，绝不伪造真机通过数据。 |
| **厂商支持** | 独立合规域（由用户自行遵守厂商条款） | 执行域明确标识为 `remote_physical_windows`，游戏与反作弊运行于用户真实物理 Windows 硬件，绝不冒充本地 Wine/VM。 |
| **真实游戏验证** | 未执行 | 尚无已配置的局域网物理主机与商业游戏实测。 |

---

## 2. 防外挂安全红线与合规自检

| 红线条款 | 落地实现与验证证据 |
| --- | --- |
| **零作弊原语（Clean-by-Design）** | 协议与实现不包含任何进程内存读写、DLL 注入、HWID/SMBIOS/TPM 伪造或虚拟化隐藏接口。 |
| **零截帧 + 宏注入闭环** | 仅委托开源 `Moonlight.app` 或受控客户端执行合规远程显示与真实物理 HID 输入；无任何画面抓取/分析/脚本宏注入接口。 |
| **零明文凭据落盘** | `RemotePhysicsConfiguration` 无密码/PIN/Token/私钥字段；自定义 `Decodable` 拒绝顶层敏感键（`password`/`pin`/`token`/`secret`/`apiKey`/`private_key`/`authorization` 等）；`validate()` 拒绝 `hostIdentifier` 中嵌入 `@`、`://`、`?`、`&`。 |
| **零 Shell 注入** | `Moonlight` 与 `externalClient` 均以 `Process.arguments` 强类型数组传参；`validate()` 显式拒绝 `sh`/`bash`/`zsh`/`fish`/`python*`/`osascript` 等 shell 与脚本解释器作为外部客户端。 |
| **执行域诚实隔离** | 固定暴露 `RemotePhysicsExecutionDomain.remotePhysicalWindows`（`remote_physical_windows`），不与 Wine / Windows Guest 混淆。 |

---

## 3. 交付物与不可变 SHA-256 清单

- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/RemotePhysicsModels.swift`  
  SHA-256: `43e9e40fac342657348430eaca868c632bacc045844c17d5705236cd1a8aa5c8`
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/RemotePhysicsBackend.swift`  
  SHA-256: `b12c9ce9ce2fbcdd8da8ecf01d5c99ffd8bfc5a2f9894123f01fa90e1b5a0eda`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/RemotePhysicsBackendTests.swift`  
  SHA-256: `1c47535cdfc1be093f83be6bd60819a9811e11682587c5e165828aa3d75e245b`
- `handoff/phase-3/evidence/p3-c/interface-proposal.md`（给总控的 `RuntimeBackendKind.remotePhysics` / `RuntimeCoordinator` 接入提案）
- `handoff/phase-3/evidence/p3-c/environment-check.json`（脱敏环境体检证据）
