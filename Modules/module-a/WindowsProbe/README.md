# Windows Self-Probe

This standalone diagnostic checks whether a Windows guest can load this project's own minimal WDM driver and whether its read-only request is handled in the caller's process context. It does not implement or adapt any third-party anti-cheat component.

The shared protocol and JSON report schema are version 2. Protocol version 2 adds the fixed-size BIND_NOTIFICATION response so the collector can verify the exact suspended child PID accepted by the driver before resuming it. A version mismatch is a protocol failure; it must not be treated as a missing driver.

## Scope

Child binding uses the PID returned by the collector's suspended CreateProcessW call. The child remains suspended until the driver echoes that PID, so the test relies on the process identity remaining stable for that short interval. The eight-slot candidate table is intentionally bounded; saturation is a probe failure and must never count as successful process coverage.

The driver exposes buffered, read-only self-probe IOCTLs. It accepts no caller-selected PID, address, process, or target path; it does not read or write process memory. The process-notification callback is registered before the device becomes available and remains registered until unload. It records create/exit state only for the collector-owned process and one child while explicitly armed. Child creation first places a short-lived PID candidate in an eight-slot in-memory table; the elevated collector binds the PID returned by its own suspended CreateProcessW call before resuming that child. BIND_NOTIFICATION returns the exact PID accepted by the driver, and the collector requires that response to match CreateProcessW before it resumes the child. The candidate is removed on bind, child exit, session cleanup, or unload. The table retains PIDs only; it retains no names, paths, image bytes, or event records for unrelated processes. Each notification callback takes session rundown protection and a short state spin lock; disarm and owner-exit recovery stop new session callbacks, wait for callbacks already in flight, clear the retained process reference, then reopen rundown for a later session. Device access is limited to SYSTEM and local Administrators. Run the collector elevated when testing this device ACL.


The collector places its suspended test child in a private Job Object configured to terminate assigned processes when its last handle closes. If the child misses both bounded waits, closing the job requests termination and the collector performs one final handle wait; childCleanupComplete remains false unless that wait observes process termination.

\`observation.bytesReturned\` is the output byte count from the latest response-bearing IOCTL. The no-output arm/disarm cleanup calls are excluded. A successful run reports the 32-byte \`QUERY_NOTIFICATION\` response; \`QUERY_SELF\` uses a 40-byte response. The bind call separately validates a 16-byte \`BIND_NOTIFICATION\` response and reports \`notification.childPIDMatched\` plus the driver-confirmed \`notification.boundChildPID\`. A failed query may report zero or a partial count; interpret it together with \`failureStage\` and \`win32Error\`. \`failureStage=notification\` means the self-owned create/exit observation did not complete or the arm/query/disarm sequence failed.

## Portable ABI Test

From this directory on macOS or Windows with CMake and a C11 compiler:

~~~sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
~~~

This test locks structure sizes and field offsets, the IOCTL value, and device-name constants. It does not execute kernel code.

## Windows Build

Install Visual Studio with the Desktop C++ workload, Windows SDK, and WDK. The driver project enables the linker Force Integrity option required by the documented process-create notification API. Build the driver for the guest's architecture:

~~~powershell
msbuild driver\ModuleAProbe.vcxproj /p:Configuration=Release /p:Platform=x64
msbuild driver\ModuleAProbe.vcxproj /p:Configuration=Release /p:Platform=ARM64
cmake -S . -B build -A x64
cmake --build build --config Release
~~~

Use the matching -A ARM64 generator option for an ARM64 collector. The driver project intentionally leaves signing off; its output is not a deployable signed driver. Sign and deploy only through the current Microsoft-supported driver-signing process for the target Windows version and test environment. Do not weaken Secure Boot, code-integrity, or other Windows security settings to make the probe load.

## Lifecycle and Failure Paths

Run the lifecycle script from an elevated PowerShell session inside the isolated guest. It records the probe JSON's loadState, failureStage, win32Error, bytesReturned, and notification booleans, without emitting process IDs:

~~~powershell
.\tests\verify-lifecycle.ps1 -Phase cycle -DriverImage C:\module-a\ModuleAProbe.sys -CollectorPath C:\module-a\module_a_probe.exe
~~~

If a phase fails after collecting probe reports, the script emits the stage records gathered so far before returning the failure. This preserves partial evidence for diagnosis without changing the test's nonzero failure result.

For the demand-started reboot check, run -Phase before-reboot, restart the guest, then run -Phase after-reboot. The script verifies that a stopped demand-started service leaves the device absent, that a missing image fails to start, and that service registration is not treated as a successful driver load. The reboot phases require the same service name to remain in the guest between invocations.

During unload, the driver first removes the process callback; Windows waits for callback invocations already in progress. The driver then drains session rundown and releases the retained owner process reference. If callback removal unexpectedly fails, the probe deliberately stops the Windows guest instead of continuing with a callback that could reference unloaded driver code. Treat this as a fatal driver invariant failure and preserve the guest crash dump for diagnosis. The callback remains registered across idle and armed states, so ARM does not dynamically register it after publishing session state.

## Isolated Guest Run

Copy the correctly signed .sys file to a neutral test directory in a dedicated Windows guest. From an elevated terminal, register and start the service:

~~~powershell
sc.exe create ModuleAProbe type= kernel start= demand binPath= C:\module-a\ModuleAProbe.sys
sc.exe start ModuleAProbe
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$bytes = New-Object byte[] 32
$rng.GetBytes($bytes)
$nonce = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
$rng.Dispose()
.\build\Release\module_a_probe.exe --nonce $nonce --driver-image C:\module-a\ModuleAProbe.sys
sc.exe stop ModuleAProbe
sc.exe delete ModuleAProbe
~~~

Preserve the exact JSON output with the guest OS build, guest architecture, driver package hash, and test time in a local test record; redact process IDs before sharing it.

loadState=loaded means the device answered the self-probe IOCTL. The response reports the requestor PID and dispatchAttachedContextPID, obtained from PsGetProcessId(PsGetCurrentProcess()), separately. sameProcessObject=true additionally means the driver compared the requestor process object with the current dispatch context process object, and both reported PIDs matched the collector. No kernel object pointer is returned. A missing device is reported as notLoaded only when opening the device returns file/path-not-found; access, protocol, response-size, and notification errors remain unknown and are recorded with failureStage, win32Error, and bytesReturned. If a future IRP path cannot establish the attached context, the field must be reported as 0/unknown rather than inferred.

## Current Verification Boundary

The portable ABI test can run on macOS. Driver compilation, signing, service lifecycle, process-object comparison, unload, reboot persistence, and Windows failure-path checks require an isolated Windows guest with the matching WDK and an authorized signing setup. No commercial anti-cheat driver or game is included in this module.
