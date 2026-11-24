# 窗口 5C 原生游戏壳验收报告

署名：@DNPMBHC  
证据时间（UTC）：2026-11-24T07:02:55.793137+00:00

任务书完整验收=False。当前验证为 snapshot 4，契约 revision 2；生产指纹 `3627d20d3e6a9acf0f333ab3c8a757221a88bf9cd1b5ae84bc9442532e134c27`。历史 snapshot 3 发行证据单独保留，当前候选不冒充已封版产物。

| 验收要求 | 状态 | 证据 |
| --- | --- | --- |
| 本地 Swift、Strict SwiftLint、格式和安全门禁 | passed | local-validation.json |
| 极简优化 / Session 1 / 安全不变量 | passed | guest-minimal-apply.json |
| WHQL 3D / 硬件适配器 / FL 11_1 / 根退出码 | pending | guest-d3d-hardware-probe.json |
| 真实标准缩放控件发现及设置窗口关闭 | pending | guest-dpi-controls.json |
| 真实 Guest 原生点对点 / 退出恢复 | pending | guest-runtime-real-display-lifecycle.json |
| 真实 Guest 高性能 / 退出恢复 | pending | guest-runtime-real-display-lifecycle.json |
| 真实 Guest 窗口跟随及动态切换 / 退出恢复 | failed | guest-supported-display-lifecycle.json |
| 真实 DPI Apply 150% / Restore 基线 | failed_prior_snapshot | guest-dpi-real-roundtrip.json |
| 真实冷后台启动 / 挂起归位 | pending | guest-runtime-real-display-lifecycle.json |
| 完整运行时 IOSurface GPU 逐像素互操作 | passed | runtime-binary-roundtrip.json |
| 真实原生全屏窗口 / 关闭 / 输入释放回执 | passed | native-fullscreen-probe.json |
| 真实 Windows scanout / 合法虚拟 HID | pending_upstream_capability | interface-proposal.md |
| target-cn DX11 / 大厅或训练场 / 精确退出取证 | pending | target-game-real-validation.json |
| 自有克隆删除 / 主源与原备份独立复核 | pending | own-cleanup-proof.json |

本地 SwiftPM 252 项：242 通过、10 项既有显式跳过、0 失败。Strict SwiftLint、严格格式、format_check、防外挂审计和租约反例门禁见 local-validation.json。完整运行时互操作和原生窗口以本轮源码指纹绑定，宿主合成帧不作为 Guest 游戏帧。

C1 原型已实现，但当前真实生命周期验收未通过，不能作为后台启动到退游归位的完整实证。Headless 编排使用 Session 1 helper 监控真实根及子进程树。退游先释放光标和关闭窗口，再恢复显示，恢复成功后才按策略挂起；失败与取消路径有独立行为测试。窗口捕获只接受聚焦窗口相对位移，缺少合法 HID sink 时拒绝捕获。热键、失焦、Cmd+Tab、关闭和退游释放均有状态机测试；系统调用失败保留 releasePending，自动重试不伪造成功回执。

宿主读取 NSScreen 逻辑尺寸、Backing Scale Factor 与刷新上限。Guest 分辨率采用标准枚举和 ChangeDisplaySettingsExW，DPI 通过已验证签名的系统设置窗口、限定 UIA 控件和新建 Per-Monitor V2 窗口回读。改变前保留恢复基线，DPI 恢复失败仍尝试分辨率恢复。默认 Restricted 的失败记录保留；当前仅使用脚本进程 RemoteSigned，持久与组织策略不被覆盖。

C 自有克隆已独立验证硬件适配器、FL 11_1、Session 1、根退出码 0；AdapterRAM=0。游戏是否检查该值仍须由未修改日志或对应进程的实际证据证明，未取得时为 unknown。最新 supported-lifecycle 在取消树时失败，baselineRestored=false；恢复日志早于该次失败，不能据此认定本次已恢复。原生点对点首次返回 -2 并恢复基线；后续系统盘被更新下载缓存占满，引发传输失败。失败、空间诊断及清理后回读均保留，未隐藏或计作成功。

真实 Windows scanout 与合法 HID 的完整链路仍未实证。target-cn 登录、协议、实名、验证码必须本人完成；若自然退出，须记录精确弹窗文本、完整脱敏截图与根/子进程退出码。无自然退出时不得填造退出码或声称进入大厅。

当前 C 租约=held。结束必须彻底删除自有克隆，独立复核主源八份文件与原游戏备份的 SHA/size/mtime 后才能标记清理通过。原备份仅用于创建独立副本。没有跨窗口汇报、修改主 UI、Git commit/push/reset 或全局 Git 配置改动。最小主 App 接线见 interface-proposal.md。

五维口径：代码=implemented_prototype；本机验证=True；真实 Guest=见逐项实证；厂商支持=unknown；真实游戏=见单独取证。未完成项保持明确状态。
