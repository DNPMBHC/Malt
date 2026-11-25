# module-b cancellation race acceptance plan

Maintainer: @DNPMBHC

This is an executable test plan, not a claim that the Guest tests have passed. `verify-cancel-contract.ps1` runs the first scenario through the Session 0 SYSTEM control channel using only the self-owned helper and probe. It reports synthetic counts and booleans without local paths or raw request IDs.

## Cancellation before any controller record

1. Generate a new unpredictable request UUID.
2. Invoke `cancel` before invoking `launch`.
3. Require a complete frame with `state: failed`, `error: launchCancelled`, `win32Error: 1223`, `cancelled: true`, `launchSuppressed: true`, `targetPID: 0`, and `activeProcessCount: 0`.
4. Invoke a later `launch` with that same UUID and a valid manifest for a long-running self-owned probe.
5. Require the same suppression result, no target creation, and no restored execution. Query status and repeat cancellation to check idempotence.
6. Repeat with fresh UUIDs. A missing record or `requestMissing` is never accepted as cleanup evidence.

## Cancellation during controller startup

Start the controller and cancel immediately, before its first status record is observed. Retry the bounded cancellation command if necessary. The request must finish as either a persisted launch suppression or a real cancelled process-tree result; no later status may become running after a verified suppression. Check controller completion separately when a controller PID exists.

## Cancellation before target resume

The relay creates the real target suspended and reports a starting frame containing its actual PID, Session ID, and creation time. The controller holds `request.lock` while checking the cancellation tombstone and sending either `R` (resume grant) or `C` (cancel). Cancellation that wins this lock cannot be followed by a resume grant. The relay does not resume from an unauthenticated or missing grant.

## Cancellation after parent exit

Run the self-owned probe with a short-lived parent and `--spawn-child 30000`. Require `state: running`, `rootExited: true`, `rootExitCode: 0`, and an active child count. Cancel the session and require empty process tree, `state: exited`, `cancelled: true`, `exitCode: 1223`, and the unchanged `rootExitCode: 0`. Repeat cancellation and verify that the terminal result stays stable.

## Natural completion

Run the same parent/child scenario with a short child lifetime and no cancellation. The child must remain alive after root exit, then end naturally. Require a final empty tree with `cancelled: false` and session `exitCode` equal to the actual `rootExitCode`.

## Final natural frame racing cancellation

Repeat short-lived self-owned root processes while issuing cancellation near normal completion. The broker must verify the relay's original flag/code pair first. A cancellation committed before finalization yields `cancelled: true`, session 1223, and the unchanged real `rootExitCode`; a cancellation after committed natural completion leaves the natural result. Neither ordering may produce a false `targetExitMismatch`. The shared portable resolution function has seven passing host regressions; Guest timing races remain a separate real-execution gate.

## Persistence and replay

Cancellation flags and authority records are flushed inside a SYSTEM/Administrators-only directory. Request IDs are never reused. A replay of a cancelled UUID remains suppressed even after the invoking cancellation helper has exited; a replay of an active UUID is rejected without overwriting its controller's authority record.

The native builder passed strict x64 cross-compilation. Actual Guest race results must be recorded separately by the coordinator before these acceptance scenarios are marked verified.
