# 阶段验收结果

日期：2026-11-26  
维护：@DNPMBHC

- Swift：执行 346 项，跳过 10 项，失败 0 项。
- Python：142 项通过，涵盖实例管理、原生服务合同与打包脚本。
- 项目 strict SwiftLint：通过；构建：通过。
- 构建期间与最终校验后的源码指纹：稳定。
- DMG：360.379 MiB；只读压缩镜像校验：通过。
- SHA-256：af10e99e2abeac6f92aa8d6a9eb6e78f65fdf689c2ce047187d4223ce2453aa9。
- 制品清单的实际相对路径、大小与哈希：通过。
- 从实际 DMG 复制到临时位置后的完整校验：通过。
- 实际 DMG 内管理脚本、来宾脚本及中英指南与冻结源码逐字节/文本比对：通过。
- 载荷：1479 项资源，164 个 Mach-O，未发现受管代码依赖非系统绝对路径。
- 已验证内嵌 Python 的隔离环境标准库与管理器帮助、控制 CLI 帮助、网络辅助程序自检、辅助程序登记与自动化权限标记、deep strict 签名，以及干净用户数据下的主进程存活。
- 本地验收：通过。

## 交付边界

本机未发现有效 Developer ID Application 签名身份。本轮制品使用 ad-hoc 签名，正式分发门禁会阻断它。Developer ID、公证和用户系统批准仍须完成，不能把本机签名校验当作默认跨机运行许可。

未进行真实 Windows 来宾、游戏、UAC/TCC 批准、原生联网或另一台物理 Mac 验收。Swift 跳过的 10 项包含真实来宾与显式 GPU 实验；未用合成测试替代这些验收。

完整包不含 Windows 镜像和许可证、Wine 核心运行库、游戏及游戏许可证。适用硬件架构为 arm64；应用声明最低 macOS 14.0。

完整证据见同目录 evidence 中的 validation-summary.json、package-manifest.json 与 dmg-final-verification.json；先前失败尝试保留作诊断，不作为当前通过证据。没有提交或推送。
