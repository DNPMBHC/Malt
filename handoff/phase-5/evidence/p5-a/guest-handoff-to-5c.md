# 5A → 5C 只读接力说明

署名：@DNPMBHC。

本轮租约已经 released。vm-cleanup-proof.json 与 vm-lease.json 记录独立克隆已删除、共享与剪贴板关闭、可写盘包含、源 stopped、退出前 VM 工作进程为 0。vm-source-before.json 与 vm-source-after.json 八份文件 SHA-256、大小及 mtime 一致。A 的 Guest 克隆与整个自有 runtime 已彻底删除，原备份完整 SHA 与 mtime 已复核一致（client-backup-final-proof.json）；请创建 C 自有克隆，勿复用 A 的 runtime 或旧 UUID。

客户端备份用 client-backup-x.qcow2 中性别名。原始盘未删除。定位时只读搜索已挂载 external APFS 卷的浅层 qcow2，排除所有 .utm 包和实验 runtime；先筛选 35,935,027,200 字节，再验证完整 SHA-256 ffe1dd96382759c4bce6b9c412dc6eae9b3c5da321ed1eab9bd5057695b2b1a2。零个或多个匹配均暂停，不能按文件名猜选。基线 mtime_ns=1795366805738950146。client-backup-header.json 和 client-backup-attachment.json 绑定 qcow2 v3、无 backing file、virtual size=96,636,764,160 字节；本轮只验证头部与完整哈希，未运行完整 qcow2 一致性校验。

必须用 APFS clonefile 创建 C 自有可写副本，并放在 C 克隆的 Data 内；原备份禁止可写连接。A 中该盘枚举为 D:，C 的盘符必须自行查询。备份根仅一个客户端目录，逐层进入到 live 目录，包含一个名称以 -Win64-Shipping.exe 结尾的主游戏映像（239,250,040 字节）。backup-client-discovery.json 给出辅助映像元数据。备份不含官方启动器，不能声称已完成全量在线校验。

当前官方安装器版本 2.17.4.510，491,792,264 字节，SHA-256 686ee838411863d2eccdbe8a0596129e509819ae46626408760588ae8b0c800e；official-installer-guest-trust.json 记录 Authenticode Valid。可以只读发现 workspace 根目录已有 *_CN_installer_*.exe 并按上述 SHA 验证，或从官方入口重新下载同一版本并独立验签。该原有文件不是 A 临时 runtime 的清理目标。

在可见 C 克隆中安装启动器至 C 自有数据盘，软件协议、登录、实名和验证码由用户亲自操作。A 的登录会话不会交接。官方启动器点选择路径 → 指定新路径，进入备份中的 live 并确认；A 中按钮随后成为“进入游戏”。这只证明官方路径识别和允许启动，没有取得全量在线文件校验完成日志。A 点击后按钮为“游戏进行中”，主游戏映像和辅助进程真实创建，随后持续黑屏；没有明确 GPU/DX11 或虚拟化策略弹窗，没有主进程自然退出码。

不要从干净主源推断 WHQL 3D 已安装。C 应独立核验 UTM 5.0.9 Guest Tools 中 viogpu3d.inf，用标准 pnputil 安装厂商签名包，保留 Secure Boot、TPM 与 Test Signing=false。guest-whql-package.json 提供版本 100.6.101.58000 的逐文件 Machine、签名和 SHA；viogpu3d.sys 为 0xaa64，SHA-256 24824d4df669987313f06c382e39db2866f408c213b6cbca916a2e01f342d31b。早期 guest-whql-loaded.json 的 CIM State=Stopped 不能替代冷启内核加载验证，应参考本轮完整 after-kernel-inventory.json 与 post-recovery-kernel-inventory.json，并在 C 自己的克隆重验。真实重压探针为 FL 11_1、硬件适配器、72.676 FPS（三轮平均）；AdapterRAM 仍为 0。

A 观察到两个运行时 ACE 原生 ARM64 SYS，版本 0.6.6.6 与 21.0.2506.56，WHQL Valid、SCM Running 与 PSAPI 加载映像匹配。本轮主启动于 02:35:48 UTC，原生驱动约 02:36:04 UTC 落地。备份三个 SYS 仍为 AMD64。不能继续把最新版描述为全部 AMD64，也不能把已加载两个组件外推为厂商允许 VM 或真实对局通过。详情见 A1 的 real-run-report.json 与 ace-mechanism-analysis.md。

安全边界仍有 TPM Ready For Attestation=false、缺 EK certificate、VBSStatus=0、HVCI未运行。CPU 架构、安全链和厂商策略分别判断；不能使用硬件伪造、虚拟化隐藏或反作弊修改补齐这些边界。

5A 前台取证与正式性能测量均已结束。Wine 两条加速路线与软件绘制诊断均由用户确认仍黑屏；日志已脱敏封存。A1 保留完整在线校验、主游戏自然退出码、厂商 VM 准入与受保护大厅/对局的证据缺口，请在 C 自有克隆独立复验。

