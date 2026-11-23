[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('cycle', 'before-reboot', 'after-reboot')]
    [string]$Phase,

    [Parameter(Mandatory)]
    [string]$DriverImage,

    [Parameter(Mandatory)]
    [string]$CollectorPath,

    [string]$RebootStatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ServiceName = 'module-x-probe-lifecycle'
$FailureServiceName = 'module-x-probe-start-failure'
$script:Events = [System.Collections.Generic.List[object]]::new()
$leaveServiceForReboot = $false

function Assert-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this lifecycle check from an elevated PowerShell session.'
    }
}

function Get-ServiceEntry([string]$Name) {
    Get-Service -Name $Name -ErrorAction SilentlyContinue
}

function Invoke-ServiceControl([string]$Operation, [string[]]$Arguments, [switch]$AllowFailure) {
    $output = & sc.exe $Operation @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $script:Events.Add([pscustomobject]@{
            stage = 'service-control'
            operation = $Operation
            win32Error = $exitCode
        })
        if (-not $AllowFailure) {
            throw "sc.exe $Operation failed with exit code $exitCode."
        }
    }
    return $exitCode
}

function New-Nonce {
    $bytes = [byte[]]::new(32)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Get-RequiredPropertyValue($Object, [string]$Name, [string]$Stage) {
    if ($null -eq $Object) {
        throw "Collector returned an incomplete report during '$Stage' (missing '$Name')."
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "Collector returned an incomplete report during '$Stage' (missing '$Name')."
    }
    return $property.Value
}

function Assert-StringProperty($Object, [string]$Name, [string]$Stage) {
    $value = Get-RequiredPropertyValue $Object $Name $Stage
    if ($value -isnot [string]) {
        throw "Collector returned a non-string '$Name' during '$Stage'."
    }
}

function Assert-BooleanProperty($Object, [string]$Name, [string]$Stage) {
    $value = Get-RequiredPropertyValue $Object $Name $Stage
    if ($value -isnot [bool]) {
        throw "Collector returned a non-boolean '$Name' during '$Stage'."
    }
}

function Assert-UnsignedProperty($Object, [string]$Name, [string]$Stage) {
    $value = Get-RequiredPropertyValue $Object $Name $Stage
    if (($value -isnot [byte] -and $value -isnot [sbyte] -and
         $value -isnot [int16] -and $value -isnot [uint16] -and
         $value -isnot [int32] -and $value -isnot [uint32] -and
         $value -isnot [int64] -and $value -isnot [uint64]) -or $value -lt 0) {
        throw "Collector returned a non-unsigned-integer '$Name' during '$Stage'."
    }
}

function Resolve-ServiceImagePath([string]$PathName) {
    if ([string]::IsNullOrWhiteSpace($PathName)) { return $null }
    $path = $PathName.Trim()
    if ($path.StartsWith('"')) {
        if ($path -notmatch '^"([^"]+)"$') { return $null }
        $path = $Matches[1]
    } elseif ($path.Contains('"')) {
        return $null
    }
    $path = [Environment]::ExpandEnvironmentVariables($path)
    if ($path.Contains('%')) { return $null }
    if ($path.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        $path = $path.Substring(4)
    }
    if ($path.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
        if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { return $null }
        $path = Join-Path $env:SystemRoot $path.Substring(12)
    } elseif ($path -match '(?i)^System32[\\/]') {
        if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { return $null }
        $path = Join-Path $env:SystemRoot $path
    }
    if ($path -notmatch '^[A-Za-z]:[\\/]') { return $null }
    try { return [IO.Path]::GetFullPath($path) } catch { return $null }
}

function Assert-ServiceImageIdentity([string]$Stage) {
    $entry = Get-CimInstance -ClassName Win32_SystemDriver -Filter "Name='$ServiceName'"
    if ($null -eq $entry) { throw "Service image identity is unavailable during '$Stage'." }
    $pathName = Get-RequiredPropertyValue $entry 'PathName' $Stage
    if ($pathName -isnot [string]) { throw "Service image identity is malformed during '$Stage'." }
    $actualPath = Resolve-ServiceImagePath $pathName
    $expectedPath = [IO.Path]::GetFullPath($DriverImage)
    if ($null -eq $actualPath -or
        -not [string]::Equals($actualPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Service image identity does not match DriverImage during '$Stage'."
    }
    return $true
}

function Get-BootTimestamp {
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -Property LastBootUpTime
    if ($null -eq $operatingSystem -or $null -eq $operatingSystem.LastBootUpTime) {
        throw 'Cannot verify the Windows boot timestamp.'
    }
    return ([datetime]$operatingSystem.LastBootUpTime).ToUniversalTime()
}

function Get-ArtifactHashes {
    return [pscustomobject]@{
        driverSha256 = (Get-FileHash -LiteralPath $DriverImage -Algorithm SHA256).Hash.ToLowerInvariant()
        collectorSha256 = (Get-FileHash -LiteralPath $CollectorPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Save-RebootState {
    if (Test-Path -LiteralPath $RebootStatePath) {
        throw 'A reboot baseline already exists; refusing to replace it.'
    }
    $hashes = Get-ArtifactHashes
    $state = [pscustomobject]@{
        schemaVersion = 1
        serviceName = $ServiceName
        bootedAtUtc = (Get-BootTimestamp).ToString('o')
        driverSha256 = $hashes.driverSha256
        collectorSha256 = $hashes.collectorSha256
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $RebootStatePath -Encoding UTF8
    $script:Events.Add([pscustomobject]@{
        stage = 'reboot-baseline'
        bootedAtUtc = $state.bootedAtUtc
        driverSha256 = $state.driverSha256
        collectorSha256 = $state.collectorSha256
    })
}

function Assert-RebootOccurred {
    if (-not (Test-Path -LiteralPath $RebootStatePath -PathType Leaf)) {
        throw 'Run before-reboot first; the reboot baseline is missing.'
    }
    $state = Get-Content -LiteralPath $RebootStatePath -Raw | ConvertFrom-Json
    if ((Get-RequiredPropertyValue $state 'schemaVersion' 'reboot') -ne 1 -or
        (Get-RequiredPropertyValue $state 'serviceName' 'reboot') -ne $ServiceName) {
        throw 'The reboot baseline is incompatible with this lifecycle run.'
    }
    $previousBoot = [datetime]::Parse(
        (Get-RequiredPropertyValue $state 'bootedAtUtc' 'reboot'),
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
    $currentBoot = Get-BootTimestamp
    if ($currentBoot -le $previousBoot) {
        throw 'No later Windows boot was observed; restart the guest before after-reboot.'
    }
    $hashes = Get-ArtifactHashes
    if ($hashes.driverSha256 -ne (Get-RequiredPropertyValue $state 'driverSha256' 'reboot') -or
        $hashes.collectorSha256 -ne (Get-RequiredPropertyValue $state 'collectorSha256' 'reboot')) {
        throw 'The driver or collector changed across reboot.'
    }
    $script:Events.Add([pscustomobject]@{
        stage = 'reboot-verified'
        beforeBootedAtUtc = $previousBoot.ToUniversalTime().ToString('o')
        afterBootedAtUtc = $currentBoot.ToString('o')
        actualRebootObserved = $true
        artifactsUnchanged = $true
        driverSha256 = $hashes.driverSha256
        collectorSha256 = $hashes.collectorSha256
    })
}

function Assert-ProbeReportShape($Report, [string]$Stage) {
    Assert-UnsignedProperty $Report 'schemaVersion' $Stage
    Assert-StringProperty $Report 'nonce' $Stage
    $driver = Get-RequiredPropertyValue $Report 'driver' $Stage
    Assert-UnsignedProperty $driver 'protocolVersion' $Stage
    foreach ($name in @('candidateImageArchitecture', 'loadedProbeArchitecture', 'candidateImageAuthenticode')) {
        Assert-StringProperty $driver $name $Stage
    }
    $guest = Get-RequiredPropertyValue $Report 'guest' $Stage
    foreach ($name in @('kernelArchitecture', 'processArchitecture')) {
        Assert-StringProperty $guest $name $Stage
    }
    Assert-UnsignedProperty $guest 'windowsBuild' $Stage
    Assert-StringProperty $driver 'loadState' $Stage
    $observation = Get-RequiredPropertyValue $Report 'observation' $Stage
    Assert-StringProperty $observation 'failureStage' $Stage
    foreach ($name in @('deviceControlSucceeded', 'sameProcessObject', 'requestorMatchesCurrentContext')) {
        Assert-BooleanProperty $observation $name $Stage
    }
    foreach ($name in @('win32Error', 'bytesReturned', 'requestorPID', 'observedPID', 'dispatchAttachedContextPID')) {
        Assert-UnsignedProperty $observation $name $Stage
    }
    $notification = Get-RequiredPropertyValue $observation 'notification' $Stage
    foreach ($name in @('attempted', 'createObserved', 'exitObserved', 'childCleanupComplete', 'childPIDMatched')) {
        Assert-BooleanProperty $notification $name $Stage
    }
    Assert-UnsignedProperty $notification 'boundChildPID' $Stage
}

function Invoke-Probe([string]$Stage, [string]$ExpectedLoadState, [switch]$AllowMismatch) {
    $nonce = New-Nonce
    $output = & $CollectorPath --nonce $nonce --driver-image $DriverImage 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Collector failed during '$Stage' with exit code $exitCode."
    }

    try {
        $report = (($output -join [Environment]::NewLine).Trim() | ConvertFrom-Json)
    } catch {
        throw "Collector returned invalid JSON during '$Stage'."
    }
    Assert-ProbeReportShape $report $Stage
    if ($report.nonce -cne $nonce) { throw "Collector nonce mismatch during '$Stage'." }
    $notification = $report.observation.notification
    $imageIdentityMatched = $null
    if ($report.driver.loadState -eq 'loaded') {
        try {
            $imageIdentityMatched = Assert-ServiceImageIdentity $Stage
        } catch {
            $script:Events.Add([pscustomobject]@{ stage = $Stage; imageIdentityMatched = $false })
            throw
        }
    }
    $script:Events.Add([pscustomobject]@{
        stage = $Stage
        schemaVersion = $report.schemaVersion
        protocolVersion = $report.driver.protocolVersion
        guestKernelArchitecture = $report.guest.kernelArchitecture
        collectorArchitecture = $report.guest.processArchitecture
        windowsBuild = $report.guest.windowsBuild
        candidateImageArchitecture = $report.driver.candidateImageArchitecture
        loadedProbeArchitecture = $report.driver.loadedProbeArchitecture
        candidateImageAuthenticode = $report.driver.candidateImageAuthenticode
        nonceMatched = $true
        imageIdentityMatched = $imageIdentityMatched
        deviceControlSucceeded = $report.observation.deviceControlSucceeded
        sameProcessObject = $report.observation.sameProcessObject
        requestorMatchesCurrentContext = $report.observation.requestorMatchesCurrentContext
        requestorPIDMatched = ($report.observation.requestorPID -ne 0 -and
            $report.observation.requestorPID -eq $report.observation.observedPID -and
            $report.observation.requestorPID -eq $report.observation.dispatchAttachedContextPID)
        loadState = $report.driver.loadState
        failureStage = $report.observation.failureStage
        win32Error = $report.observation.win32Error
        bytesReturned = $report.observation.bytesReturned
        notification = [pscustomobject]@{
            attempted = $notification.attempted
            createObserved = $notification.createObserved
            exitObserved = $notification.exitObserved
            childCleanupComplete = $notification.childCleanupComplete
            childPIDMatched = $notification.childPIDMatched
            boundChildPIDPresent = ($notification.boundChildPID -ne 0)
        }
    })
    if (-not $AllowMismatch -and $report.driver.loadState -ne $ExpectedLoadState) {
        throw "Expected loadState '$ExpectedLoadState' during '$Stage'; got '$($report.driver.loadState)'."
    }
    return $report
}

function Assert-SuccessfulProbe($Report, [string]$Stage) {
    if ($Report.schemaVersion -ne 2 -or
        $Report.driver.protocolVersion -ne 2 -or
        $Report.driver.loadState -ne 'loaded' -or
        $Report.guest.kernelArchitecture -notin @('arm64', 'x64') -or
        $Report.driver.candidateImageArchitecture -ne $Report.guest.kernelArchitecture -or
        $Report.driver.loadedProbeArchitecture -ne $Report.guest.kernelArchitecture -or
        $Report.guest.processArchitecture -ne $Report.guest.kernelArchitecture -or
        $Report.observation.failureStage -ne 'none' -or
        -not $Report.observation.deviceControlSucceeded -or
        -not $Report.observation.sameProcessObject -or
        -not $Report.observation.requestorMatchesCurrentContext -or
        $Report.observation.requestorPID -eq 0 -or
        $Report.observation.requestorPID -ne $Report.observation.observedPID -or
        $Report.observation.requestorPID -ne $Report.observation.dispatchAttachedContextPID -or
        $Report.observation.win32Error -ne 0 -or
        $Report.observation.bytesReturned -ne 32 -or
        -not $Report.observation.notification.attempted -or
        -not $Report.observation.notification.createObserved -or
        -not $Report.observation.notification.exitObserved -or
        -not $Report.observation.notification.childPIDMatched -or
        $Report.observation.notification.boundChildPID -eq 0 -or
        -not $Report.observation.notification.childCleanupComplete) {
        throw "Self-probe evidence was incomplete during '$Stage'."
    }
}

function Wait-ForDeviceState([string]$Stage, [string]$ExpectedLoadState) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $report = Invoke-Probe $Stage $ExpectedLoadState -AllowMismatch
        if ($report.driver.loadState -eq $ExpectedLoadState) { return $report }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Device did not reach '$ExpectedLoadState' during '$Stage'."
}

function Remove-TestService([string]$Name) {
    $service = Get-ServiceEntry $Name
    if ($null -ne $service) {
        if ($service.Status -ne 'Stopped') {
            try {
                Stop-Service -Name $Name -Force -ErrorAction Stop
                $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
            } catch {
                throw "Could not stop test service '$Name'; leaving it registered. $($_.Exception.Message)"
            }
        }
        Invoke-ServiceControl 'delete' @($Name) | Out-Null
    }
}

function Start-ProbeService([string]$Name, [string]$ImagePath) {
    Invoke-ServiceControl 'create' @($Name, 'type=', 'kernel', 'start=', 'demand', 'binPath=', ('"' + $ImagePath + '"')) | Out-Null
    $null = Assert-ServiceImageIdentity 'registered-before-start'
    $script:Events.Add([pscustomobject]@{ stage = 'registered-before-start'; imageIdentityMatched = $true })
    Invoke-ServiceControl 'start' @($Name) | Out-Null
    (Get-ServiceEntry $Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
}

function Test-StartFailure {
    if ($null -ne (Get-ServiceEntry $FailureServiceName)) {
        throw "Service '$FailureServiceName' already exists; refusing to replace it."
    }
    $missingImage = Join-Path $env:TEMP ('module-a-missing-' + [Guid]::NewGuid().ToString('N') + '.sys')
    if (Test-Path -LiteralPath $missingImage) { throw 'The generated failure-test image path unexpectedly exists.' }
    Invoke-ServiceControl 'create' @($FailureServiceName, 'type=', 'kernel', 'start=', 'demand', 'binPath=', ('"' + $missingImage + '"')) | Out-Null
    try {
        $nativeErrorCode = Invoke-ServiceControl 'start' @($FailureServiceName) -AllowFailure
        if ($nativeErrorCode -ne 2) {
            throw "The missing-image service returned Win32 error $nativeErrorCode; expected 2."
        }
        $serviceAfterFailure = Get-ServiceEntry $FailureServiceName
        if ($null -eq $serviceAfterFailure -or $serviceAfterFailure.Status -ne 'Stopped') {
            throw 'The missing-image service was not left stopped after the expected failure.'
        }
        $script:Events.Add([pscustomobject]@{ stage = 'expected-start-failure'; win32Error = $nativeErrorCode; serviceStatus = $serviceAfterFailure.Status })
        $null = Invoke-Probe 'after-start-failure' 'notLoaded'
    } finally {
        Remove-TestService $FailureServiceName
    }
}

try {
    Assert-Elevated
    if ([string]::IsNullOrWhiteSpace($RebootStatePath)) {
        $RebootStatePath = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($DriverImage))) 'module-x-reboot-state.json'
    }
    if (-not (Test-Path -LiteralPath $DriverImage -PathType Leaf)) { throw 'DriverImage must name an existing file.' }
    if (-not (Test-Path -LiteralPath $CollectorPath -PathType Leaf)) { throw 'CollectorPath must name an existing file.' }

    if ($Phase -eq 'before-reboot') {
        if ($null -ne (Get-ServiceEntry $ServiceName)) { throw "Service '$ServiceName' already exists; refusing to replace it." }
        try {
            Start-ProbeService $ServiceName $DriverImage
            $loadedReport = Invoke-Probe 'before-reboot-loaded' 'loaded'
            Assert-SuccessfulProbe $loadedReport 'before-reboot-loaded'
            Stop-Service -Name $ServiceName
            (Get-ServiceEntry $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
            $null = Wait-ForDeviceState 'before-reboot-unloaded' 'notLoaded'
            $driverService = Get-CimInstance Win32_SystemDriver -Filter "Name='$ServiceName'"
            if ($null -eq $driverService -or $driverService.StartMode -ne 'Manual') {
                throw 'The probe service must remain demand-started before reboot.'
            }
            $null = Assert-ServiceImageIdentity 'before-reboot-service'
            $script:Events.Add([pscustomobject]@{ stage = 'before-reboot-service'; status = 'stopped'; startMode = $driverService.StartMode; imageIdentityMatched = $true })
            Save-RebootState
            $leaveServiceForReboot = $true
        } finally {
            if (-not $leaveServiceForReboot) { Remove-TestService $ServiceName }
        }
    } elseif ($Phase -eq 'after-reboot') {
        $service = Get-ServiceEntry $ServiceName
        if ($null -eq $service) { throw 'Run before-reboot phase first; the demand-started service is missing.' }
        Assert-RebootOccurred
        try {
            if ($service.Status -ne 'Stopped') { throw 'The service was running after reboot; expected demand-started state.' }
            $driverService = Get-CimInstance Win32_SystemDriver -Filter "Name='$ServiceName'"
            if ($null -eq $driverService -or $driverService.StartMode -ne 'Manual') {
                throw 'The service start mode changed across reboot.'
            }
            $null = Assert-ServiceImageIdentity 'after-reboot-service'
            $script:Events.Add([pscustomobject]@{ stage = 'after-reboot-service'; status = 'stopped'; startMode = $driverService.StartMode; imageIdentityMatched = $true })
            $null = Invoke-Probe 'after-reboot-before-start' 'notLoaded'
            Invoke-ServiceControl 'start' @($ServiceName) | Out-Null
            (Get-ServiceEntry $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
            $loadedReport = Invoke-Probe 'after-reboot-loaded' 'loaded'
            Assert-SuccessfulProbe $loadedReport 'after-reboot-loaded'
            Stop-Service -Name $ServiceName
            (Get-ServiceEntry $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
            $null = Wait-ForDeviceState 'after-reboot-unloaded' 'notLoaded'
            Test-StartFailure
        } finally {
            Remove-TestService $ServiceName
        }
    } else {
        if ($null -ne (Get-ServiceEntry $ServiceName)) { throw "Service '$ServiceName' already exists; refusing to replace it." }
        try {
            Start-ProbeService $ServiceName $DriverImage
            $loadedReport = Invoke-Probe 'loaded' 'loaded'
            Assert-SuccessfulProbe $loadedReport 'loaded'
            Stop-Service -Name $ServiceName
            (Get-ServiceEntry $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
            $null = Wait-ForDeviceState 'unloaded' 'notLoaded'
            Test-StartFailure
        } finally {
            Remove-TestService $ServiceName
        }
    }

    if (-not $leaveServiceForReboot) { Remove-TestService $ServiceName }
    if ($Phase -eq 'after-reboot') { Remove-Item -LiteralPath $RebootStatePath }
    ConvertTo-Json -InputObject @($script:Events.ToArray()) -Depth 5
} catch {
    if ($script:Events.Count -gt 0) {
        ConvertTo-Json -InputObject @($script:Events.ToArray()) -Depth 5
    }
    throw
}
