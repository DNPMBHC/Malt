$ErrorActionPreference = 'Stop'
$lab = Join-Path $env:SystemDrive 'lab-b2'
$path = Join-Path $lab 'b2-driver-inventory.ps1'
$tokens = $null
$errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if ($errors.Count -ne 0) {
    [pscustomobject]@{native_exit_code=1;artifact_alias='b2-driver-inventory.ps1';parse_error_count=$errors.Count;errors=@($errors|ForEach-Object {[pscustomobject]@{message=$_.Message;line=$_.Extent.StartLineNumber}})} | ConvertTo-Json -Depth 4 -Compress
    exit 1
}
[pscustomobject]@{native_exit_code=0;artifact_alias='b2-driver-inventory.ps1';parse_status='passed';sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()} | ConvertTo-Json -Compress