## 游戏盘接入字段与标准识别步骤（补充）

此处仅是给 5C 的离线操作说明；5A 本轮没有复制、挂载或控制任何 VM。5A 已删除测试克隆，未保留它的完整 config.plist，不能把下面的字段示例冒充逐字历史配置。示例使用本轮只读核验到的 UTM 磁盘 schema（NVMe、InterfaceVersion=1）；5C 应由自己的配置器在自有克隆停止、配置不被 UTM 缓存覆盖时接入并重新加载。原源与原备份均不作为修改目标。

1. 在已挂载 APFS 外置卷浅层发现 qcow2，排除 .utm 包及所有窗口的 runtime。唯一文件先满足 size=35,935,027,200 与 mtime_ns=1795366805738950146，再完整验证 SHA-256：

```text
ffe1dd96382759c4bce6b9c412dc6eae9b3c5da321ed1eab9bd5057695b2b1a2
```

零个或多个匹配都不能猜选。绑定证据是 client-backup-final-proof.json、client-backup-header.json 与 client-backup-attachment.json。qcow2 v3、无 backing、虚拟容量 96,636,764,160 字节；这不代替完整 qcow2 一致性检查。

2. 仅向 5C 自有克隆 Data 内创建 APFS 独立副本，目标必须尚不存在。以下命令全部为中性占位示例，须先由 5C 在本地把变量解析为自己的已验证路径；本窗口不执行：

```sh
P5C_BACKUP='<EXTERNAL_VOLUME>/client-backup-x.qcow2'
P5C_CLONE='<EXTERNAL_VOLUME>/test-vm-p5c.utm'
if test -e "$P5C_CLONE/Data/client-backup-x.qcow2"; then
    exit 1
fi
cp -c -n "$P5C_BACKUP" "$P5C_CLONE/Data/client-backup-x.qcow2"
```

macOS cp 的 -c 使用 clonefile；不要用 reflink 不支持时自动退回的跨文件系统复制来声称 APFS 克隆成功。复制后重新计算副本完整 SHA，核对原备份 SHA、大小和 mtime 未变。不要把原备份直接设置成可写磁盘。

3. 在 5C 自有 config.plist 的顶层 Drive 数组追加一个独立条目；保留已有系统盘和其他条目，Identifier 使用新 UUID，ImageName 只填自有 Data 内的文件名：

```json
{
  "Identifier": "<new-unique-uuid>",
  "ImageType": "Disk",
  "Interface": "NVMe",
  "InterfaceVersion": 1,
  "ImageName": "client-backup-x.qcow2",
  "ReadOnly": false
}
```

该条目可通过 UTM 自有克隆的标准 Drive 设置建立，也可由 5C 的离线配置器写入。请核实磁盘文件确在自有 Data 中、不是 symlink、没有 backing 文件；共享目录和剪贴板仍关闭。只重新加载或启动 5C 自己的 UUID。5A 的历史 Guest 证据显示该副本为 Disk 2、GPT、非只读、容量 96,636,764,160 字节，NTFS 分区容量 96,618,934,272 字节并分配为 D:；这是 guest-backup-disk-reloaded.json 的观测，不保证 C 的盘号或盘符相同。

4. Guest 先只读查询盘号和盘符，不输出卷标：

```powershell
Get-Disk | Select-Object Number,BusType,PartitionStyle,IsOffline,IsReadOnly,Size
Get-Volume | Select-Object DriveLetter,FileSystem,Size,SizeRemaining
```

按上述虚拟容量找到 C 的游戏盘，再在可见界面定位其唯一客户端目录下的 live。检查 live 目录树内存在一个以 -Win64-Shipping.exe 结尾、239,250,040 字节的主映像。官方路径选择的是 live 安装根，不能把某个二进制子目录当作安装根。整个发现过程不读取、输出或复用 A 的登录会话。

5. 备份不含启动器。使用本轮官方安装器 2.17.4.510（491,792,264 字节），完整 SHA-256 为：

```text
686ee838411863d2eccdbe8a0596129e509819ae46626408760588ae8b0c800e
```

签名证据是 official-installer-guest-trust.json（Authenticode Valid）；发现规则为 workspace 根已有 *_CN_installer_*.exe，再按 SHA 匹配，或由官方入口下载后独立验签。安装到 C 自有数据盘。软件协议、登录、实名、CAPTCHA 必须交给用户在可见界面亲自操作；不继承 A 的认证。

6. 官方启动器选择路径 → 指定新路径 → 选择游戏盘中的 live → 确认。A 的一手记录 guest-client-recognized-visible.json 表明按钮成为“进入游戏”，此前轮播和控件正常呈现；点击后显示“游戏进行中”。按钮就绪仅证明官方路径识别和允许启动，不证明完整在线校验完成。C 应另行获取官方校验完成日志，再独立记录 GPU/DX11 弹窗、主/子进程退出码、SCM/CI 与大厅状态。A 本轮未取得完整在线校验或主游戏自然退出，仍保持这些证据缺口。
