# Host Game Mode evidence and A/B procedure

Paths and sample identifiers below are placeholders. The diagnostic tools do not emit application names, bundle identifiers, process arguments, file paths, user accounts, process identifiers, or entitlement values.

## Independent evidence states

HostGameModeEvidence records the plist Boolean LSSupportsGameMode as missing, enabled, disabled, or invalid. Apple documents this declaration for macOS 26 and later. It also preserves the raw deprecated GCSupportsGameMode value independently; that key does not substitute for the macOS declaration.

Platform eligibility means Apple silicon and macOS 14 or later. It is only a prerequisite. Activation remains unknown by default. A fresh explicit observation of the selected application's system Game Mode UI, with native full screen confirmed, can record observedOn or observedOff. The collector does not automatically discover activation.

Manual observations bind to a positive, still-existing subject process identifier internally. A mismatched subject, stale/future observation, unconfirmed native full screen, or incompatible platform stays unknown. Process identifiers are never written by the diagnostic tools. The caller must associate the supplied plist and manual observation with the same subject process; the observation is manual evidence, not a cryptographic attestation. The default maximum age is 120 seconds. PID reuse remains possible; a short-lived manual observation is not an OS attestation or automatic activation query.

Wine-child and Windows-guest benefit remain unmeasured. Parent declarations, parent full-screen state, system menu state, QoS, and process ancestry do not prove another execution domain's performance benefit.

## Local observation

HostGameModeObservation.json contains the actual source-plist and entitlement-key evidence, with no bundle identifier, path, process identifier, signing identity, or personal data. The host was 27.2.1 and SDK 27.0. Both source support declarations were absent; project build settings also contain neither declaration and classify the application as utilities. On 2026-11-22 the successful unsigned Debug product Info.plist was inspected separately: both declarations were also absent. This does not validate final signed entitlements. Platform prerequisites were present; activation and child benefit were not measured.

Reviewing SDK headers and Swift interfaces did not identify a supported public macOS Game Mode activation query. The deprecated GLUT fullscreen API is unrelated. Kernel resource_private.h declarations are private and are not called. No dedicated Game Mode entitlement key was present.

Only project-owned fixtures and render tools were inspected. MetalFX tests execute isolated scaling passes but are not a full-screen Game Mode workload. No existing runnable Game Mode game fixture was found. Personal game history, accounts, and media were not inspected.

## Independent checks and natural-event recorder

~~~sh
xcrun swiftc -swift-version 6 -parse-as-library \
  <module-d>/HostGameModeEvidence.swift \
  <module-d-tools>/HostGameModeEvidenceChecks.swift \
  -o /tmp/module-d-game-mode-checks
/tmp/module-d-game-mode-checks

xcrun swiftc -swift-version 6 -parse-as-library \
  <module-d-tools>/host-state-observer.swift \
  -o /tmp/module-d-state-observer
/tmp/module-d-state-observer --duration 30 --run-label sample-001 \
  --phase control --execution-domain host --game-mode-observation unknown
~~~

The checks compile with the evidence source as an independent executable; no shared interface or application-module import is changed. HostStateObservation.jsonl contains an actual two-second recorder smoke run. The initial state was nominal and Low Power Mode was false. No thermal, power, or wake notification arrived. This verifies recorder operation; it does not verify a physical state transition.

The recorder observes ProcessInfo.thermalStateDidChangeNotification, NSProcessInfoPowerStateDidChange, and NSWorkspace.didWakeNotification. It reads thermal state before subscribing, then records each naturally received event with current thermal/power values. It never requests sleep, changes power preferences, or posts substitute notifications. Zero event counts leave transitions unverified. A startup snapshot after wake does not prove receipt of a wake notification.

Each JSONL row includes schema_version, synthetic sample-NNN run_label, control/treatment/recovery phase, host/wine/guest execution_domain, event, elapsed_monotonic_ms, thermal_state, low_power_mode, and child_process_benefit=unmeasured. The manually supplied Game Mode label is scoped to the start of the run; it is never represented as a live activation query after power changes or wake.

## Reproducible A/B format

Use a synthetic, account-free, repeatable workload. Fix scene, window dimensions, render scale, frame limit, binaries, power source, warm-up, and measurement duration. Reject comparisons with materially different thermal/power conditions. Confirm macOS-native full screen separately from a borderless window.

On macOS 26 and later, open the Game Overlay with Command-Escape or the menu-bar game icon, then inspect Settings > Game Mode for the application being measured. Record the actual state. A declaration or visible game icon alone does not establish that Game Mode is On.

After warm-up, collect the identical scene in A/B/A order:

| Phase | Explicit system UI state | Measured domain | Required data |
| --- | --- | --- | --- |
| control | observed-off | host, Wine, or guest separately | frame count, elapsed time, median/p95 frame time, sample count |
| treatment | observed-on | same domain | same measurements |
| recovery | observed-off | same domain | same measurements |

Use distinct sample-NNN labels. Match the recorder's phase, execution-domain, and game-mode-observation arguments with independently collected frame data. Those supplied labels preserve manual provenance; they do not query system state. A parent's observed-on state never marks a Wine/guest run improved. Each measured domain needs its own repeated comparable frame data. Report raw results and uncertainty. The evidence collector deliberately leaves child benefits unmeasured.

## Apple primary sources

- Use Game Mode, updated September 14, 2026: https://support.apple.com/en-us/105118
- LSSupportsGameMode: https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode
- Deprecated GCSupportsGameMode: https://developer.apple.com/documentation/bundleresources/information-property-list/gcsupportsgamemode
