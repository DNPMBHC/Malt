# module-b desktop helper implementation review

Maintainer: @DNPMBHC

Review status: source inspection and strict x64 cross-compilation completed. Real Guest execution is pending the root coordinator's VM availability check. No VM was started, stopped, or modified by this subtask.

## Process identity and cancellation

- The persistent Session 0 controller PID is the QGA launch PID. It is never substituted for the target PID.
- The relay retains the real target process handle until the controller acknowledges its final result. This closes the rapid-exit race where the target object could disappear before its PID and creation time are checked.
- The controller independently opens that process, checks its creation time and Windows Session ID, and compares the handle's actual exit code before storing `exited`.
- The authority record contains a decimal-string `targetCreationTime`; the host's Swift schema must validate it along with stable request ID, target PID, controller PID, and Session ID across snapshots.
- A controller job contains the relay and descendants, while the relay job contains the target and its descendants. Both use kill-on-close. Relay faults, controller faults, and target-spawn failures cannot become wrapper success evidence.
- A root exit no longer closes the target job. The relay remains running until its job's active process count reaches zero; an installer or launcher child remains alive naturally. Separate `rootExited`, `rootExitCode`, and `activeProcessCount` fields preserve this distinction. In the authenticated starting frame, the relay supplies its real target-job handle. The controller duplicates that handle from the verified relay with only query and termination rights and checks that the suspended root is a member before sending resume or cancellation. It independently checks that this target job is empty before accepting completion. The outer controller job may include console/control processes and is not used as a proxy for the real target tree.
- Cancellation requests terminate the target job and wait for the real target handle. Repeated cancellation preserves a terminal result. A failure to acknowledge cancellation is an explicit error.
- Emergency `force-cancel` authenticates the controller handle by PID and creation time, independently authenticates the real root by PID/creation/session, and duplicates only the broker-owned target job with query/termination rights. It terminates the job and broker, then requires an exited root and independently empty job before committing `exited`. An inaccessible, unverifiable, or nonempty tree returns `cleanupUnconfirmed`. Bare-PID killing and QGA cache liveness are not used. Both output truncation flags become true after forced teardown. Historical records without the controller-owned job handle cannot prove emergency cleanup.
- If the root has already exited successfully but its remaining child tree is cancelled, the actual `rootExitCode` remains zero while session `exitCode` is 1223 and `cancelled` records the separate tree cancellation. Consumers must not silently rewrite the real root exit code.
- Cancellation before a controller record no longer returns `requestMissing`. It flushes a protected tombstone and an explicit `launchCancelled` / `launchSuppressed` result. A delayed launch of this UUID cannot create a relay or resume a target.
- A protected per-request lock serializes cancellation with controller initialization and resume grants. The relay initially creates the real target suspended and requires an authenticated `R` grant; cancellation can instead send `C`. Active duplicate launches cannot overwrite another controller's record.
- Final-frame verification uses the relay's untouched cancellation flag and exit code before combining controller cancellation intent. Finalization and cancellation tombstones share the request lock, so a completed natural frame racing cancellation becomes an explicit session cancellation with the unchanged real root status instead of a false `targetExitMismatch`.

## Desktop selection

- Exactly one active logged-in WTS session is required. Multiple active sessions produce `ambiguousDesktop`; no active login produces `noInteractiveDesktop`.
- WTS extended session information must report unlocked. The relay also opens the current input desktop and requires its name to be Default. These are actual runtime checks, not inferred from a nonzero Session ID.
- WTS user-token and process-launch privileges are checked explicitly. No error path silently launches the target in Session 0.
- Standard output/error handles are created by the relay and inherited only inside its own session. The inheritance allowlist contains only stdin, stdout, and stderr.

## Channel and storage

