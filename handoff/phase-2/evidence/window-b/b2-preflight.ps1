$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$os = Get-CimInstance Win32_OperatingSystem
$computer = Get-CimInstance Win32_ComputerSystem
$secureBoot = 'unknown'
try { $secureBoot = [string](Confirm-SecureBootUEFI) } catch { $secureBoot = 'unavailable' }
$tpm = 'unknown'
try { $tpm = Get-Tpm | Select-Object TpmPresent,TpmReady,TpmEnabled,TpmActivated } catch { $tpm = 'unavailable' }
$deviceGuard = $null
try { $deviceGuard = Get-CimInstance -Namespace root/Microsoft/Windows/DeviceGuard -ClassName Win32_DeviceGuard | Select-Object VirtualizationBasedSecurityStatus,SecurityServicesConfigured,SecurityServicesRunning,AvailableSecurityProperties } catch {}
$bcd = (& bcdedit.exe /enum '{current}' 2>&1 | Out-String)
$bcdSecurity = @($bcd.Split([Environment]::NewLine) | Where-Object { $_ -match 'testsigning|nointegritychecks|hypervisorlaunchtype|vsmlaunchtype' } | ForEach-Object { $_.Trim() })
$programRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
$vswhere = $programRoots | ForEach-Object { Join-Path $_ 'Microsoft Visual Studio/Installer/vswhere.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
$visualStudio = @()
if ($vswhere) {
    $instances = & $vswhere -all -products '*' -format json | ConvertFrom-Json
    $visualStudio = @($instances | Select-Object installationVersion,displayName,isComplete,isLaunchable)
}
$kits = $null
try { $kits = (Get-ItemProperty 'HKLM:/SOFTWARE/Microsoft/Windows Kits/Installed Roots').KitsRoot10 } catch {}
$kitVersions = @()
if ($kits) {
    $kitVersions = @(Get-ChildItem (Join-Path $kits 'Include') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{version=$_.Name;kernel_headers_present=(Test-Path (Join-Path $_.FullName 'km/ntddk.h'));shared_headers_present=(Test-Path (Join-Path $_.FullName 'shared'))}
    })
}
$result = [ordered]@{
    captured_at_utc = [DateTime]::UtcNow.ToString('o')
    os_caption = $os.Caption
    os_version = $os.Version
    os_build = $os.BuildNumber
    os_architecture = $os.OSArchitecture
    kernel_architecture_environment = $env:PROCESSOR_ARCHITECTURE
    boot_time_utc = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    administrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    session_id = (Get-Process -Id $PID).SessionId
    hypervisor_present = $computer.HypervisorPresent
    secure_boot = $secureBoot
    tpm = $tpm
    device_guard = $deviceGuard
    bcd_security = $bcdSecurity
    qga_running = [bool](Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'qemu-ga' -and $_.Status -eq 'Running' })
    visual_studio = $visualStudio
    kit_versions = $kitVersions
    logical_disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { [pscustomobject]@{size_bytes=[long]$_.Size;free_bytes=[long]$_.FreeSpace;system_drive=($_.DeviceID -eq $env:SystemDrive)} })
}
$result | ConvertTo-Json -Depth 8 -Compress
