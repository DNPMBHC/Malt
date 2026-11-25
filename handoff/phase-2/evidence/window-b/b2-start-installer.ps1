$ErrorActionPreference = 'Stop'
$lab = Join-Path $env:SystemDrive 'lab-b2'
$installer = Join-Path $lab 'installer-x.exe'
if (-not (Confirm-SecureBootUEFI)) { throw 'Commercial sampling requires restored Secure Boot.' }
$bcd = (& bcdedit.exe /enum '{current}' 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $bcd -match '(?im)^\s*(testsigning|nointegritychecks)\s+Yes\s*$') { throw 'Commercial sampling requires the original boot integrity configuration.' }
$expected = '686ee838411863d2eccdbe8a0596129e509819ae46626408760588ae8b0c800e'
if ((Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'The staged official installer does not match the read-only sample.' }
$signature = Get-AuthenticodeSignature $installer
if ($signature.Status -ne 'Valid') { throw 'The official installer Authenticode signature did not validate.' }
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if ([string]::IsNullOrWhiteSpace($user)) { throw 'No interactive Guest desktop is logged in.' }
$taskName = 'module-x-installer-interactive'
if ($null -ne (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) { throw 'The neutral installer task already exists.' }
$action = New-ScheduledTaskAction -Execute $installer -WorkingDirectory $lab
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromHours(2)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $taskName
[pscustomobject]@{captured_at_utc=[DateTime]::UtcNow.ToString('o');native_exit_code=0;installer_alias='installer-x.exe';installer_sha256=$expected;authenticode_status=[string]$signature.Status;interactive_task_started=$true;normal_installer_arguments=$true;installation_result='pending_ui_observation';secure_boot_enabled=$true;test_signing_enabled=$false;identity_exported=$false} | ConvertTo-Json -Compress
