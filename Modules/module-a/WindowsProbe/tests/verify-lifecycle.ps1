[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('cycle', 'before-reboot', 'after-reboot')]
    [string]$Phase,

    [Parameter(Mandatory)]
    [string]$DriverImage,

    [Parameter(Mandatory)]
    [string]$CollectorPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ServiceName = 'ModuleAProbeLifecycle'
$FailureServiceName = 'ModuleAProbeStartFailure'
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

function Invoke-ServiceControl([string]$Operation, [string[]]$Arguments) {
    $output = & sc.exe $Operation @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "sc.exe $Operation failed with exit code $exitCode."
    }
    return $output
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

function Assert-ProbeReportShape($Report, [string]$Stage) {
    $null = Get-RequiredPropertyValue $Report 'schemaVersion' $Stage
    $driver = Get-RequiredPropertyValue $Report 'driver' $Stage
    $null = Get-RequiredPropertyValue $driver 'protocolVersion' $Stage
    Assert-StringProperty $driver 'loadState' $Stage
    $observation = Get-RequiredPropertyValue $Report 'observation' $Stage
    Assert-StringProperty $observation 'failureStage' $Stage
    foreach ($name in @('deviceControlSucceeded', 'sameProcessObject', 'requestorMatchesCurrentContext')) {
        Assert-BooleanProperty $observation $name $Stage
    }
    foreach ($name in @('win32Error', 'bytesReturned')) {
        $null = Get-RequiredPropertyValue $observation $name $Stage
    }
    $notification = Get-RequiredPropertyValue $observation 'notification' $Stage
    foreach ($name in @('attempted', 'createObserved', 'exitObserved', 'childCleanupComplete', 'childPIDMatched')) {
        Assert-BooleanProperty $notification $name $Stage
    }
    $null = Get-RequiredPropertyValue $notification 'boundChildPID' $Stage
}

function Invoke-Probe([string]$Stage, [string]$ExpectedLoadState, [switch]$AllowMismatch) {
    $output = & $CollectorPath --nonce (New-Nonce) --driver-image $DriverImage 2>&1
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
    $notification = $report.observation.notification
    $script:Events.Add([pscustomobject]@{
        stage = $Stage
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
        $Report.observation.failureStage -ne 'none' -or
        -not $Report.observation.deviceControlSucceeded -or
        -not $Report.observation.sameProcessObject -or
        -not $Report.observation.requestorMatchesCurrentContext -or
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
    Start-Service -Name $Name
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
        $nativeErrorCode = $null
        try {
            Start-Service -Name $FailureServiceName -ErrorAction Stop
        } catch {
            $exception = $_.Exception
            while ($null -ne $exception -and
                   $exception -isnot [System.ComponentModel.Win32Exception]) {
                $exception = $exception.InnerException
            }
            if ($exception -is [System.ComponentModel.Win32Exception]) {
                $nativeErrorCode = $exception.NativeErrorCode
            }
        }
        if ($null -eq $nativeErrorCode) {
            throw 'The missing-image service did not expose a structured Win32 start error.'
        }
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
            $script:Events.Add([pscustomobject]@{ stage = 'before-reboot-service'; status = 'stopped'; startMode = $driverService.StartMode })
            $leaveServiceForReboot = $true
        } finally {
            if (-not $leaveServiceForReboot) { Remove-TestService $ServiceName }
        }
    } elseif ($Phase -eq 'after-reboot') {
        $service = Get-ServiceEntry $ServiceName
        if ($null -eq $service) { throw 'Run before-reboot phase first; the demand-started service is missing.' }
        try {
            if ($service.Status -ne 'Stopped') { throw 'The service was running after reboot; expected demand-started state.' }
            $driverService = Get-CimInstance Win32_SystemDriver -Filter "Name='$ServiceName'"
            if ($null -eq $driverService -or $driverService.StartMode -ne 'Manual') {
                throw 'The service start mode changed across reboot.'
            }
            $null = Invoke-Probe 'after-reboot-before-start' 'notLoaded'
            Start-Service -Name $ServiceName
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
    $script:Events | ConvertTo-Json -Depth 5
} catch {
    if ($script:Events.Count -gt 0) {
        $script:Events | ConvertTo-Json -Depth 5
    }
    throw
}
