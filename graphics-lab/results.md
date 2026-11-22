# Task 03 results

## Scope and status

This record separates source implementation from the parts actually run. It does not claim D3D11, Wine, Windows guest, anti-cheat, or game validation.

| Area | Status | Evidence |
| --- | --- | --- |
| D3D11 workload and data collection | Implemented, not built or run here | d3d11_probe.cpp contains direct DXGI and TCP-offload modes, D3D timestamp queries, CPU/working-set sampling, and byte counters. The workload sets triangle-list topology. A Windows SDK/D3D runtime is unavailable on the test host. |
| Host presentation and protocol | Built and run locally | metal_host.swift compiled with the installed Swift/Metal toolchain and accepted three local synthetic sender runs. |
| Wine public backend comparison | Not run | Wine and its D3D backends are not installed. No cold-start, shader-cache, or steady-state Wine measurements are available. |
| Windows guest transport | Not run | environment_not_verified: provider code exists, but no real guest is configured on this host. The local TCP test does not cross a guest boundary. |
| Protection-driver boundary | Not implemented or verified | No guest driver or protected process was present. The D3D probe runs as an ordinary process. |
| Vendor support and real-game validation | Not available | No commercial protection component or real game was tested. |

## Graphics path layers and trust boundary

| Layer | Self-owned D3D prototype | macOS receiver | Implemented boundary |
| --- | --- | --- | --- |
| API | The probe calls D3D11/DXGI. Direct mode uses a DXGI swap chain; offload mode uses a D3D11 render target and staging readback. | The receiver uses AppKit, CAMetalLayer and Metal to present RGBA images. | Under Wine, the selected public Wine backend translates the D3D API to the host graphics API. Wine was absent on this host, so DXVK and D3DMetal were not measured. |
| Device | `D3D11CreateDevice` requests the hardware device exposed by the test environment. | `MTLCreateSystemDefaultDevice` creates the host Metal device. | No guest virtual GPU driver was implemented or installed. A user-mode D3D program or API translator is not a substitute for one. The TCP smoke sender also does not create a D3D device. |
| Resource ownership | The test process owns D3D devices, textures, buffers, queries and views through COM references. Offload copies the render target to a staging texture and maps it to CPU memory. | The receiver owns packet buffers, a reusable Metal input texture and command queue; CAMetalLayer supplies drawables. | Resources are reconstructed by pixel copy; no cross-process or cross-device texture handle is shared. The reported host texture footprint is a model, not a measured GPU allocation. |
| Synchronization | The D3D11 immediate context queues draws, CopyResource and staging Map; the synchronous readback waits for readable data. | The receiver sends an ACK only after the Metal command buffer completes. | The TCP request/ACK is the prototype's per-frame round-trip fence. There is no shared GPU fence, DMA fence or asynchronous multi-frame queue. |
| Transport | Offload sends a batched set of 16-byte command records, optional resource payload and tightly packed RGBA pixels per frame. | The receiver validates the protocol and opcodes, retains the latest command/resource payloads, and presents only the received pixels. | The receiver does not execute D3D commands and does not use the resource payload as a draw input. This measures CPU staging plus TCP image transport. |

The task 01/02 protection boundary requires the game and its protection driver to run inside the same real Windows guest when validating protected execution with graphics offload. A Wine process remains a host user-mode process and is not that guest. No guest backend was configured here, so there is no guest D3D device, real guest-to-host transfer or protection-scope validation. Shared application interfaces remain owned by task 05; this experiment did not change shared models.

## Metric coverage

This table separates measurements from the native synthetic receiver from the requested D3D/Wine/guest measurements.

