$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$lab = Join-Path $env:SystemDrive 'lab-b2'
& (Join-Path $lab 'b2-ui-dispatch.ps1') -Action capture `
    -PrivateTokensPath (Join-Path $lab 'private-ui-tokens.json') `
    -TimeoutSeconds 45
