# Graphics path experiment

This directory is an isolated task-03 experiment. It does not change the shared launch, guest, or compatibility interfaces. Any product-level interface changes remain with task 05. The D3D test process runs in whichever execution environment launches it; Wine is not represented as a Windows guest.

## What is implemented

- d3d11_probe.cpp is a self-owned D3D11 program. It draws a fixed full-screen workload, submits a configurable batch of draw commands, reads a deterministic resource buffer in its pixel shader, and supports either a local DXGI swap chain or a staging-readback transport to the host.
- metal_host.swift is a macOS AppKit/Metal receiver. It accepts a small versioned TCP protocol, checks dimensions, sequence numbers, command opcodes and byte limits, uploads pixels into one reusable shared Metal texture, presents them, and returns a per-frame acknowledgement with host timing and memory data.
- synthetic_client.py exercises only the receiver and the wire protocol. It generates synthetic commands, resources and pixels. It is not a D3D or guest test.
- analyze.py validates one run's CSV and reports mean, P95/P99, frame-rate estimate, transfer totals, memory and telemetry coverage. Empty telemetry remains missing.

The offload prototype is deliberately a CPU-staged baseline: D3D11 renders in the producer process, CopyResource moves the render target to a CPU-readable staging texture, and TCP carries a batched opaque command stream, an optional resource update and the rendered RGBA image to the host. The host validates but does not execute the D3D commands; it retains the most recent command batch and resource update for the connection and presents the received image with Metal. `--command-every` and `--resource-every` control wire resend cadence only. The D3D workload still executes its draw batch and updates its local shader-input buffer on every frame. The synchronous acknowledgement follows Metal command-buffer completion and acts as the per-frame fence for this experiment. There is no shared GPU-memory handle, guest driver, virtual GPU, zero-copy path, protected-memory bridge or production command interpreter.

## Repeatable local receiver run

Use a graphical macOS session with Xcode command-line tools and Metal available. Keep the receiver on loopback for local runs:

~~~sh
swiftc -O graphics-lab/metal_host.swift -framework AppKit -framework Metal -framework QuartzCore -o metal_host
./metal_host --bind 127.0.0.1 --port 39003 --jsonl host.jsonl
~~~

In a second terminal, run three equivalent passes and summarize each CSV:

~~~sh
python3 graphics-lab/synthetic_client.py --frames 90 --warmup 20 --width 640 --height 360 --commands 16 --resource-bytes 65536 --csv run-1.csv
python3 graphics-lab/analyze.py run-1.csv
~~~

Change only the output filename for the next two passes. For other workloads, keep resolution, frame count, warm-up, command batch, resource size and command/resource resend intervals identical across comparisons. A run is unpaced except for host drawable presentation and the synchronous acknowledgement; it is not a game-frame pacing test. To compare retained payloads, run paired sender passes with `--command-every 30 --resource-every 30` and with both intervals set to `1`. The D3D probe exposes the same controls.

## Build and run the D3D11 probe

Build on Windows with a Windows SDK and a D3D11-capable compiler:

~~~bat
cl /nologo /std:c++17 /O2 /EHsc d3d11_probe.cpp /Fe:d3d11_probe.exe
~~~

For a direct-present baseline, run the executable on Windows or through an installed Wine D3D backend:

~~~bat
d3d11_probe.exe --frames 900 --warmup 120 --width 1280 --height 720 --commands 16 --resource-bytes 65536 --csv direct.csv
~~~

To capture process-launch-to-ready time, run the same invocation through the shell-free wrapper. The wrapper waits for the probe's flushed readiness marker, records outer launch time (including a Wine launcher when used), and does not persist the command line:

~~~bat
python run_probe.py --json cold-start.json -- d3d11_probe.exe --frames 900 --warmup 120 --width 1280 --height 720 --commands 16 --resource-bytes 65536 --csv direct.csv
~~~

For Wine, build the self-owned executable with a Windows SDK, then invoke it through the installed Wine runtime. Keep one disposable prefix per backend and use the runtime's documented selector for each backend; do not infer the backend from the executable name. Example shell form:

~~~sh
WINEPREFIX=/tmp/graphics-lab-prefix-dxvk python3 graphics-lab/run_probe.py --json wine-cold-start.json -- wine d3d11_probe.exe --frames 900 --warmup 120 --width 1280 --height 720 --commands 16 --resource-bytes 65536 --csv wine-cold.csv
WINEPREFIX=/tmp/graphics-lab-prefix-dxvk python3 graphics-lab/run_probe.py --json wine-hot-start.json -- wine d3d11_probe.exe --frames 900 --warmup 120 --width 1280 --height 720 --commands 16 --resource-bytes 65536 --csv wine-hot.csv
~~~

Use the equivalent isolated prefix and documented backend setting for the other installed backend. Record the exact runtime/backend versions and the cache preparation method next to each result.

For host presentation, start metal_host on a host-only or otherwise isolated test network interface reachable from the guest. The receiver defaults to loopback; choose its bind address deliberately. The receiver protocol has no authentication or encryption, so do not expose it to an untrusted network. Run:

