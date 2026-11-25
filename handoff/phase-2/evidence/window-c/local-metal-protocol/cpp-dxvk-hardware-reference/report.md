# Local D3D11 hardware reference comparison

Owner: @DNPMBHC

The final D3D11 probe executable rendered one 1280×720 frame through the real D3D11 hardware API under host Wine DXVK. It used 16 draws, a seeded 65,536-byte InputData resource, seed 7, zero warmup frames, and GPU-complete synchronization. The result was compared against the existing final Metal command-only replay capture for frame 0.

All 921,600 RGBA pixels are byte-identical: maximum channel error 0 LSB, differing pixels 0, pixels exceeding 1 LSB 0. Both 3,686,400-byte images have SHA-256 `db3a7df7f0018da65d4d1267997201bb1e1291f1fdb8b95fdc64d613bb643d39`.

The queried adapter was Apple M4, vendor ID 4203, device ID 1009, flags 0, software flag false, selected feature level 11_0, and the Wine-reported session ID 1. The single reference frame measured 12.772542 ms D3D11 GPU time. This timing includes a cold first frame and is not a performance sample.

The Metal capture records 16 scene draws and one presentation draw, display synchronization disabled, and GPU-command-complete scope. The resource SHA-256 is `91b89c64622612ba4a9bed1bcdc76a1b5be08ae7cefc57631e506842145a0185` and the command SHA-256 is `1dbf309f16ee36af4936ba06e88276227544e929771b1d3fcd904ea825f5ac0e`.

This is supplemental host Wine hardware evidence. It is not a Windows Guest run, a WARP software reference, or paired Guest performance acceptance. Those checks remain required.

## Evidence

- `validation.json`: complete pixel comparison, image digests, source and binary digests, and engine digests.
- `metadata.json`: real DXGI adapter and session metadata.
- `reference.rgba`: native RGBA reference capture.
- `reference.csv`: single-frame GPU measurement.
- `stdout.log` and `stderr.log`: sanitized runtime diagnostics.
- `inputs/`: frozen source and validator snapshots.
- `cleanup.json`: scoped Wine prefix idle verification and frozen artifact checks.

No Metal receiver was started for this comparison. The disposable scoped Wine prefix is idle after cleanup. The final D3D11 and Metal sources and binaries retain their frozen SHA-256 bindings.
