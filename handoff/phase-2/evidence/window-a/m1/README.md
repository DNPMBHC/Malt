# module-b：M1 显式计算委托

贡献记录：@DNPMBHC。

本目录包含自有 Guest 探针源码、静态 x64 Windows 可执行文件和可重现构建记录。ARM64 Guest 可以通过其 x64 仿真层运行该探针；必须分别记录 Guest 与探针架构。本用例仅验证显式计算委托接口，不验证透明 PE 迁移、图形指令迁移或商业游戏兼容性。

## 使用接口

`WindowsGuestComputeService` 是单请求、单终态的宿主 actor。调用 `start()` 获取临时 endpoint，启动 Guest 自有探针，再调用 `wait()` 获取终态。`cancelGuest` 闭包绑定真实目标会话的 `cancel()`；不要绑定启动包装器的 PID。

endpoint 必须绑定经过当前实测确认的 VM 专用网络地址。端口由系统分配；每次会话生成新 nonce。不能绑定通配地址，也不能把历史网络可达记录作为当前实测结果。

探针参数全部通过执行接口的独立参数数组传递：`--host`、`--port`、`--nonce`、`--request-id`、`--operation affine|reject`、`--scale`、`--bias`、`--values`、`--deadline-ms`、`--socket-timeout-ms`。不要拼接 shell 命令。

默认请求向量为 `0,1,-1,2147483647,-2147483647`，计算为 `y[i]=x[i]*3-7`。宿主和 Guest 分别执行带溢出检查的整数计算；返回数据带 FNV1a 摘要。协议使用大端整数与四字节长度前缀，最大帧 64 KiB，向量最多 4096 项。

## 验证边界

- 成功：Guest 独立核对每个结果与摘要，退出码 0。
- 请求超时：宿主取消计算并回传 `timedOut` / `deadlineExceeded`，探针退出码 20。
- 取消：宿主回传 `cancelled`、关闭连接并调用真实 Guest 取消闭包；可捕获终态时探针退出码 21。强制终止目标时以真实 PID 消失及目标退出状态为准。
- 错误：`reject` 或整数溢出回传明确错误代码，探针退出码 22。
- 传输/协议失败：探针退出码 23；结果不一致为 24。

`dataConsistent` 在成功响应中表示独立数值核对通过，在错误响应中仅表示关联、摘要和错误响应空负载一致。计算一致性验收必须使用成功用例；错误用例应核对错误类型和退出状态。

宿主默认 handler 每项检查取消。注入 handler 必须协作取消；不协作的 handler 在 200 ms 清理宽限期后如实记录 `hasActiveComputation=true` 和 `computation.cancellationUnconfirmed`，终态不会永久等待，也不会被迟到结果覆盖。该状态不能标作宿主计算清理通过。

序列化 trace 不包含认证 nonce 或网络 endpoint。Guest JSON 输出包含自有目标 PID、会话 ID、Guest/探针架构、请求 ID、状态、错误代码、数值与摘要；证据不保存本地真实路径或地址。

## 重现构建

从工作区运行：

```sh
python3 handoff/phase-2/evidence/window-a/m1/build-probe.py
```

`probe-build.json` 仅证明宿主交叉编译及系统 DLL 导入检查。真实 Guest 执行证据由窗口 A 调度程序另行记录；测试数量与真实执行数量应分开统计。
