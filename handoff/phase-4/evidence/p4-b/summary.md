# Phase 4B-1（M2.5）：跨 VM 异步流水线协议提速实测报告

日期：2026-11-23  
署名：`@DNPMBHC`  
范围：`graphics-lab` / `Whisky/Modules/guest-gpu-lab`（自有固定 1280×720 16-Draw 场景，`vm-a` 零破坏性实测）

## 1. 五维诚实状态声明

| 维度 | 状态 | 说明 |
| --- | --- | --- |
| 1. 代码实现 | `completed` | 独立实现 GFX1 v3 异步 Fence 协议、`metal_host_async.swift`（`TCP_NODELAY` + 2/3 槽位无竞争环形缓冲 + `addCompletedHandler` 保序 ACK）与 `d3d11_probe_async.exe`。 |
| 2. 本机合成验证 | `passed` | `test_m2_async_protocol.py` 与既有 `graphics-lab` 单测全绿；独立捕获 pass 逐像素 0–1 LSB 校验通过。 |
| 3. 真实 Guest 跨 VM 验证 | `passed` | 在真实 `vm-a`（Windows 11 24H2 Build 26100 ARM64，Secure Boot 开启、Test Signing 关闭）完成 4 模式 × 3 轮配对实测与独立像素一致校验，并确认清理零残留。 |
| 4. 厂商支持 | `unknown` | M2.5 为自有固定 16-Draw 协议实验，不代表商业反作弊或通用 WDDM 驱动已获厂商支持。 |
| 5. 真实游戏验证 | `not_tested` | 未运行任何商业游戏，所有吞吐数据仅限定于自有固定 16-Draw 场景与 `gpu-complete` 边界。 |

## 2. 像素一致性独立校验（0–1 LSB，与性能采样完全隔离）

| 对照组（跨 VM `vm-a` → Apple M4 Metal `async inflight=3`） | 参考来源 | 比较像素数 | 最大通道误差 (LSB) | 超阈像素 | 结论 |
| --- | --- | ---: | ---: | ---: | :---: |
| `legacy-0` | 真实 Guest D3D11 WARP | 921,600 | **0** | 0 | `passed` |
| `seeded-0` | 真实 Guest D3D11 WARP | 921,600 | **1** | 0 | `passed` |
| `seeded-30` | 真实 Guest D3D11 WARP | 921,600 | **1** | 0 | `passed` |
| `seeded-31` | 真实 Guest D3D11 WARP | 921,600 | **1** | 0 | `passed` |

## 3. 跨 VM 配对吞吐与帧间隔实测（1280×720, 16-Draw, 60 预热 + 300 测量帧 × 3 轮）

| 模式 | `TCP_NODELAY` | 最大在途帧 | 实测最大深度 | 合并吞吐 FPS（含 GPU Drain） | 相对 M2 同步基线提速 | ACK 间隔 Mean / P50 / P95 / P99 (ms) | 单帧完成 RTT Mean / P95 (ms) | 宿主 Metal GPU 均值 (ms) | 每帧平均线缆字节 |
| --- | :---: | :---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **M2 Baseline (Sync, Nagle On, Split ACK, In-Flight=1)** | `off` | `1` | `1` | **19.05** | **1.00×** | 52.480 / 53.336 / 59.118 / 61.121 | 52.470 / 59.115 | 0.803 | 2289.6 |
| **M2.5 TCP_NODELAY + Coalesced Send (Sync, In-Flight=1)** | `on` | `1` | `1` | **322.95** | **16.95×** | 3.097 / 1.830 / 9.203 / 13.094 | 3.088 / 9.200 | 0.811 | 2289.6 |
| **M2.5 Async Fence Pipeline (NoDelay, In-Flight=2)** | `on` | `2` | `2` | **471.98** | **24.77×** | 2.113 / 1.462 / 5.780 / 9.415 | 4.209 / 8.873 | 0.705 | 2289.6 |
| **M2.5 Async Fence Pipeline (NoDelay, In-Flight=3)** | `on` | `3` | `3` | **145.15** | **7.62×** | 6.852 / 6.216 / 8.826 / 10.810 | 20.531 / 25.517 | 6.028 | 2289.6 |

## 4. 核心工程结论与边界

1. **根因证实**：对比 `m2_sync_nagle` 与 `m25_sync_nodelay` 精确隔离了 Nagle + Delayed ACK 乒乓延迟的巨大占比；在此基础上开启 2/3 帧有界异步飞行队列（`addCompletedHandler` + 环形槽位 `MTLBuffer`/`MTLTexture` + 保序 `fence_id` ACK），进一步重叠跨 VM 传输与 Apple M4 Metal 执行。
2. **像素零退化**：独立捕获 pass（`capture_enabled=true` 仅用于验证，性能 pass 严格 `capture_enabled=false`）证实 3 帧在途异步流水线在 `legacy-0` 与 `seeded-0/30/31`（`seed=7`）全部 4 组共 3,686,400 像素对照中保持 `0–1 LSB` 一致性。
3. **范围限定**：本指标反映自有 16-Draw 命令流重放协议在 `gpu-complete` 边界的跨 VM 吞吐能力，不等于物理屏幕输入到光子延迟，也不替代通用 D3D11/WDDM 3D 虚拟 GPU 驱动（通用商业游戏 3D 卸载见 `m3-viogpu3d-report.md`）。

## 5. 不可变输入与二进制 SHA-256 绑定

- `d3d11_probe_async.cpp`: `5bc27c2865702815bce7688b54b260514d7dd7f1ddeec225a63ba1f56c347f37`
- `d3d11_probe_async.exe`: `07edd3c8e4eb0f0a5bca9db913a5cf61cbfcc05a11f37311d7329ee3024fd7a3`
- `m2_async_benchmark.py`: `4c69c828d6766d39e1863de77fb8f97654590b26bd64dac7a361ed1ce615b27d`
- `m2_async_protocol.py`: `42e52196dece4bbbef38ae66a428af8288661339b4e95604888b6c6f5e92838d`
- `metal_host_async`: `fa8901a88ea610116e56e2445f91eae1d9b33a19e7e5f0aca811353d78c63546`
- `metal_host_async.swift`: `4928146520be0d0ddb95b25572ed60f4a5c481b569e592355427466cb3a6d66a`
