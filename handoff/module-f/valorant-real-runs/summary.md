# target-cn 双端真实运行实测记录

署名：@DNPMBHC。双端实验及本轮宿主复验已封存；游戏未确认跑通，A1 保留在线校验和退出码等证据缺口。

Guest 已真实加载两份原生 ARM64 ACE SYS（0xaa64），版本为 0.6.6.6 与 21.0.2506.56。WHQL Authenticode Valid、WinVerifyTrust=0、SCM Running/exit=0 与 PSAPI 映像身份关联共同支持此结论。历史备份的三份 SYS 仍为 AMD64，不能将其外推为最新保护链全部只有 x64。客户端和启动器 SYS/DLL 清单 474 项，保护运行目录另 3 项。

Guest 官方启动器安装、人工登录和客户端路径识别完成；点击“进入游戏”后显示“游戏进行中”，主游戏与图形辅助进程创建并触及 DXGI/D3D11/Neptune，但持续黑屏或空白。未观察明确厂商、GPU/DX11 或虚拟化策略弹窗，未验证大厅或对局。辅助进程退出 6 和 0 不代表主游戏或厂商码；主自然退出码保持 null。第二次生命周期采集失败 0x80070057、之后 VM 停止原因 unknown，均保留为不完整记录。

Wine 先前 DXMT、D3DMetal 和 --disable-gpu 参数尝试均由用户确认黑屏或空白。参数是否被采纳、是否实际软件绘制尚未验证。本轮新 Bottle 静默引导退出 0 却未出现窗口或目标安装文件；去掉静默参数后用户确认安装完成，随后只显示图标，无法打开窗口。对 SHA 绑定的 AMD64 主启动器执行 --enable-logging=stderr --v=1 标准诊断满 60 秒，用户最终确认仍无窗口。调用和主子进程自然退出码未获得，受控关闭不冒充自然退出。

新安装目录 317 份 DLL、0 份 SYS，全部 SHA 与此前 Windows 已验签字节匹配。官方包 32 份 EXE 中 25 份 AMD64、7 份 I386；安装器为 I386，两份历史实际启动器则经精确 SHA 绑定为 AMD64。不能用安装器 32 位解释启动器失败。Wine builtin/native 标签不是后端字节证明，日志 context 不是已绑定 PID。最终日志有 36 条 OLE、2 条 D3D 错误，后者为 wined3d_check_gl_call / GL_INVALID_ENUM；尚未建立主进程、致命失败或厂商拒绝归因，根因 unknown。

| 五维口径 | 结果 |
| --- | --- |
| 实现 | 只读采集、30 秒驱动巡检、真实异步压力探针及脱敏诊断工具完成 |
| 本地门禁 | 220 项 unittest 通过，0 失败、0 错误、0 跳过；127 源码与 6 反例安全自检通过 |
| 真实运行 | Guest 原生 ACE 已加载；Wine 官方启动链已实跑，双端视觉失败 |
| 厂商允许与支持 | unknown；加载成功不能代替 VM 准入 |
| 受保护大厅与对局 | 未验证 |

Guest 为 Win11 24H2 ARM64 build 26100，Secure Boot=true、Test Signing=false，WHQL viogpu3d 100.6.101.58000 已加载，TPM 2.0 已初始化。TPM attestation=false、缺 EK certificate、VBS/HVCI 未运行、AdapterRAM=0 单独保留。System SCM、Application、CodeIntegrity 按 RecordID 取证；时钟跳变和历史 7000/1275 不能冒充本次 ACE 拒绝码。

正式五路基线各三轮，15 轮、13,500 测量帧，原生退出码均 0；本轮再次复核全部 CSV、摘要及源码 SHA。1280×720、每帧 16,384 Draw、4,096 次常量缓冲更新、动态顶点缓冲、双 Pass、三缓冲 Present(0,0)，GPU drain 仅在预热后和测量末。FPS：DXMT 339.524、D3DMetal 372.817、DXVK+KosmicKrisp 115.886、DXVK+MoltenVK 370.264、QEMU WHQL viogpu3d 72.676。P50/P95/P99 与宿主 CPU 范围见正式基线；不能外推商业游戏或物理输入/显示延迟。

自有 Wine 已关闭，独立 Guest 克隆与本轮 host-only runtime 已删除；主源八份文件 SHA、大小及 mtime 一致并保持停止，原备份完整 SHA、大小及 mtime 本轮复核一致。租约保留原 released 时刻。私有原始诊断日志随 runtime 删除，仅保留允许字段的结构化记录和原始字节 SHA，不能据此宣称原始日志仍可取回。

运行报告、ACE 归因与正式基线分别见 real-run-report.json、ace-mechanism-analysis.md 和 real3d-baseline.json。未完成的实证：客户端完整官方在线校验日志、Guest 主游戏自然退出码、厂商 VM 正式准入、受保护大厅和对局。没有修改反作弊或官方启动器，没有隐藏虚拟化、伪造硬件或自动化认证。
