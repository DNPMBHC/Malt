# 窗口 A：最小化真实 UTM Windows 11 ARM64 Guest 落地与外接卷映射指南

日期：2026-11-22
适用阶段：Phase 2 · 窗口 A（`task-02 / module-b`）
当前状态：
- **UTM 5.0.9 (`utmctl 5.0.9`)**：已安装就绪（`/Applications/UTM.app`、`/opt/homebrew/bin/utmctl`）。
- **外接卷 QEMU ARM64 虚拟机包**：已在外接卷 `/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/vms/Windows11-ARM64.utm` 自动创建并注册到 UTM（UUID：`B107A021-E60C-426B-BB62-626122CE44BE`），通过符号链接接入 UTM 容器目录，**不占用仅剩 13 GiB 的内置系统盘**。
- **外接卷共享目录**：`/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/shared` 已自动绑定至该虚拟机的 SPICE WebDAV 共享目录注册表。
- **真实 UTM AppleScript 契约修复**：已在 `WindowsGuestTransport.swift`、`UTMWindowsGuestProvider.swift`、`WindowsGuestProbeService.swift` 中修复真实 UTM 5.0.9 下 `inspectScript` 的 `configuration of vm` record 求值错误 (`-1700`)、目标父目录自动创建、`terminate` 退出竞态容错及 `WindowsGuestProbeReporting` 标准输出采集。

---

## 1. 宿主环境体检基线与存储红线

- **宿主架构与硬件**：Apple Silicon (`arm64`)，10 核 CPU，16 GiB RAM，`kern.hv_support = 1`。
- **存储空间约束**：
  - 内置系统盘 (`/System/Volumes/Data`) 可用空间仅约 **13 GiB**（使用率 98%），**严禁存放 `.utm` 虚拟机包或测试安装包**。
  - 外接挂载卷 (`/Volumes/<EXTERNAL_VOLUME>`) 可用空间约 **60 GiB** 且具备完整读写权限（`r/w`）。
- **外接卷标准目录结构**（已自动创建并配置就绪）：
  - `/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/vms/Windows11-ARM64.utm`：已预置 4 核 CPU、6144 MB 内存、36 GiB NVMe 稀疏动态磁盘、UEFI + TPM 2.0 + Hypervisor.framework 加速。
  - `/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/shared/`：作为宿主与 Guest 的共享映射根目录（对应 `RuntimeGuestConfiguration.fileMappings[0].hostDirectory`）。

---

## 2. 已预置的 UTM 虚拟机参数与核验命令

在宿主机终端可直接运行以下命令核验已注册的真实 UTM 虚拟机：

```zsh
/opt/homebrew/bin/utmctl version
# 输出: 5.0.9

/opt/homebrew/bin/utmctl list
# 输出:
# UUID                                 Status   Name
# B107A021-E60C-426B-BB62-626122CE44BE stopped  Windows11-ARM64
```

### 为什么必须使用 UTM 的 **QEMU** 后端（而非 Apple Virtualization）
`UTMWindowsGuestProvider.validate(_:config:)` 强制校验：
1. `snapshot.backend.lowercased() == "qemu"`；
2. 进程启动 (`execute`)、退出码轮询 (`get result of guest process`)、文件推送 (`open file ... for writing` / `push`) 与输出捕获 (`with output capturing`) 均依赖 **QEMU Guest Agent (`qemu-ga`)** 串口通道，Apple Virtualization (`Virtualization.framework`) 后端不支持上述 AppleScript QGA 指令。

---

## 3. 导入/安装 Windows 11 ARM64 系统镜像的最小化步骤

当前虚拟机 `B107A021-E60C-426B-BB62-626122CE44BE` 硬件壳、外接卷稀疏磁盘、WebDAV 共享目录及 `utm-guest-tools` 驱动包已全部预配完毕，仅需挂载 Windows 11 ARM64 安装 ISO 或导入 VHDX 即可启动 Guest OS：

### 步骤 1：获取 Windows 11 ARM64 安装镜像（ISO 或 VHDX）到外接卷
将 Windows 11 ARM64 (23H2 / 24H2) 的 `.iso` 或 `.vhdx` 存放在外接卷 `/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/` 下：
- **方式 A（使用 CrystalFetch 下载官方 ISO）**：
  ```zsh
  /opt/homebrew/bin/brew install --cask crystalfetch
  ```
  打开 CrystalFetch 选择 `Windows 11` → `Apple Silicon (ARM64)` → 下载 ISO 保存至 `/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/Win11_ARM64.iso`。
- **方式 B（使用现有 VHDX / QCOW2）**：
  若已有安装好的 Windows 11 ARM64 `.vhdx` 或 `.qcow2`，可直接通过 `qemu-img convert` 替换 `/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/vms/Windows11-ARM64.utm/Data/` 下的 `.qcow2` 磁盘。

### 步骤 2：在已创建的 `Windows11-ARM64` 虚拟机中完成系统与 QEMU Guest Agent 安装
1. 在 `UTM.app` 中选中 `Windows11-ARM64`（`B107A021-E60C-426B-BB62-626122CE44BE`），将 USB/CD 光驱挂载为 `/Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/Win11_ARM64.iso` 并启动。
2. 若在 Windows 11 OOBE 联网界面需跳过联网：
   - 按 `Shift + F10`（Mac 键盘 `Fn + Shift + F10`）打开 `cmd.exe`，输入 `OOBE\BYPASSNRO` 回车，重启后创建本地管理员账户（无密码自动登录）。
3. 进入桌面后，运行 UTM 自动挂载的 Guest Tools 光盘中的 **`spice-guest-tools-xxx.exe`**，一键安装 VirtIO 驱动、SPICE WebDAV 与 **QEMU Guest Agent (`qemu-ga`)**。
4. 在 Guest 管理员 PowerShell 中确认 `QEMU Guest Agent` 服务已运行并创建映射目录 `C:\whisky-guest-share`：

```powershell
Set-Service -Name "QEMU Guest Agent" -StartupType Automatic
Start-Service -Name "QEMU Guest Agent"
Get-Service -Name "QEMU Guest Agent"
New-Item -ItemType Directory -Force -Path "C:\whisky-guest-share"
```

---

## 4. 符合 `RuntimeGuestConfiguration` 的脱敏 JSON 配置模板

同目录已落盘 [runtime-guest-configuration.template.json](./runtime-guest-configuration.template.json)：

```json
{
  "identifier": "B107A021-E60C-426B-BB62-626122CE44BE",
  "architecture": "aarch64",
  "startupTimeoutSeconds": 120,
  "fileMappings": [
    {
      "hostDirectory": "file:///Volumes/<EXTERNAL_VOLUME>/whisky-phase2-guest/shared/",
      "guestDirectory": "C:\\whisky-guest-share"
    }
  ]
}
```
