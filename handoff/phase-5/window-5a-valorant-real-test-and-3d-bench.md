# 窗口 5A 任务书：无畏契约双端真实运行实测、合法 ACE 机制取证与 3D 高压力裁判基线（P0）

署名：`@DNPMBHC`  
启动前提：**优先占用独立克隆 VM 租约（绝不触碰主干净 `vm-a`），可立即启动**  
请先阅读：`handoff/phase-5/README.md`、`handoff/module-f/guest-dynamic-observations.json`、`handoff/phase-4/evidence/p4-b/m3-viogpu3d-report.md`、`handoff/phase-4/evidence/p4-a/interface-proposal.md`

---

## 1. 独占可写路径（严格互斥）

- `graphics-lab/bench_real3d_*`（新建）
- `graphics-lab/test_real3d_*`（新建）
- `handoff/module-f/valorant-real-runs/`（新建）
- `handoff/phase-5/evidence/p5-a/`（新建）

严禁修改 `Whisky/` 下任何 Swift 源码、`Whisky.xcodeproj`、`handoff/task-07/` 及其他窗口独占路径。

---

## 2. 核心任务拆解

### 任务 A1（P0 · 绝对核心）：无畏契约（`target-cn`）双端最新真实运行实测
本项目最终目标是探索在 macOS 上合法运行 `target-cn` 真实对局的可行路径。尽管前期采样显示其内核驱动为 `0x8664`，本任务必须在新底座上完成**双端真实运行实测**，拿到完整一手观测数据：

1. **端 1 — Windows 11 24H2 ARM64 独立克隆 + WHQL `viogpu3d`（Secure Boot 开启 / TPM 2.0 激活 / Test Signing 关闭）**：
   - 在 `<EXTERNAL_VOLUME>` 创建 `vm-a` 的 APFS Copy-on-Write 独立克隆并安装 UTM 5.0.9 官方 WHQL `viogpu3d` 驱动（验证 `Red Hat VirtIO GPU 3D controller` 枚举成功，且 `Secure Boot = Enabled`、`Test Signing = Disabled`）；
   - 真实启动最新官方 `target-cn` 客户端（**若需账号登录、实名认证或人机验证码 CAPTCHA，必须立即暂停并请用户在可见界面亲自完成**，严禁自动化绕过任何认证或人机校验）；
   - 全程只读采集以下一手事实证据：
     - 启动器在 WHQL 3D 加速下的真实界面渲染、更新校验与登录状态；
     - 客户端及 ACE 目录下全部 `.sys` / 核心保护 `.dll` 的完整版本、文件大小、PE `Machine`（逐一核实是否仍全部为 `0x8664` 或已有 `0xaa64` 变体）、Authenticode 签名与 SHA-256；
     - 点击“开始游戏”后的完整系统级观测：Windows Event Log（System `7045` / `7000` / `7026`、Application、CodeIntegrity Operational）、SCM 服务注册与启停状态码、确切错误码（如 Win32 `1275` / `193` / `STATUS_INVALID_IMAGE_FORMAT` 或厂商自定义提示文案）、退出码以及是否触及 3D 渲染进程创建。
2. **端 2 — 宿主机 Wine 隔离测试 Bottle（补齐 Wine 路线实证空白）**：
   - 在 `<EXTERNAL_VOLUME>` 隔离临时 `WINEPREFIX` 下，使用宿主机 Wine（DXMT / D3DMetal）真实运行官方 `target-cn` 安装器与启动器；
   - 如实记录启动器界面表现、ACE 检测弹窗/错误码、进程退出日志与确切拦截阶段（严禁任何反作弊绕过或欺骗）。

### 任务 A2（P0）：合法 ACE 机制与“为何部分 Win VM / Intel PD 可运行”客观归因分析 + 30 秒巡检脚本
1. 基于任务 A1 抓到的一手运行日志与公开合规资料，撰写 `handoff/module-f/valorant-real-runs/ace-mechanism-analysis.md`：
   - **正交剥离三大因素**：① CPU/内核驱动架构（`x86_64` VM / Intel Mac PD vs Apple Silicon ARM64 VM）；② Windows 安全链前置（Secure Boot / TPM 2.0 / HVCI / VBS / WHQL）；③ 厂商虚拟化策略（轴 2 当前是否已触发或仍被轴 1 遮蔽）；
   - 给出清晰、诚实、零幻想的**合规可行路径清单**：明确哪些前提只能等待厂商下发原生 `0xaa64` 驱动，哪些底座条件（Secure Boot + TPM + WHQL 3D + 方案 B 高性能零拷贝）我们已经可以提前 100% 备齐。
2. 交付 30 秒可复用的轻量只读脚本 `graphics-lab/bench_real3d_ace_arch_watch.py`（含单测）：一键扫描最新客户端目录中的 `.sys` PE 头与签名，快速判断上游是否已开始下发 `0xaa64` 驱动。

### 任务 A3（P0）：为【方案 B】建立 2,000+ Draw Call 真实 3D 压力裁判基线
为窗口 5B 的方案 B 性能验收提供统一、严苛、告别 16-Draw 轻探针的真实 3D 标尺：
1. 构建/引入 **2,000+ Draw Call/帧、动态常量/顶点缓冲每帧更新、多 Pass 纹理采样、异步 SwapChain（取消每帧强制 `WaitForEventQuery`）** 的 D3D11 真实高压力基准（以及可选免费公开 3D 引擎 Benchmark，如 Unigine Heaven，大文件放 `<EXTERNAL_VOLUME>` 临时目录并在测完清理）；
2. 在同台宿主机跑出 **宿主机 Wine 四路（DXMT / D3DMetal / DXVK+KosmicKrisp / DXVK+MoltenVK）** vs **当前 UTM/QEMU WHQL `viogpu3d`（`neptune_umd`）** 的真实高压力 FPS、P50/P95/P99 帧时间与宿主 CPU 占比，把数据沉淀为方案 B 的官方对比基线。

---

## 3. 验收标准与交付物

1. `handoff/module-f/valorant-real-runs/real-run-report.json`、`summary.md` 与 `ace-mechanism-analysis.md`：双端真实运行完整证据 + 合法归因分析，严格五维分离、零绕过、零隐私泄露；
2. `handoff/phase-5/evidence/p5-a/real3d-baseline-report.md` 与 `real3d-baseline.json`：2,000+ Draw Call 高压力 Wine vs QEMU `viogpu3d` 基线数据（含 SHA-256 绑定）；
3. `graphics-lab/test_real3d_*.py` 单测全部通过，`(cd graphics-lab && python3 -B -m unittest discover -v)` 全绿；
4. 实测结束后**彻底删除独立测试克隆 VM**，确认主干净 `vm-a` 未被修改并记录释放租约，以便窗口 5C 接力使用 VM 时段。