| Metric | Native synthetic receiver | Wine D3D | Windows guest D3D |
| --- | --- | --- | --- |
| Mean FPS, P95/P99 frame interval | Measured in three 640x360 synthetic runs; FPS is derived from the mean interval and interval sample count is 89/90. | Not measured | Not measured |
| Cold/hot startup and shader warm-up | Receiver setup and synthetic warm-up are recorded; no cold/hot cache comparison exists. | Not measured | Not measured |
| CPU/GPU time | Synthetic sender CPU time and host Metal command GPU time are available; these are not D3D guest CPU/GPU results. | Not measured | Not measured |
| Input-to-present latency | Only a synthetic frame-request-to-software-ACK proxy and host receive-to-Metal-completion time are available; no physical input/scan-out measurement exists. | Not measured | Not measured |
| Transfer volume | TCP application-payload bytes are recorded. The resource resend comparison is synthetic and does not represent GPU resource sharing. | Not measured | Not measured |
| Resource use | Process RSS, host resident memory and a dimension-based texture footprint estimate are recorded; GPU memory allocation was not measured. | Not measured | Not measured |
| Power and temperature | Not sampled | Not measured | Not measured |

The three retained receiver baselines used macOS 27.2.1 (build 26B131), Apple M4 arm64, Xcode/macOS SDK 27.0, Swift 6.4 and Python 3.12.8; loopback TCP; 640x360 RGBA; 20 synthetic warm-up frames; 90 measured frames; 16 command records; and a 65,536-byte resource sent every frame. This is a deterministic protocol/image-presentation scene, not a D3D quality preset; display refresh was not recorded.

The D3D source defines a fixed workload (default 1280x720, 16 draws, 64 KiB resource, 120 warm-up frames and 900 measured frames) and a process-start-to-probe-ready wrapper. The host lacks a Windows SDK/D3D runtime, so the probe has not been compiled or run. No cold/hot cache samples exist. Wine/backend versions, guest provider, display refresh, D3D image correctness, guest CPU/GPU, physical latency, power and temperature were not collected. The available data therefore cannot rank Wine against a guest path or establish a performance improvement.

## Reproducible local synthetic run

All runs used the same receiver and sender build on 2026-11-21: Apple M4 / arm64, macOS 27.2.1 (build 26B131), Xcode 27.0, macOS SDK 27.0, Swift 6.4 and Python 3.12.8. Sender and receiver communicated over 127.0.0.1 TCP. Each baseline run had 20 warm-up frames then 90 measured frames at 640x360 RGBA, 16 command records and 65,536 resource bytes per frame. The host presented each generated image through Metal. These are native synthetic protocol results, not D3D results.

An earlier draft listed macOS 27.2 after reading the Darwin kernel release. This was a labeling error; the product version and build above were checked with sw_vers and are preserved in machine.json.

| Run | Connect/setup ms | Warm-up ms | Derived FPS | Frame interval mean / P95 / P99 ms | Synthetic request-to-present-return mean / P95 / P99 ms | Host receive-to-present mean / P95 ms | Metal GPU mean / P95 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 20.036 | 401.635 | 36.731 | 27.225 / 64.796 / 66.369 | 27.462 / 64.632 / 66.319 | 26.481 / 63.467 / 65.168 | 0.168 / 0.226 / 0.235 |
| 2 | 16.085 | 552.633 | 41.021 | 24.378 / 65.932 / 66.461 | 24.458 / 65.883 / 66.421 | 23.353 / 64.600 / 65.763 | 0.155 / 0.236 / 0.247 |
| 3 | 18.362 | 476.104 | 41.685 | 23.989 / 64.366 / 67.957 | 23.719 / 64.216 / 67.898 | 22.599 / 63.007 / 66.716 | 0.181 / 0.239 / 0.244 |

The per-run synthetic sender CPU-time means were 0.772, 0.820 and 0.940 ms/frame. Mean sender peak-RSS samples were 28.9, 32.4 and 30.0 MiB; mean host resident-memory samples were 83.3, 83.8 and 84.3 MiB. Power, temperature and device-memory telemetry coverage was zero. These process/host readings do not represent D3D or guest resource use.

Every measured frame sent 987,424 bytes to the host: a 32-byte header, 256-byte command batch, 65,536-byte resource payload and 921,600-byte RGBA image. The host returned 56 bytes of acknowledgement and timing/memory metrics. Total observed protocol traffic was 987,480 bytes per frame, 88,873,200 bytes per 90-frame run, and 266,619,600 bytes across all measured runs. Warm-up frame traffic is excluded from the CSV summaries. The 90-frame interval statistic has 89 samples because the first measured row has no preceding measured-row timestamp.

