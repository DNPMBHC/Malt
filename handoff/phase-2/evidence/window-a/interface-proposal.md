# module-b interface proposal

Owner: @DNPMBHC
Date: 2026-11-22
Status: proposed; shared models are outside this window's write scope.

## Desktop execution

Expose a typed execution mode: background or interactiveDesktop. Desktop selection must use an active logged-in Windows session, reject unavailable or locked desktops, and never silently fall back to Session 0. VM control and agent preflight remain background operations.

A detailed process session should expose requestID, real targetPID, Windows sessionID, controllerPID, process creation identity, stdout/stderr capture, terminal exit status, and idempotent cancellation. A controller exit is not a target exit. Existing wait/cancel adapters remain compatible.

Errors should distinguish no desktop, locked desktop, token/privilege failure, helper version mismatch, launch failure, protocol failure, timeout, controller loss and cancellation failure. Elevated installers require a separately measured capability and result.

## Explicit compute delegation

Use a scoped endpoint and per-session random challenge. Requests carry protocol version, requestID, operation, bounded payload and time budget. Responses carry matching identity, succeeded/timedOut/cancelled/failed state, typed error, result bytes and an integrity summary. Operations are explicitly allowlisted; this is not arbitrary code execution.

Cancellation owns both host computation cleanup and the real Guest probe lifetime. A terminal state is delivered once. Trace data should support success, timeout, repeated cancellation, host errors and connection loss without storing local identities or paths.

This interface validates explicit Guest-owned requests and host computation. It makes no claim of transparent PE migration, rendering acceleration, protected-game support or vendor approval.

## Integration boundary

This window implements local provider/session/compute types inside its assigned runtime files. Shared request, configuration, session and UI changes must be performed by their owning windows after review of this proposal.

Probe architecture and Guest architecture must be recorded separately. An x64 probe executed by an ARM64 Guest is not a native ARM64 probe.

## Process-tree cancellation semantics

Root process exit and session completion are distinct. Keep a rootExitCode fact even when a launcher exits before its descendants. The session remains running until the owned process tree is empty. A cancelled tree produces an explicit cancelled outcome; the current compatibility adapter uses nonzero Windows cancellation status 1223 while retaining the real root exit code in the detailed snapshot. Shared models should encode cancellation directly instead of requiring consumers to infer it from the root exit.

## Launch cancellation before PID delivery

A launch request allocates its identity before invoking automation. If the transport cannot return the controller PID, cleanup must use that identity and a fresh bounded cancellation scope. A missing record is an unresolved race and requires retry. A helper may prove suppression with a persistent cancellation fence: failed/launchCancelled, cancelled=true, launchSuppressed=true, and targetPID=0. Late launches using that identity must remain suppressed. Ordinary failed responses never prove cleanup by themselves.

A cancelled completed session carries exitCode=1223 and a separate rootExitCode fact. Natural completion keeps the root code. Nested launch and status operations use the earlier parent deadline; independent cleanup receives a new bounded budget.

## Authenticated recovery and retries

QGA completion caches identify command delivery only. Target lifecycle facts come from the helper record bound to request UUID, real PID, process creation time and desktop session. Captured helper responses must match the expected request before they are accepted.

Normal cancellation drains captured output. A force-cancel fallback authenticates native process handles and the owned target Job; completion requires the root to have exited and the Job to contain zero active processes. Forced teardown declares both output streams truncated. cleanupUnconfirmed is a failure, even when a broker has stopped.

Concurrent cancel calls share and await one cleanup operation. A failed operation can be retried after transport recovery; a confirmed terminal cleanup remains idempotent. The compatibility adapter preserves cancellation status 1223 separately from rootExitCode.

The current real desktop token is already elevated. Its successful elevated probe does not establish a medium-token UAC approval path. Shared configuration should expose that capability separately.
