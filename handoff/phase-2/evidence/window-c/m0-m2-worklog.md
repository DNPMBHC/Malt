# M0 / M2 implementation worklog

Owner: @DNPMBHC
Date: 2026-11-22

Completed:
- Probe actual GetDesc1 and ProcessIdToSessionId startup JSON, plus HRESULTs.
- Probe command-only v2, zero Guest raster/readback path, seeded resource epochs.
- Metal v2 descriptor/cache validation and 16 real scene draws; raw RGBA capture.
- Per-frame GPU-completion option and whole-run throughput including GPU drain.
- Separate performance/capture runners and strict byte/session/GPU/SHA audits.
- 51 Python regression tests passed.
- Scoped Swift frontend/Clang build and restart safety checks passed.
- Actual Wine three-engine adapter collection passed; final-source recapture pending.
- Local native Metal 32-frame protocol and CPU auxiliary pixel check passed, max 1 LSB.
- Local Wine CPP v2 path passed preliminarily; final-source rebuild/retest in progress.

Remaining:
- Final display-sync option and matching source/binary freeze.
- Final Wine M0 recapture with archived source/binary inputs.
- Real Windows Guest M0, explicit WARP cross-API pixel validation, three-mode paired performance.
- Final evidence manifest/architecture report and digest verification.

Shared Guest remains fully stopped from this window. Maintenance owner has not
released it. No Guest exec, push, pull, scheduled task, or benchmark has started.

The local CPU pixel oracle is auxiliary. It does not satisfy the requested real
Guest D3D11 software-reference acceptance. Historical 11.35/6.19 FPS values are
not current paired measurements. GPU command completion is not physical
screen-display latency.


Final local hardening:
- 73 local regression tests passed; strict environment, workload, adapter and host identity audits.
- Guest task cleanup binds run token, process creation time and executable; stale outputs are removed before launch.
- GPU-complete main wall endpoint excludes later timestamp-query extraction; collection time is a separate field.
- Final-source Wine three-engine M0 recapture with source/binary/helper/script snapshots passed.
- Supplemental real DXVK D3D11 vs Metal frame-0 comparison passed at 0 LSB.
- Guest ownership remains with the maintenance window; module-c is ready and has performed zero Guest work.

Shared Guest handoff update: maintenance owner explicitly transferred the slot to module-a. Module-c has not executed Guest jobs. Final local 32-frame CPP/Metal validation passed with 512 scene draws and source/binary binding; only the real Guest acceptance items remain. Cross-thread scheduling message is pending direct user authorization.

Current acceptance gate update:
- Module-a explicitly released Guest cleanly to C via a timezone-aware file record; check-only validated it without Guest operations.
- Preflight uses a byte/SHA-verified staged ScriptBlock and leaves execution/security policies unchanged.
- Owned scheduled-task absence is queried after cleanup, and module-c task/command patterns are included in postflight quiescence.
- Formal runs reject truncated CSV or mismatched uploaded/archived/current probe SHA.
- Pooled frame percentiles exclude the first placeholder frame of every round: 897 intervals per mode, while FPS uses all 900 measured frames.
- Final acceptance separately audits all nine runs, four WARP pixel cases, cross-stage Session/adapter/SHA and immutable input archives.
- Real Guest preflight and acceptance are next; no Guest job has run from this window yet.