**Instrument field discrepancy:** the preserved original receiver JSONL files report ack_bytes_out as 32 bytes, counting only the ACK header. The client-side CSV records network_bytes_in as 56 bytes per frame because it reads the 32-byte header plus a separate 24-byte telemetry block. The total-traffic numbers above use the client-side byte counts and include all 56 response bytes. The original JSONL files were retained unchanged; their SHA-256 values are in sha256-manifest.json. Receiver source logging is now corrected to report 56 total response bytes and to split header and telemetry lengths. See instrumentation-note.json for affected evidence names and interpretation.

The corrected logger was separately optimized-compiled and exercised for three smoke frames. instrumentation-fix-smoke.jsonl records ack_bytes_out=56, ack_header_bytes_out=32 and ack_metrics_bytes_out=24, while the paired CSV records network_bytes_in=56. This smoke evidence verifies the logger repair and is not included in the baseline performance table.

A separate 320x180 payload-cadence comparison held resolution, 16 commands, 65,536-byte resource size, 5 warm-up frames and 60 measured frames constant. Sending command and resource payloads every frame produced 17,776,800 total network bytes (296,280 per measured frame). Sending the resource every 30 frames, while still sending commands every frame, produced 13,975,712 bytes (232,928.5 per frame) and exactly two measured resource updates. On 2026-11-22, a follow-up sent both command and resource payloads every 30 frames and produced 13,960,864 bytes (232,681.1 per measured frame), with exactly two measured updates of each payload. Its synthetic frame interval was 8.360 ms mean, 9.294 ms P95 and 9.522 ms P99; request-to-ACK proxy was 8.339 / 9.263 / 9.492 ms mean/P95/P99, sender CPU time averaged 0.197 ms/frame, host Metal GPU time averaged 0.118 ms, sender peak RSS averaged 19.8 MiB, and host resident memory averaged 81.3 MiB. Power, temperature and D3D GPU time were unavailable. The receiver retained each last payload between updates. Raw evidence for the follow-up is `cadence-both-every-30.csv`, `cadence-both-every-30-host.jsonl`, `cadence-both-every-30-summary.json` and `cadence-both-every-30-meta.json` under `data/native-synthetic/`; their byte sizes and hashes are recorded in the manifest. This demonstrates lower protocol traffic for these synthetic retained-payload cases only; D3D buffers are still updated locally every frame, and the test does not establish GPU-resource sharing or a performance gain for a game.

The modeled host texture footprint was 3,686,400 bytes: one input image plus three same-sized drawable surfaces. This is a dimension-based estimate, not measured VRAM allocation. Peak observed client RSS high-water marks were 31.4, 34.7 and 30.3 MiB; host resident-memory peaks were 83.5, 84.0 and 84.5 MiB. The sender uses macOS process peak-RSS reporting, while the receiver samples task resident memory, so those values are not perfectly equivalent memory measurements.

The synthetic run varied between 36.7 and 41.7 derived FPS, with frame-time P95 around 64-66 ms. This is a high-variance local sender/receiver measurement; display refresh rate was not captured, and scheduler or drawable stalls may contribute. It cannot be compared to a D3D guest frame rate or treated as a stable performance claim. The request-to-present-return metric ends at a software acknowledgement after Metal command-buffer completion; it does not measure display scan-out or physical input-to-photon latency. Power and temperature were not sampled.

## Verification

