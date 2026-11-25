$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$lab = Join-Path $env:SystemDrive 'lab-b2'
& (Join-Path $lab 'source-native/tests/verify-lifecycle-self-test.ps1')
