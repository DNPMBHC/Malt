# 窗口 10B 任务书：开源 UTM 最小化定制架构与「纯净原生全屏游戏壳」补丁集（🟡 中等难度 · 推荐 `Hydrogen Medium`）

署名：`@DNPMBHC`  
难度与模型建议：**🟡 中等难度 — 推荐 `Hydrogen Medium`**（开源工程源码审计、最小补丁设计与自动化脚本，无需高阶额度）  
启动前提：**全程宿主机进行，不占用 VM，可立即启动**  
请先阅读：`handoff/phase-10/README.md`、`handoff/phase-9/evidence/p9-a/utm-native-capabilities.md`、`handoff/phase-9/evidence/p9-b/report.md`

---

## 1. 独占可写路径（严格互斥）

- `Whisky/Modules/utm-custom/`（新建）
- `graphics-lab/utm_custom_*`（新建）
- `graphics-lab/test_utm_custom_*`（新建）
- `handoff/phase-10/evidence/p10-b/`（新建）

严禁修改 `Whisky/Whisky/`、`Whisky/WhiskyKit/`、`Whisky/.swiftlint.yml`、`handoff/task-07/`、窗口 10A 独占路径及任何 VM。
> **红线提醒**：外部拉取的 `utmapp/UTM` 源码与编译产物**必须放在仓库外临时目录或 `<EXTERNAL_VOLUME>`**，绝不允许进入本仓库；本仓库 `Whisky/Modules/utm-custom/` 仅存放轻量补丁（`patches/*.patch`）、构建脚本与架构说明（所有新增 `.swift` 如有则必过 Strict SwiftLint 0 违规）。

---

## 2. 核心任务拆解

既然用户已授权合法魔改开源 UTM 以完美适配我们的游戏场景，窗口 10B 负责基于本机验证过的 **UTM 5.0.9** 开源上游基线，设计与落地一套**最小侵入、易跟进上游更新、零破坏安全合规红线**的定制 UTM 方案：

### 任务 10B-1（P0）：UTM 5.0.9 / `CocoaSpice` 源码精准定位与架构设计
1. 在仓库外临时目录浅克隆 `utmapp/UTM`（锁定 v5.0.9 tag）与 `CocoaSpice` 对应版本，只读精准定位 3 处关键源码位置并写入 `Whisky/Modules/utm-custom/ARCHITECTURE.md`：
   - **位置 1（默认图形后端与渲染调优）**：`QEMUDirectXDriver`（默认强制或按 CLI 参数锁定 `2 = dxmt-native.framework`）、`QEMURendererFPSLimit` 与 `DXMT_SHADER_CACHE` 持久化传递；
   - **位置 2（游戏内光标可见性与 FPS 相对鼠标）**：`CocoaSpice` 的 `CSMetalRenderer` / `_cursorSource` 光标合成逻辑与 `captureMouseButtonPressed:` 逻辑——查明为何 Guest 游戏接管焦点后光标不可见，并设计最小修复补丁（同时预留吸纳窗口 10A 的 `cursor-diagnosis-for-10b.md` 实测反馈）；
   - **位置 3（无桌面「纯净原生全屏游戏壳模式」）**：如何通过新增轻量启动参数（如 `--game-shell-vm <UUID>`）在启动指定 VM 时**隐藏 UTM 管理主窗口与工具栏、直接弹出无边框原生全屏 `CSMetalRenderer` 游戏窗口、绑定 `Cmd+Option+G` 安全释放光标、VM 关机自动退出**——直接复用 UTM 合法的 Metal 呈现与 SPICE HID，零重复造轮子！

### 任务 10B-2（P0）：交付最小化补丁集（`patches/`）、补丁应用校验脚本与单元测试
1. 在 `Whisky/Modules/utm-custom/patches/` 产出清晰、独立、可 `git apply --check` 的最小化 `.patch` 文件：
   - `01-default-dxmt-backend.patch`（支持参数/配置一键启用 `dxmt-native`）；
   - `02-cursor-and-fps-capture.patch`（修复/增强 `CocoaSpice` / UTM 游戏内光标可见性与相对鼠标安全释放）；
   - `03-clean-fullscreen-game-shell.patch`（纯净无工具栏原生全屏游戏窗口启动模式）；
2. 在 `Whisky/Modules/utm-custom/scripts/build_custom_utm.sh` 与 `graphics-lab/utm_custom_patch_verify.py` 中实现：
   - 自动核验补丁零越权（断言补丁**严禁触碰** QEMU CPUID/SMBIOS/ACPI/TPM/Hypervisor 伪装代码、严禁触碰任何 Windows 驱动或反作弊相关逻辑）；
   - 自动验证补丁在目标 `utmapp/UTM` commit 上 `git apply --check` 100% 通过，并在本机尝试最小化构建验证（诚实记录 Xcode/依赖前置与构建状态，不掩盖任何依赖缺口）。
3. 编写 `graphics-lab/test_utm_custom_patch_verify.py` 单元测试，确保 `(cd graphics-lab && python3 -B -m unittest discover -v)` 全绿。

---

## 3. 验收标准与交付物

1. `Whisky/Modules/utm-custom/ARCHITECTURE.md`、`patches/*.patch` 与 `scripts/build_custom_utm.sh` 全部落盘且零越权（通过合规边界自检 + `audit_anticheat_hardening.py --self-test`）；
2. `graphics-lab/test_utm_custom_*.py` 与全量 `graphics-lab` unittest 通过，Strict SwiftLint **0 违规**；
3. `handoff/phase-10/evidence/p10-b/report.md` 与 `patch-audit.json` 落盘，零隐私泄露且仓库内零 `>5 MiB` 构建/源码残留。