- The local-only named pipe has a DACL for SYSTEM, Administrators, and the selected user. Its unpredictable UUID name is specific to one request.
- The controller verifies the client process PID is the relay it created; the relay verifies the server PID is its controller. A different same-user process cannot provide accepted frames.
- Authority records and cancellation flags are inside a protected SYSTEM/Administrators-only tree. Existing directories with user owners are rejected, preventing the owner's implicit permission to rewrite a DACL.
- Reparse points are rejected, records are replaced atomically, and binary message sizes are bounded.
- Internal relay and authority records now use `MBS5` to carry the relay-owned target-job binding handle and the verified controller-owned copy for emergency cleanup; reads remain compatible with historical `MBS1`, `MBS2`, `MBS3`, and `MBS4` records. Relay frames must not supply a controller-owned handle. The public JSON schema stays at version 1 and does not expose raw handles.
- Controller lifetime and authority-state reads are independent snapshots. The native status command rereads the protected authority record if a previously active snapshot is followed by controller exit; it returns a committed terminal record only after comparing all previously bound controller/target creation times, PIDs, Session ID, and target-job handle. A host consumer must likewise reread authority status after independently observing controller exit before reporting an active request lost, because the terminal record can be committed between the two observations. Every reread must retain the established request and target identity binding.

## Encoding and bounded resources

- The request is strict UTF-8 length-prefixed binary with a 16 KiB limit. NUL, malformed base64, duplicate environment keys, invalid UUIDs, and trailing manifest data are rejected.
- The target application name is explicit. Arguments use WinCRT backslash/quote encoding; there is no shell interpreter or string interpolation into a script.
- Unicode environment overrides are merged with the real desktop user's environment. The complete environment and target command line have explicit bounds. The target working directory is its executable directory.
- Each output stream retains 16 KiB. Extra bytes are drained to prevent the target from blocking, and truncation flags are exposed. Truncated output must never be reported as complete.
- Each capture iteration has a drainage budget so continuous output cannot starve cancellation or process-tree accounting.
- Directory creation calls Win32 filesystem APIs; dynamic paths cannot become `cmd.exe` instructions.

## GUI and elevation

- The self-owned GUI probe creates a real HWND, checks visibility/cloaking, creates a D3D11 DXGI swap chain, and calls Present. It reports its actual PID and Session ID.
- The installer preview has functioning synthetic Next and Cancel controls and does not install software.
- The self-owned child probe verifies parent/child lifetime separation, and the synthetic large-output mode exercises retention limits.
- A separate self-owned elevation probe embeds a requireAdministrator manifest. With a limited token, `CreateProcessW` reports error 740 as `elevationRequired`. The helper does not approve UAC or claim elevated installer support.

## Validation performed

- `build.py` completed with `-std=c++17 -O2 -Wall -Wextra -Werror` and statically linked C++ runtime libraries.
- `build.json` records SHA-256 for the helper, GUI probe, elevation probe, source files, manifest, resource source, and builder.
- Seven host-executable regressions passed against the broker's shared `exit-resolution.hpp` function. They cover natural completion with controller cancellation, root error preservation, real relay cancellation, two malformed-frame rejection cases, high-bit root status, and repeated intent. The results are in `exit-resolution-tests.json`.
- `verify-cancel-contract.ps1` and `cancel-contract-plan.md` provide an executable early-cancel/replay acceptance plan and further process-tree checks. They have not been run against the Guest by this subtask.
- The artifacts are x86_64. ARM64 Windows Guest execution relies on its x64 emulation layer; no native ARM64 artifact or transparent PE migration is claimed.
- Guest success, timeout/cancel behavior, locked-desktop behavior, and actual UAC behavior remain real-execution gates until separate evidence records them.

## Additional cancellation safeguards

- MBS5 persists the real target binding under the per-request lock before the resume grant. Emergency target-zero suppression rereads the authority after verifying original broker absence or terminating its authenticated handle; a stale target-zero snapshot cannot authorize suppression after a target was recorded.
- Historical active target-zero records without this barrier remain unconfirmed. Explicit historical desktop-selection failures occurring before relay creation can receive a durable launch suppression result.
- Controller PID reuse proves the original controller is absent but never grants rights to terminate the unrelated current process. Root PID reuse fails its creation-time authentication and cannot cause direct root termination.
- Emergency lock acquisition, controller/root waits, and empty-job polling share one five-second native budget. No serial sequence of three separate five-second waits remains.