- On 2026-11-22, `python3 -B -m unittest discover -v` from `my-project/graphics-lab` passed all 8 tests. This includes the five analyzer tests, the startup-wrapper test, the MetalFX SDK typecheck, and a regression test that checks local workspace, home, temporary, and SDK path redaction.
- The MetalFX check resolved the active SDK with `xcrun --sdk macosx --show-sdk-path` and ran `xcrun swiftc -typecheck -sdk <macOS SDK> -module-cache-path <temporary directory> <three dynamically discovered Swift sources>`. It discovered the unique Xcode project and its unique local Swift package without embedding their directory names in the test.
- Verified toolchain: Xcode 27.0 (build 27A266a), macOS SDK 27.0, Apple Swift 6.4, macOS 27.2.1 (build 26B131), arm64. The check is a local SDK typecheck of three experiment source files; it does not build or run a Windows D3D program and provides no guest graphics performance data.
- Swift type checking and optimized native compilation of the Metal receiver passed.
- The receiver processed the three baseline runs and both earlier resource-cadence cases (460 valid frames), kept each connection's frame sequence, accepted the D3D-compatible command record format, retained resource updates between frames, returned all acknowledgements, and remained available for subsequent sessions. A deliberately malformed handshake was rejected; the following valid run succeeded. A new 320x180 protocol smoke also verified retention and two measured updates each for command and resource payloads at a 30-frame resend interval (60 measured frames).
- The CSV analyzer validated all three generated run files and produced frame percentiles, traffic totals, memory samples, and explicit missing power/temperature coverage.
- Original sender CSV files, corresponding receiver JSONL files, analyzer JSON summaries, machine metadata, protocol checks, an instrument discrepancy note and SHA-256 hashes are preserved under data/native-synthetic/ for independent re-analysis. The old JSONL hashes were checked before adding the note and are unchanged; the new cadence evidence is included in the updated manifest.
- A separate corrected-logger smoke JSONL/CSV pair is also preserved; it verifies the ACK field accounting without modifying the original baseline JSONL evidence.
- The D3D11 source, Windows compiler output, direct-present baseline and actual D3D offload CSV remain unverified because this host lacks a Windows SDK and D3D runtime.

## Follow-up needed for a real comparison

Run the D3D executable on a Windows system or configured Windows guest and collect at least three runs for each installed public Wine D3D backend and each guest presentation mode. Record exact OS, CPU/GPU, driver/backend versions, resolution, display refresh, workload settings and cache state. Use a host-only or isolated network for TCP; the prototype has no authentication or encryption. Add independently documented power/temperature collection and an external high-speed input-to-photon measurement if those metrics are required. Do not infer commercial protection compatibility from this ordinary-process probe.

---

## Phase 2 Window C Update (2026-11-22)

### Five-Dimensional Status Separation

| Dimension | Status | Evidence & Boundary |
| --- | --- | --- |
| Code implementation | Completed (C1 + C2) | `d3d11_probe.cpp` MinGW-w64 compatible; `metal_host.swift` dynamic resource policy + MetalFX spatial gate + QoS-isolated pacing; `HostResourcePolicy.swift` consumer-backed launch policies; `restart_metal_host.sh` auto rebuild-and-restart script. |
| Local synthetic verification | Passed | `metal_host` policy A/B & fallback (15 runs, 5 arms × 3 rounds); `graphics-lab` unittest 10/10 (including `test_metalfx_sdk_compile.py`); `WhiskyKit` Host XCTests 0 failures; Strict SwiftLint 0 violations. |
| Real Wine / Guest verification | Wine: **Verified (12 paired runs)**<br>Windows Guest: **Pending Window A (C3)** | Real PE32+ `d3d11_probe.exe` executed under Wine 11.0 comparing DXVK 1.10.3 (MoltenVK 1.2.1) vs D3DMetal (Apple GPTK 4.0-1) across 3 alternating rounds × cold/hot cache (10,800 measured frames). Local Wine `offload_tcp` smoke (1280×720, 120 frames) also verified; **cross-VM Windows Guest offload remains unverified until Window A delivers a Windows Guest**. |
| Vendor support | Not available | No commercial anti-cheat vendor interface or driver contract. |
| Real game validation | Not run | Self-owned deterministic D3D11 probe only; no real game benchmarked. |

### 1. Real `d3d11_probe.exe` Build & Immutable Digests

Built on Apple M4 / macOS 27.2.1 (26B131) via `graphics-lab/build_probe.sh` using Homebrew `mingw-w64` (`x86_64-w64-mingw32-g++ (GCC) 16.2.0`), statically linked (`-static -static-libgcc -static-libstdc++`) so the PE32+ import table references only standard Windows system DLLs (`d3d11.dll`, `D3DCOMPILER_47.dll`, `KERNEL32.dll`, `USER32.dll`, `WS2_32.dll`, `api-ms-win-crt-*`).

