$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$lab = Join-Path $env:SystemDrive 'lab-b2'
$roots = @(Get-ChildItem ($env:SystemDrive+'/') -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$roots | ConvertTo-Json | Set-Content (Join-Path $lab 'private-root-baseline.json') -Encoding UTF8
& (Join-Path $lab 'b2-driver-inventory.ps1') -Stage before -StateFile (Join-Path $lab 'private-driver-baseline-r2.json') -OutputFile (Join-Path $lab 'inventory-before.json')
