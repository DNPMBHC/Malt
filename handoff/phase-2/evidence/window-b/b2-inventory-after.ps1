$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$lab = Join-Path $env:SystemDrive 'lab-b2'
$baseline = @(Get-Content (Join-Path $lab 'private-root-baseline.json') -Raw | ConvertFrom-Json)
$new = @(Get-ChildItem ($env:SystemDrive+'/') -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notin $baseline } | ForEach-Object { $_.FullName })
$roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) + $new
& (Join-Path $lab 'b2-driver-inventory.ps1') -Stage after -StateFile (Join-Path $lab 'private-driver-baseline-r2.json') -OutputFile (Join-Path $lab 'inventory-after.json') -InstallRoot $roots -MaxRootDirectories 10000 -MaxRootDriverFiles 10000
