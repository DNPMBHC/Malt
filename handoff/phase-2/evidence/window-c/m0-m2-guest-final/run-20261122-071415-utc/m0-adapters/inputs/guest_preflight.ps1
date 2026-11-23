# Read-only preflight for module-c. Owner: @DNPMBHC.
[CmdletBinding()]
param(
    [string[]]$ExpectedAbsentDriverServices = @(),
    [string[]]$ForbiddenProcessNamePatterns = @('*module-a*', '*selfprobe*', '*self-probe*', 'd3d11_probe.exe'),
    [string[]]$ForbiddenCommandLinePatterns = @('*module-a*', '*module-c*', '*selfprobe*', '*self-probe*')
)
$ErrorActionPreference = 'Stop'

# WTSINFOEX_W uses an 8-byte-aligned union. Data starts at 8;
# SessionFlags starts at 8 within LEVEL1, hence its absolute offset is 16.
# The flags are 0=locked and 1=unlocked on Windows 11.
$nativeSource = @'
using System;
using System.Runtime.InteropServices;

public static class ModuleCReadOnlyPreflight {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WTSINFOEX_LEVEL1_W {
        public UInt32 SessionId;
        public Int32 SessionState;
        public Int32 SessionFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 33)] public string WinStationName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)] public string UserName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 18)] public string DomainName;
        public Int64 LogonTime;
        public Int64 ConnectTime;
        public Int64 DisconnectTime;
        public Int64 LastInputTime;
        public Int64 CurrentTime;
        public UInt32 IncomingBytes;
        public UInt32 OutgoingBytes;
        public UInt32 IncomingFrames;
        public UInt32 OutgoingFrames;
        public UInt32 IncomingCompressedBytes;
        public UInt32 OutgoingCompressedBytes;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WTSINFOEX_W {
        public UInt32 Level;
        public WTSINFOEX_LEVEL1_W Data;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_CODEINTEGRITY_INFORMATION {
        public UInt32 Length;
        public UInt32 CodeIntegrityOptions;
    }
    public sealed class SessionSnapshot {
        public UInt32 ConsoleSessionId;
        public bool QuerySucceeded;
        public bool SessionMatchesConsole;
        public bool LoggedIn;
        public bool Unlocked;
        public Int32 SessionState = -1;
        public Int32 SessionFlags = -1;
        public Int32 Win32Error;
        public Int32 StructureBytes;
        public Int32 SessionFlagsOffset;
        public UInt32 ReturnedBytes;
    }
    public sealed class CodeIntegritySnapshot {
        public bool QuerySucceeded;
        public UInt32 Options;
        public bool TestSigning;
        public bool KernelHvciEnforced;
    }
    [DllImport("kernel32.dll")]
    private static extern UInt32 WTSGetActiveConsoleSessionId();
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WTSQuerySessionInformationW(IntPtr server, UInt32 sessionId,
        Int32 informationClass, out IntPtr buffer, out UInt32 bytesReturned);
    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr buffer);
    [DllImport("ntdll.dll")]
    private static extern Int32 NtQuerySystemInformation(Int32 informationClass,
        ref SYSTEM_CODEINTEGRITY_INFORMATION information, UInt32 length, out UInt32 returnLength);

    public static SessionSnapshot ReadConsoleSession() {
        var result = new SessionSnapshot();
        result.ConsoleSessionId = WTSGetActiveConsoleSessionId();
        result.StructureBytes = Marshal.SizeOf(typeof(WTSINFOEX_W));
        result.SessionFlagsOffset = Marshal.OffsetOf(typeof(WTSINFOEX_W), "Data").ToInt32()
            + Marshal.OffsetOf(typeof(WTSINFOEX_LEVEL1_W), "SessionFlags").ToInt32();
        if (result.ConsoleSessionId == UInt32.MaxValue || result.ConsoleSessionId == 0
            || result.StructureBytes != 232 || result.SessionFlagsOffset != 16) return result;
        IntPtr buffer = IntPtr.Zero;
        UInt32 bytes = 0;
        try {
            if (!WTSQuerySessionInformationW(IntPtr.Zero, result.ConsoleSessionId, 25, out buffer, out bytes)) {
                result.Win32Error = Marshal.GetLastWin32Error();
                return result;
            }
            result.ReturnedBytes = bytes;
            if (buffer == IntPtr.Zero || bytes < result.StructureBytes) return result;
            var information = (WTSINFOEX_W)Marshal.PtrToStructure(buffer, typeof(WTSINFOEX_W));
            if (information.Level != 1) return result;
            result.QuerySucceeded = true;
            result.SessionMatchesConsole = information.Data.SessionId == result.ConsoleSessionId;
            result.SessionState = information.Data.SessionState;
            result.SessionFlags = information.Data.SessionFlags;
            // Account strings are inspected inside this function and never returned.
            result.LoggedIn = information.Data.SessionState == 0
                && information.Data.LogonTime > 0 && !String.IsNullOrEmpty(information.Data.UserName);
            result.Unlocked = result.LoggedIn && result.SessionMatchesConsole && information.Data.SessionFlags == 1;
            return result;
        } finally {
            if (buffer != IntPtr.Zero) WTSFreeMemory(buffer);
        }
    }
    public static CodeIntegritySnapshot ReadCodeIntegrity() {
        var result = new CodeIntegritySnapshot();
        var information = new SYSTEM_CODEINTEGRITY_INFORMATION();
        information.Length = (UInt32)Marshal.SizeOf(typeof(SYSTEM_CODEINTEGRITY_INFORMATION));
        UInt32 returned;
        Int32 status = NtQuerySystemInformation(103, ref information, information.Length, out returned);
        if (status < 0 || returned < information.Length) return result;
        result.QuerySucceeded = true;
        result.Options = information.CodeIntegrityOptions;
        result.TestSigning = (information.CodeIntegrityOptions & 0x0002) != 0;
        result.KernelHvciEnforced = (information.CodeIntegrityOptions & 0x0400) != 0;
        return result;
    }
}
'@

