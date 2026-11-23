# Anti-cheat minimal Windows 11 24H2 ARM64 Guest optimizer (apply).
# Owner: @DNPMBHC
# Compliance: Strictly removes non-essential consumer bloat and background overhead.
# Never modifies Secure Boot, TPM, BCD, Code Integrity, Prism AVX/AVX2, or anti-cheat drivers.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfilePath,
    [string]$StateDirectory = (Join-Path $env:SystemDrive 'graphics-lab\guest-optimizer'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$HardProtectedServices = @(
    'BFE', 'CoreMessagingRegistrar', 'CryptSvc', 'DcomLaunch', 'Dhcp', 'Dnscache',
    'EventLog', 'KeyIso', 'LSM', 'mpssvc', 'Netman', 'NlaSvc', 'nsi', 'PlugPlay',
    'Power', 'QEMU-GA', 'RpcEptMapper', 'RpcSs', 'SamSs', 'Schedule',
    'SecurityHealthService', 'Sense', 'SystemEventsBroker', 'TBS',
    'TrustedInstaller', 'UserManager', 'VaultSvc', 'VirtioFsSvc', 'WinDefend',
    'Winmgmt', 'Audiosrv', 'AudioEndpointBuilder', 'wuauserv',
    'vgc', 'vgk', 'ACE-BASE', 'ACE-GAME', 'AntiCheatExpert Service',
    'AntiCheatExpert Protection', 'EasyAntiCheat', 'EasyAntiCheat_EOS', 'BEService'
)

$HardProtectedAppxPrefixes = @(
    'Microsoft.VCLibs', 'Microsoft.UI.Xaml', 'Microsoft.NET', 'Microsoft.DirectX',
    'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost',
    'Microsoft.Windows.SecHealthUI', 'Microsoft.AAD.BrokerPlugin',
    'Microsoft.AccountsControl', 'Microsoft.LockApp', 'Microsoft.DesktopAppInstaller',
    'Microsoft.Services.Store.Engagement', 'Microsoft.StorePurchaseApp',
    'Microsoft.WindowsStore'
)

$HardProtectedTaskPrefixes = @(
    '\Microsoft\Windows\Windows Defender\',
    '\Microsoft\Windows\TPM\',
    '\Microsoft\Windows\Device Information\',
    '\Microsoft\Windows\CertificateServicesClient\',
    '\Microsoft\Windows\Servicing\',
    '\Microsoft\Windows\TaskScheduler\'
)

function Get-FileSha256Lower([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-PrefixMatch([string]$Value, [string[]]$Prefixes) {
    foreach ($prefix in $Prefixes) {
        if ($Value.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Assert-ProfileSafe($Profile) {
    if ($null -eq $Profile -or $Profile.schema_version -ne 1) {
        throw 'optimizer profile schema_version must be 1'
    }
    if ($Profile.compliance.forbid_virtualization_hiding -ne $true -or
        $Profile.compliance.forbid_hardware_spoofing -ne $true -or
        $Profile.compliance.forbid_bcd_or_ci_weakening -ne $true -or
        $Profile.compliance.forbid_kernel_driver_tampering -ne $true -or
        $Profile.compliance.preserve_official_signatures -ne $true) {
        throw 'optimizer profile compliance flags must all be true'
    }

    $protectedServices = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($svc in $HardProtectedServices) { [void]$protectedServices.Add($svc) }
    foreach ($svc in @($Profile.protected_whitelist.services)) { [void]$protectedServices.Add([string]$svc) }

    $protectedAppx = @($HardProtectedAppxPrefixes) + @($Profile.protected_whitelist.appx_prefixes)
    $protectedTasks = @($HardProtectedTaskPrefixes) + @($Profile.protected_whitelist.task_prefixes)

    foreach ($svcEntry in @($Profile.optimization_blacklist.services)) {
        $name = [string]$svcEntry.name
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw 'blacklist service name cannot be empty'
        }
        if ($protectedServices.Contains($name)) {
            throw "whitelist violation: protected service '$name' is in optimization_blacklist"
        }
        if ($svcEntry.target_start_type -notin @('Disabled', 'Manual')) {
            throw "invalid target_start_type for service '$name'"
        }
    }

    foreach ($pkg in @($Profile.optimization_blacklist.uwp_packages)) {
        $pkgName = [string]$pkg
        if ([string]::IsNullOrWhiteSpace($pkgName)) {
            throw 'blacklist UWP package name cannot be empty'
        }
        if (Test-PrefixMatch $pkgName $protectedAppx) {
            throw "whitelist violation: protected UWP package '$pkgName' is in optimization_blacklist"
        }
    }

    foreach ($taskEntry in @($Profile.optimization_blacklist.scheduled_tasks)) {
        $fullPath = ([string]$taskEntry.task_path) + ([string]$taskEntry.task_name)
        if (Test-PrefixMatch $fullPath $protectedTasks) {
            throw "whitelist violation: protected scheduled task '$fullPath' is in optimization_blacklist"
        }
    }

    foreach ($regEntry in @($Profile.optimization_blacklist.registry_tweaks)) {
        $regPath = [string]$regEntry.path
        if (-not $regPath.StartsWith('HKCU:\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "whitelist violation: registry tweak must be scoped to HKCU:\ ($regPath)"
        }
        if ($regPath -match '(?i)DeviceGuard|CodeIntegrity|Lsa|Policies\\System|CurrentControlSet') {
            throw "whitelist violation: forbidden security registry path ($regPath)"
        }
    }
}

function Read-SecurityAndPrismInvariants($Profile) {
    $secureBoot = $null
    try { $secureBoot = [bool](Confirm-SecureBootUEFI) } catch { $secureBoot = $false }

    $tpmPresent = $false
    $tpmEnabled = $false
    try {
        $tpm = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName Win32_Tpm
        if ($null -ne $tpm) {
            $tpmPresent = $true
            $tpmEnabled = [bool]$tpm.IsEnabled_InitialValue
        }
    } catch { }

    $bcdSafe = $false
    try {
        $bcd = @(& bcdedit.exe /enum '{current}' 2>$null)
        if ($LASTEXITCODE -eq 0) {
            $unsafe = @($bcd | Where-Object { $_ -match '^\s*(testsigning|nointegritychecks)\s+(yes|on|true|1|enabled)\s*$' })
            $bcdSafe = ($unsafe.Count -eq 0)
        }
    } catch { }

    $prismResults = @()
    $allPrismVerified = $true
    $allPrismSigned = $true
    foreach ($rel in @($Profile.protected_whitelist.prism_files)) {
        $full = Join-Path $env:SystemRoot ([string]$rel)
        $exists = Test-Path -LiteralPath $full
        $sigStatus = 'Missing'
        if ($exists) {
            try {
                $sigStatus = [string](Get-AuthenticodeSignature -FilePath $full).Status
            } catch {
                $sigStatus = 'Error'
            }
        }
        if (-not $exists) { $allPrismVerified = $false }
        if ($sigStatus -ne 'Valid') { $allPrismSigned = $false }
        $prismResults += [ordered]@{
            relative_path = [string]$rel
            exists = $exists
            signature_status = $sigStatus
        }
    }

    $qgaRunning = $false
    try {
        $qga = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
        if ($null -ne $qga -and $qga.Status -eq 'Running') { $qgaRunning = $true }
    } catch { }

    return [ordered]@{
        secure_boot_enabled = $secureBoot
        tpm_present = $tpmPresent
        tpm_enabled = $tpmEnabled
        bcd_safe = $bcdSafe
        prism_files_verified = $allPrismVerified
        prism_signatures_valid = $allPrismSigned
        prism_files = $prismResults
        qga_service_running = $qgaRunning
    }
}

function Read-GuestMetrics {
    $processes = @(Get-Process -ErrorAction SilentlyContinue)
    $runningServices = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    $usedBytes = [int64]($drive.Size - $drive.FreeSpace)
    return [ordered]@{
        process_count = $processes.Count
        running_service_count = $runningServices.Count
        system_drive_total_bytes = [int64]$drive.Size
        system_drive_used_bytes = $usedBytes
        system_drive_free_bytes = [int64]$drive.FreeSpace
    }
}

function Capture-InitialSnapshot($Profile, [string]$ProfileSha) {
    $svcSnap = @()
    foreach ($svcEntry in @($Profile.optimization_blacklist.services)) {
        $name = [string]$svcEntry.name
        $cim = Get-CimInstance Win32_Service -Filter ("Name='" + $name.Replace("'", "''") + "'") -ErrorAction SilentlyContinue
        if ($null -eq $cim) {
            $svcSnap += [ordered]@{ name = $name; exists = $false; start_mode = $null; state = $null; delayed_autostart = $null }
            continue
        }
        $regKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
        $delayed = $null
        try {
            $prop = Get-ItemProperty -Path $regKey -Name 'DelayedAutostart' -ErrorAction SilentlyContinue
            if ($null -ne $prop) { $delayed = [int]$prop.DelayedAutostart }
        } catch { }
        $svcSnap += [ordered]@{
            name = $name
            exists = $true
            start_mode = [string]$cim.StartMode
            state = [string]$cim.State
            delayed_autostart = $delayed
        }
    }

    $taskSnap = @()
    foreach ($taskEntry in @($Profile.optimization_blacklist.scheduled_tasks)) {
        $taskPath = [string]$taskEntry.task_path
        $taskName = [string]$taskEntry.task_name
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            $taskSnap += [ordered]@{ task_path = $taskPath; task_name = $taskName; exists = $false; state = $null }
        } else {
            $taskSnap += [ordered]@{ task_path = $taskPath; task_name = $taskName; exists = $true; state = [string]$task.State }
        }
    }

    $uwpSnap = @()
    foreach ($pkgName in @($Profile.optimization_blacklist.uwp_packages)) {
        $installed = @(Get-AppxPackage -Name ([string]$pkgName) -ErrorAction SilentlyContinue)
        if ($installed.Count -eq 0) {
            $uwpSnap += [ordered]@{ name = [string]$pkgName; installed = $false; packages = @() }
            continue
        }
        $pkgItems = @()
        foreach ($pkg in $installed) {
            $manifest = if ($pkg.InstallLocation) { Join-Path $pkg.InstallLocation 'AppxManifest.xml' } else { $null }
            $pkgItems += [ordered]@{
                package_full_name = [string]$pkg.PackageFullName
                manifest_exists = ($null -ne $manifest -and (Test-Path -LiteralPath $manifest))
                manifest_path = $manifest
                non_removable = [bool]$pkg.NonRemovable
            }
        }
        $uwpSnap += [ordered]@{ name = [string]$pkgName; installed = $true; packages = $pkgItems }
    }

    $regSnap = @()
    foreach ($regEntry in @($Profile.optimization_blacklist.registry_tweaks)) {
        $regPath = [string]$regEntry.path
        $regName = [string]$regEntry.name
        $existed = $false
        $oldVal = $null
        $oldKind = [string]$regEntry.kind
        if (Test-Path -LiteralPath $regPath) {
            try {
                $item = Get-Item -LiteralPath $regPath -ErrorAction Stop
                if ($item.Property -contains $regName) {
                    $existed = $true
                    $oldVal = $item.GetValue($regName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $oldKind = [string]$item.GetValueKind($regName)
                }
            } catch { }
        }
        $regSnap += [ordered]@{
            path = $regPath
            name = $regName
            existed = $existed
            value = $oldVal
            kind = $oldKind
        }
    }

    return [ordered]@{
        schema_version = 1
        owner = '@DNPMBHC'
        captured_at_utc = [DateTime]::UtcNow.ToString('o')
        profile_id = [string]$Profile.profile_id
        profile_sha256 = $ProfileSha
        services = $svcSnap
        scheduled_tasks = $taskSnap
        uwp_packages = $uwpSnap
        registry_tweaks = $regSnap
    }
}

$profileData = Get-Content -Raw -LiteralPath $ProfilePath | ConvertFrom-Json
Assert-ProfileSafe $profileData

$profileSha = Get-FileSha256Lower $ProfilePath
$scriptSha = Get-FileSha256Lower $PSCommandPath

New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null
$snapshotPath = Join-Path $StateDirectory 'snapshot-initial.json'
$snapshotReused = $false
if (Test-Path -LiteralPath $snapshotPath) {
    $snapshotReused = $true
} elseif (-not $DryRun) {
    $initialSnapshot = Capture-InitialSnapshot $profileData $profileSha
    $initialSnapshot | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $snapshotPath
}

$metricsBefore = Read-GuestMetrics
$serviceChanges = @()
$taskChanges = @()
$uwpChanges = @()
$registryChanges = @()

foreach ($svcEntry in @($profileData.optimization_blacklist.services)) {
    $name = [string]$svcEntry.name
    $targetStart = [string]$svcEntry.target_start_type
    $svcObj = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $svcObj) {
        $serviceChanges += [ordered]@{ name = $name; status = 'not_present' }
        continue
    }
    if ($DryRun) {
        $serviceChanges += [ordered]@{ name = $name; status = 'dry_run'; target_start_type = $targetStart }
        continue
    }
    try {
        Set-Service -Name $name -StartupType $targetStart -ErrorAction Stop | Out-Null
        if ($svcEntry.stop_running -eq $true -and $svcObj.Status -eq 'Running') {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $after = Get-Service -Name $name -ErrorAction SilentlyContinue
        $serviceChanges += [ordered]@{
            name = $name
            status = 'applied'
            target_start_type = $targetStart
            running_after = ($null -ne $after -and $after.Status -eq 'Running')
        }
    } catch {
        $serviceChanges += [ordered]@{ name = $name; status = 'skipped_protected' }
    }
}

foreach ($taskEntry in @($profileData.optimization_blacklist.scheduled_tasks)) {
    $taskPath = [string]$taskEntry.task_path
    $taskName = [string]$taskEntry.task_name
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        $taskChanges += [ordered]@{ task = ($taskPath + $taskName); status = 'not_present' }
        continue
    }
    if ($DryRun) {
        $taskChanges += [ordered]@{ task = ($taskPath + $taskName); status = 'dry_run' }
        continue
    }
    try {
        if ($task.State -ne 'Disabled') {
            Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop | Out-Null
        }
        $taskChanges += [ordered]@{ task = ($taskPath + $taskName); status = 'disabled' }
    } catch {
        $taskChanges += [ordered]@{ task = ($taskPath + $taskName); status = 'skipped_error' }
    }
}

foreach ($pkgName in @($profileData.optimization_blacklist.uwp_packages)) {
    $installed = @(Get-AppxPackage -Name ([string]$pkgName) -ErrorAction SilentlyContinue)
    if ($installed.Count -eq 0) {
        $uwpChanges += [ordered]@{ name = [string]$pkgName; status = 'not_present' }
        continue
    }
    $removedCount = 0
    $skippedNonRemovable = 0
    $failedCount = 0
    foreach ($pkg in $installed) {
        if ($pkg.NonRemovable) {
            $skippedNonRemovable++
            continue
        }
        if ($DryRun) {
            $removedCount++
            continue
        }
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop | Out-Null
            $removedCount++
        } catch {
            $failedCount++
        }
    }
    $stateLabel = if ($DryRun) { 'dry_run' } elseif ($removedCount -gt 0 -and $failedCount -eq 0) { 'removed_user_registration' } elseif ($skippedNonRemovable -gt 0 -and $removedCount -eq 0) { 'skipped_non_removable' } else { 'partial_or_skipped' }
    $uwpChanges += [ordered]@{
        name = [string]$pkgName
        status = $stateLabel
        removed_count = $removedCount
        skipped_non_removable = $skippedNonRemovable
        failed_count = $failedCount
    }
}

foreach ($regEntry in @($profileData.optimization_blacklist.registry_tweaks)) {
    $regPath = [string]$regEntry.path
    $regName = [string]$regEntry.name
    $regKind = [string]$regEntry.kind
    $regVal = $regEntry.value
    if ($DryRun) {
        $registryChanges += [ordered]@{ name = $regName; status = 'dry_run' }
        continue
    }
    try {
        if (-not (Test-Path -LiteralPath $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        New-ItemProperty -Path $regPath -Name $regName -Value $regVal -PropertyType $regKind -Force | Out-Null
        $registryChanges += [ordered]@{ name = $regName; status = 'applied' }
    } catch {
        $registryChanges += [ordered]@{ name = $regName; status = 'skipped_error' }
    }
}

$metricsAfter = Read-GuestMetrics
$invariants = Read-SecurityAndPrismInvariants $profileData
$invariantsPassed = (
    $invariants.secure_boot_enabled -eq $true -and
    $invariants.tpm_present -eq $true -and
    $invariants.tpm_enabled -eq $true -and
    $invariants.bcd_safe -eq $true -and
    $invariants.prism_files_verified -eq $true -and
    $invariants.prism_signatures_valid -eq $true -and
    $invariants.qga_service_running -eq $true
)

$report = [ordered]@{
    schema_version = 1
    owner = '@DNPMBHC'
    action = if ($DryRun) { 'dry_run' } else { 'apply' }
    captured_at_utc = [DateTime]::UtcNow.ToString('o')
    profile_id = [string]$profileData.profile_id
    profile_sha256 = $profileSha
    script_sha256 = $scriptSha
    snapshot_reused = $snapshotReused
    whitelist_guard_passed = $true
    security_invariants_passed = $invariantsPassed
    security_invariants = $invariants
    metrics_before = $metricsBefore
    metrics_after = $metricsAfter
    changes = [ordered]@{
        services = $serviceChanges
        scheduled_tasks = $taskChanges
        uwp_packages = $uwpChanges
        registry_tweaks = $registryChanges
    }
}

if (-not $DryRun) {
    $reportPath = Join-Path $StateDirectory 'last-apply-report.json'
    $report | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $reportPath
}

$report | ConvertTo-Json -Depth 8 -Compress
