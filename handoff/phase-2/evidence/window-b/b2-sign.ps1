$ErrorActionPreference = 'Stop'
$lab = Join-Path $env:SystemDrive 'lab-b2'
$output = Join-Path $lab 'out'
$statePath = Join-Path $lab 'private-signing-state.json'
if (Confirm-SecureBootUEFI) { throw 'The approved temporary Secure Boot change has not been verified.' }
if (Test-Path $statePath) { throw 'An owned signing state already exists; inspect it before creating another certificate.' }
$certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=module-x-probe-local-test' -CertStoreLocation 'Cert:\LocalMachine\My' -HashAlgorithm SHA256 -KeyAlgorithm RSA -KeyLength 2048 -NotAfter (Get-Date).AddDays(7)
$certificatePath = Join-Path $lab 'module-x-test.cer'
Export-Certificate -Cert $certificate -FilePath $certificatePath | Out-Null
Import-Certificate -FilePath $certificatePath -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
Import-Certificate -FilePath $certificatePath -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null
[pscustomobject]@{ thumbprint=$certificate.Thumbprint; created_at_utc=[DateTime]::UtcNow.ToString('o'); private_state_only=$true } | ConvertTo-Json | Set-Content $statePath -Encoding UTF8
$roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
$candidates = @($roots | ForEach-Object { Join-Path $_ 'Windows Kits/10/bin' }) + @(Join-Path $lab 'toolchain/Microsoft.Windows.SDK.cpp.10.0.26100.6584/c/bin')
$signtool = $candidates | Where-Object { Test-Path $_ } | ForEach-Object { Get-ChildItem $_ -Filter signtool.exe -Recurse -File } | Where-Object { $_.Directory.Name -in @('arm64','x64') } | Select-Object -First 1
if ($null -eq $signtool) { throw 'An official signing utility was not found.' }
$records = @()
foreach ($name in @('module-x-probe.sys','module-x-probe.exe')) {
    $path = Join-Path $output $name
    $bytes = [IO.File]::ReadAllBytes($path)
    $offset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ([BitConverter]::ToUInt16($bytes, $offset+4) -ne 0xaa64) { throw 'A candidate image is not ARM64.' }
    $nativeOutput = & $signtool.FullName sign /fd SHA256 /sm /s My /sha1 $certificate.Thumbprint $path 2>&1
    $nativeExit = $LASTEXITCODE
    if ($nativeExit -ne 0) {
        [pscustomobject]@{stage='sign';artifact_alias=$name;native_exit_code=$nativeExit;output=($nativeOutput -join [Environment]::NewLine)} | ConvertTo-Json -Compress
        exit $nativeExit
    }
    $signature = Get-AuthenticodeSignature $path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) { throw 'The signed image did not validate against the owned test certificate.' }
    $records += [pscustomobject]@{artifact_alias=$name;pe_machine='0xaa64';architecture='ARM64';signature_status=[string]$signature.Status;signer_alias='owned-test-certificate';sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant();size_bytes=(Get-Item $path).Length}
}
$bcdOutput = & bcdedit.exe /set testsigning on 2>&1
$bcdExit = $LASTEXITCODE
[pscustomobject]@{captured_at_utc=[DateTime]::UtcNow.ToString('o');native_exit_code=$bcdExit;secure_boot='disabled_verified';testsigning_requested=($bcdExit -eq 0);reboot_required=$true;binaries=$records;bcd_output=($bcdOutput -join [Environment]::NewLine)} | ConvertTo-Json -Depth 6 -Compress
exit $bcdExit
