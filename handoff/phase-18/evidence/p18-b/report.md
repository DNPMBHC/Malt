# Phase 18 窗口 18B 交付报告：自动部署精简后端、Launcher 派生子进程树全屏联动、零特权代理随包托管与新包端到端复验

- **署名**：`@DNPMBHC`
- **生成时间（UTC）**：`2026-11-26T10:41:25.001242+00:00`

## 1. 新版全合体 `Malt.dmg` 搬迁与隔离启动验收
- DMG 体积：`360.846 MiB`，SHA-256：`a74276d902c7193e5a42a2e2e369e05027d269e70dbc559adf0258180a0d5686`
- 搬迁后 `codesign --verify --deep --strict`：`True`
- `runtime_payload.py verify`：`True`（清点文件数 `1483`，外部绝对动态库 `0`）
- 内嵌 Helper：`LSUIElement = True`，`UTMRuntimeSettingsContractVersion = 1`
- 内嵌零特权 TCP+UDP+ICMP 高 QoS 代理 `malt-net-proxy`：`passed = True`，`qosUserInteractive = True`
- 隔离用户数据启动冒烟（4s 存活）：`True`

## 2. 派生受管游玩副本真机端到端复验
- 临时受管副本清理状态：`ephemeral_cleaned_up = True`
- 零特权代理启停与清理：`started = True`，`socket_cleaned = True`
- 4 步部署精简优化 + 回滚：`apply_exit_code = 0`，`rollback_consistent = True`
- 图形与托管网络连通：`viogpu3dPresent = True`，`shader_cache_writable = True`，`guestProxyIP = 10.12.0.15`，`icmpGatewayOk = True`，`tcpProxyRoundtripOk = True`，`udpProxyRoundtripOk = True`，`udpDnsOk = False`
- 安装入口只读扫描：`shortcut_count = 41`，`valorant_present = False`
- Launcher 派生子进程树全屏联动：`verified = True`，`lineage_depth = 2`，`is_fullscreen = True`，`host_bridge_roundtrip_ok = True`

## 3. 全盘零漂移与合规铁证
- 只读母盘 `golden-win11-arm64-v1.utm`：`golden_readonly = True`，`golden_zero_drift = True`
- 冷备 `vm-a`：`primary_zero_drift = True`
- `/Applications/UTM.app` 原件签名：`original_utm_codesign_ok = True`
- 残留 QEMU 进程：`[]`，`zero_drift = True`

## 4. 验收门禁与诚实边界

- `swift test --package-path Whisky/WhiskyKit`：**431 项全绿**（10 项硬件/实机显式跳过，0 失败）
- `(cd Whisky && ../handoff/task-07/.tools/swiftlint lint --strict --quiet)`：**0 violations**
- `python3 handoff/task-07/format_check.py`：**通过**（6 项声明文件 0 诊断）
- `(cd Whisky/scripts && python3 -B -m unittest discover -v)`：**92 项全绿**
- `(cd Whisky/Modules/guest-optimizer && python3 -B -m unittest discover -s tests -v)`：**13 项全绿**
- `(cd graphics-lab && python3 -B -m unittest test_p18_malt_app_e2e -v)`：**5 项全绿**（全量 `graphics-lab` 351 项中 349 项通过，其余 2 项为既有 `test_utm_custom_patch_verify.py` 对 Phase 16 补丁 08 `UTMScriptingVirtualMachineImpl.swift` 白名单未同步的历史漂移，超出 18B 写入边界未越界修改）
- `python3 handoff/phase-3/evidence/p3-b/audit_anticheat_hardening.py --self-test`：**通过**（163 个生产源文件 + 6 项负向自检全绿）
- 合规与仓库纯净：零 `> 5 MiB` 新增跟踪文件、零隐私路径泄漏、零 `git commit/push/reset`、未触碰 18A 独占路径或任何母盘/冷备原件。
- 实机范围说明：只读母盘未预装《无畏契约》客户端（`valorant_present = False`），本轮以真实 Windows 11 ARM64 派生副本上的父启动器派生全屏子进程实证 `Win32_Process.ParentProcessId` + `CreationDate` + `IsWindowFullscreen` 血缘链与宿主机 `AppShellSessionBridge` 全屏往返；待用户在已安装《无畏契约》的受管游玩容器内手动登录后即可直接一键复用该全屏联动路径（`--interactive-valorant`）。

