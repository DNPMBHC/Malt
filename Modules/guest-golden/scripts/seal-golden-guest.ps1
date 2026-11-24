# Golden Guest v1 Sealing & Verification Script
# Owner: @DNPMBHC
# Verifies WHQL viogpu3d, security invariants, 4C optimizer state, cleans Windows Update
# download cache, checks zero commercial residue, and emits structured JSON.
[CmdletBinding()]
param(
    [switch]$CleanCache,
    [string]$OptimizerStateDir = (Join-Path $env:SystemDrive 'graphics-lab\guest-optimizer')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Test-BcdSafe {
    $bcdLines = @(& bcdedit.exe /enum '{current}' 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return @{
            bcd_query_ok = $false
            test_signing_disabled = $false
            nointegritychecks_disabled = $false
            bcd_safe = $false
        }
    }
    $text = ($bcdLines -join "`n")
    $testSigningOn = ($text -match '(?im)^\s*testsigning\s+Yes\s*$')
    $noIntegrityOn = ($text -match '(?im)^\s*nointegritychecks\s+Yes\s*$')
    return @{
        bcd_query_ok = $true
        test_signing_disabled = (-not $testSigningOn)
        nointegritychecks_disabled = (-not $noIntegrityOn)
        bcd_safe = ((-not $testSigningOn) -and (-not $noIntegrityOn))
    }
}

function Get-PrismStatus {
    $relPaths = @(
        'System32\xtajit.dll',
        'System32\xtajit64.dll',
        'System32\wow64.dll',
        'System32\wow64win.dll'
    )
    $items = @()
    $allExist = $true
    $allValid = $true
    foreach ($rel in $relPaths) {
        $full = Join-Path $env:SystemRoot $rel
        $exists = Test-Path -LiteralPath $full
        $sigStatus = 'Missing'
        if ($exists) {
            try {
                $sigStatus = [string](Get-AuthenticodeSignature -LiteralPath $full).Status
            } catch {
                $sigStatus = 'Error'
            }
        }
        if (-not $exists) { $allExist = $false }
        if ($sigStatus -ne 'Valid') { $allValid = $false }
        $items += @{
            relative_path = $rel
            exists = $exists
            signature_status = $sigStatus
        }
    }
    return @{
        prism_files = $items
        prism_files_verified = $allExist
        prism_signatures_valid = $allValid
    }
}

function Get-Viogpu3dStatus {
    $videoControllers = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    $virtioController = $videoControllers | Where-Object {
        $_.Name -like '*VirtIO GPU 3D*' -or $_.PNPDeviceID -like '*VEN_1AF4*DEV_1050*'
    } | Select-Object -First 1

    $pnpDriver = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object {
        $_.InfName -like 'viogpu3d*.inf' -or $_.DeviceName -like '*VirtIO GPU 3D*'
    } | Select-Object -First 1

    $driverRepoDirs = @(Get-ChildItem -Path (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository') -Directory -Filter 'viogpu3d.inf_*' -ErrorAction SilentlyContinue)
    $components = @{}
    $requiredNames = @('viogpu3d.sys', 'neptune_umd_arm64.dll', 'neptune_umd_ec.dll', 'vulkan_virtio_arm64.dll')
    foreach ($name in $requiredNames) {
        $found = $false
        foreach ($dir in $driverRepoDirs) {
            if (Test-Path -LiteralPath (Join-Path $dir.FullName $name)) {
                $found = $true
                break
            }
        }
        if (-not $found -and (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$name"))) {
            $found = $true
        }
        if (-not $found -and (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\drivers\$name"))) {
            $found = $true
        }
        $components[$name] = $found
    }

    $driverVersion = if ($pnpDriver) { [string]$pnpDriver.DriverVersion } elseif ($virtioController) { [string]$virtioController.DriverVersion } else { '' }
    $isSigned = if ($pnpDriver) { [bool]$pnpDriver.IsSigned } else { $false }
    $signer = if ($pnpDriver) { [string]$pnpDriver.Signer } else { '' }
    $status = if ($virtioController) { [string]$virtioController.Status } else { 'Missing' }
    $errCode = if ($virtioController) { [int]$virtioController.ConfigManagerErrorCode } else { -1 }

    return @{
        adapter_present = ($null -ne $virtioController)
        adapter_name = if ($virtioController) { [string]$virtioController.Name } else { '' }
        pnp_device_id = if ($virtioController) { [string]$virtioController.PNPDeviceID } else { '' }
        status = $status
        config_manager_error_code = $errCode
        driver_version = $driverVersion
        is_signed = $isSigned
        signer = $signer
        inf_name = if ($pnpDriver) { [string]$pnpDriver.InfName } else { '' }
        components_present = $components
        all_components_present = (($components.Values | Where-Object { -not $_ }).Count -eq 0)
        whql_ready = (($null -ne $virtioController) -and ($status -eq 'OK') -and ($errCode -eq 0) -and $isSigned -and ($driverVersion -eq '100.6.101.58000'))
    }
}

function Invoke-CacheCleanup {
    $downloadDir = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    $removedItems = 0
    $freedBytes = [int64]0
    if (Test-Path -LiteralPath $downloadDir) {
        $wuSvc = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
        $wasRunning = ($null -ne $wuSvc -and $wuSvc.Status -eq 'Running')
        if ($wasRunning) {
            Stop-Service -Name 'wuauserv' -Force -ErrorAction SilentlyContinue
        }
        try {
            $entries = @(Get-ChildItem -LiteralPath $downloadDir -Force -ErrorAction SilentlyContinue)
            foreach ($entry in $entries) {
                try {
                    if ($entry.PSIsContainer) {
                        $size = (Get-ChildItem -LiteralPath $entry.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                        if ($null -ne $size) { $freedBytes += [int64]$size }
                        Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    } else {
                        $freedBytes += [int64]$entry.Length
                        Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction SilentlyContinue
                    }
                    $removedItems += 1
                } catch {
                }
            }
        } finally {
            if ($wasRunning) {
                Start-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
            }
        }
    }
    return @{
        cleaned = $true
        windows_update_download_dir_exists = (Test-Path -LiteralPath $downloadDir)
        removed_entries = $removedItems
        freed_bytes = $freedBytes
    }
}

function Get-CommercialResidueCheck {
    $forbiddenServices = @(
        'vgc', 'vgk', 'ACE-BASE', 'ACE-GAME',
        'AntiCheatExpert Service', 'AntiCheatExpert Protection',
        'EasyAntiCheat', 'EasyAntiCheat_EOS', 'BEService'
    )
    $foundServices = @()
    foreach ($svcName in $forbiddenServices) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            $foundServices += $svcName
        }
    }
    $forbiddenPaths = @(
        (Join-Path $env:SystemDrive 'Riot Games'),
        (Join-Path $env:ProgramFiles 'Riot Vanguard'),
        (Join-Path $env:ProgramFiles 'AntiCheatExpert'),
        (Join-Path ${env:ProgramFiles(x86)} 'WeGame')
    )
    $foundPaths = @()
    foreach ($p in $forbiddenPaths) {
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p)) {
            $foundPaths += $p
        }
    }
    return @{
        found_services = $foundServices
        found_paths = $foundPaths
        zero_commercial_residue = (($foundServices.Count -eq 0) -and ($foundPaths.Count -eq 0))
    }
}

$secureBoot = $false
try { $secureBoot = [bool](Confirm-SecureBootUEFI) } catch { $secureBoot = $false }

$tpmPresent = $false
$tpmEnabled = $false
$tpmReady = $false
try {
    $tpm = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
    if ($null -ne $tpm) {
        $tpmPresent = $true
        $tpmEnabled = [bool]$tpm.IsEnabled_InitialValue
        $tpmReady = [bool]$tpm.IsActivated_InitialValue
    }
} catch {
}

$qgaSvc = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
$qgaRunning = ($null -ne $qgaSvc -and $qgaSvc.Status -eq 'Running')

$bcd = Test-BcdSafe
$prism = Get-PrismStatus
$gpu = Get-Viogpu3dStatus

$cleanupReport = if ($CleanCache) {
    Invoke-CacheCleanup
} else {
    @{
        cleaned = $false
        removed_entries = 0
        freed_bytes = 0
    }
}

$residue = Get-CommercialResidueCheck

$snapshotPath = Join-Path $OptimizerStateDir 'snapshot-initial.json'
$optimizerApplied = (Test-Path -LiteralPath $snapshotPath)

$drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem

$report = @{
    schema_version = 1
    owner = '@DNPMBHC'
    captured_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    os = @{
        caption = [string]$os.Caption
        version = [string]$os.Version
        build_number = [string]$os.BuildNumber
        architecture = [string]$os.OSArchitecture
        logical_processors = [int]$cs.NumberOfLogicalProcessors
        total_physical_memory_bytes = [int64]$cs.TotalPhysicalMemory
    }
    disk = @{
        system_drive_used_bytes = [int64]$drive.Used
        system_drive_free_bytes = [int64]$drive.Free
        system_drive_total_bytes = [int64]($drive.Used + $drive.Free)
    }
    security_invariants = @{
        secure_boot_enabled = $secureBoot
        test_signing_disabled = $bcd.test_signing_disabled
        nointegritychecks_disabled = $bcd.nointegritychecks_disabled
        bcd_safe = $bcd.bcd_safe
        tpm_present = $tpmPresent
        tpm_enabled = $tpmEnabled
        tpm_ready = $tpmReady
        qga_service_running = $qgaRunning
        prism_files_verified = $prism.prism_files_verified
        prism_signatures_valid = $prism.prism_signatures_valid
        prism_files = $prism.prism_files
    }
    graphics_driver = $gpu
    optimizer = @{
        state_dir = $OptimizerStateDir
        rollback_snapshot_present = $optimizerApplied
    }
    cache_cleanup = $cleanupReport
    commercial_residue = $residue
    all_golden_checks_passed = (
        $secureBoot -and
        $bcd.bcd_safe -and
        $tpmPresent -and
        $tpmEnabled -and
        $qgaRunning -and
        $prism.prism_files_verified -and
        $prism.prism_signatures_valid -and
        $gpu.whql_ready -and
        $gpu.all_components_present -and
        $optimizerApplied -and
        $residue.zero_commercial_residue
    )
}

$report | ConvertTo-Json -Depth 6 -Compress
