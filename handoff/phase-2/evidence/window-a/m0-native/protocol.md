# module-b desktop helper protocol

Maintainer: @DNPMBHC

This is a self-owned x86_64 helper and probe for an ARM64 Windows Guest. The Guest's x64 emulation layer is required. A successful build is not a real Guest execution result.

## Fixed commands

- `desktop-helper.exe launch <request-id> <manifest-base64>` starts a persistent Session 0 controller. Its PID is the controller PID returned by QGA. The host reads the independent status command instead of waiting for this controller's exit.
- `desktop-helper.exe status <request-id>` returns one JSON status frame.
- `desktop-helper.exe cancel <request-id>` asks the controller to terminate the real target and descendants, waits for acknowledgement, and returns one JSON frame. Repeated cancellation of a terminal request returns the same terminal result.
- `desktop-helper.exe force-cancel <request-id>` is an emergency path after ordinary cancellation fails. It authenticates the controller and real root by PID plus creation time, duplicates the real target job from the authenticated controller, terminates that job and controller, and independently checks root exit and an empty job. An unavailable or unverifiable job returns `failed` / `cleanupUnconfirmed`; a wrapper exit is never completion proof. Forced output is explicitly marked truncated.
- `desktop-helper.exe mkdir <directory-utf8-base64>` calls filesystem APIs directly. It does not send the directory to a shell interpreter.

Request IDs must have UUID syntax. A request uses a cryptographically random ID supplied by the host; IDs are not reused. Dynamic arguments never become script source or shell text.

## Manifest

All integers are unsigned 32-bit little endian. Each string is its byte length followed by strict UTF-8 bytes, with no NUL. The complete decoded manifest is at most 16 KiB.

1. Four literal ASCII bytes `MBD1`.
2. Absolute target executable string.
3. Argument count, followed by each argument string.
4. Environment entry count, followed by each key string and value string.

Empty arguments are preserved. Environment keys cannot contain `=`; duplicate keys are rejected case insensitively. The relay merges overrides into the logged-in user's environment block and sets the target's working directory to its executable directory.

## Status schema

Every response contains `schemaVersion: 1`, `requestID`, `controllerPID`, `targetPID`, `sessionID`, `state`, `exitCode`, `stdoutBase64`, `stderrBase64`, `error`, `win32Error`, `stdoutTruncated`, `stderrTruncated`, `cancelled`, `launchSuppressed`, decimal-string `targetCreationTime`, `rootExited`, `rootExitCode`, and `activeProcessCount`.

`state` is `starting`, `running`, `exited`, or `failed`. `exitCode` is null until `exited`; on natural completion it equals the root's signed 32-bit Windows status, while a cancelled session returns 1223. The actual root status is retained separately in `rootExitCode`. A missing launch record returns `starting` with `requestNotReady`; the host must bound its retry deadline. Other errors are explicit `failed` frames. Output bytes are base64 encoded; each stream has a 16 KiB retention limit and an explicit truncation flag. A consumer must not call truncated output complete.

A normal root process exit is different from process-tree completion. While legitimate child processes remain active, state stays `running`, `rootExited` is true, `rootExitCode` retains the actual root code, and `activeProcessCount` remains nonzero. Only an empty job becomes `exited`. Cancellation of a remaining child tree does not change the already-exited root's true code; `cancelled: true` and session `exitCode: 1223` record that cancellation separately.

If the relay completes naturally while a controller cancellation is pending, the broker first validates the relay's original cancellation flag and original exit code against the actual root process. Only after that check does it combine cancellation intent and recompute session `exitCode`. The final decision and authority-record commit hold the same per-request lock used by cancellation. Cancellation that commits before finalization yields session 1223; cancellation after an already-committed terminal result preserves that result. The actual `rootExitCode` never changes, and a malformed relay frame cannot be made valid by a controller cancellation flag.

## Startup cancellation

An early `cancel` creates and flushes a cancellation tombstone inside the protected request directory, even if no controller PID or record exists yet. Its complete response is `failed` with `launchCancelled`, Windows error 1223, `cancelled: true`, `launchSuppressed: true`, and no target PID. This is proof that the request is persistently forbidden from starting; it is not a `requestMissing` response.

Controller initialization, tombstone writes, and resume decisions use an exclusive per-request file lock. A later launch of a suppressed UUID returns the persisted suppression state without creating a relay. An active request replay cannot overwrite its authority record. The relay creates a target suspended and sends a starting frame; the controller checks the tombstone while holding the lock and grants `R` only when cancellation has not won. `C` terminates the suspended target. The host must recognize the explicit suppression fields rather than treating an arbitrary missing or failed status as successful cleanup.

## Desktop and lifecycle boundaries

The controller requires Session 0, exactly one active unlocked login session, and the Windows privileges needed for `WTSQueryUserToken` / `CreateProcessAsUserW`. It does not store credentials or enable automatic login. No desktop or privilege failure falls back to Session 0 target execution.

The controller launches a relay in `winsta0\default`; the relay validates the input desktop and creates the real target suspended through `CreateProcessW` with explicit application name, WinCRT argument encoding, an independent Unicode environment block, and an inherited-handle allowlist. It resumes the target only after an authenticated controller grant. Anonymous stdout/stderr handles are inherited only inside the same Windows Session.

An ACL-protected local named pipe joins the controller and relay. The controller verifies the pipe client's PID; the relay verifies the server PID. The controller owns the authority record in a SYSTEM/Administrators-only directory beneath the Windows ProgramData known folder. The target user's token cannot modify this record. A retained process handle plus creation time and Session ID binds target identity; the controller checks the real process exit code before recording completion.

