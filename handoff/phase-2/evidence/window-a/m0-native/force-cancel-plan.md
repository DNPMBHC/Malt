# module-b emergency cleanup acceptance

Maintainer: @DNPMBHC

This plan requires a real Windows Guest execution by the root coordinator. Source inspection and a successful build are separate from these runtime results.

1. Launch a fresh UUID with the self-owned probe arguments `--spawn-child 60000 --sleep-ms 1000 --exit-code 42`. Wait for `running`, a real target PID, and `spawnedChildPID` in the captured probe output.
2. Invoke the fixed command `desktop-helper.exe force-cancel <request-id>` through a fresh Guest command. Do not read cached QGA results for the persistent broker PID.
3. Require a matching UUID and unchanged controller/target/session/creation identity. A confirmed result must have `state: exited`, `cancelled: true`, session `exitCode: 1223`, a real `rootExitCode`, `rootExited: true`, `activeProcessCount: 0`, and both truncation flags true.
4. Query independent native status and require that same committed terminal result. Independently check the captured self-owned child PID has exited; PID alone is auxiliary evidence because the native target-job handle supplies tree accounting.
5. Repeat the same `force-cancel` and require an unchanged terminal record. A pre-launch `force-cancel` must instead persist explicit `launchSuppressed`; a late launch of that UUID must create no target.
6. A missing historical controller-owned job handle, an unavailable broker handle, or an identity mismatch must return `failed` / `cleanupUnconfirmed`. Such a result is never counted as confirmed cleanup even if best-effort broker termination occurred.

Only explicit desktop execution and self-owned process-tree cleanup are covered. The x86_64 probe uses the ARM64 Guest's x64 emulation layer; this does not verify native ARM64 execution or transparent PE migration.

7. With no active unlocked desktop, retain the original launch failure and invoke emergency cleanup. Require persistent `failed` / `launchCancelled`, `cancelled: true`, `launchSuppressed: true`, and `targetPID: 0`, rather than replacing the original cause with unconfirmed cleanup. A stale active target-zero snapshot must be reread after authenticated broker exit under the cancellation lock; if a target binding appears, suppression is forbidden.
8. Measure native emergency elapsed waiting against the common five-second budget. Lock acquisition and controller/root/job waits share that budget. PID-reuse cases must never terminate the unrelated replacement process.
