# M0 / M2 真实 Guest 验收

负责方：@DNPMBHC。时间：2026-11-22 22:30:42（Asia/Shanghai）。

Windows HARDWARE 请求实际选择的适配器：`Microsoft Basic Render Driver`；vendor/device=5140/140，flags=0，software=false，feature level=11_1，Windows Session=1。

Win32_VideoController 本轮检测到：Red Hat VirtIO GPU DOD controller。显式 WARP 请求的实际适配器为 `Microsoft Basic Render Driver`，vendor/device=5140/140，flags=2，software=true。完整 DXGI 枚举与创建 HRESULT 保存在 M0 原始元数据中。

显式 Guest WARP 参考与宿主 Metal 原生 RGBA 的四组逐像素对照全部通过，最大逐通道误差 1 LSB。正确性捕获未混入性能运行。

以下统计使用同一 Session、同一二进制、1280×720、16 次绘制、64 KiB 资源，三轮轮换，每组 60 帧预热加 300 帧测量。FPS 用所有轮次的测量帧数除以 GPU 完成边界内的总时间；P50/P95/P99 来自合并帧间隔样本。

| 模式 | 完成吞吐 FPS | P50 / P95 / P99 ms | 每帧应用层字节 | 宿主 Metal GPU 均值 ms |
|---|---:|---:|---:|---:|
| Direct Present | 15.673 | 63.028 / 94.581 / 125.498 | 0.000 | — |
| Pixel Readback TCP | 7.096 | 127.983 / 219.438 / 332.853 | 3688681.067 | 0.205007 |
| Command-Only Metal Replay | 18.847 | 49.010 / 69.566 / 109.944 | 2289.600 | 0.881399 |

GPU command completion 和实际屏幕显示分开。Metal 时间包含场景绘制及单独的展示绘制；没有测量输入到光子的延迟。历史 11.35 / 6.19 FPS 属于旧提交统计口径，仅保留为历史记录。

command-only 的正常帧不执行 Guest 场景 Draw、CopyResource、像素 Map(READ) 或像素传输；宿主实际执行每帧 16 次场景 Draw。缓存帧 88 字节，资源和描述符刷新帧 66,136 字节，另有每连接 32 字节 hello。

完整源码、二进制、CSV、JSONL、参考帧和捕获帧摘要见三个子目录的 manifest 与本目录的 acceptance.json。范围为自有固定场景，不代表通用 D3D/WDDM 栈已经完成。
