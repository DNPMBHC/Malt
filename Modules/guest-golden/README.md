# Golden Guest v1 (`golden-win11-arm64-v1`)

署名：`@DNPMBHC`

## 1. 设计目标

解决此前每次测试重复安装驱动、运行优化脚本导致版本与性能漂移的问题。本模块定义并维护一份**不可变、版本锁死、开箱即用**的 Windows 11 24H2 ARM64 黄金母盘（`golden-win11-arm64-v1`，存放在 `<EXTERNAL_VOLUME>`），并配合宿主机工具 `graphics-lab/golden_guest_manager.py` 实现：

- **冷备永不动**：严格保护原始裸 `vm-a`，任何构建或测试均不原地修改 `vm-a`；
- **母盘只读封存**：`golden-win11-arm64-v1` 封存后锁定为只读，所有测试只能基于其 APFS Copy-on-Write (`cp -c`) 瞬时克隆执行；
- **1–2 秒瞬时派生与销毁**：`spawn-ephemeral` 生成独立 UUID/MAC 的一次性克隆（关闭共享目录与剪贴板共享），`destroy-ephemeral` 测试后一键停机销毁并复核母盘与 `vm-a` 零漂移。

## 2. 黄金母盘锁定基线

详细规格见 [golden-win11-arm64-v1.json](profiles/golden-win11-arm64-v1.json)：

- **QEMU/UTM 参数**：`virtio-ramfb-gl`（UTM 5.0.9 自动启用 `hostmem=8G,blob=true,venus=true,neptune=true,refresh_rate=120000`）、6 vCPU、6 GiB RAM、UEFI Secure Boot、swtpm TPM 2.0、共享目录 `None`；
- **WHQL 3D 驱动栈**：UTM 5.0.9 官方 WHQL 签名 `viogpu3d.sys`（`v100.6.101.58000`）+ `neptune_umd_arm64.dll` + `neptune_umd_ec.dll` + `vulkan_virtio_arm64.dll`；
- **4C 极简 Guest 优化器**：预运行 `Whisky/Modules/guest-optimizer/scripts/apply-optimizer.ps1`（保留一键回滚快照与全部 Prism / 安全链 / ACE 白名单）；
- **卫生与安全不变量**：`Secure Boot = Enabled`、`Test Signing = Disabled`、Windows Update 下载缓存已清理、零商业游戏/反作弊残留。

## 3. CLI 用法（`graphics-lab/golden_guest_manager.py`）

```bash
# 检查 VM 租约与运行中 QEMU 进程
python3 graphics-lab/golden_guest_manager.py check-lease

# 校验黄金母盘并生成 golden-guest-manifest.json
python3 graphics-lab/golden_guest_manager.py verify-golden \
  --golden /Volumes/<EXTERNAL_VOLUME>/.../golden-win11-arm64-v1.utm \
  --primary /Volumes/<EXTERNAL_VOLUME>/.../Windows11-ARM64.utm \
  --output handoff/phase-6/evidence/p6-a/golden-guest-manifest.json

# 1–2 秒 APFS CoW 派生一次性测试克隆
python3 graphics-lab/golden_guest_manager.py spawn-ephemeral \
  --golden /Volumes/<EXTERNAL_VOLUME>/.../golden-win11-arm64-v1.utm \
  --primary /Volumes/<EXTERNAL_VOLUME>/.../Windows11-ARM64.utm \
  --name ephemeral-test-01

# 停机、注销、销毁一次性克隆并复核母盘与 vm-a 零漂移
python3 graphics-lab/golden_guest_manager.py destroy-ephemeral \
  --ephemeral /Volumes/<EXTERNAL_VOLUME>/.../ephemeral-test-01.utm \
  --golden /Volumes/<EXTERNAL_VOLUME>/.../golden-win11-arm64-v1.utm \
  --primary /Volumes/<EXTERNAL_VOLUME>/.../Windows11-ARM64.utm
```

## 4. `golden-guest-manifest.json` 契约（供窗口 6B 集成读取）

- `schema_version`: `1`
- `golden_id`: `"golden-win11-arm64-v1"`
- `status`: `"sealed_readonly"`
- `qemu_profile`: 显示设备、vCPU、内存、TPM/UEFI、共享目录锁定状态
- `graphics_driver`: WHQL `viogpu3d` 版本、`FL 11_1` 与 `0 LSB` 校验摘要
- `security_invariants`: `secure_boot_enabled`、`test_signing_disabled`、`tpm_enabled`、`prism_signatures_valid`、`qga_service_running`
- `optimizer`: `profile_id`、`profile_sha256`、`rollback_snapshot_present`
- `fingerprints`: `golden_bundle_sha256`、`golden_config_sha256`、`primary_vm_a_config_sha256`、`sealed_readonly`
- `smoke_metrics`: `cold_boot_qga_seconds`、`idle_host_rss_mib`、`d3d11_probe_fps`、`max_channel_error_lsb`
