# 窗口 A（`task-02 / module-b`）阶段执行与真实 UTM 验证总结

日期：2026-11-22
窗口职责：真实 Windows Guest 后端与环境打通（P0 · 第一优先冲刺主线）

---

## 1. 五维状态分离声明（严格遵守工程纪律）

| 维度 | 当前状态 | 证据与边界说明 |
| --- | --- | --- |
| **1. 代码实现** | `completed` | 完成 `UTMWindowsGuestProvider`、`WindowsGuestTransport`、`WindowsGuestProbeService` 真实 UTM 5.0.9 契约修复与 `WindowsGuestProbeReporting` 协议接入；Strict SwiftLint 0 违规，Strict `swift-format` 6 文件全过。 |
| **2. 本机合成验证** | `passed` | `WhiskyKit` 全量 107 项测试（105 通过 / 2 跳过 / 0 失败），其中 UTM / 存储预检专项 24 项全部通过。 |
| **3. 真实 Guest / UTM 验证** | `utm_vm_lifecycle_verified`（待装入 Windows 11 ARM64 OS 镜像完成 QGA 内部执行） | 已在宿主机真实安装 `UTM.app` 5.0.9 (`utmctl 5.0.9`)，在外接卷创建并注册真实 QEMU `aarch64` 虚拟机（`B107A021-E60C-426B-BB62-626122CE44BE`）、挂载 `utm-guest-tools` ISO 及 WebDAV 共享目录；通过生产 `UTMWindowsGuestProvider` 实测 `availability == .ready`、外接卷 `preflightStorage`、`inspect`、架构不匹配真实拦截、真实 QEMU VM 冷启动与超时自动停机回收。因本机与外接卷无现成 Windows 11 ARM64 `.iso`/`.vhdx`，Guest OS 内部 QGA 命令待镜像导入后一键复跑。 |
| **4. 厂商支持** | `unknown` | 严禁将 UTM 虚拟机就绪或探针通信等同于反作弊厂商支持。 |
| **5. 真实游戏验证** | `not_verified` | 未在 Guest 中声明任何受保护商业游戏（如 VALORANT）受支持。 |

---

## 2. 真实 UTM 5.0.9 对接中发现并修复的 5 项关键契约缺陷

在将 `UTMWindowsGuestProvider` 与真实 `UTM.app` 5.0.9 对接实测的过程中，发现原有仅靠 Mock 测试的代码存在 **5 处真实环境不兼容或功能缺失**，已全部在窗口 A 独占路径内修复：

1. **`inspectScript` 在真实 UTM 5.0.9 下必现 `-1700` 错误（已修复并实测通过）**：
   - **根因**：`UTM.sdef` 中 `configuration of vm` 是 `record-type`（而非对象元素）。原代码 `architecture of (configuration of vm) as text` 触发 AppleEvent 链式对象引用错误 `-1700`（`不能将“«class ArCh» of «class CoFg» of «class UTMv» ...”转换为“text”类型`）。
   - **修复**：在 `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/WindowsGuestTransport.swift` 中先求值到局部变量 `set vmConfig to configuration of vm`，再读取 `architecture of vmConfig as text`。
2. **`stopScript` 使用 `by request` 导致超时回滚无法关停真实 QEMU VM（已修复并实测通过）**：
   - **根因**：`UTM.sdef` 定义 `by request` 为向 Guest OS 发送可被忽略的电源请求。当 VM 处于启动途中或 `waitForAgent` 超时触发 `catch` 自动停机回滚时，`by request` 被忽略，导致 QEMU 进程残留于 `.started` 状态。
   - **修复**：在 `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/WindowsGuestTransport.swift` 中将 `stopScript` 对齐 `utmctl stop` 的默认策略 `by force`，实测关停耗时 `563.42 ms`。
3. **`push` 目标父目录缺失与句柄关闭契约（已修复）**：
   - **根因**：QGA `guest-file-open` (`for writing`) 在 Guest 内父目录不存在时直接报错。
   - **修复**：在 `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/WindowsGuestTransport.swift` 与 `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/UTMWindowsGuestProvider.swift` 中实现 `pushCreatingParentDirectory`，首次推送失败时自动通过 `cmd.exe /d /c if not exist <parent> mkdir <parent>` 创建父目录后重试推送，并显式指定 `push guestFile from ... with closing`。
