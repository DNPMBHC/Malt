# 窗口 5C 任务书：无桌面「原生全屏游戏壳」体验原型 — 对齐方案 B `IOSurface` 零拷贝 + Retina 同步 + Raw Input（P1）

署名：`@DNPMBHC`  
启动前提：**Swift 模块实现与本地单元测试可立即启动；涉及真机 Guest 端到端联调必须等待窗口 5A 释放 VM 租约后，在独立克隆快照上执行**  
请先阅读：`handoff/phase-5/README.md`、`handoff/phase-4/evidence/p4-c/optimizer-benchmark.json`、`handoff/phase-4/evidence/p4-b/m3-viogpu3d-report.md`

---

## 1. 独占可写路径（严格互斥）

- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/GuestSurface*.swift`（新建）
- `Whisky/WhiskyKit/Sources/WhiskyKit/Runtime/UTM*.swift`
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/GuestSurface*.swift`（新建）
- `Whisky/WhiskyKit/Tests/WhiskyKitTests/UTM*.swift`
- `handoff/phase-5/evidence/p5-c/`（新建）

严禁修改 `Whisky/Whisky/`（App 主 UI 视图）、`Whisky/WhiskyCmd/`、`Whisky/Whisky.xcodeproj/`、`BottleSettings.swift` 及其他窗口独占路径；如需在主 App 菜单/视图中暴露入口，将最小化接线方案写入 `handoff/phase-5/evidence/p5-c/interface-proposal.md` 交由窗口 5D 统筹。

---

## 2. 核心任务拆解

面向用户核心体验需求（“不要看到低分辨率卡顿的 UTM 和 Windows 桌面，而是把 Windows 游戏尽量像 macOS 原生全屏应用一样运行在 macOS 桌面上”），在 `WhiskyKit` 运行时层落地**对齐方案 B 零拷贝 `IOSurface` 契约的无桌面「原生全屏游戏壳」**：

### 任务 C1（P1）：Headless Guest 静默启动与「应用聚焦模式」编排
1. 在 `UTMWindowsGuestProvider` / `GuestSurfaceSession` 中实现无感后台生命周期编排：
   - 后台拉起已启用极简优化（4C）+ WHQL `viogpu3d`（4B）的 Guest（不强弹 UTM 管理界面，支持空闲低占用或按需挂起）；
   - 通过 Session 1 交互式执行链路直接拉起目标 Windows 3D 应用/游戏并监控根进程与子进程树；
   - 应用退出时自动触发安全收尾（释放鼠标锁定、关闭宿主全屏容器窗口、恢复 Guest 分辨率并按策略挂起或热待命）。
2. **绝不破坏反作弊与 Windows 安全链**：严禁删改系统 Shell 签名文件、严禁向游戏进程注入 DLL 或 Hook DWM，仅通过标准 Windows 显示/窗口管理与宿主呈现层实现“无桌面体感”。

### 任务 C2（P1）：Mac Retina 点对点分辨率自动同步协议
1. 构建 `GuestDisplayResolutionPolicy` 与 QGA 显示同步指令：
   - 自动读取宿主目标显示器（`NSScreen`）的逻辑分辨率、Backing Scale Factor（1× / 2× Retina）与刷新率上限，支持「原生点对点（如 2560×1600）」、「高性能 1080p/1440p（自动 16:10/16:9 匹配）」和「窗口跟随」三档策略；
   - 启动游戏壳前，通过 Guest Agent 在 Session 1 下发标准 Windows Display API (`ChangeDisplaySettingsEx`) 切换分辨率与 DPI，彻底消除 UTM 默认低分辨率模糊拉伸；退出游戏壳后自动恢复原始基线分辨率。

### 任务 C3（P1）：原生全屏 `NSWindow` 容器（支持方案 B `IOSurface` 零拷贝直挂）+ FPS Raw Input 鼠标锁定
1. 在 `WhiskyKit/Sources/WhiskyKit/Runtime/GuestSurfaceWindowController.swift` 实现轻量级 macOS 原生全屏/无边框窗口控制器：
   - 原生支持 macOS Fullscreen Space（`collectionBehavior = [.fullScreenPrimary]`）与 `CAMetalLayer` / `CALayer.contents = ioSurface` 零拷贝直挂协议（抽象 `GuestSurfaceFrameSource`，直接预留对接窗口 5B 方案 B 的 `IOSurface` 零拷贝句柄与 `MTLSharedEvent`，同时兼容现有测试源）；
   - 在浮层/标题栏安全展示当前分辨率、刷新率、来源后端与热键退出提示；
   - 实现 **FPS Raw Input 鼠标捕获状态机**（`CGAssociateMouseAndMouseCursorPosition(false)` + 相对位移事件提取 + 强保障防卡死释放机制：`Cmd+Option+G` / 窗口失焦 / `Cmd+Tab` / 游戏退出瞬间 100% 恢复系统光标，绝不锁死用户 Mac）。
2. 补齐完整本地单元测试（分辨率策略、零拷贝 `IOSurface` 契约绑定、状态机防死锁释放、Headless 启停回滚、参数防注入校验）；待 5A 释放 VM 后，在独立克隆快照上实测端到端“后台启动 → 动态切分辨率 → 启动 3D 探针全屏呈现 → 退出自动还原分辨率并关闭”。

---

## 3. 验收标准与交付物

1. `swift test --package-path Whisky/WhiskyKit` 全绿（新增 `GuestSurface*Tests.swift` 全部通过）；
2. Strict SwiftLint **0 违规**，`python3 handoff/task-07/format_check.py` 全绿，`audit_anticheat_hardening.py --self-test` 全绿（确认无违禁全局键鼠注入/宏原语，仅限合法聚焦窗口内原始位移捕获）；
3. `handoff/phase-5/evidence/p5-c/headless-shell-report.md`、`display-sync-evidence.json` 与 `interface-proposal.md`（给 5D 的主 App UI 接线方案）；
4. 若执行了独立克隆实测，测完必须彻底删除独立克隆并确认主干净 `vm-a` 零触碰。
