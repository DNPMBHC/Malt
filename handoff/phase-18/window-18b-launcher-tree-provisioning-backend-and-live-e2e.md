# Phase 18 窗口 18B 任务书：自动部署精简后端、Launcher 派生子进程全屏联动、非 `slirp` 代理随包托管与真机端到端复验

- **窗口角色**：Phase 18 窗口 18B
- **难度评级**：🔴 高难度（建议模型：**`Neon Medium`**）
- **署名**：`@DNPMBHC`
- **必读前置**：`handoff/phase-18/README.md`、`handoff/phase-17/README.md`、`handoff/phase-17/frontend-integration.md`
- **母盘基线**：`golden-win11-arm64-v1`（只读不可变，必须全盘 SHA-256 `zero_drift = true`）

---

## 1. 任务目标

### 任务 18B-1：落地「一键部署与精简优化注入服务」（`ContainerProvisioningService.swift`）
在 `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/ContainerProvisioningService.swift`（同步补齐 `WhiskyKitTests` 单元测试）严格按 `handoff/phase-18/README.md` 契约实现：
1. **受管工作容器校验与准备**：校验传入的合法 `.utm` 容器（绝不修改只读母盘 `golden*` 与冷备 `vm-a.utm`），支持一键从只读母盘通过 APFS CoW 安全派生受管可游玩副本；
2. **4 步可观测自动化流水线**（带实时 `@Published var steps`、失败重试与一键无损回滚）：
   - `verifySourceContainer`：验证容器结构、Secure Boot 与只读边界；
   - `configureHardwarePipeline`：自动写入本机安全范围的 RAM / vCPU、`VirtIO-Blk` 多队列 `iothread` + `discard=unmap`、WHQL `virtio-mouse-pci`、清零 `usb-redir`、保留 `intel-hda` 声卡、`QEMURendererFPSLimit = 120` + 三重缓冲；
   - `applyGuestOptimization`：在容器启动就绪后通过 QGA 自动注入并核验 `guest-optimizer v3.1`（`zh-CN` 中文与微软拼音、暂停游戏期后台更新、动态安全页面文件、禁用 `spice-webdavd`、突发稳帧与前台高优先级），并支持 `rollbackOptimization(...)` 无损还原；
   - `verifyGraphicsAndNetwork`：核验 WHQL `viogpu3d`、`DXMT_SHADER_CACHE` 持久化目录与非 `slirp` 托管网络状态。

### 任务 18B-2：攻克「官方启动器（Launcher）派生游戏子进程树」前台全屏联动
升级 `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/GuestAppShellSession.swift`、`GuestAppShellScripts.swift` 与 `Whisky/Modules/guest-optimizer/scripts/kiosk-app-shell.ps1`（补齐完整单测）：
1. **解决 Phase 17 留下的真实痛点**：当用户在 `Malt` 中点击《无畏契约》（或其他带官方启动器的游戏）时，启动的是启动器 `.exe`（如官方 Launcher），随后启动器再派生出真实游戏主进程（如 `VALORANT-Win64-Shipping.exe`）；
2. **100% 合规的只读进程树归属证明（零 Hook、零注入、零全局广播）**：
   - 在私有会话中不仅校验所选 `.exe` 自身，还通过只读查询 Windows 进程父子关系（`Win32_Process.ParentProcessId` + 进程创建时间校验，防止 PID 复用）追踪该启动器合法派生的子进程树；
   - 当派生子进程树中出现**全屏/独占或无边框全屏图形主窗口**（或匹配该条目可选配置的预期游戏进程名）进入前台时，通过现有私有 `AppShellSessionBridge` 触发 `MaltContainerHelper` 自动平滑展开为无边框原生全屏 + 激活 macOS Game Mode + 捕获纯相对鼠标；
   - 当游戏主进程退出、失联或用户切出时，自动安全恢复紧凑窗口或收尾。

