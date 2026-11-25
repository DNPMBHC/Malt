$ErrorActionPreference = 'Stop'
$lab = Join-Path $env:SystemDrive 'lab-b2'
$files = @('b2-driver-inventory.ps1', 'b2-ui-worker.ps1', 'b2-ui-dispatch.ps1')
$parsed = @()
foreach ($leaf in $files) {
    $path = Join-Path $lab $leaf
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $parsed += [pscustomobject]@{
        artifact_alias = $leaf
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        parser_error_count = @($errors).Count
        parser_error_lines = @($errors | ForEach-Object { $_.Extent.StartLineNumber })
    }
}
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
$secureBoot = Confirm-SecureBootUEFI
$bcd = (& bcdedit.exe /enum '{current}' 2>&1 | Out-String)
$bcdExit = $LASTEXITCODE
$safe = [pscustomobject]@{
    stage = 'sampling-preflight'
    captured_at = [DateTimeOffset]::UtcNow.ToString('o')
    source_parsers = $parsed
    secure_boot_enabled = $secureBoot
    bcd_native_exit_code = $bcdExit
    test_signing_entry_present = [bool]($bcd -match '(?im)^testsigning\s+')
    no_integrity_checks_entry_present = [bool]($bcd -match '(?im)^nointegritychecks\s+')
    system_disk_size_bytes = [long]$disk.Size
    system_disk_free_bytes = [long]$disk.FreeSpace
    installer_sha256 = (Get-FileHash -LiteralPath (Join-Path $lab 'installer-x.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    installer_signature_status = (Get-AuthenticodeSignature -LiteralPath (Join-Path $lab 'installer-x.exe')).Status.ToString()
    interactive_user_present = [bool]((Get-CimInstance Win32_ComputerSystem).UserName)
}
$safe | ConvertTo-Json -Depth 8 -Compress
if (@($parsed | Where-Object { $_.parser_error_count -ne 0 }).Count -gt 0 -or
    -not $secureBoot -or $bcdExit -ne 0 -or $safe.test_signing_entry_present -or
    $safe.no_integrity_checks_entry_present -or -not $safe.interactive_user_present -or
    $safe.installer_signature_status -ne 'Valid' -or
    $safe.installer_sha256 -ne '686ee838411863d2eccdbe8a0596129e509819ae46626408760588ae8b0c800e') {
    exit 1
}
