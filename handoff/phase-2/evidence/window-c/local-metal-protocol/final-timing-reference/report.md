# Final timing D3D11 hardware reference comparison

Owner: @DNPMBHC

The final timing revision rendered a real D3D11 hardware reference through host Wine DXVK in a newly initialized independent prefix. Its 1280×720 frame 0 was compared with the previously stored Metal command-only replay frame 0; the Metal source, binary, and capture were unchanged.

All 921,600 RGBA pixels are byte-identical: maximum error 0 LSB, differing pixels 0, pixels exceeding 1 LSB 0. Each frame is 3,686,400 bytes. Both image SHA-256 values are `db3a7df7f0018da65d4d1267997201bb1e1291f1fdb8b95fdc64d613bb643d39`.

The queried adapter was Apple M4, software flag false, feature level 11_0. The cold first-frame D3D11 GPU measurement is 18.670166 ms. This single cold capture is a functional reference and does not establish throughput. The final timing scope completes each frame on the GPU and excludes deferred timestamp query extraction from the main throughput endpoint; GPU completion does not measure physical screen display.

## Frozen artifacts

- D3D11 source: `11fc000464f0dcf98aec3044c4d956a2b74ce491fc4d69567bf252bbec64af74`.
- D3D11 executable: `09bb190bf5d763f9749345300b937728db886a4ec26c32c361a920c565cf1bee`.
- Metal source: `cf6d0f50b9b68dcde7324f12423d3de242950aa35fe25b2cf0d2b0afdd74c734`.
- Metal binary: `9b0fefb3c181125c943f6d7b8c6f6fdf3ebade939f80cd41f58f3dc17c658a38`.
- Final source freeze JSON: `db307c1f1a409f18c54c36a082687c8ff75353683e3ef56b13aa9e965d274e96`.

`validation.json`, `metadata.json`, `reference.rgba`, `reference.csv`, sanitized runtime logs, `inputs/`, and `cleanup.json` provide the complete evidence. The previous `cpp-dxvk-hardware-reference/` evidence remains preserved; its earlier source and executable binding should be interpreted separately.

The independent prefix `graphics-lab/build/final-timing-reference-runtime/prefix` was verified idle after scoped cleanup. The main M0 prefix was not used or stopped. No Guest operation or Metal receiver start/restart occurred. This is host Wine hardware evidence; the Guest/WARP software reference and paired Guest performance checks remain required.
