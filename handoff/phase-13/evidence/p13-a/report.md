# Phase 13A 实验报告：突发大特效稳帧优化、热待机秒开与无桌面 Kiosk 会话

- 署名：`@DNPMBHC`
- 采样时间（UTC）：`2026-11-25T13:32:57.182438+00:00`
- 硬件配置：`8 vCPU / 10240 MiB RAM / VirtIO-Blk 多队列 (iothread + num-queues=4) / vmnet-shared 原生网络 / dxmt-native`

## 1. 突发大特效稳帧对比（平稳段 → 4× Draw-Call + 4 MiB/帧动态缓冲 + 4 线程计算爆发 → 恢复段）

| 指标 | Baseline 基线（突发段） | Optimized 突发优化态（突发段） | 变化幅度 |
| --- | ---: | ---: | ---: |
| Mean FPS | 46.812 | 49.027 | +4.73% |
| P50 FPS | 48.216 | 48.916 | +1.45% |
| **P1 Low FPS** | 27.457 | **42.362** | **+54.28%** |
| **P0.1 Low FPS** | 24.847 | **37.706** | **+51.75%** |
| P99 Frame Time (ms) | 36.42 | 23.606 | -35.18% |
| **Max Frame Time (ms)** | 40.672 | **26.845** | **-34.00%** |

- 平稳段对照：Baseline Mean `117.661 FPS` vs Optimized Mean `121.271 FPS`；优化态恢复段 Mean `121.551 FPS`（P1 Low `93.31 FPS`）。

## 2. 冷启动精简 vs 热待机秒开（`warm-standby` / `pause` / `resume-launch`）

| 模式 | 耗时 (s) | 关键指标 |
| --- | ---: | --- |
| 精简冷启动（Cold Boot → QGA 就绪） | 15.899 | 全量启动 Windows 11 ARM64 + VirtIO-GPU 3D |
| **热待机唤醒（Warm Resume → QGA 就绪）** | **0.347** | 节省 **15.552 s**（提速 **45.82×** / 缩短 **97.82%**） |

- 暂停驻留态（`utmctl suspend` / QMP `stop`）：QEMU CPU 占用 `0.1%`，macOS 内存压缩页 `4678.0 MiB`。
- 恢复后健康校验：`viogpu3d`（`Red Hat VirtIO GPU 3D controller 100.6.101.58000`）状态 `OK`，恢复后 44 帧 D3D11 硬件渲染实测 **`126.183 FPS`（P1 Low `76.034 FPS`）**（注：该次运行中 PowerShell 5.1 未预取 `$proc.Handle` 导致 `ExitCode` 为空使 `done_marker` 判为 `False`，代码已补齐 `$null = $proc.Handle`）；`Secure Boot = True`，`Prism = True`，`test_signing_disabled = True`，`nointegritychecks_disabled = True`，母盘保持 `zero_commercial_residue`（无异常 `ACE` 驱动/服务残留）。

## 3. 无桌面 Kiosk 会话脚本（`kiosk-app-shell.ps1`）真机校验

- 合规标记：`zero_dwm_hook = True`，`zero_process_injection = True`，`read_only_foreground_polling = True`
- 进入无桌面态：`taskbar_hidden = True`，`desktop_icons_hidden = True`，`background_solid_black = True`
- 退出还原：`restored = True`，`taskbar_visible = True`，`desktop_icons_visible = True`

## 4. 零漂移校验（`zero-drift-proof.json`）

- `golden_zero_drift`: `True`（`readonly = True`）
- `primary_zero_drift`: `True`
- `original_utm_app_present`: `True`
- `zero_drift`: **`True`**
