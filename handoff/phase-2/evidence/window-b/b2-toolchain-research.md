# B2 ARM64 工具链官方资料核验

核验日期：2026-11-22（Asia/Shanghai）。本文件仅为网络只读资料研究，不代表 Guest 已安装任何工具，也不代表驱动已编译或加载。未操作 VM、运行商业安装器或修改安全设置。

## 结论

1. WDK **10.0.26100.1 起**支持在 ARM64 宿主原生开发、测试和部署。微软当前文档明确说明 WDK **及 EWDK**可在 ARM64 硬件原生运行。不得套用旧版 EWDK 仅限 x64 宿主的结论。
2. 原生 ARM64 Visual Studio 要求 Windows 11；VS 2022 的原生 ARM64 支持始于 **17.4**。官方安装器自动识别 ARM64 系统。
3. 当前 WDK 主下载页推荐 **WDK 28000.2526 + VS 2026**。继续使用 VS 2022 时，官方支持表推荐 **WDK 26100.6584**，且 SDK/WDK 的 **build number 必须相同**；QFE 不必相同，除非用到了更高 QFE 才提供的头文件功能。
4. 对本轮 Windows 11 24H2 ARM64 的自有 WDM C 探针，可优先选 **VS 2022 + 26100 SDK/WDK** 兼容链，明确固定目标 OS 和 ARM64 平台。下载目录标注 25H2 不代表该 WDK 只能构建 25H2 驱动；是否使用超出目标 OS 的 API，仍由源码与目标版本检查决定。

## VS 2022 官方组件标识

| 用途 | 组件 ID |
| --- | --- |
| C++ 构建工作负载 | `Microsoft.VisualStudio.Workload.VCTools` |
| ARM64/ARM64EC 编译工具 | `Microsoft.VisualStudio.Component.VC.Tools.ARM64` |
| ARM64 Spectre 库 | `Microsoft.VisualStudio.Component.VC.Runtimes.ARM64.Spectre` |
| CMake | `Microsoft.VisualStudio.Component.VC.CMake.Project` |
| 26100 SDK | `Microsoft.VisualStudio.Component.Windows11SDK.26100` |
| Build Tools 的 WDK 扩展 | `Component.Microsoft.Windows.DriverKit.BuildTools` |
| 可选 x64/x86 编译工具 | `Microsoft.VisualStudio.Component.VC.Tools.x86.x64` |
| 可选 x64/x86 Spectre 库 | `Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre` |

通用 ARM64 驱动安装指南还列出 ARM64/x64 的 ATL/MFC Spectre 组件；本轮纯 C WDM 探针是否需要这些库应以实际构建依赖为准，避免为未使用的库增加空间占用。构建应明确选 ARM64 内核二进制，而非 ARM64EC 用户态目标。

## 低空间备选：Build Tools + 原生 WDK NuGet

微软官方支持 WDK NuGet；仍须安装 Visual Studio/构建工具及 WDK 构建扩展。微软文档明确写明 **dotnet CLI 不适用于 WDK，且不建议使用**。

已通过官方 NuGet API 实际核实以下固定版本存在、依赖和 HTTP Content-Length：

| 包 | 版本 | 下载字节数 |
| --- | --- | ---: |
| `Microsoft.Windows.WDK.ARM64` | `10.0.26100.6584` | 45,983,131 |
| `Microsoft.Windows.SDK.cpp.ARM64` | `10.0.26100.6584` | 103,843,219 |
| `Microsoft.Windows.SDK.cpp` | `10.0.26100.6584` | 160,036,542 |

三包压缩下载总计 **309,862,892 字节**，约 295.51 MiB。此数不含 Build Tools、扩展、CMake、解压空间及缓存；安装后总空间未知，须先核实实际容量。

依赖关系：WDK ARM64 要求 SDK.cpp.ARM64 的 `[10.0.26100, 10.0.26101)` 范围；SDK.cpp.ARM64 26100.6584 要求 SDK.cpp 恰好 26100.6584。固定三包版本可避免自动恢复拿到未来 QFE。

微软公开驱动样例的原生构建方式为 `packages.config` 的 `targetFramework="native"`、`nuget restore` 和 `Directory.Build.props` 导入三包 `build/native/*.props`，随后使用 MSBuild。不能仅下载包后直接假定现有 `WindowsKernelModeDriver10.0` 项目会自动找到包：须验证实际 props/targets 导入，并仅在中性实验构建目录进行必要接入。仅恢复 ARM64 三包，不必恢复全部 x64 示例依赖。

EWDK 则是包含 Build Tools、SDK、WDK 的自包含命令行环境；需从本地卷挂载 ISO 并启动 `LaunchBuildEnv.cmd`。官方说明网络共享路径不受支持。ISO 下载和解压占用本轮未测，不能宣称它一定比 NuGet 更省空间。

## 测试签名和真实加载约束

- 默认 Windows 不加载测试签名内核驱动。`bcdedit -set TESTSIGNING ON` 要求管理员权限；模式变化后重启。关闭为 `bcdedit -set TESTSIGNING OFF`，也须重启复核。
- 若修改被 Secure Boot 策略保护，微软文档会提示该原因。按照本轮计划保留既有安全设置并记为明确阻塞；不把此情况归因于缺少 ARM64 驱动或厂商 VM 拒绝。
- 启用 Memory Integrity/HVCI 时，二进制仍须具备测试签名，未签名二进制不受支持。HVCI 也要求驱动代码自身符合内存完整性约束；不能仅凭签名有效判断能加载。
- 测试根证书须安装于 **LocalMachine** 的 Root 存储；测试包安装通常同时使用 TrustedPublisher。使用中性证书 subject，记录创建和清理结果，避免按模糊证书名称删除其他证书。
- 对自有 demand-start WDM 驱动，可使用嵌入签名及正常服务控制路径测试。文件 Authenticode 信任、内核策略验证、服务 running、设备 IOCTL 成功是独立证据；任何一个都不应代替另外几个。
- 商业组件采样前清理自有服务/证书、关闭测试签名，重启并复核安全基线。遇签名或安全配置失败须单列，不能强塞入架构轴或虚拟化策略轴。

## 一手资料

下列页面均已在核验日实际读取到相关正文：

- [WDK 下载与 ARM64/EWDK 支持](https://learn.microsoft.com/en-us/windows-hardware/drivers/download-the-wdk)
- [官方 WDK/VS 支持版本表](https://learn.microsoft.com/en-us/windows-hardware/drivers/other-wdk-downloads)
- [Visual Studio 原生 ARM64 支持](https://learn.microsoft.com/en-us/visualstudio/install/visual-studio-on-arm-devices?view=vs-2022)
- [ARM64 驱动构建指南](https://learn.microsoft.com/en-us/windows-hardware/drivers/develop/building-arm64-drivers)
- [Build Tools 工作负载和组件 IDs](https://learn.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-build-tools?view=vs-2022)
- [WDK NuGet 官方说明](https://learn.microsoft.com/en-us/windows-hardware/drivers/install-the-wdk-using-nuget)
- [TESTSIGNING 官方说明](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/the-testsigning-boot-configuration-option)
- [安装测试证书](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/installing-test-certificates)
- [微软公开样例的 NuGet 原生构建方法](https://github.com/microsoft/Windows-driver-samples/blob/main/Building-Locally.md)

NuGet 版本与依赖通过 `api.nuget.org` 的官方 v3 flat-container 元数据核实；字节数来自对应固定版本包的 HEAD 响应。未下载或执行包内代码。
