# Command-only graphics prototype

Owner: @DNPMBHC

The prototype forwards one fixed D3D11 scene. Each frame executes 16 identical
full-screen draws. The original HLSL does not use the legacy command x/y/value
fields; command-only preserves that behavior.

## Transport

Pixel-readback retains GFX1 version 1 and the original CSV schema.
Command-only uses GFX1 version 2: a 32-byte header, optional command/resource
updates, zero pixel bytes, and a 56-byte GPU-completion acknowledgement.

The first frame initializes all state. Thereafter command-every and
resource-every control updates. Each of 16 descriptors contains eight
little-endian uint32 values:

opcode=1, vertexCount=3, vertexStart=0, reserved=0,
PayloadOffset=512, PayloadBytes=65536, ImageWidth=width, Pad=0

The combined host InputData allocation is 512 command bytes plus a 65,536-byte
resource. The shader reads eight aligned uint32 values from the resource,
XORs them, and applies the original FP32 color formula. The host issues 16
scene draws into an RGBA8 UNORM render target, then one separate presentation
draw. Normal command-only frames perform no Guest scene Draw, CopyResource,
pixel Map(READ), or pixel transfer.

## Evidence and timing

--metadata-json records the actual selected DXGI adapter via GetDesc1,
requested driver type, API HRESULTs, selected feature level, and the
ProcessIdToSessionId result. Wine session results describe Wine's API behavior;
they are not Windows desktop-session evidence.

--completion-mode gpu-complete waits for Direct's GPU event each frame.
Both TCP paths wait for the host GPU-completion ACK. The paired runner disables
host display sync to match Direct Present(0,0); the host default remains on. The probe additionally
reports whole-run throughput including the final Guest GPU drain.

GPU completion, submission/ACK intervals, and physical screen presentation are
different measurements. No recorded metric measures input-to-photon latency.
Metal time includes scene rendering and the presentation draw.

Capture runs are separate from performance runs. The performance audit rejects
capture-configured host samples. Guest GPU time is empty in command-only.

## Reproducible commands

Run from the workspace root:

~~~sh
./graphics-lab/build_probe.sh
./graphics-lab/restart_metal_host.sh --build-only
python3 graphics-lab/run_m0_fingerprints.py --host-only
~~~

Once the shared Guest maintenance owner has released it:

~~~sh
python3 graphics-lab/run_m0_fingerprints.py --guest-only
python3 graphics-lab/run_guest_pixel_validation.py
python3 graphics-lab/run_guest_m2_benchmark.py
~~~

The Guest runners use one interactive session and verify the uploaded PE SHA.
Every TCP run invokes restart_metal_host.sh to rebuild and restart the host.
All outputs are confined to graphics-lab or window-c evidence directories.

The pixel check compares actual Guest D3D11 WARP RGBA frames with actual Metal
render-target frames at native 1280 by 720 resolution. Every channel, including
alpha, must differ by at most one LSB. Seeded resource runs cover initial,
updated, and retained resource epochs. CPU reference checks are auxiliary.

Historical 11.35/6.19 FPS values remain historical references. Current paired
measurements require the same probe binary, Guest session, resolution, and
completion boundary. Source, binary, script, frame, CSV, and JSONL digests
bind each run to its inputs.
