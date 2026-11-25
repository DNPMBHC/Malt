# Phase 10A 光标不可见根因诊断与虚拟机完善交接清单（交付窗口 10B）

- 署名：`@DNPMBHC`
- 来源阶段：Phase 10A（`ephemeral-p10a-valorant`，`golden-win11-arm64-v1` + `--trim-hardware --dx-driver DXMT --fps-limit 120` + 优化器 v2）
- 关联证据：
  - `handoff/phase-10/evidence/p10-a/spawn-preflight.json`
  - `handoff/phase-10/evidence/p10-a/monitor-live-dxmt-trimmed.json`
  - `handoff/phase-10/evidence/p10-a/ace-eventlog-check.json`

---

## 1. 游戏内光标不可见实证根因分析

### 1.1 宿主机与 Guest 输入栈基线审计（实测）
1. **宿主机 QEMU 输入设备拓扑**：UTM 5.0.9 在 `aarch64` Windows VM 上默认**同时注入**了绝对坐标设备与相对坐标设备：
   - `-device usb-tablet,bus=usb-bus.0`
   - `-device usb-mouse,bus=usb-bus.0`
   - `-device usb-kbd,bus=usb-bus.0`
   - 结果：`has_usb_tablet = true`、`has_usb_mouse = true`、`pure_relative_mouse_only = false`。
2. **Guest 侧设备映射（已通过 `DEVPKEY_Device_BusReportedDeviceDesc` 精确核实）**：
   - `USB\VID_0627&PID_0001\28754-0000:00:03.0-1` → `QEMU USB Tablet`（子设备 `HID\VID_0627&PID_0001\6&2f5ff349&0&0000`）
   - `USB\VID_0627&PID_0001\89126-0000:00:03.0-2` → `QEMU USB Mouse`（子设备 `HID\VID_0627&PID_0001\6&1da9ee55&0&0000`）
   - `USB\VID_0627&PID_0001\68284-0000:00:03.0-3` → `QEMU USB Keyboard`
3. **SPICE Guest 服务状态**：
   - Guest 内**未安装/未运行 `spice-vdagent`**；仅存在 `spice-webdavd`（`Status = Stopped`）。
4. **Windows 指针与图形驱动状态**：
   - 显卡：`Red Hat VirtIO GPU 3D controller`（WHQL `100.6.101.58000`），静态 `1280×720 @ 120 Hz`（`DynamicResolution=False`、`FullscreenMode=2`）；
   - 宿主机渲染后端：`QEMURenderServer` 已实证加载 `dxmt-native.framework`（`QEMUDirectXDriver = 2`、`QEMURendererFPSLimit = 120`）；
   - 注册表基线：`MouseTrails = 0`（已验证设置 `MouseTrails = 2` 会导致鼠标一进入 UTM 窗口即完全隐藏，严禁开启）、默认 `MouseSpeed = 1, MouseThreshold1 = 6, MouseThreshold2 = 10`；
   - 交互桌面 `GetCursorInfo()` 实测：`cursor_info_ok = true`、`cursor_flags = 1 (CURSOR_SHOWING)`、`cursor_handle = 0x10003`、`cursor_pos = (640, 360)`（正好处于 `1280×720` 画面中心）。

### 1.2 三项有序光标试验结果
| 试验编号 | 合规操作内容 | 实时生效状态 | 游戏内光标可见性结果 |
| --- | --- | --- | --- |
| **基线** | `usb-tablet + usb-mouse`、`MouseTrails = 0`、无 `spice-vdagent` | 已运行 `VALORANT-Win64-Shipping`（`dxmt-native` 零冻结） | 游戏成功运行，但**游戏画面内光标不可见** |
| **试验 1** | 在 Guest 设备管理器精准禁用 `QEMU USB Tablet`（`Problem = 22`），仅留纯相对 `QEMU USB Mouse`（`Status = OK`）+ UTM `Capture Mouse` | 已实时生效 | 仅靠 Guest 侧禁用 `usb-tablet` 仍未恢复游戏内光标显示 |
| **试验 2** | 关闭 Windows 指针阴影（`SPI_SETCURSORSHADOW = 0`）与指针加速（`MouseSpeed = 0, MouseThreshold1/2 = 0`），严格保持 `MouseTrails = 0`；核查无 `spice-vdagent` | 已实时生效 | 未恢复游戏内光标显示 |
| **试验 3** | 合法辅助通过创角进入大厅与靶场 | 本轮暂停 | 用户决策优先基于已取得的大量实测数据先完善虚拟机（光标合成 + 声音 + 中文环境 + 持久化免重装），本轮未强行盲操进大厅/靶场 |

