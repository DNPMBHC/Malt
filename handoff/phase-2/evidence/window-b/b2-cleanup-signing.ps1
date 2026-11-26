$ErrorActionPreference = 'Stop'
$lab = Join-Path $env:SystemDrive 'lab-b2'
$lifecycleSource = Get-Content (Join-Path $lab 'source-native/tests/verify-lifecycle.ps1') -Raw
$serviceMatches = [regex]::Matches($lifecycleSource, '(?m)^\$(?:ServiceName|FailureServiceName)\s*=\s*''([^'']+)''')
if ($serviceMatches.Count -ne 2) { throw 'Owned service cleanup scope could not be resolved.' }
foreach ($match in $serviceMatches) {
    $name = $match.Groups[1].Value
    if ($null -ne (Get-Service -Name $name -ErrorAction SilentlyContinue)) { throw 'An owned test service remains registered; lifecycle cleanup must finish first.' }
}
$statePath = Join-Path $lab 'private-signing-state.json'
if (-not (Test-Path $statePath)) { throw 'The private owned signing state is missing.' }
$state = Get-Content $statePath -Raw | ConvertFrom-Json
$thumbprint = [string]$state.thumbprint
if ($thumbprint -notmatch '^[A-Fa-f0-9]{40}$') { throw 'The owned test certificate identifier is invalid.' }
$certificate = Get-Item ('Cert:\LocalMachine\My\'+$thumbprint)
if ($certificate.Subject -ne 'CN=module-x-probe-local-test') { throw 'The certificate is outside the owned experiment scope.' }
$bcdOutput = & bcdedit.exe /deletevalue testsigning 2>&1
$bcdExit = $LASTEXITCODE
if ($bcdExit -ne 0) {
    [pscustomobject]@{stage='restore-test-signing';native_exit_code=$bcdExit;output=($bcdOutput -join [Environment]::NewLine)} | ConvertTo-Json -Compress
    exit $bcdExit
}
foreach ($store in @('Root','TrustedPublisher')) { Remove-Item ('Cert:\LocalMachine\'+$store+'\'+$thumbprint) -ErrorAction Stop }
Remove-Item ('Cert:\LocalMachine\My\'+$thumbprint) -DeleteKey -ErrorAction Stop
$certificateRemoved = -not (@('Root','TrustedPublisher','My') | Where-Object { Test-Path ('Cert:\LocalMachine\'+$_+'\'+$thumbprint) })
if (-not $certificateRemoved) { throw 'The owned test certificate remains in a certificate store.' }
Remove-Item $statePath -ErrorAction Stop
Remove-Item (Join-Path $lab 'module-x-test.cer') -ErrorAction Stop
[pscustomobject]@{captured_at_utc=[DateTime]::UtcNow.ToString('o');native_exit_code=0;test_signing_restored_to_original_absent_value=$true;owned_certificate_removed=$true;owned_services_absent=$true;secure_boot_restore_pending=$true;reboot_required=$true} | ConvertTo-Json -Compress