Both the controller and relay own kill-on-close jobs. Normal root exit keeps these jobs open until all legitimate child processes end; it does not kill an installer's downloader or child installer. The relay supplies its real target-job handle in the authenticated starting frame. Before granting resume or cancellation, the controller duplicates that job from the verified relay process with only query and termination rights, then independently verifies that the suspended real root belongs to it. Cancellation terminates this target job; a lost controller or relay kills remaining processes and produces an explicit failure. Before accepting completion, the controller independently checks that the duplicated target job has zero active processes. The outer controller job can contain console and control processes and cannot establish target-tree completion. The relay retains its root target handle until the controller acknowledges the final result, so fast target exits do not lose identity.

The internal relay and authority-record format is `MBS5`. It contains the relay-owned target-job handle for authenticated startup binding and a separate controller-owned target-job handle for emergency duplication. The relay must send zero in the controller-owned field; only the controller fills it after successful binding. Existing `MBS1`, `MBS2`, `MBS3`, and `MBS4` records remain readable. Older records lack an independent emergency job binding and cannot become forced-cleanup success evidence. The public JSON schema remains version 1 and never exposes either handle. The native status command rereads the authority record if it reads an active snapshot and then finds the controller has exited. It returns a newly committed terminal record after verifying all previously bound identity fields. A host consumer that independently observes a controller exit after reading an active status must likewise reread the independent authority status before classifying the request as lost, since completion is committed before the wrapper exits. This reread must preserve all previously bound target identity fields.

With a limited desktop token, executables requiring UAC elevation fail with `elevationRequired`. If the selected token is already elevated, the self-owned probe reports that actual token state. This helper does not approve UAC prompts or claim general elevated installer support. A normal self-owned GUI probe and an elevation-required failure are separate capability results.

## Probe

`desktop-probe.exe --gui --sleep-ms 1000 --exit-code 0` creates a synthetic Win32 window, attempts a D3D11 DXGI swap chain, and presents one synthetic frame. It reports process/session IDs, window visibility and cloaking, swap-chain and Present results, architecture, arguments excluding executable path, the synthetic `DEMO_E2E_ENV` variable, and token elevation. Stderr contains a fixed synthetic marker.

`--installer` enables a self-owned setup preview with visible Next and Cancel controls. Next changes the synthetic step label; Cancel closes the preview. No actual software installation or system change occurs.

`--spawn-child 3000` starts a self-owned same-executable child that remains alive for three seconds. The parent reports `spawnedChildPID` before resuming the child, then follows its own exit/sleep arguments. This verifies that normal parent exit preserves the child's lifetime, captures its inherited output, and leaves cancellation effective. `--output-bytes 131072` supplies a synthetic output stream for explicit truncation tests.

`desktop-elevation-probe.exe` embeds a `requireAdministrator` manifest. Starting it through a limited desktop token must produce the helper's `elevationRequired` error with Windows error 740; if the chosen logged-in token is already elevated, the probe instead reports its actual elevation. Building this artifact does not verify either real behavior.

No real username, VM identifier, local project path, or personal desktop content is included in the protocol or probe output. Only explicit desktop execution and self-owned rendering are in scope; no transparent PE migration, game compatibility, or vendor support is implied.

`exit-resolution-test` runs seven host regression cases against the same portable resolution function used by the broker, including natural completion racing cancellation, real relay cancellation, malformed flag/code pairs, high-bit Windows status preservation, and repeated cancellation. This host validation does not replace real Guest execution.

## Emergency cleanup acceptance

Ordinary cancellation remains the preferred path and uses the authenticated relay channel plus broker-verified target-job accounting. The emergency command is reserved for an ordinary cancellation failure or host automation timeout. It does not use QGA cached PID results or a bare-PID termination command.

An already committed `exited` record is returned unchanged. A request with no controller receives the same protected cancellation tombstone as ordinary early cancellation, so a late launch is forbidden. For an active request, the command holds the request lock, retains the authenticated controller/root handles, duplicates the broker-owned job with only query and termination rights, and checks live-root membership. The broker-owned job number remains valid for the life of that exact controller process; it cannot be substituted through PID reuse.

Confirmed emergency cleanup produces `exited`, `cancelled: true`, session `exitCode: 1223`, the independently read actual `rootExitCode`, and `activeProcessCount: 0`. Both truncation flags are true because abrupt teardown cannot drain all final output. Missing handles, identity disagreement, a nonempty or unqueryable job, or a failed wait produces `failed` / `cleanupUnconfirmed`. Best-effort broker termination in an unconfirmed case must never be reported as successful tree cleanup.

## Startup barrier and bounded emergency wait

MBS5 requires the broker to persist the verified starting target PID, creation time, Session ID, and Job binding while holding the cancellation lock, before it sends the relay any resume grant. Emergency cleanup keeps that same request lock, persists cancellation, authenticates or proves the absence of the original broker, and rereads the newest authority record after broker exit. A record still having no target binding can then return `failed` / `launchCancelled`, `cancelled: true`, `launchSuppressed: true`, and `targetPID: 0`. This proves no delayed target execution can be authorized. It does not claim that no suspended relay target could have briefly existed before authority binding. An old target-zero active record without the MBS5 barrier is conservatively `cleanupUnconfirmed`; specific historical desktop failures that precede relay creation may be suppressed safely.

A reused controller PID is never terminated or used as a handle-table source. A reused root PID fails the creation-time check and is never terminated directly. Emergency lock acquisition, broker wait, root wait, and target-job accounting all consume one five-second native wait budget; exhaustion returns an explicit unconfirmed failure instead of adding separate five-second waits. Disk and operating-system call completion are outside polling budget guarantees.