function Match-AnyPattern([string]$Value, [string[]]$Patterns) {
    if (!$Value) { return $false }
    foreach ($pattern in $Patterns) {
        if ($Value -like $pattern) { return $true }
    }
    return $false
}
function Read-BcdFlag([string[]]$Lines, [string]$Element) {
    $found = @($Lines | Where-Object { $_ -match ('^\s*' + [regex]::Escape($Element) + '\s+') })
    if ($found.Count -eq 0) { return 'absent' }
    if ($found.Count -ne 1 -or $found[0] -notmatch ('^\s*' + [regex]::Escape($Element) + '\s+(\S+)\s*$')) {
        return 'unknown'
    }
    switch ($Matches[1].ToLowerInvariant()) {
        { $_ -in @('no', 'off', 'false', 'disabled', '0', '否') } { return 'off' }
        { $_ -in @('yes', 'on', 'true', 'enabled', '1', '是') } { return 'on' }
        default { return 'unknown' }
    }
}

$result = [ordered]@{
    schema_version = 1
    owner = '@DNPMBHC'
    captured_at_utc = [DateTime]::UtcNow.ToString('o')
    boot_time_utc = $null
    os_product = $null
    display_version = $null
    build = $null
    architecture = $null
    hypervisor_present = $null
    os_query_succeeded = $false
    console_session_id = $null
    session_query_succeeded = $false
    session_matches_console = $false
    session_state = $null
    session_flags = $null
    session_flags_offset = $null
    wts_info_ex_struct_bytes = $null
    wts_returned_bytes = $null
    session_query_win32_error = $null
    logged_in = $false
    unlocked = $false
    forbidden_process_count = $null
    forbidden_running_task_count = $null
    quiescence_query_succeeded = $false
    secure_boot_enabled = $null
    secure_boot_query_succeeded = $false
    bcd_query_succeeded = $false
    bcd_security = @()
    bcd_flags = [ordered]@{ testsigning = 'unknown'; nointegritychecks = 'unknown' }
    expected_absent_driver_service_count = $ExpectedAbsentDriverServices.Count
    driver_service_query_succeeded = $false
    remaining_driver_service_count = $null
    owned_services_absent = $null
    tpm_query_succeeded = $false
    tpm = [ordered]@{ present = $null; enabled = $null; activated = $null; owned = $null; specification_version = $null }
    device_guard_query_succeeded = $false
    vbs_status = $null
    security_services_running = @()
    security_services_configured = @()
    hvci_running = $null
    hvci_configured = $null
    temporary_directory_scoped = $false
    code_integrity_query_succeeded = $false
    code_integrity_options = $null
    code_integrity_test_signing = $null
    hvci_kernel_enforced = $null
    baseline_comparison_required = $true
    read_only = $true
    preflight_gates_passed = $false
}
$originalTemp = $env:TEMP
$originalTmp = $env:TMP
try {
    $scratch = Join-Path $env:SystemDrive 'graphics-lab\module-c\tmp'
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null
    $env:TEMP = $scratch
    $env:TMP = $scratch
    $result.temporary_directory_scoped = $true
    if (-not ('ModuleCReadOnlyPreflight' -as [type])) {
        Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop | Out-Null
    }
    $session = [ModuleCReadOnlyPreflight]::ReadConsoleSession()
    $result.console_session_id = $session.ConsoleSessionId
    $result.session_query_succeeded = $session.QuerySucceeded
    $result.session_matches_console = $session.SessionMatchesConsole
    $result.session_state = $session.SessionState
    $result.session_flags = $session.SessionFlags
    $result.session_flags_offset = $session.SessionFlagsOffset
    $result.wts_info_ex_struct_bytes = $session.StructureBytes
    $result.wts_returned_bytes = $session.ReturnedBytes
    $result.session_query_win32_error = $session.Win32Error
    $result.logged_in = $session.LoggedIn
    $result.unlocked = $session.Unlocked
    $integrity = [ModuleCReadOnlyPreflight]::ReadCodeIntegrity()
    $result.code_integrity_query_succeeded = $integrity.QuerySucceeded
    if ($integrity.QuerySucceeded) {
        $result.code_integrity_options = $integrity.Options
        $result.code_integrity_test_signing = $integrity.TestSigning
        $result.hvci_kernel_enforced = $integrity.KernelHvciEnforced
    }
} catch { } finally {
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
}
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $computer = Get-CimInstance Win32_ComputerSystem
    $currentVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $result.boot_time_utc = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    $result.os_product = $os.Caption
    $result.display_version = $currentVersion.DisplayVersion
    $result.build = $os.BuildNumber
    $result.architecture = if ($cpu.Architecture -eq 12) { 'ARM64' } else { 'other' }
    $result.hypervisor_present = [bool]$computer.HypervisorPresent
    $result.os_query_succeeded = $true
} catch { }
try {
    $processes = @(Get-CimInstance Win32_Process)
    $result.forbidden_process_count = @($processes | Where-Object {
        $_.ProcessId -ne $PID -and ((Match-AnyPattern $_.Name $ForbiddenProcessNamePatterns) -or
        (Match-AnyPattern $_.CommandLine $ForbiddenCommandLinePatterns))
    }).Count
    $tasks = @(Get-ScheduledTask | Where-Object { $_.State -eq 'Running' })
    $result.forbidden_running_task_count = @($tasks | Where-Object {
        $matching = Match-AnyPattern $_.TaskName $ForbiddenCommandLinePatterns
        foreach ($action in $_.Actions) {
            $matching = $matching -or (Match-AnyPattern $action.Execute $ForbiddenProcessNamePatterns)
            $matching = $matching -or (Match-AnyPattern $action.Arguments $ForbiddenCommandLinePatterns)
        }
        $matching
    }).Count
    $result.quiescence_query_succeeded = $true
} catch { }
try {
    $result.secure_boot_enabled = [bool](Confirm-SecureBootUEFI)
    $result.secure_boot_query_succeeded = $true
} catch { }
try {
    $bcd = @(& bcdedit.exe /enum '{current}' 2>$null)
    if ($LASTEXITCODE -eq 0) {
        $result.bcd_security = @($bcd | Where-Object { $_ -match '^\s*(testsigning|nointegritychecks)\s+\S+\s*$' } | ForEach-Object { $_.Trim() })
        $result.bcd_flags.testsigning = Read-BcdFlag $bcd 'testsigning'
        $result.bcd_flags.nointegritychecks = Read-BcdFlag $bcd 'nointegritychecks'
        $result.bcd_query_succeeded = ($result.bcd_flags.testsigning -ne 'unknown' -and
                                     $result.bcd_flags.nointegritychecks -ne 'unknown')
    }
} catch { }
try {
    if ($ExpectedAbsentDriverServices.Count -gt 0 -and
        @($ExpectedAbsentDriverServices | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
        $drivers = @(Get-CimInstance Win32_SystemDriver)
        $serviceKeys = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services')
        $remaining = @($ExpectedAbsentDriverServices | Where-Object {
            $name = $_
            @($drivers | Where-Object { $_.Name -eq $name }).Count -gt 0 -or
            @($serviceKeys | Where-Object { $_.PSChildName -eq $name }).Count -gt 0
        })
        $result.remaining_driver_service_count = $remaining.Count
        $result.owned_services_absent = $remaining.Count -eq 0
        $result.driver_service_query_succeeded = $true
    }
} catch { }
try {
    $tpm = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName Win32_Tpm
    $result.tpm.present = $null -ne $tpm
    if ($null -ne $tpm) {
        $result.tpm.enabled = [bool]$tpm.IsEnabled_InitialValue
        $result.tpm.activated = [bool]$tpm.IsActivated_InitialValue
        $result.tpm.owned = [bool]$tpm.IsOwned_InitialValue
        $result.tpm.specification_version = $tpm.SpecVersion
    }
    $result.tpm_query_succeeded = $true
} catch { }
try {
    $guard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard
    if ($null -ne $guard) {
        $result.vbs_status = $guard.VirtualizationBasedSecurityStatus
        $result.security_services_running = @($guard.SecurityServicesRunning)
        $result.security_services_configured = @($guard.SecurityServicesConfigured)
        $result.hvci_running = 2 -in @($guard.SecurityServicesRunning)
        $result.hvci_configured = 2 -in @($guard.SecurityServicesConfigured)
        $result.device_guard_query_succeeded = $true
    }
} catch { }
$result.preflight_gates_passed = (
    $result.os_query_succeeded -and $result.display_version -eq '24H2' -and
    $result.build -eq '26100' -and $result.architecture -eq 'ARM64' -and
    $result.session_query_succeeded -and $result.session_matches_console -and
    $result.console_session_id -gt 0 -and $result.console_session_id -lt [uint32]::MaxValue -and
    $result.logged_in -and $result.unlocked -and
    $result.quiescence_query_succeeded -and $result.forbidden_process_count -eq 0 -and
    $result.forbidden_running_task_count -eq 0 -and
    $result.secure_boot_query_succeeded -and $result.secure_boot_enabled -eq $true -and
    $result.bcd_query_succeeded -and $result.bcd_flags.testsigning -in @('off', 'absent') -and
    $result.bcd_flags.nointegritychecks -in @('off', 'absent') -and
    $result.driver_service_query_succeeded -and $result.owned_services_absent -eq $true -and
    $result.temporary_directory_scoped -and $result.code_integrity_query_succeeded -and $result.code_integrity_test_signing -eq $false -and
    $result.tpm_query_succeeded -and $result.device_guard_query_succeeded
)
$result | ConvertTo-Json -Depth 8 -Compress