- `d3d11_probe.cpp` SHA-256: `011adfc0422cea672d4014865451ee0c15e17e80f3f13d9d014bf5ac3567d34f`
- `build/d3d11_probe.exe` SHA-256: `4498e38244e7b06ecfaecfa6d025bcb44d9c9cfe2c9487ae8e38cd0713b6c34e`
- `metal_host.swift` SHA-256: `43159ad0f49076f28c1b6180c01636d0ffda09e3f4bb4f1aa94e78a474ea1784`

### 2. Paired Wine Benchmark: DXVK vs D3DMetal (1280×720, 120 Warm-up + 900 Measured × 3 Rounds)

Raw sanitized CSVs, `run_probe.py` startup JSONs, per-run summaries, and full SHA-256 manifest (binding source, probe binary, Wine, DXVK, MoltenVK, and D3DMetal library digests) are archived in `handoff/phase-2/evidence/window-c/wine-dxvk-vs-d3dmetal/`.

- **Runtime versions**: Wine `wine-11.0-ge1cd80458f5` (x86_64 via Rosetta 2); DXVK `1.10.3 (cxaddon-1.10.3-1-25-g737aacd)` + `MoltenVK 1.2.1` (`D3D_FEATURE_LEVEL_11_0`, note: MoltenVK 1.4.1 omitted `geometryShader` required by DXVK 1.10.3); D3DMetal `Apple GPTK 4.0-1`.
- **Cache isolation**: Each round used a fresh disposable `WINEPREFIX` and alternating backend order (`dxvk`/`d3dmetal`, `d3dmetal`/`dxvk`, `dxvk`/`d3dmetal`). DXVK cold runs started with an empty `DXVK_STATE_CACHE_PATH` (verified 0 → 219 bytes `.dxvk-cache` written); D3DMetal used an isolated prefix and `XDG_CACHE_HOME` while leaving the shared macOS system Metal pipeline cache untouched.

| Backend & Cache | Start→Ready mean ms | Probe Init mean ms | Warm-up (120f) mean ms | Derived FPS mean | Frame Interval Mean / P50 / P95 / P99 ms | D3D GPU mean ms (coverage) | Process RSS mean MiB | DXGI Local Mem mean MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| DXVK cold (3 rounds) | 4121.92 | 688.31 | 922.86 | 324.12 | 3.095 / 2.683 / 7.596 / 9.677 | 2.016 (100%) | 68.13 | 223.72 |
| DXVK hot (3 rounds) | 4375.94 | 538.02 | 802.78 | 335.31 | 2.984 / 2.704 / 6.928 / 9.936 | 2.296 (100%) | 75.84 | 223.72 |
| D3DMetal cold (3 rounds) | 4310.55 | 969.70 | 779.37 | 309.55 | 3.275 / 2.615 / 8.206 / 9.690 | N/A (0%)* | 77.25 | 67.34 |
| D3DMetal hot (3 rounds) | 3804.89 | 574.37 | 762.35 | 353.63 | 2.829 / 2.574 / 7.199 / 9.698 | N/A (0%)* | 81.99 | 67.34 |

*Apple D3DMetal (GPTK 4.0-1) explicitly logs `Unsupported: D3D11 timestamp query`; missing GPU timing values remain `null` rather than estimated. Power and temperature remain `null` (0% coverage).

