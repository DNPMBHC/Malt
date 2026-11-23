$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ArchitectureX {
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
}
'@
[UInt16]$processMachine = 0
[UInt16]$nativeMachine = 0
if (-not [ArchitectureX]::IsWow64Process2([ArchitectureX]::GetCurrentProcess(),[ref]$processMachine,[ref]$nativeMachine)) { throw 'Native architecture query failed.' }
$tpm = $null
try {
    $provider = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftTpm' -ClassName Win32_Tpm
    if ($null -ne $provider) { $tpm = [pscustomobject]@{present=$true;specification_version=$provider.SpecVersion;enabled=$provider.IsEnabled_InitialValue;activated=$provider.IsActivated_InitialValue;owned=$provider.IsOwned_InitialValue} }
} catch {}
$guard = Get-CimInstance -Namespace 'root/Microsoft/Windows/DeviceGuard' -ClassName Win32_DeviceGuard
$bcd = & bcdedit.exe /enum '{current}' 2>&1
$bcdExit = $LASTEXITCODE
if ($bcdExit -ne 0) { throw 'Boot configuration query failed.' }
$security = @($bcd | Where-Object { $_ -match '^\s*(testsigning|nointegritychecks|hypervisorlaunchtype|vsmlaunchtype)\s+' } | ForEach-Object { $_.Trim() })
[pscustomobject]@{captured_at_utc=[DateTime]::UtcNow.ToString('o');boot_time_utc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o');native_machine=('0x{0:x4}' -f $nativeMachine);process_machine=('0x{0:x4}' -f $processMachine);guest_kernel_architecture='ARM64';secure_boot_enabled=[bool](Confirm-SecureBootUEFI);tpm=$tpm;hypervisor_present=(Get-CimInstance Win32_ComputerSystem).HypervisorPresent;vbs_status=$guard.VirtualizationBasedSecurityStatus;security_services_running=$guard.SecurityServicesRunning;bcd_security=$security} | ConvertTo-Json -Depth 6 -Compress