### 任务 18B-3：将 Phase 15A 零特权完整 TCP+UDP 非 `slirp` 代理随 `Malt.app` 打包与托管
1. 在 `Whisky/scripts/package_malt_dmg.sh` 与 `runtime_payload.py` 中：
   - 打包最新 12+1 补丁版 `MaltContainerHelper.app`（合并 Phase 15A 补丁 09 + Phase 16 补丁 10，保持 `LSUIElement = true`）；
   - 将 Phase 15A 实证通过的**零特权完整 TCP+UDP+ICMP 高 QoS（`USER_INTERACTIVE`）非 `slirp` 代理二进制**随 `Malt.app/Contents/Helpers/` 一并打包、签名（Hardened Runtime + `deep --strict`）并纳入 `UnifiedRuntimeOrchestrator` 生命周期托管（启动容器前自动拉起本地 Unix Socket，停机自动清理退出；若用户已授权内核 `vmnet` 守护进程且 socket 就绪则优先走内核 `vmnet`）。
2. 重新产出全合体 `Whisky/build/release/Malt.dmg` 并通过搬迁后 `deep --strict` 签名、1479+ 载荷检查与隔离启动冒烟测试（`0` 外部绝对动态库依赖）。

### 任务 18B-4：当前新包真机端到端复验（在 `Malt` 内直接验证全链路 + 零漂移证明）
新增 `graphics-lab/p18_malt_app_e2e.py`（及单测 `test_p18_malt_app_e2e.py`）：
1. 用本轮重打的新版 `Malt.app` 在派生受管游玩副本上实测：
   - 一键部署精简优化 4 步流水线全通 + `rollback_consistent = true`；
   - 安装包拖入无桌面弹窗 + `discoverInstalledGameCandidates` 真实扫描到游戏入口 + `registerInstalledGame` 核验落盘；
   - 随包托管的非 `slirp` 完整 TCP+UDP 代理随容器自动启停并连通；
   - 若条件允许（需用户手动登录时暂停请用户操作，严禁自动化绕过），实测从 `Malt` 内直接启动《无畏契约》并验证 **Launcher 派生 `VALORANT-Win64-Shipping.exe` 后自动切入无边框原生全屏**；
2. 清理临时测试副本，产出 `handoff/phase-18/evidence/p18-b/{provisioning-and-launcher-e2e.json,package-manifest.json,zero-drift-proof.json,report.md}`。

---

## 2. 独占写入范围（严禁越界）

- 允许写入：
  - `Whisky/WhiskyKit/Sources/WhiskyKit/Orchestration/**`
  - `Whisky/WhiskyKit/Tests/WhiskyKitTests/**`
  - `Whisky/Modules/guest-optimizer/**`
  - `Whisky/scripts/**`
  - `graphics-lab/p18_malt_app_e2e.py`
  - `graphics-lab/test_p18_malt_app_e2e.py`
  - `handoff/phase-18/evidence/p18-b/**`
- 严禁触碰：`Whisky/Whisky/Views/`（归 18A）、`Whisky/Whisky.xcodeproj/project.pbxproj`（归 18A）、`Whisky/Modules/utm-custom/`、`handoff/task-07/`、`/Applications/UTM.app` 原件、只读母盘与冷备 `vm-a`。

---

## 3. 验收门禁

1. `swift test --package-path Whisky/WhiskyKit` 全绿；
2. `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)` **0 violations**；
3. `python3 handoff/task-07/format_check.py` 全绿；
4. `(cd Whisky/scripts && python3 -B -m unittest discover -v)` 全绿；
5. `(cd Whisky/Modules/guest-optimizer && python3 -B -m unittest discover -s tests -v)` 全绿；
6. `(cd graphics-lab && python3 -B -m unittest discover -v)` 全绿；
7. `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test` 全绿；
8. 零 `> 5 MiB` 新增跟踪文件、零隐私路径泄漏、零 git 操作、母盘与 `vm-a` 全盘 SHA-256 `zero_drift = true`。