4. **`terminate` 中 `taskkill.exe` 的进程自然退出竞态（已修复）**：
   - **根因**：若目标进程在 `taskkill.exe` 执行前刚刚自行退出，`taskkill.exe` 返回非 0 退出码。
   - **修复**：在 `taskkill.exe` 返回非 0 时二次检查 `result(identifier, pid: pid) != nil`，若目标进程已退出则视为成功终止。
5. **`UTMWindowsGuestProvider` 补齐 `WindowsGuestProbeReporting` 协议（已修复）**：
   - **根因**：原 `UTMWindowsGuestProvider` 未遵循 `WindowsGuestProbeReporting`，调用 `WindowsGuestProbeService.assess()` 恒定抛出 `.providerDoesNotSupportProbe`。
   - **修复**：在 `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/WindowsGuestProbeService.swift` 与 `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/WindowsGuestTransport.swift` 中基于 UTM 5.0.9 的 `execute ... with output capturing` 与 `output data of r` (Base64) / `output text of r` 实现 `collectSelfProbeReport(nonce:)`，支持自动推送共享目录中的 `module_a_probe.exe` / `ModuleAProbe.sys` 并捕获 JSON 报告。

---

## 3. 真实 UTM 5.0.9 + QEMU (`aarch64`) 基础设施基线实测数据

基于外接卷 `/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/vms/Windows11-ARM64.utm`（UUID: `B107A021-E60C-426B-BB62-626122CE44BE`，4 核 CPU / 6144 MB RAM / 36 GiB NVMe 稀疏磁盘 / Hypervisor.framework 开启）实测：

| 指标 | 实测值 | 说明 |
| --- | --- | --- |
| **AppleScript `inspect` 延迟（冷态）** | `186.89 ms` | 读取 `id`、`backend: "qemu"`、`status: "stopped"`、`architecture: "aarch64"` |
| **QEMU VM 冷启动耗时 (`.stopped` → `.started`)** | `3224.76 ms` | 包含 `UTM.app` 拉起 `QEMU` 辅助进程与 Hypervisor.framework 初始化 |
| **已运行 VM 热附着 `inspect` 延迟** | `173.99 ms` | VM 处于 `.started` 状态下的快速状态核验 |
| **QEMU VM 停止回收耗时 (`.started` → `.stopped`)** | `563.42 ms` | 通过 `stop ... by force` 完成 QEMU 进程回收 |
| **宿主 `UTM.app` 内存占用 (RSS)** | `66.34 MiB` | VM 运行期间 `UTM.app` 主进程常驻内存 |
| **宿主 `QEMU (aarch64)` 内存占用 (RSS)** | `177.81 MiB` | UEFI 启动阶段 QEMU 虚拟化进程常驻内存（按需分配，上限 6144 MiB） |
| **外接卷共享目录写入延迟 (1 MiB + `fsync`)** | `5.33 ms` | `/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/shared` |
| **外接卷共享目录读取延迟 (1 MiB)** | `0.61 ms` | `/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/shared` |

---

## 4. 下一步一键复跑入口（导入 Windows 11 ARM64 镜像后）

当按照 [guest-setup-guide.md](./guest-setup-guide.md) 在 `Windows11-ARM64`（`B107A021-E60C-426B-BB62-626122CE44BE`）中完成 Windows 11 ARM64 与 `spice-guest-tools` (`qemu-ga`) 安装后，直接执行以下命令即可运行真实 Guest 端到端回归：

```zsh
WHISKY_REAL_UTM_VM_ID="B107A021-E60C-426B-BB62-626122CE44BE" \
WHISKY_REAL_UTM_SHARED_DIR="/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/shared" \
swift test --package-path Whisky/WhiskyKit --filter testRealUTMProviderHostAndVMLifecycleWhenConfigured
```
