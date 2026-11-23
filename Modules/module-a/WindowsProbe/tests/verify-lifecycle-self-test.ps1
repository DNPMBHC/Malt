[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'verify-lifecycle.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Lifecycle script contains PowerShell parse errors.' }
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }

$script:Events = [System.Collections.Generic.List[object]]::new()
$ServiceName = 'module-x-probe-lifecycle'
$FailureServiceName = 'module-x-probe-start-failure'
$DriverImage = Join-Path $env:SystemDrive 'synthetic-driver.sys'
$CollectorPath = 'Invoke-TestCollector'
$script:MismatchNonce = $false
$script:ServiceStates = @{}
$script:SCMImageOverride = $null
$script:Fixture = [pscustomobject]@{
    schemaVersion = 2
    nonce = ''
    guest = [pscustomobject]@{ kernelArchitecture = 'arm64'; processArchitecture = 'arm64'; windowsBuild = 26100 }
    driver = [pscustomobject]@{
        protocolVersion = 2
        loadState = 'loaded'
        candidateImageArchitecture = 'arm64'
        loadedProbeArchitecture = 'arm64'
        candidateImageAuthenticode = 'trustedAuthenticode'
    }
    observation = [pscustomobject]@{
        failureStage = 'none'
        deviceControlSucceeded = $true
        sameProcessObject = $true
        requestorMatchesCurrentContext = $true
        win32Error = 0
        bytesReturned = 32
        requestorPID = 10
        observedPID = 10
        dispatchAttachedContextPID = 10
        notification = [pscustomobject]@{
            attempted = $true
            createObserved = $true
            exitObserved = $true
            childCleanupComplete = $true
            childPIDMatched = $true
            boundChildPID = 20
        }
    }
}

function Invoke-TestCollector {
    $script:Fixture.nonce = if ($script:MismatchNonce) { 'stale' } else { $args[1] }
    $global:LASTEXITCODE = 0
    $script:Fixture | ConvertTo-Json -Depth 6 -Compress
}

function Assert-Rejected([scriptblock]$Action, [string]$Expected) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -match $Expected) { return }
        throw 'Unexpected lifecycle self-test rejection.'
    }
    throw 'Lifecycle self-test accepted invalid evidence.'
}

function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, [string[]]$Property)
    if ($ClassName -eq 'Win32_SystemDriver') {
        $imagePath = if ($null -eq $script:SCMImageOverride) { [IO.Path]::GetFullPath($DriverImage) } else { $script:SCMImageOverride }
        return [pscustomobject]@{ PathName = $imagePath; StartMode = 'Manual' }
    }
    return [pscustomobject]@{ LastBootUpTime = $script:TestBootTime }
}

function Get-Service {
    param([string]$Name)
    if ($script:ServiceStates.ContainsKey($Name)) {
        return [pscustomobject]@{ Status = $script:ServiceStates[$Name] }
    }
}

function sc.exe {
    param([string]$Operation)
    $name = $args[0]
    $global:LASTEXITCODE = 0
    switch ($Operation) {
        'create' { $script:ServiceStates[$name] = 'Stopped' }
        'start' { $global:LASTEXITCODE = 2 }
        'delete' { $null = $script:ServiceStates.Remove($name) }
    }
}

$report = Invoke-Probe 'synthetic-loaded' 'loaded'
Assert-SuccessfulProbe $report 'synthetic-loaded'
$event = $script:Events[0]
if (-not $event.sameProcessObject -or -not $event.requestorPIDMatched -or
    -not $event.nonceMatched -or -not $event.imageIdentityMatched -or
    -not $event.notification.boundChildPIDPresent) {
    throw 'Lifecycle evidence omitted a required assertion.'
}

$script:SCMImageOverride = 'C:\synthetic-other-driver.sys'
Assert-Rejected { Invoke-Probe 'synthetic-other-image' 'loaded' } 'does not match DriverImage'
$script:SCMImageOverride = $null
foreach ($form in @(('"' + $DriverImage + '"'), ('\??\' + $DriverImage), ('\\?\' + $DriverImage))) {
    $script:SCMImageOverride = $form
    $null = Assert-ServiceImageIdentity 'synthetic-supported-path'
}
$script:SCMImageOverride = 'unknown-relative-driver.sys'
Assert-Rejected { Assert-ServiceImageIdentity 'synthetic-ambiguous-path' } 'does not match DriverImage'
$script:SCMImageOverride = $null

$script:Fixture.observation.sameProcessObject = 'true'
Assert-Rejected { Invoke-Probe 'synthetic-wrong-type' 'loaded' } 'non-boolean'
$script:Fixture.observation.sameProcessObject = $true
$script:Fixture.observation.bytesReturned = 32.5
Assert-Rejected { Invoke-Probe 'synthetic-fractional-size' 'loaded' } 'non-unsigned-integer'
$script:Fixture.observation.bytesReturned = 32
$script:MismatchNonce = $true
Assert-Rejected { Invoke-Probe 'synthetic-stale-nonce' 'loaded' } 'nonce mismatch'
$script:MismatchNonce = $false
$script:Fixture.observation.dispatchAttachedContextPID = 11
Assert-Rejected { Assert-SuccessfulProbe $script:Fixture 'synthetic-context-mismatch' } 'incomplete'
$script:Fixture.observation.dispatchAttachedContextPID = 10
$script:Fixture.observation.notification.childCleanupComplete = $false
Assert-Rejected { Assert-SuccessfulProbe $script:Fixture 'synthetic-incomplete-cleanup' } 'incomplete'
$script:Fixture.observation.notification.childCleanupComplete = $true
$script:Fixture.driver.loadState = 'notLoaded'
Test-StartFailure
if (-not ($script:Events | Where-Object { $_.stage -eq 'expected-start-failure' })) {
    throw 'Lifecycle evidence omitted the native start-failure result.'
}

$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('module-x-lifecycle-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testDirectory
try {
    $DriverImage = Join-Path $testDirectory 'synthetic-driver.sys'
    $CollectorPath = Join-Path $testDirectory 'synthetic-collector.exe'
    $RebootStatePath = Join-Path $testDirectory 'module-x-reboot-state.json'
    Set-Content -LiteralPath $DriverImage -Value 'driver-initial' -Encoding UTF8
    Set-Content -LiteralPath $CollectorPath -Value 'collector-initial' -Encoding UTF8
    $script:TestBootTime = [datetime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime()
    Save-RebootState
    Assert-Rejected { Assert-RebootOccurred } 'No later Windows boot'
    $script:TestBootTime = $script:TestBootTime.AddMinutes(1)
    Assert-RebootOccurred
    Add-Content -LiteralPath $DriverImage -Value 'changed' -Encoding UTF8
    Assert-Rejected { Assert-RebootOccurred } 'changed across reboot'
} finally {
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}

[pscustomobject]@{
    result = 'passed'
    lifecycleSyntax = 'passed'
    validEvidenceRetained = 'passed'
    invalidEvidenceRejected = 7
    serviceImageIdentity = 'passed'
    nativeStartErrorPreserved = 'passed'
    rebootVerified = 'passed'
    noRebootRejected = 'passed'
    changedArtifactRejected = 'passed'
} | ConvertTo-Json
