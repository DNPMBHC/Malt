# 窗口 A（`task-02 / module-b`）真实 Windows 11 ARM64 Guest 端到端验证总结

日期：2026-11-22
窗口职责：真实 Windows Guest 后端与环境打通（P0 · 第一优先冲刺主线）
当前结论：**阶段 A1 与阶段 A2 全部真机端到端验证通过，存储映射状态已从 `configured` 真实达到 `verified`，`WindowsGuestProbeService` 真机 JSON 报告链路已打通并可立即交接窗口 B 与窗口 C。**

---

## 1. 五维状态分离声明（严格遵守工程纪律）

| 维度 | 当前状态 | 证据与边界说明 |
| --- | --- | --- |
| **1. 代码实现** | `completed` | 完成 `UTMWindowsGuestProvider`、`WindowsGuestTransport`、`WindowsGuestProbeService` 真实 UTM 5.0.9 + Windows 11 QGA 契约修复与 `WindowsGuestProbeReporting` 接入；Strict SwiftLint 0 违规，Strict `swift-format` 6 文件全过。 |
| **2. 本机合成验证** | `passed` | `WhiskyKit` 全量 107 项测试（105 通过 / 2 跳过 / 0 失败），UTM / 存储预检专项 24 项全部通过。 |
| **3. 真实 Guest / UTM 验证** | **`verified`** | 已在外接卷真实部署并启动 **Windows 11 Enterprise Evaluation 24H2 ARM64 (`Build 10.0.26100.1`, `26100.1.arm64fre.ge_release.240331-1435`)** + `QEMU Guest Agent`；通过生产 `UTMWindowsGuestProvider` 真机实测通过：架构识别与不匹配拦截、QGA 就绪握手、存储映射从 `configured` 升级为 **`verified`**、带空格/引号参数与自定义环境变量回传、`0` 与 `42` 真实退出码、运行中 `cancel()` 与重复 `cancel()`（无副作用）、`stop()` 与超时回滚、以及 `WindowsGuestProbeService` 真机取回 Schema v2 JSON 报告。 |
| **4. 厂商支持** | `unknown` | 严禁将 Guest 握手、普通程序执行或自有探针通信等同于反作弊厂商支持。 |
| **5. 真实游戏验证** | `not_verified` | 未在 Guest 中声明任何受保护商业游戏（如 VALORANT）受支持，`protectedGameLaunchAuthorized == false`。 |

---

## 2. 真实 Windows 11 24H2 ARM64 Guest 环境与架构元数据

- **`host_cpu_architecture`**：`arm64`（Apple Silicon，10 核 CPU，16 GiB RAM，`kern.hv_support = 1`）
- **`guest_cpu_architecture`**：`arm64` / `aarch64`（Win32 `IsWow64Process2` 实测返回 `0xAA64` / `arm64`，`PROCESSOR_IDENTIFIER = ARMv8 (64-bit) Family 8 Model 0 Revision 0, QEMU`）
- **`guest_os_build`**：`10.0.26100.1`（`BuildLabEx: 26100.1.arm64fre.ge_release.240331-1435`，`DisplayVersion: 24H2`）
- **`guest_os_edition`**：`Windows 11 Enterprise Evaluation`（`EditionID: EnterpriseEval`）
- **外接卷虚拟机路径**：`/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/vms/Windows11-ARM64.utm`（UUID: `B107A021-E60C-426B-BB62-626122CE44BE`，内置系统盘 0 字节占用）
- **外接卷共享目录映射**：`/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/shared` ↔ `C:\whisky-guest-share`

---

## 3. 阶段 A2 真机端到端全生命周期验证结果

通过 `WHISKY_REAL_UTM_VM_ID="B107A021-E60C-426B-BB62-626122CE44BE" WHISKY_REAL_UTM_SHARED_DIR="/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/shared" swift test --package-path Whisky/WhiskyKit --filter testRealUTMProviderHostAndVMLifecycleWhenConfigured` 实测（`Executed 1 test, with 0 failures in 9.958 seconds`）：

1. **架构识别与不匹配拦截**：
   - 传入 `architecture: "x86_64"` 时，生产 `UTMWindowsGuestProvider` 通过 `inspectScript` 读取真实 VM 架构 `aarch64`，在启动前准确抛出 `UTMGuestError.architectureMismatch`。
