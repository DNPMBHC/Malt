# Window A current review response

Owner: @DNPMBHC

R1 is resolved: normal root exit retains the real target Job and relay until its active process count reaches zero. Real parent/child acceptance verifies both natural completion and cancellation after root exit 0.

R2 is resolved: in-flight host automation uses a cancellable process runner with propagated deadlines and reaping. Interactive recovery uses request UUIDs and authenticated native process/Job handles. Launch suppression persists before PID delivery. Captured responses must match their request; QGA completion caches do not define target lifecycle.

R5 is resolved: rootExitCode remains independent from the session cancellation result 1223. Real normal and forced cancellation verify an already-exited root and living descendants. Forced output is explicitly truncated, and cleanupUnconfirmed cannot become success. Concurrent cancellation awaits shared cleanup, failed cleanup can retry, and terminal snapshots remain monotonic.

The final local gate has 175 counted cases: 165 passed, 10 explicitly skipped, zero failures. The bound real gate has seven passed cases, zero skips and failures. M1 includes five authenticated Guest-to-host roundtrips with exact data, identity, timeout, cancellation and error assertions. The final cleanup audit accepted the same run and independently verified no self-owned Guest processes or host services remained.

The Guest lease is released to C in guest-benchmark-handoff.json. Source and artifact fingerprints are current. acceptance-report.md lists evidence and capability boundaries. The probes execute as x64 emulation on ARM64; explicit compute does not establish transparent PE migration. Current elevated-token success does not establish a medium-token UAC flow.
