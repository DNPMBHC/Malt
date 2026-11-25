# 窗口 6A 任务书：固化不可变「Golden Guest v1」黄金镜像与一键克隆核验工具（P0）

署名：`@DNPMBHC`  
启动前提：**脚本设计与单元测试可立即启动；构建真机黄金镜像前需确认窗口 5C 已释放 VM 租约且无运行中的测试克隆**  
请先阅读：`handoff/phase-6/README.md`、`handoff/phase-4/evidence/p4-b/m3-viogpu3d-report.md`、`handoff/phase-4/evidence/p4-c/optimizer-benchmark.json`、`handoff/module-f/valorant-real-runs/summary.md`

---

## 1. 独占可写路径（严格互斥）

- `Whisky/Modules/guest-golden/`（新建）
- `graphics-lab/golden_guest_*`（新建）
- `graphics-lab/test_golden_guest_*`（新建）
- `handoff/phase-6/evidence/p6-a/`（新建）

严禁修改 `Whisky/Whisky/`、`Whisky/WhiskyKit/`、`Whisky/.swiftlint.yml`、`handoff/task-07/` 及窗口 6B 独占路径；严禁修改原始冷备 `vm-a`。

---

## 2. 核心任务拆解

解决当前痛点（每次测试重复装驱动、跑优化导致版本与性能不统一），在 `<EXTERNAL_VOLUME>` 构建一份**统一、锁版、零污染、可 1 秒克隆复现**的黄金 Windows 11 24H2 ARM64 母盘：

### 任务 6A-1（P0）：构建并封存 `golden-win11-arm64-v1` 黄金母盘
1. **严格基于原始冷备 `vm-a` 克隆创建**（先校验 `vm-a` 保持停止且指纹未变，绝不原地修改 `vm-a`）；
2. **一次性集成并锁定全套已验证成果**：
   - **QEMU/UTM 显示与安全硬件配置锁定**：`virtio-ramfb-gl,hostmem=8G,blob=true,venus=true,neptune=true,refresh_rate=120000`、`swtpm` TPM 2.0、`Secure Boot = Enabled`、`Test Signing = Disabled`、6 vCPU / 6 GiB RAM（或按实测最优定档并写入清单）；
   - **WHQL 3D 图形驱动锁定**：安装 UTM 5.0.9 官方 WHQL 签名 `viogpu3d.sys`（`v100.6.101.58000`）+ `neptune_umd` + `vulkan_virtio`，实测验证设备管理器 `Status=OK`、`Red Hat VirtIO GPU 3D controller`（`FL 11_1`）与 `d3d11_probe.exe` 逐像素 `0 LSB` 一致；
   - **4C 极简 Guest 优化器预应用**：运行 `Whisky/Modules/guest-optimizer/scripts/apply-optimizer.ps1`（保留一键回滚快照与全部 Prism / 安全链 / ACE 白名单），清理 Windows Update 临时下载缓存，确保系统盘保持充裕可用空间；
   - **零商业残留校验**：确认母盘内无任何临时游戏安装包、无残留第三方服务、QGA 正常响应、所有安全不变量通过，然后干净关机封存为只读黄金母盘。

### 任务 6A-2（P0）：交付 `golden-guest-manifest.json` 与一键克隆/漂移校验/销毁工具
1. 在 `Whisky/Modules/guest-golden/` 与 `graphics-lab/golden_guest_manager.py` 交付轻量 CLI（含完整单元测试 `graphics-lab/test_golden_guest_manager.py`）：
   - `verify-golden`：校验黄金母盘配置、关键文件指纹、驱动版本与安全基线，输出 `golden-guest-manifest.json`（JSON Schema 清晰供窗口 6B 读取）；
   - `spawn-ephemeral`：通过 APFS Copy-on-Write（`cp -c`）在 1–2 秒内从 `golden-win11-arm64-v1` 派生一次性测试克隆（独立 UUID/MAC，自动防误操作主母盘与冷备 `vm-a`）；
   - `destroy-ephemeral`：测试结束后一键停机、彻底删除一次性克隆并复核黄金母盘与冷备 `vm-a` 零漂移。
2. 实跑一次完整的 **「黄金母盘封存 → `spawn-ephemeral` 瞬时克隆 → 冷启 + 3D 硬件枚举 + 空载 RSS/帧率冒烟 → `destroy-ephemeral` 销毁并复核零漂移」** 闭环取证。

---

## 3. 验收标准与交付物

1. `handoff/phase-6/evidence/p6-a/golden-guest-manifest.json` 与 `golden-guest-report.md`：记录统一驱动版本、QEMU 配置、安全不变量、冷启耗时、空载 RSS、标准 3D 冒烟 FPS 与只读母盘指纹；
2. `graphics-lab/test_golden_guest_*.py` 与 `(cd graphics-lab && python3 -B -m unittest discover -v)` 全部通过；
3. 严守脱敏与零大文件红线（绝不把 `.qcow2` 或 `>5 MiB` 二进制放入仓库），且主冷备 `vm-a` 与封存后的 `golden-win11-arm64-v1` 均处于干净停止态。
