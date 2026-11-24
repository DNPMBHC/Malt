# SPDX-License-Identifier: GPL-3.0-or-later
# Maintainer: @DNPMBHC
# Executable Guest test plan; this script is not a real-execution evidence record.
param(
    [string]$HelperPath = (Join-Path $PSScriptRoot 'desktop-helper.exe'),
    [string]$ProbePath = (Join-Path $PSScriptRoot 'desktop-probe.exe'),
    [ValidateRange(1, 100)][int]$Iterations = 12
)
$ErrorActionPreference = 'Stop'
if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem -or
    [Diagnostics.Process]::GetCurrentProcess().SessionId -ne 0) {
    throw 'This self-owned contract test requires the Session 0 SYSTEM control channel.'
}
$HelperPath = [IO.Path]::GetFullPath($HelperPath)
$ProbePath = [IO.Path]::GetFullPath($ProbePath)

function Invoke-Helper([string[]]$Arguments) {
    $lines = & $HelperPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Helper process contract failed.' }
    return (($lines -join "`n") | ConvertFrom-Json)
}
function Assert-Tombstone($Frame) {
    if ($Frame.schemaVersion -ne 1 -or $Frame.state -ne 'failed' -or
        $Frame.error -ne 'launchCancelled' -or $Frame.win32Error -ne 1223 -or
        -not $Frame.cancelled -or -not $Frame.launchSuppressed -or
        $Frame.targetPID -ne 0 -or $Frame.activeProcessCount -ne 0) {
        throw 'Persisted launch-suppression contract failed.'
    }
}
function Write-String($Writer, [string]$Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $Writer.Write([uint32]$bytes.Length)
    $Writer.Write([byte[]]$bytes)
}
$memory = New-Object IO.MemoryStream
$writer = New-Object IO.BinaryWriter($memory)
$writer.Write([byte[]][Text.Encoding]::ASCII.GetBytes('MBD1'))
Write-String $writer $ProbePath
$writer.Write([uint32]2)
Write-String $writer '--sleep-ms'
Write-String $writer '30000'
$writer.Write([uint32]0)
$writer.Flush()
$manifest = [Convert]::ToBase64String($memory.ToArray())
$writer.Dispose()
$memory.Dispose()

$passed = 0
for ($index = 0; $index -lt $Iterations; $index++) {
    $request = [Guid]::NewGuid().ToString()
    $cancel = Invoke-Helper -Arguments @('cancel', $request)
    Assert-Tombstone $cancel
    # This late launch must complete without creating either relay or target.
    $late = Invoke-Helper -Arguments @('launch', $request, $manifest)
    Assert-Tombstone $late
    $status = Invoke-Helper -Arguments @('status', $request)
    Assert-Tombstone $status
    $repeated = Invoke-Helper -Arguments @('cancel', $request)
    Assert-Tombstone $repeated
    $passed++
}
[ordered]@{
    schemaVersion = 1
    test = 'cancel-before-late-launch'
    executionScope = 'selfOwnedExplicitDesktopControl'
    iterations = $Iterations
    passed = $passed
    targetCreated = $false
    lateResumeAllowed = $false
    rawRequestIDsIncluded = $false
} | ConvertTo-Json -Depth 4