~~~bat
d3d11_probe.exe --frames 900 --warmup 120 --width 1280 --height 720 --commands 16 --command-every 30 --resource-bytes 65536 --resource-every 30 --transport-host HOST_IPV4 --port 39003 --csv offload.csv
~~~

The fixed D3D scene is windowed, single-sample, with no MSAA, a full-screen triangle, a deterministic resource-read shader and 16 identical draw calls per frame by default. `Present(0, 0)` disables the explicit sync interval. This is a repeatable synthetic workload, not a representative game scene.

For startup reporting, keep one disposable Wine prefix per backend and record its cache state. A cold-cache pass must use a fresh test environment or a backend-documented cache reset scoped to that environment; a hot-cache pass reruns the same command with the resulting cache retained. If a backend cache cannot be isolated or reset through documented controls, mark cold-cache timing unavailable rather than clearing a shared user cache. Capture each process start with `run_probe.py`, then keep the probe's own 120-frame warm-up duration separate from launch-to-ready time. Retain separate cold and hot JSON/CSV files. Repeat each condition at least three times after recording OS, CPU/GPU, Wine or guest version, D3D backend/driver version, resolution, workload parameters, cache state and display refresh rate. For Wine comparisons, use the same isolated prefix layout and compare DXVK with D3DMetal only when both are available in the installed runtime; select each through that runtime's supported configuration. Keep each backend in a separate CSV and record its exact runtime configuration alongside the result. For guest tests, use the same D3D workload and compare direct-present to TCP offload from the same guest configuration.

## Measurements and interpretation

Each D3D CSV row records the process frame interval, CPU submit/round-trip time, process CPU time, D3D timestamp-query GPU time, synthetic request-to-present-return proxy, network bytes in/out, command/resource bytes updated on the wire, process working set and DXGI local-segment usage when available. The GPU timestamp interval encloses the draw batch and, in offload mode, the following `CopyResource`; it excludes staging `Map`, socket transfer, receiver work and `Present`. CPU submit time includes the direct `Present` return or the full offload ACK round-trip. The probe initialization field begins in main and ends after D3D device/shader/resource/query setup; the wrapper separately captures process-start-to-ready time. The proxy ends after Present returns on the direct path or after the host acknowledgement on the offload path. It is not physical input-to-photon latency. DXGI local-segment usage is adapter-level usage, not per-process GPU allocation. Power and temperature fields are blank unless an external, documented telemetry collector supplies them.

The receiver JSONL records host receive-to-present-completion time, Metal command-buffer GPU time, incoming/outgoing protocol bytes, host resident memory, and a modeled surface footprint of one input image plus three drawable images. That footprint is a size estimate from the fixed RGBA dimensions, not measured VRAM allocation. The synthetic sender's RSS is a peak process measurement and is separate from the D3D process working set.

The D3D workload owns all created D3D objects through COM smart pointers and exits on device removal, transport failure or a 15-second GPU-query timeout. The receiver validates each connection independently, reuses its fixed-size input texture, retains command/resource payloads between updates, drops a malformed session and continues accepting a new one. Restart the probe and receiver after a failed transport or device session; automated guest restart/recovery is not implemented.

## Trust boundary and outstanding work

Only the D3D probe's ordinary test process and its synthetic resources are in scope. In path A, a real Windows guest would execute both the game and its protection driver; this prototype does not verify that boundary or an anti-cheat driver. The receiver sees only the explicitly sent synthetic command/resource payload and rendered pixels. It does not inspect guest processes or memory.

In path B, a Wine process remains an ordinary host process; it is not a Windows guest process. Commercial protection across that boundary requires vendor support and an authenticated interface. No such interface is implemented here. Guest provider, lifecycle and storage-mapping code have synthetic tests; real guest execution remains environment_not_verified. Protected-process proof, driver interfaces, shared application API, zero-copy resources, power/temperature sampling, physical latency instrumentation, real recovery and real-game validation remain outstanding.

## Verification record

Recorded 2026-11-21 on an Apple silicon macOS host (Apple M4, arm64), macOS 27.2.1, Xcode 27.0 / macOS SDK 27.0, Swift 6.4, Python 3.12.8. The host had no Wine executable, D3D compiler/runtime or configured Windows VM provider, so neither the D3D binary nor a real Windows guest path could be executed on this host.

The native Metal receiver compiled and ran. Three synthetic protocol runs used 640x360 RGBA, 20 warm-up frames, 90 measured frames, a 16-record command batch and a 65,536-byte resource payload. All 270 measured frames were acknowledged; each carried 987,424 bytes to the host and received a 56-byte acknowledgement plus metrics (987,480 total bytes per frame). Raw CSV, per-frame receiver JSONL, analyzer JSON and machine metadata are preserved in data/native-synthetic/. Per-run summaries are in results.md. These values verify the receiver and data collection only; they are not D3D, Wine, guest, game, power, thermal or input-to-photon results.

The CSV analyzer's five unit tests and one run-wrapper test pass. metal_host.swift passes Swift type checking and native compilation. D3D11 source compilation and execution require a Windows SDK/runtime; Windows guest and Wine backend comparison remain pending that environment.