### 1.3 根因定位结论（供窗口 10B 定制 UTM / `CocoaSpice` 根治）
结合 Phase 9A 与 Phase 10A 实证，游戏内光标不可见不是 `MouseTrails` 或 Windows 指针加速设置问题，也无法仅靠在 Guest 内禁用 `usb-tablet` 绕过，**核心瓶颈位于宿主机 UTM / `CocoaSpice` / `virtio-ramfb-gl` 光标合成链路**：
1. **QEMU 层仍挂载了 `usb-tablet`**：UTM 5.0.9 未暴露真正移除 `-device usb-tablet` 的 `config.plist` 开关，即使在 Guest 中禁用 HID 实例，QEMU / SPICE 主机端仍认为存在绝对指针设备，影响 SPICE 在 `SPICE_MOUSE_MODE_CLIENT` 与 `SPICE_MOUSE_MODE_SERVER` 之间的切换与光标隐藏策略；
2. **`viogpu3d` WDDM2 硬件光标面 → `virtio-ramfb-gl` `CURSORQ` → SPICE `CursorChannel` → `CocoaSpice` / `CSMetalRenderer` 合成断层**：
   - 当 UE4/无畏契约在 DX11 窗口内设置自定义光标位图（或切换相对输入捕获）时，Guest 侧 `GetCursorInfo()` 报告 `CURSOR_SHOWING (1)` 且坐标位于窗口中心 `(640, 360)`；
   - 但在 macOS 宿主机端，`CocoaSpice` 在 `Capture Mouse` / 无 `vdagent` 状态下隐藏了 macOS 系统 `NSCursor`，同时 `CSMetalRenderer` 未将 Guest `virtio-gpu` `CURSORQ`（或 SPICE `cursor_set` ARGB 位图）作为 Metal Overlay 合成到帧缓冲上，导致“宿主机光标已隐藏 + Guest 硬件光标面未渲染 = 画面中完全无光标”。

---

## 2. 给窗口 10B 与下一阶段“完善虚拟机”的 5 项高优先级工程需求

| 优先级 | 问题现象（10A 实测实锤） | 根因证据 | 建议修复方案（供 10B / 定制 UTM / 优化器 v3） |
| --- | --- | --- | --- |
| **P0** | 游戏内光标不可见（阻塞创角、UI 点击与 FPS 瞄准闭环） | 宿主机同时挂载 `usb-tablet + usb-mouse`；无 `spice-vdagent`；试验 1 & 2 均未恢复 | 1. 定制 UTM 增加真正的纯相对鼠标开关（QEMU 启动参数不注入 `usb-tablet`）；<br>2. 在 `CocoaSpice` / `CSMetalRenderer` 中确保 `SPICE CursorChannel` / `virtio-gpu CURSORQ` 的 ARGB 光标在 `Capture Mouse` 模式下通过 Metal Overlay 渲染到输出帧（或仅在确认 Guest 光标显式隐藏时才隐藏覆盖层）；<br>3. 评估在 Guest 中预装签名版 ARM64 `spice-vdagent` 的合规性与效果 |
| **P0** | 游戏全程**没有声音** | `ephemeral-p10a-valorant.utm/config.plist` 中 `Sound: []` 为空，由 `--trim-hardware` 默认清空声卡所致 | 将 `--trim-hardware` 拆分为「安全裁剪（保留标准 `intel-hda` / `hda-duplex` 声卡，仅裁剪摄像头/共享目录/剪贴板/串口等）」与可选 `--no-sound`；游戏默认配置必须保留声卡 |
| **P1** | 系统界面为英文、默认无中文输入法（影响国服取名与聊天） | `dism /online /get-intl` 实证母盘已预装 `zh-CN` 语言包与 `Language.Basic~~~zh-CN`，但默认配置为 `en-US` | 在黄金母盘 v2 或会话初始化脚本中预置 `zh-Hans-CN`（微软拼音）优先 + `en-US`、`Set-WinUILanguageOverride zh-CN`、`Set-WinSystemLocale zh-CN` |
| **P1** | 每次打开瞬时克隆都要重新运行安装器、体验繁琐 | 虽然 `33+ GiB` 游戏本体在 `F:\VALORANT_CN`（APFS CoW 秒挂），但 `C:` 盘注册表与启动器状态每次随瞬时克隆归零 | 区分「零漂移洁净实验模式（瞬时克隆）」与「日常游玩模式（持久化工作 VM / 含官方启动器状态的工作快照）」，面向日常使用默认复用持久化 VM，避免重复走安装器 |
| **P1** | 运行期弹出虚拟内存不足且后台 Windows Update 抢占资源 | `monitor-live-dxmt-trimmed.json` 捕获 `System Event 26 (Virtual Memory Minimum Too Low)` 及 `WindowsUpdateClient` 在游戏期下载安装 `KB5036908` + 语言包（`TrustedInstaller` 活跃） | 1. 在优化器中增加游戏会话期暂停 `wuauserv` / `UsoSvc` 后台更新策略；<br>2. 适当提高 VM RAM 配额并预分配固定最小页面文件（如 `8192–12288 MiB`），杜绝游戏运行期内存抖动 |

---

## 3. 10B 验证建议（回归验收口径）
1. 在定制 UTM 中修复 `CSMetalRenderer` / `CocoaSpice` 光标覆盖与声卡保留后，先用轻量窗口化 DX11 自定义光标测试程序（如 `SetCursor` + `ClipCursor` + `WM_INPUT` 相对移动）验证光标在「非捕获」和「`Capture Mouse` 捕获」双模式下均 100% 可见且不抖动；
2. 再在持久化中文工作 VM（保留声卡、禁用后台 Windows Update、加大页面文件）中回归实测 `target-cn` 创角 → 大厅 → 靶场 3–5 分钟，并补全 `ACE-GAME.sys (1275)` 在靶场与队列预检中的终局验证。
