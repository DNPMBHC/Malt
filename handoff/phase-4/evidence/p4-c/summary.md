# Phase 4 窗口 4C 交付汇总：反作弊专用极简 Guest 优化器（Phase 3-A）与 `x86_64` ACE 轴 2 预研

- **日期**：2026-11-23
- **负责方**：`@DNPMBHC`
- **主干净 `vm-a` 保护状态**：**全程未启动、未修改**（`stopped_clean`）；所有实测均在外接 APFS 卷 `/Volumes/<EXTERNAL_VOLUME>` 上的独立 Copy-on-Write 克隆快照完成，测试结束后已彻底卸载并删除临时克隆，内置系统盘 0 字节占用。

---

## 1. 五维诚实状态声明

| 维度 | 状态 | 说明与边界 |
| --- | --- | --- |
| **1. 代码实现** | `completed` | 交付 `Whisky/Modules/guest-optimizer/`（声明式 Profile、幂等优化与一键回滚脚本、独立克隆编排与离线单测）及 Swift 适配层（`WindowsGuestOptimizerModels.swift`、`WindowsGuestOptimizerService.swift`、`UTMWindowsGuestOptimizerTests.swift`），通过 `extension UTMWindowsGuestProvider: WindowsGuestOptimizing` 接入可审计接口。 |
| **2. 本机合成验证** | `passed` | 离线 Python 单测 `10/10` 全过；`WhiskyKit` SwiftPM 全量测试（含新增 6 项 `UTMWindowsGuestOptimizer*Tests`）0 失败；窗口 4C 全部新增 Swift 文件 Strict SwiftLint 0 违规；`format_check.py` 6/6 通过；`audit_anticheat_hardening.py --self-test` 通过。 |
| **3. 真实 Guest 独立克隆验证** | `passed` | 在外接 APFS 卷独立克隆（Windows 11 Enterprise Evaluation 24H2 ARM64 `Build 26100.1`）完成**干净基线 → 幂等优化 → 一键回滚**三态配对量化实测；三态下 Secure Boot、TPM 2.0、BCD 安全开关、ARM64 Prism/WOW64 核心 4 个 DLL 官方签名与 `SFC /verifyonly`（退出码 `0`）全部保持完好，一键回滚 `mismatch_count = 0`（100% 一致）。 |
| **4. 厂商支持** | `unknown` | 极简 Guest 优化器仅移除消费级冗余组件与后台开销，不代表商业反作弊厂商已支持 ARM64 虚拟化环境；`target-cn`（`2.17.4.510`）轴 1 仍为 `observed_amd64_only_in_sample`，轴 2 保持 `unknown`。 |
| **5. 真实游戏验证** | `not_verified` | 本次实测聚焦 Guest 系统底座资源削减、安全完整性与一键回滚一致性，不宣称任何商业受保护游戏兼容或帧率提升。 |

---

## 2. 三态量化配对对比（独立 APFS 克隆快照）

完整原始脱敏数据见 `handoff/phase-4/evidence/p4-c/optimizer-benchmark.json`（采样口径：每次重启均经 Guest 内 `shutdown.exe /s /t 0` 优雅关机刷新卷与注册表；进入交互式桌面静置 `15 s` 后，以 `2 s` 间隔连续采样 5 次宿主机 `UTM` + `QEMU` 真实 RSS 与 CPU 均值，并执行 `sfc /verifyonly` 与完整安全链核验）。

| 量化指标 | 干净基线 (`clean_baseline`) | 优化后 (`optimized`) | 优化相对基线变化 | 一键回滚后 (`rolled_back`) |
| --- | ---: | ---: | ---: | ---: |
| **宿主机总空载 RSS（UTM + QEMU）** | `4077.99 MiB` | **`3927.27 MiB`** | **`-150.72 MiB`** | `3979.19 MiB` |
| **宿主机 QEMU 空载 RSS** | `3958.19 MiB` | **`3818.32 MiB`** | **`-139.87 MiB`** | `3872.01 MiB` |
| **宿主机 QEMU 空载 CPU** | `8.56%` | **`3.46%`** | **`-5.10 pp`（`-59.6%`）** | `3.46%` |
| **冷启动至 QGA 就绪** | `14.485 s` | **`13.565 s`** | **`-0.920 s`** | `13.598 s` |
| **冷启动至桌面就绪** | `21.952 s` | **`20.054 s`** | **`-1.898 s`** | `21.168 s` |
| **热启动至 QGA 就绪** | `30.706 s` | **`13.404 s`** | **`-17.302 s`** | `13.672 s` |
| **热启动至桌面就绪** | `68.457 s` | **`20.923 s`** | **`-47.534 s`** | `22.205 s` |
| **Guest 后台进程数** | `123` | **`102`** | **`-21`（`-17.1%`）** | `112` |
| **Guest 运行中服务数** | `89` | **`75`** | **`-14`（`-15.7%`）** | `79` |
| **Guest 系统盘已用容量** | `31.200 GiB` | `31.231 GiB` | `+0.031 GiB`（保留离线回滚包本体与快照） | `31.234 GiB` |
| **VM 虚拟盘包体大小（外接 APFS）** | `26.228 GiB` | `26.439 GiB` | `+0.211 GiB`（qcow2 写时增量） | `26.446 GiB` |
| **`SFC /verifyonly` 退出码** | `0` | **`0`** | **无损通过** | **`0`** |
| **Secure Boot / TPM 2.0 / BCD 安全** | `true / true / true` | **`true / true / true`** | **100% 保持** | **`true / true / true`** |
| **ARM64 Prism 4 核心 DLL 签名有效** | `true`（4/4 `Valid`） | **`true`（4/4 `Valid`）** | **100% 保持** | **`true`（4/4 `Valid`）** |

