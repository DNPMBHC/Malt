[CmdletBinding()]
param(
    [ValidateSet('launch', 'capture', 'invoke', 'toggle', 'select')][string]$Action = 'capture',
    [string]$WorkerPath = (Join-Path $PSScriptRoot 'b2-ui-worker.ps1'),
    [string]$StateDirectory = (Join-Path $env:ProgramData 'demo-app-ui-private'),
    [string]$ExecutablePath = '',
    [string]$ExpectedSha256 = '',
    [int]$Generation = 0,
    [int]$ControlIndex = 0,
    [string]$DesiredToggleState = '',
    [string]$PrivateTokensPath = '',
    [ValidateRange(2, 45)][int]$TimeoutSeconds = 25
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$taskName = $null
$stage = 'resolve-existing-interactive-logon'
$taskRegistered = $false
$dispatchLock = $null
$workerContextPath = Join-Path $StateDirectory 'worker-context.json'
$requestPath = Join-Path $StateDirectory 'request.json'
$resultPath = Join-Path $StateDirectory 'result.json'
$activePath = Join-Path $StateDirectory 'active-task.json'

function Worker-ExitConfirmed([bool]$AllowUnstartedCancelledWorker = $false) {
    if (Test-Path -LiteralPath $workerContextPath) {
        try {
            $saved = Get-Content -LiteralPath $workerContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$saved.id -le 0 -or [string]$saved.started -notmatch '^\d+$') { return $false }
            $process = [Diagnostics.Process]::GetProcessById([int]$saved.id)
            try { return $process.HasExited -or $process.StartTime.ToUniversalTime().Ticks.ToString() -ne [string]$saved.started }
            finally { $process.Dispose() }
        } catch [ArgumentException] { return $true }
        catch { return $false }
    }
    if (-not $AllowUnstartedCancelledWorker) { return $false }
    $currentTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($currentTask -and $currentTask.State -eq 'Running') { return $false }
    # A worker that failed before writing its identity must also be absent by its
    # exact private command-line arguments; no process IDs are emitted.
    try {
        $matches = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
            $_.CommandLine -and $_.CommandLine.Contains($WorkerPath) -and $_.CommandLine.Contains($requestPath)
        })
        return $matches.Count -eq 0
    } catch { return $false }
}
function Wait-WorkerExit([int]$Seconds, [bool]$AllowUnstartedCancelledWorker = $false) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (Worker-ExitConfirmed $AllowUnstartedCancelledWorker) { return $true }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}
function Remove-CurrentRegistration {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue
}
try {
    $account = [string](Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $account) { throw [InvalidOperationException]::new('No existing interactive logon.') }
    $identity = [Security.Principal.NTAccount]::new($account)
    $userSid = $identity.Translate([Security.Principal.SecurityIdentifier])
    $stage = 'prepare-private-state-directory'
    if (-not (Test-Path -LiteralPath $StateDirectory)) { $null = New-Item -Path $StateDirectory -ItemType Directory }
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach ($sid in @([Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'), $userSid)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inheritance, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $StateDirectory -AclObject $acl
    $dispatchLock = [IO.File]::Open((Join-Path $StateDirectory 'dispatch.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $stage = 'recover-only-finished-private-worker'
    if (Test-Path -LiteralPath $activePath) {
        $prior = Get-Content -LiteralPath $activePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $priorTask = Get-ScheduledTask -TaskName $prior.task_name -ErrorAction SilentlyContinue
        if (-not (Worker-ExitConfirmed)) { throw [InvalidOperationException]::new('Previous UI worker exit is unconfirmed.') }
        if ($priorTask) { Unregister-ScheduledTask -TaskName $prior.task_name -Confirm:$false }
        Remove-Item -LiteralPath $activePath -Force
    }
    if (-not (Test-Path -LiteralPath $WorkerPath -PathType Leaf)) { throw [IO.FileNotFoundException]::new() }
    foreach ($path in @($WorkerPath, $StateDirectory)) {
        if ($path -match '["\r\n]') { throw [ArgumentException]::new('Unsafe worker argument.') }
    }
    if ($Action -eq 'launch' -and (-not $ExecutablePath -or $ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$')) { throw [ArgumentException]::new('Launch fingerprint required.') }
    if ($Action -in @('invoke', 'toggle', 'select') -and ($Generation -le 0 -or $ControlIndex -le 0)) { throw [ArgumentException]::new('Observed capture and control required.') }
    $sequencePath = Join-Path $StateDirectory 'task-sequence.txt'
    $sequence = if (Test-Path -LiteralPath $sequencePath) { [long]([IO.File]::ReadAllText($sequencePath)) + 1 } else { 1 }
    [IO.File]::WriteAllText($sequencePath, $sequence.ToString())
    # A new task URI per dispatch keeps capture/invoke stop operations separate
    # from the task/job that launched the official application.
    $taskName = 'demo-app-ui-task-' + $sequence.ToString('D6') + '-' + $Action
    $tokens = @()
    if ($PrivateTokensPath) { $tokens = @(Get-Content -LiteralPath $PrivateTokensPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    $tokens += @($account, $env:USERNAME, $env:COMPUTERNAME)
    $request = [pscustomobject]@{
        action = $Action; executable_path = $ExecutablePath; expected_sha256 = $ExpectedSha256
        generation = $Generation; control_index = $ControlIndex; desired_toggle_state = $DesiredToggleState
        private_tokens = @($tokens)
    }
    [IO.File]::WriteAllText($requestPath, (ConvertTo-Json -InputObject $request -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $resultPath, $workerContextPath -Force -ErrorAction SilentlyContinue
    $stage = 'schedule-interactive-worker'
    $arguments = '-NoLogo -NoProfile -NonInteractive -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $WorkerPath + '" -RequestPath "' + $requestPath + '" -ResultPath "' + $resultPath + '" -StateDirectory "' + $StateDirectory + '"'
    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Highest
    $executionLimit = if ($Action -eq 'launch') { [TimeSpan]::Zero } else { New-TimeSpan -Minutes 2 }
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit $executionLimit -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    $null = Register-ScheduledTask -TaskName $taskName -Action $taskAction -Principal $principal -Settings $settings
    $taskRegistered = $true
    [IO.File]::WriteAllText($activePath, (ConvertTo-Json -InputObject ([pscustomobject]@{ task_name = $taskName; action = $Action }) -Compress), [Text.UTF8Encoding]::new($false))
    Start-ScheduledTask -TaskName $taskName
    $stage = 'wait-for-sanitized-worker-result'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-Path -LiteralPath $resultPath) {
            $observation = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $exited = Wait-WorkerExit 2
            if ($exited) { Remove-CurrentRegistration; $taskRegistered = $false }
            $publicStatus = if ($observation.status -eq 'completed') { 'completed' } else { 'failed' }
            [pscustomobject]@{ status = $publicStatus; task_registration_removed = (-not $taskRegistered); worker_exit_confirmed = $exited; private_task_recovery_needed = $taskRegistered; observation = $observation } | ConvertTo-Json -Depth 16 -Compress
            if ($publicStatus -eq 'completed') { exit 0 } else { exit 1 }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
    $exited = $false
    if ($Action -ne 'launch') {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        $exited = Wait-WorkerExit 5 $true
        if ($exited) { Remove-CurrentRegistration; $taskRegistered = $false }
    }
    [pscustomobject]@{ status = 'pending_or_timed_out'; action = $Action; last_task_result = $taskInfo.LastTaskResult; worker_exit_confirmed = $exited; private_task_recovery_needed = $taskRegistered; account_values_read = $false } | ConvertTo-Json -Compress
    exit 124
} catch {
    [pscustomobject]@{ status = 'failed'; failure_stage = $stage; error_type = $_.Exception.GetType().Name; hresult = $_.Exception.HResult; private_task_recovery_needed = $taskRegistered } | ConvertTo-Json -Compress
    exit 1
} finally {
    if ($null -ne $dispatchLock) { $dispatchLock.Dispose() }
}
