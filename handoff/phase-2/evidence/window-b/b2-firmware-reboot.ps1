$ErrorActionPreference = 'Stop'
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
$output = & shutdown.exe /r /fw /t 3 2>&1
$nativeExit = $LASTEXITCODE
[pscustomobject]@{captured_at_utc=[DateTime]::UtcNow.ToString('o');before_boot_time_utc=$boot;native_exit_code=$nativeExit;reboot_requested=($nativeExit -eq 0);output=($output -join [Environment]::NewLine)} | ConvertTo-Json -Compress
exit $nativeExit