> **说明**：
> 1. 干净基线热启耗时（`30.706 s` / `68.457 s`）受 Windows 后台搜索索引（`WSearch`）、`SysMain` 及遥测计划任务在首次干净重启后的密集磁盘活动拉高；关闭上述非必要后台服务后，热启收敛至稳定 **`13.404 s`**（QGA）/ **`20.923 s`**（桌面）。
> 2. 为了确保 **100% 离线精确一键回滚且零破签**，消费级 UWP 移除仅解除当前用户注册而不破坏系统预置源目录（`WindowsApps`），因此 `System Drive` 空间保留原始包体以便离线 `Add-AppxPackage -Register` 恢复，换取绝对可逆性与 `SFC /verifyonly == 0`。

---

## 3. 幂等性、硬白名单保护与一键回滚验收

1. **三层硬白名单保护**：Profile JSON、`apply-optimizer.ps1`（内嵌 `$HardProtectedServices`）、Python 校验器与 Swift `WindowsGuestOptimizerProfileValidator` 三层同步拦截：任何试图将核心系统/安全服务（`CryptSvc`、`TBS`、`EventLog`、`Winmgmt`、`QEMU-GA`、`VirtioFsSvc`、主流反作弊服务）、受保护 UWP 运行时（`VCLibs`/`DirectX`/`SecHealthUI`）、安全计划任务或非 `HKCU:\` 注册表路径加入裁剪清单的配置都会在宿主机与 Guest 双侧 fail-closed 拒绝。
2. **真机校准的 ARM64 Prism 保护清单**：真机实测确认 Windows 11 24H2 ARM64 原生不存在 x64 专属的 `System32\wow64cpu.dll`，实际核心 Prism + WOW64 文件为 `System32\xtajit.dll`、`System32\xtajit64.dll`、`System32\wow64.dll`、`System32\wow64win.dll`，三态下均保持 `exists = true` 且 Authenticode `signature_status = Valid`。
3. **幂等与一键回滚 100% 一致**：
   - 连续两次执行 `apply-optimizer.ps1`，第二次准确复用初始干净快照（`snapshot_reused = true`），不覆盖基线状态；
   - 执行 `rollback-optimizer.ps1` 后，`14/14` 被停用服务恢复原始启动类型、`6/6` 计划任务恢复原状、`5/5` `HKCU:\` 视觉与搜索注册表项恢复原状、`1/1` 已移除消费级 UWP（`Microsoft.OutlookForWindows`）离线重新注册成功（`status = reregistered`），**`mismatch_count = 0`、`rollback_consistent = true`**。

---

## 4. 任务 C2（`x86_64` ACE 轴 2 预研）结论摘要

完整评估报告见 `handoff/phase-4/evidence/p4-c/x86-ace-axis2-assessment.md`：
- **结论**：**`No-Go`**。基于窗口 B 已实锤的 `target-cn`（`2.17.4.510`）3 个 WHQL 驱动全为 `0x8664`（轴 1 确凿阻塞），在 Apple Silicon 上通过 QEMU `x86_64` TCG 纯软件 JIT 临时建机探测轴 2 需新增 `58–82 GiB` 外接卷开销、承受 `10×–30×` CPU 仿真减速与高假阳性计时/超时失真，且无论测得“允许”或“拒绝”均无法在轴 1 未解前提下转化为可玩产品路径。
- **推荐策略**：维持诚实口径（轴 1 阻塞、轴 2 `unknown`），等待 NVIDIA RTX Spark / Windows on Arm 生态推动厂商发布原生 `0xAA64` 驱动后，直接在现有原生 HVF ARM64 `vm-a` 上零额外成本一次复测双轴。

---

## 5. 不可变源码与证据 SHA-256 绑定

- `Whisky/Modules/guest-optimizer/profiles/anticheat-minimal-win11-arm64.json`: `906b01c178307f7cec917a90a1d96de62e123d69e41282f3b0276659ef77f76a`
- `Whisky/Modules/guest-optimizer/scripts/apply-optimizer.ps1`: `84c0b2fbac89240c25176b09bd7c108b6b8318265cd7ae3c9f5a5bdffa8a4a11`
- `Whisky/Modules/guest-optimizer/scripts/rollback-optimizer.ps1`: `d71161af5673d1ae205230377ae7e256f32091e98f6a3ab8e046a227739ab768`
- `Whisky/Modules/guest-optimizer/scripts/benchmark-optimizer-clone.py`: `f5e94153a77d001dc44f871b9a1b447b966c98108746e59e336745fc4c51ddb6`
