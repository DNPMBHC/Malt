# Final C++ command-only protocol validation

Owner: @DNPMBHC

The final C++ executable sent 32 command-only frames through host Wine DXVK to a Metal receiver rebuilt and restarted by `graphics-lab/restart_metal_host.sh`. The run used 1280×720, seed 7, resource and descriptor cadence 30, and native captures for frame 0, 30, and 31. Display synchronization was explicitly disabled.

All 32 frames completed real host Metal GPU execution: 16 scene draws and one presentation draw per frame, totaling 512 scene draws and 32 presentation draws. Every frame used protocol v2, transferred zero pixel bytes, received its 56-byte GPU-completion ACK, and matched its descriptor and resident resource fingerprints. No D3D11 scene GPU timing appears in the C++ CSV for command-only mode.

The descriptor prefix is 512 bytes and the resource buffer is 65,536 bytes. Frames 0 and 30 refreshed both; the other 30 frames retained their state. Application request plus ACK bytes were 66,136 per refresh frame and 88 per retained frame, totaling 134,912 bytes for the run.

All 921,600 pixels in each of captures 0, 30, and 31 passed the independent scalar FP32 CPU auxiliary oracle with maximum error 1 LSB and zero pixels exceeding tolerance. Frame 0 differs from frame 30; frame 30 and 31 are byte-identical, confirming both resource refresh and subsequent retention.

Frame 0 also matches the final timing revision's real host Wine DXVK D3D11 hardware reference byte-for-byte: maximum error 0 LSB and image SHA-256 `db3a7df7f0018da65d4d1267997201bb1e1291f1fdb8b95fdc64d613bb643d39`. That reference remains stored in `final-timing-reference/`.

The real Metal GPU interval ranged from 0.286375 to 11.328750 ms, with median 7.525896 ms. This functional run includes capture work on three frames and is not a throughput benchmark. GPU completion scope does not measure physical screen display.

## Frozen bindings

- D3D11 source: `11fc000464f0dcf98aec3044c4d956a2b74ce491fc4d69567bf252bbec64af74`.
- D3D11 executable: `09bb190bf5d763f9749345300b937728db886a4ec26c32c361a920c565cf1bee`.
- Metal source: `cf6d0f50b9b68dcde7324f12423d3de242950aa35fe25b2cf0d2b0afdd74c734`.
- Rebuilt Metal binary: `9b0fefb3c181125c943f6d7b8c6f6fdf3ebade939f80cd41f58f3dc17c658a38`.
- Final source freeze JSON: `db307c1f1a409f18c54c36a082687c8ff75353683e3ef56b13aa9e965d274e96`.

`validation.json`, `receiver-start.json`, `host.jsonl`, `frames.csv`, `metadata.json`, `host-captures/`, `frame-*-cpu-comparison.json`, sanitized runtime logs, and `inputs/` provide complete evidence. Previous validation directories remain preserved.

The owned receiver was stopped only after PID and executable verification. The independent prefix `graphics-lab/build/final-timing-reference-runtime/prefix` was scoped-cleaned and verified idle again after the run. `cleanup.json` records those checks. Receiver ownership has been returned to the main task. The main M0 prefix and Windows Guest were not operated.

This is local host Wine and Metal evidence. The Windows Guest/WARP software pixel reference and paired Guest performance acceptance remain required.
