# 运行环境与启动接口对接

日期：2026-11-26  
维护：@DNPMBHC

本阶段完成后端、来宾启动脚本、发行流程，以及现有运行环境页的网络授权与导入入口。前端其他功能继续由并行工作接入。

## 安装与快速启动

- install(installerURL:engineKind:title:) 返回的条目状态为 .installerRequested。它表示已请求运行安装器，不表示安装完成。
- 缺少 Wine、可玩容器、内嵌控制组件或来宾工具时应展示返回的操作提示，不能把错误转换为安装成功。
- 用户完成安装后，需要选择真正的游戏主程序，更新 executablePath、对应容器或 bottle，并将 installationState 设为 .ready 后存入 libraryStore。
- 容器条目的程序路径是来宾 Windows 内路径；不要把宿主安装器路径当成游戏路径。
- launch(entry:) 会拒绝 .installerRequested；正常容器启动必须等待来宾工具可用并收到目标进程启动回执。
- 启动回执只证明目标进程已启动，不证明安装完成、游戏兼容、反作弊可用或在线连接成功。
- 调用异步接口期间需要呈现等待状态；用户取消时保留任务取消传播，不能提前显示成功。

## 原生网络授权

在主线程使用以下接口：

| 接口 | 界面行为 |
| --- | --- |
| refreshNativeNetworkStatus() | 进入设置页、返回前台以及用户按刷新时重读系统状态 |
| requestNativeNetworkAuthorization() | 仅由用户主动点击启用触发；按需引导系统批准 |
| openNativeNetworkApprovalSettings() | 打开系统的登录项设置 |
| revokeNativeNetworkAuthorization() | 用户选择停用时撤销注册并刷新状态 |

监听 nativeNetworkPermissionState，区分：

| 状态 | 建议呈现 |
| --- | --- |
| helperMissing | 安装完整应用，不展示为已授权 |
| notRegistered | 展示启用入口 |
| requiresApproval | 提示管理员在系统设置批准，提供打开设置与刷新 |
| starting | 已注册但连接入口未就绪，展示等待与刷新 |
| ready | 服务连接入口已就绪，仍须配置容器并验证实际联网 |
| signingRequired | 提示安装签名且公证的发行版，反复点击不能修复签名 |
| operationFailed(code) | 展示可操作错误及重试，保留错误码供诊断 |

服务状态无法独立证明当前容器的网络模式。不要只凭 socket、注册成功或界面开关宣称原生网络已连通，也不要宣称已自动切换到独立 TCP/UDP 代理。

## 用户显式导入运行环境

- 现有网络卡片通过 importPlayableContainer(at:confirmedStopped:) 导入用户选择的实例，并持久化该选择供下次启动发现。
- 文件选择后必须另行确认实例已经完全关机，且不是模板或冷备；取消不会调用导入接口。
- 管理器再次检查活动进程、保存态、配置与唯一标识，并以私有权限原子建立受管元数据。已有冲突或不安全标记不会被覆盖。
- 导入不复制系统盘、不启动实例、不安装来宾工具，也不表示实例已经可以运行游戏。
- 用户显式应用或恢复网络配置时，应用会按需以仅登记模式打开控制组件，不启动容器；随后精确核验所选实例已停止，并在写入前通过安全重载拒绝引擎注册表中的挂起状态；管理器再次核验磁盘保存态。已有控制组件无法识别所选实例时，明确要求关闭后重试，状态未知时仍拒绝改写。
- 已知活动任务存在时禁用应用、恢复与停用服务；操作中禁用重复提交。撤销服务的返回错误直接保留在反馈区，不立即刷新覆盖。

## 应用或恢复容器网络配置

- 在容器完全停止后调用 configureNativeNetwork(for:restore:)。
- restore: false 需要桥接服务就绪，管理器再次确认容器为已停止、受管理的可玩实例，才保存备份并改写网络配置。
- restore: true 恢复原始配置；遇到配置漂移会拒绝覆盖，需向用户解释，不能显示为已恢复。
- 模板、冷备、运行中、状态不明、UUID 不符或不安全路径均应拒绝；界面不要自动绕过保护。
- 应用与恢复前均拒绝挂起或保存状态；写入前的拒绝不改配置与备份。成功返回也只表示配置已写入并回读验证，下次启动后仍须实际联网验收。

## 运行环境检查

healthStatus() 新增以下布尔项，可用于首次配置清单：

- runtime_python_ready
- container_control_ready
- native_network_service_bundled
- guest_config_valid
- network_management_ready

wine_ready 与 playable_vm_discovered 必须独立展示。完整安装包内含管理工具，不等于内含 Wine 核心运行库或合法 Windows 镜像；用户仍需按所选引擎完成运行环境配置。

## 发行边界

本地 ad-hoc 包用于本机验证。正式向其他 Mac 分发需要 Developer ID 签名、公证、系统批准与新用户环境验收。首次配置指南随包提供；不得以主应用存活检查替代真实游戏和跨机测试。
