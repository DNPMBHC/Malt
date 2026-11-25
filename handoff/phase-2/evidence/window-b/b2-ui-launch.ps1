$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$lab = Join-Path $env:SystemDrive 'lab-b2'
& (Join-Path $lab 'b2-ui-dispatch.ps1') -Action launch `
    -ExecutablePath (Join-Path $lab 'installer-x.exe') `
    -ExpectedSha256 '686ee838411863d2eccdbe8a0596129e509819ae46626408760588ae8b0c800e' `
    -PrivateTokensPath (Join-Path $lab 'private-ui-tokens.json') `
    -TimeoutSeconds 45