2. **存储预检从 `configured` 真实升级到 `verified`**：
   - 启动前 `preflightStorage` 返回 `hostTargetState == .writable`、`storage.state == .ready`、`storage.guestMapping == .configured`。
   - 启动 `whisky_a2_test.exe` 后，`pushCreatingParentDirectory` 将可执行文件推送至 `C:\whisky-guest-share\whisky_a2_test.exe`，并在 Guest 内执行 `C:\Windows\System32\attrib.exe /L C:\whisky-guest-share\whisky_a2_test.exe` 返回退出码 `0`。
   - `await provider.latestStoragePreflight()` 真实达到：`guestFileVisibility == .visible`、**`storage.guestMapping == .verified`**、**`canExecuteGuestFile == true`**。
3. **带空格/引号参数、自定义环境变量与真实退出码 (`0` / `42`)**：
   - 传入参数 `["--exit-code", "0", "--echo", "two words", "literal \"quote\""]` 与环境变量 `["WHISKY_E2E_ENV": "verified_from_host"]`，Guest 内真实接收并输出：
     - `ARG[3]=two words`
     - `ARG[4]=literal "quote"`
     - `WHISKY_E2E_ENV=verified_from_host`
     - `session.wait()` 返回 `RuntimeExitResult(status: 0, reason: .exit)`。
   - 传入参数 `["--exit-code", "42"]`，`session.wait()` 真实返回 `RuntimeExitResult(status: 42, reason: .exit)`。
4. **运行中 `cancel()`、重复 `cancel()`（幂等无副作用）与会话回收**：
   - 启动 `--sleep-ms 30000` 长运行进程，连续两次调用 `await session.cancel()`，真实触发 Guest 内 `taskkill.exe /PID <pid> /T /F` 终止目标进程，重复取消无副作用，`session.wait()` 正常结束返回非 0 终止状态。
5. **`WindowsGuestProbeService` 真机调用与 JSON 报告取回（窗口 B 交接就绪）**：
   - 调用 `try await WindowsGuestProbeService(provider: realProvider).assess()`，自动将共享目录中的 `module_a_probe.exe` 推送至 `C:\whisky-guest-share\module_a_probe.exe`，传入 64 位随机挑战 `nonce`，通过 `execute ... with output capturing` 取回 Schema v2 JSON 报告并通过 `AntiCheatProbeReportValidator.assess` 校验：
     - `schemaVersion == 2`
     - `guest.kernelArchitecture == .arm64`
     - `guest.windowsBuild == 26100`
     - `driver.loadState == .notLoaded`（纯净 Guest 尚未加载 `.sys` 驱动时如实报告 `failureStage: .open, win32Error: 2`）
     - `protectedGameLaunchAuthorized == false`

---

## 4. 宿主与 Guest 基础设施性能基线

| 指标 | 实测值 | 说明 |
| --- | --- | --- |
| **AppleScript `inspect` 延迟（冷态 / 热态）** | `186.89 ms` / `173.99 ms` | 读取 VM ID、Backend (`qemu`)、Status、Architecture (`aarch64`) |
| **QEMU VM 冷启动耗时 (`.stopped` → `.started`)** | `3224.76 ms` | `UTM.app` 拉起 `qemu-aarch64-softmmu` (Hypervisor.framework) |
| **QGA 热握手延迟 (`cmd.exe /d /c exit 0`)** | `209.39 ms` | `waitForAgent` 端到端进程创建 + 退出码轮询 |
| **QGA 可执行文件推送延迟 (`file push`)** | `144.56 ms` | 宿主外接卷 → Guest `C:\whisky-guest-share\whisky_a2_test.exe` |
| **Guest 文件可见性校验延迟 (`attrib.exe /L`)** | `178.28 ms` | `configured` → `verified` 校验耗时 |
| **Guest 测试程序端到端执行耗时** | `849.39 ms` | 含参数/环境变量注入、执行落盘与标准输出捕获 |
| **QEMU VM 停止回收耗时 (`.started` → `.stopped`)** | `563.42 ms` | `stop ... by force` |
| **Windows 11 桌面空载宿主内存占用 (RSS)** | `UTM: 46.20 MiB` / `QEMU: 1029.38 MiB` | Windows 11 24H2 ARM64 桌面常驻状态 |
| **执行测试程序时宿主内存占用 (RSS)** | `UTM: 57.02 MiB` / `QEMU: 1132.62 MiB` | 连续执行测试程序与探针采样期间 |
| **外接卷共享目录读写延迟 (1 MiB)** | `写: 5.33 ms` / `读: 0.61 ms` | `/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/shared` |