Key observations from real D3D11 execution:
- **Steady-state throughput**: Hot D3DMetal averaged 353.63 FPS (+5.5% over hot DXVK's 335.31 FPS) with lower P50 interval (2.574 vs 2.704 ms), whereas hot DXVK achieved slightly lower P95 (6.928 vs 7.199 ms) and full D3D11 timestamp-query support.
- **Warm-up & init**: Both backends reduced internal D3D initialization latency on hot runs (D3DMetal: 969.7 → 574.4 ms; DXVK: 688.3 → 538.0 ms), and DXVK warm-up dropped from 922.9 to 802.8 ms after `.dxvk-cache` population. Outer launch-to-ready (~3.8–4.4 s) is dominated by cold `wineserver` startup under Rosetta 2.
- **Adapter video memory**: DXVK/MoltenVK reported ~223.7 MiB DXGI local usage vs D3DMetal's ~67.3 MiB for the identical 1280×720 scene.

### 2.1 Three-Engine Incremental Update: Adding Open-Source DXMT v0.80 (DXMT vs D3DMetal vs DXVK)

Archived in `handoff/phase-2/evidence/window-c/wine-dxmt-three-engine/manifest.json` (merging 6 new DXMT cold/hot runs with the 12 unchanged baseline DXVK/D3DMetal runs using the exact same `d3d11_probe.exe` SHA-256 `4498e38244e7b06ecfaecfa6d025bcb44d9c9cfe2c9487ae8e38cd0713b6c34e`, 1280×720, 120 warm-up + 900 measured frames × 3 rounds = 18 runs / 16,200 measured frames total).

- **DXMT runtime & digests**: `dxmt-v0.80` (`dxmt-wine-builtin-7641370`), `D3D_FEATURE_LEVEL_11_1`; `d3d11.dll` SHA-256 `1cbe930e2370c4382ac4b435faf8cc563943324cfade33380cc6de0b8d94d801`, `dxgi.dll` SHA-256 `3831a078756a054027413e0c9c901a28a0a57a8dd3f327d3e2fb41a8616d251c`, `winemetal.so` SHA-256 `76843f2ab3226a9c7dc107c9d4d9ace9593ec7210edf9e74d5a6cf146384c52a`.
- **DXMT cache isolation**: Disposable `WINEPREFIX` + `DXMT_SHADER_CACHE=1` + isolated empty `DXMT_SHADER_CACHE_PATH` + `DXMT_USE_DEFAULT_METAL_CACHE=0` per round (verified `shaders_320.db` populated 0 → 16,384 bytes on cold pass and reused on hot pass).

| Backend & Cache (3 rounds each) | Feature Level | Start→Ready mean ms | Probe Init mean ms | Warm-up (120f) mean ms | Derived FPS mean | Frame Interval Mean / P50 / P95 / P99 ms | D3D GPU mean ms (coverage) | Process RSS mean MiB | DXGI Local Mem mean MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| DXMT v0.80 cold | `11_1` | 4230.34 | 702.89 | 1016.33 | 366.98 | 2.733 / 1.991 / 8.100 / 10.155 | 2.431 (90.6%) | 71.56 | 20.15 |
| DXMT v0.80 hot | `11_1` | 4177.60 | 395.90 | 833.74 | 344.96 | 2.904 / 1.983 / 8.317 / 10.064 | 2.674 (92.5%) | 73.00 | 19.91 |
| D3DMetal GPTK 4.0-1 cold | `11_1` | 4310.55 | 969.70 | 779.37 | 309.55 | 3.275 / 2.615 / 8.206 / 9.690 | N/A (0%)* | 77.25 | 67.34 |
| D3DMetal GPTK 4.0-1 hot | `11_1` | 3804.89 | 574.37 | 762.35 | 353.63 | 2.829 / 2.574 / 7.199 / 9.698 | N/A (0%)* | 81.99 | 67.34 |
| DXVK 1.10.3 + MoltenVK 1.2.1 cold | `11_0` | 4121.92 | 688.31 | 922.86 | 324.12 | 3.095 / 2.683 / 7.596 / 9.677 | 2.016 (100%) | 68.13 | 223.72 |
| DXVK 1.10.3 + MoltenVK 1.2.1 hot | `11_0` | 4375.94 | 538.02 | 802.78 | 335.31 | 2.984 / 2.704 / 6.928 / 9.936 | 2.296 (100%) | 75.84 | 223.72 |

Three-engine comparative takeaways (data-backed, no extrapolation to real games):
- **Lowest median frame time & VRAM footprint**: DXMT achieved the lowest P50 frame interval (~1.98–1.99 ms vs D3DMetal 2.57–2.62 ms and DXVK 2.68–2.70 ms), fastest hot probe initialization (395.9 ms, −43.7% vs cold), and lowest DXGI local video memory footprint (**19.9–20.2 MiB**, ~3.4× lower than D3DMetal and ~11× lower than DXVK/MoltenVK) while supporting `D3D_FEATURE_LEVEL_11_1` and >90% D3D11 timestamp-query coverage.
- **Tail latency & DX12 coverage**: Hot D3DMetal delivered the highest hot mean FPS (353.63 FPS) and remains the sole DX12 backend; hot DXVK delivered the tightest P95 tail interval (6.928 ms) and 100% timestamp-query coverage, supporting its role as compatibility fallback.
- **Routing alignment**: These measurements directly justify the deterministic three-engine router implemented in `HostWineBackendRouter.swift` (`DX12 → D3DMetal`, `DX11 performance-first → DXMT`, `DX11 compatibility fallback → DXVK`).

### 3. `metal_host.swift` Dynamic Resource Policy A/B & Fallback Verification

Archived in `handoff/phase-2/evidence/window-c/metal-host-policy-ab/` (640×360 loopback `synthetic_client.py`, 15 warm-up + 90 measured frames × 3 rounds per arm, restarted cleanly before every run via `restart_metal_host.sh`).

**Engineering finding & fix**: Putting the receiver pacing thread itself onto `.utility` / `.background` QoS with `usleep` triggered aggressive macOS XNU timer coalescing (throttling 60 FPS to 18.9 FPS and 30 FPS to 10.0 FPS). Separating QoS—keeping presentation pacing on `.userInitiated` with `nanosleep` anchored to frame start while moving asynchronous JSONL telemetry writes onto the policy-governed QoS queue—resolved the coalescing stall:

| Arm (3 rounds each) | Policy QoS | Target FPS Cap | Render Path | Derived FPS mean | Frame Interval Mean / P50 / P95 ms | Host Metal GPU mean ms |
| --- | --- | ---: | --- | ---: | ---: | ---: |
| `baseline-off` | `userInitiated` | none | `direct_blit` | 119.98 | 8.335 / 8.359 / 8.788 | 0.071 |
| `maxperf-metalfx-spatial` | `userInitiated` | none | `metalfx_spatial` | 120.01 | 8.333 / 8.345 / 8.651 | 0.378 |
| `balanced-60fps` | `utility` | 60 | `direct_blit` | 51.26 | 19.507 / 19.067 / 23.812 | 0.525 |
| `conserve-30fps` | `background` | 30 | `direct_blit` | 26.93 | 37.134 / 37.378 / 41.022 | 0.530 |
| `fallback-off` | `userInitiated` | none | `direct_blit` | 120.01 | 8.332 / 8.315 / 8.952 | 0.093 |

### 4. Real `d3d11_probe.exe` Loopback `offload_tcp` & Game Mode Bundle Observation

Archived in `handoff/phase-2/evidence/window-c/gamemode-and-offload/`:
- **Real `d3d11_probe.exe` offload smoke (local Wine D3DMetal → native fullscreen `GraphicsLabHost.app`)**: 1280×720 RGBA, 30 warm-up + 120 measured frames, `--command-every 30 --resource-every 30`. Sustained **119.95 FPS** (mean interval 8.337 ms, P50 8.286 ms, P95 9.673 ms, P99 10.042 ms), transmitting 442,641,728 bytes (~422.1 MiB; ~3.69 MB/frame) with host receive-to-present mean 8.040 ms and Metal GPU mean 0.395 ms. Live `--resource-policy auto` resolved to `maximum-performance` (`policy_source=live`). **Scope boundary**: this is a host loopback Wine process test verifying `offload_tcp` end-to-end mechanics; it does not cross a Windows Guest VM boundary.
- **Game Mode observation on macOS 27.2.1**: `GraphicsLabHost.app` declares `LSSupportsGameMode=true` and `LSApplicationCategoryType=public.app-category.games`, verified by `HostGameModeEvidence` as `declaration=enabled` and `platform_eligible=true`. Because macOS 27 SDK provides no public activation query API and no manual Game Overlay UI confirmation was recorded, `activation` remains `unknown` and `wine_child_benefit` remains `unmeasured`.

