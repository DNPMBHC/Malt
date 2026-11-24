$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$lab = Join-Path $env:SystemDrive 'lab-b2'
& (Join-Path $lab 'source-native/tests/verify-lifecycle.ps1') -Phase 'after-reboot' -DriverImage (Join-Path $lab 'out/module-x-probe.sys') -CollectorPath (Join-Path $lab 'out/module-x-probe.exe') -RebootStatePath (Join-Path $lab 'owned-reboot-state.json')
