# 窗口 6A 验收报告：不可变「Golden Guest v1」黄金镜像与一键克隆核验工具

日期：2026-11-24  
署名：`@DNPMBHC`  
范围：`Whisky/Modules/guest-golden/`、`graphics-lab/golden_guest_*`、`graphics-lab/test_golden_guest_*`、`handoff/phase-6/evidence/p6-a/`  
隔离声明：**原始冷备 `vm-a` 全程未做任何原地修改，保持 `stopped` 状态；`golden-win11-arm64-v1` 在 `<EXTERNAL_VOLUME>` 上基于 `vm-a` APFS CoW 克隆构建、封存只读并注销 UTM 注册，所有闭环冒烟均在一次性瞬时克隆上执行并在结束后彻底销毁。**

---

## 1. 五维诚实状态声明

| 维度 | 状态 | 说明 |
| --- | --- | --- |
| **1. 代码与工具交付** | `completed` | 交付 `Whisky/Modules/guest-golden/` 规格与封存脚本、`graphics-lab/golden_guest_manager.py`、`golden_guest_build_and_smoke.py` 及单元测试 `test_golden_guest_manager.py`。 |
| **2. 本机合成与单测** | `passed` | `graphics-lab` 全部 `unittest`（含新增 6 项 `test_golden_guest_manager.py`）全部通过，Strict SwiftLint 与静态安全门禁均通过。 |
| **3. 真实黄金母盘构建封存** | **`passed`** | `golden-win11-arm64-v1` 已在 `<EXTERNAL_VOLUME>` 构建完毕并锁定只读（`sealed_readonly: true`），`golden-guest-manifest.json` 完整落盘。 |
| **4. 闭环克隆与冒烟验证** | **`passed`** | `spawn-ephemeral`（`0.0074 s`）→ 冷启（QGA 就绪 `27.898 s`）→ 空载 RSS `2289.62 MiB` → WHQL `viogpu3d` (`123.609 FPS`, `0 LSB` 逐字节一致) → `destroy-ephemeral`（母盘与 `vm-a` 零漂移）。 |
| **5. 商业游戏实测** | `not_tested` | 按 Phase 6 总控协议，本阶段不运行商业游戏点亮实测，留待 Phase 7 基于本黄金母盘开展。 |

---

## 2. 黄金母盘锁定基线（`golden-win11-arm64-v1`）

| 类别 | 锁定配置 / 实测结果 | 校验状态 |
| --- | --- | --- |
| **Guest OS** | Windows 11 Enterprise Evaluation 24H2 ARM64（Build `26100`、`aarch64`） | 已锁定 |
| **QEMU / UTM 显示与硬件** | `virtio-ramfb-gl`（UTM 5.0.9 自动启用 `hostmem=8G,blob=true,venus=true,neptune=true,refresh_rate=120000`）、6 vCPU、6144 MiB RAM、UEFI Boot、swtpm TPM 2.0、关闭共享目录与剪贴板/USB 共享 | 12/12 项校验通过 |
| **WHQL 3D 驱动栈** | `viogpu3d.sys`（`100.6.101.58000`，`Microsoft Windows Hardware Compatibility Publisher` 正式签名）+ `neptune_umd_arm64.dll` + `neptune_umd_ec.dll` + `vulkan_virtio_arm64.dll` | `whql_ready: true`、`Status=OK`、`ErrorCode=0` |
| **4C 极简优化器** | 已应用 `anticheat-minimal-win11-arm64`，保留一键回滚快照 `C:\graphics-lab\guest-optimizer\snapshot-initial.json` 与全部 Prism / 安全链 / ACE 白名单 | `rollback_snapshot_present: true` |
| **安全与卫生不变量** | `Secure Boot = Enabled`、`Test Signing = Disabled`、`nointegritychecks = Disabled`、TPM 2.0 Ready、Prism 4 文件签名 `Valid`、QGA `Running`；清理 Windows Update 下载缓存释放 `3,469,998,434 bytes`（系统盘可用 `8.46 GB`）；零商业游戏/反作弊残留 | 全部通过 |

---

## 3. 完整闭环取证结果（`spawn-ephemeral → 冒烟 → destroy-ephemeral`）

1. **APFS Copy-on-Write 瞬时派生**：`spawn-ephemeral` 从只读母盘 `golden-win11-arm64-v1` 派生 `ephemeral-p6a-smoke` 仅耗时 **`0.0074 s`**，自动生成独立 UUID 与单播 MAC 地址并保持母盘只读；
2. **冷启与资源开销**：
   - VM 进程拉起：`2.825 s`
   - QGA 串口就绪：**`27.898 s`**
   - 宿主机空载总 RSS（`qemu-system-aarch64` + `QEMURenderServer` + `swtpm.0`）：**`2289.62 MiB`**
3. **3D 硬件枚举与像素/帧率冒烟（未修改 `d3d11_probe.exe`，1280×720 16-Draw `gpu-complete`）**：
   - 适配器：`Red Hat VirtIO GPU 3D controller`（`vendor_id: 6900 / 0x1AF4`，`device_id: 4176 / 0x1050`，`adapter_is_software: false`，Feature Level `11_1`）
   - 帧率（60 预热 + 300 测量帧）：**`123.609 FPS`**（平均帧间隔 `8.09 ms`，P95 `11.71 ms`）
   - 逐像素校验（vs WARP 参考帧 `validate-legacy-0-reference.rgba`）：**`max_channel_error_lsb = 0`**、`over_threshold_pixels = 0`、`byte_exact_match = true`
4. **一键销毁与零漂移复核**：
   - `destroy-ephemeral` 干净停机、注销并删除 `ephemeral-p6a-smoke`（`ephemeral_deleted: true`）；
   - 复核只读黄金母盘与原始冷备 `vm-a` 均保持 **`golden_zero_drift: true`**、**`primary_zero_drift: true`**。

---

## 4. 指纹锁定与交付物清单

- **黄金母盘指纹**（`golden-win11-arm64-v1.utm`，`sealed_readonly: true`，8 个文件，总计 `29,547,908,107 bytes`）：
  - `golden_config_sha256`: `5e3b775ca4fd05a81ae9e1f2c5d61abe576334340bd51b851b6d65ab89cff390`
  - `golden_bundle_sha256`: `784ba01e8c45bc0e32fb81849a359b909a3d87b15cb8486db49df6467bcf4947`
- **原始冷备 `vm-a` 指纹**（`stopped`，全程未修改，总计 `29,391,222,047 bytes`）：
  - `primary_vm_a_config_sha256`: `10793d07678f8621e1d75ada73443b3f14e272036dde4f90b277267c2e1033b7`
  - `primary_vm_a_bundle_sha256`: `ccd2d2de4981b8b0ca7705824ee6cc4166828651a03f198fd518ba81771caae5`
- **交付物**：
  - `Whisky/Modules/guest-golden/profiles/golden-win11-arm64-v1.json`
  - `Whisky/Modules/guest-golden/scripts/seal-golden-guest.ps1`
  - `Whisky/Modules/guest-golden/README.md`
  - `graphics-lab/golden_guest_manager.py`
  - `graphics-lab/golden_guest_build_and_smoke.py`
  - `graphics-lab/test_golden_guest_manager.py`
  - `handoff/phase-6/evidence/p6-a/golden-guest-manifest.json`
  - `handoff/phase-6/evidence/p6-a/golden-guest-seal-check.json`
  - `handoff/phase-6/evidence/p6-a/golden-smoke-metrics.json`
  - `handoff/phase-6/evidence/p6-a/golden-guest-report.md`
