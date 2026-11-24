[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][string]$StateDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stage = 'read-private-request'
$launchAttempted = $false
$actionAttempted = $false
$privateTokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Hide-PrivateText([string]$Text) {
    $safe = $Text
    if ($null -eq $safe) { return '' }
    foreach ($token in @($privateTokens | Sort-Object Length -Descending)) {
        if ($token.Length -ge 3) { $safe = [regex]::Replace($safe, [regex]::Escape($token), '[private]', 'IgnoreCase') }
    }
    $safe = [regex]::Replace($safe, '(?i)[a-z]:[\\/][^\r\n]*', '[guest-path]')
    $safe = [regex]::Replace($safe, '(?i)\\\\[^\s\\]+\\[^\r\n]*', '[network-path]')
    $safe = [regex]::Replace($safe, '(?i)/(?:Users|Volumes|home)/[^\s]*', '[private-path]')
    $safe = [regex]::Replace($safe, '(?i)[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}', '[email]')
    $safe = [regex]::Replace($safe, '(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b', '[identifier]')
    $ipv4 = [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $parts = $match.Value.Split('.')
        if (@($parts | Where-Object { [int]$_ -gt 255 }).Count -eq 0) { return '[network-address]' }
        return $match.Value
    }
    $safe = [regex]::Replace($safe, '\b(?:\d{1,3}\.){3}\d{1,3}\b', $ipv4)
    $safe = [regex]::Replace($safe, '(?i)\b(?:pid|process\s+id)\s*[:=#]?\s*\d+\b', '[process-reference]')
    $safe = [regex]::Replace($safe, '(?i)https?://\S+', '[url]')
    $safe = [regex]::Replace($safe, '(?i)\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b', '[hardware-id]')
    $safe = [regex]::Replace($safe, '\bS-\d-\d+(?:-\d+)+\b', '[identity]')
    $safe = [regex]::Replace($safe, '(?<![\p{L}\p{N}])\d{6,}(?![\p{L}\p{N}])', '[numeric-id]')
    return $safe
}
function Write-PrivateJson([string]$Path, $Value) {
    $temporary = $Path + '.pending'
    $json = ConvertTo-Json -InputObject $Value -Depth 16 -Compress
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Read-PrivateJson([string]$Path) {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Name-Hash([string]$Name) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Name)))).Replace('-', '') }
    finally { $hash.Dispose() }
}
function Process-Ticks($Entry) {
    return ([DateTime]$Entry.CreationDate).ToUniversalTime().Ticks.ToString()
}
function Resolve-AppProcesses($Context, [int]$Session) {
    $all = @(Get-CimInstance Win32_Process -Filter "SessionId=$Session")
    $liveById = [Collections.Generic.Dictionary[int, object]]::new()
    foreach ($entry in $all) { $liveById[[int]$entry.ProcessId] = $entry }
    $accepted = [Collections.Generic.HashSet[int]]::new()
    foreach ($saved in @($Context.processes)) {
        foreach ($live in $all) {
            if ([int]$saved.id -eq [int]$live.ProcessId -and [string]$saved.created -eq (Process-Ticks $live)) {
                $null = $accepted.Add([int]$live.ProcessId)
            }
        }
    }
    $rootLive = @($all | Where-Object { [int]$_.ProcessId -eq [int]$Context.root_id })
    if ($rootLive.Count -eq 1 -and (Process-Ticks $rootLive[0]) -eq [string]$Context.root_created) {
        $null = $accepted.Add([int]$Context.root_id)
    }
    do {
        $changed = $false
        foreach ($entry in $all) {
            $parentId = [int]$entry.ParentProcessId
            if ($accepted.Contains($parentId) -and $liveById.ContainsKey($parentId)) {
                $childTicks = ([DateTime]$entry.CreationDate).ToUniversalTime().Ticks
                $parentTicks = ([DateTime]$liveById[$parentId].CreationDate).ToUniversalTime().Ticks
                if ($childTicks -ge [long]$Context.launch_ticks -and $childTicks -ge $parentTicks) {
                    if ($accepted.Add([int]$entry.ProcessId)) { $changed = $true }
                }
            }
        }
    } while ($changed)
    $Context.processes = @($all | Where-Object { $accepted.Contains([int]$_.ProcessId) } | ForEach-Object {
        [pscustomobject]@{ id = [int]$_.ProcessId; created = (Process-Ticks $_) }
    })
    return ,$accepted
}
function Pattern-Supported($Element, $Pattern) {
    $value = $null
    return $Element.TryGetCurrentPattern($Pattern, [ref]$value)
}
function Capture-AppUI($Context, [int]$Session, [string]$ContextPath, [string]$MapPath) {
    $accepted = Resolve-AppProcesses $Context $Session
    $Context.generation = [int]$Context.generation + 1
    $publicWindows = [Collections.Generic.List[object]]::new()
    $privateControls = [Collections.Generic.List[object]]::new()
    $top = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    $windowIndex = 0
    $controlIndex = 0
    $skipped = 0
    $truncated = $false
    foreach ($window in $top) {
        try {
            $info = $window.Current
            if (-not $accepted.Contains([int]$info.ProcessId) -or $info.IsOffscreen) { continue }
            $windowIndex++
            $publicControls = [Collections.Generic.List[object]]::new()
            $items = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($element in $items) {
                if ($controlIndex -ge 1200) { $truncated = $true; break }
                try {
                    $current = $element.Current
                    if (-not $accepted.Contains([int]$current.ProcessId) -or $current.IsOffscreen) { continue }
                    $kind = $current.ControlType.ProgrammaticName.Replace('ControlType.', '')
                    $invoke = Pattern-Supported $element ([System.Windows.Automation.InvokePattern]::Pattern)
                    $toggle = Pattern-Supported $element ([System.Windows.Automation.TogglePattern]::Pattern)
                    $select = Pattern-Supported $element ([System.Windows.Automation.SelectionItemPattern]::Pattern)
                    $inputField = $current.IsPassword -or $kind -eq 'Edit'
                    $name = if ($inputField) { '[input-field]' } else { Hide-PrivateText $current.Name }
                    if (-not $name -and -not $invoke -and -not $toggle -and -not $select) { continue }
                    $controlIndex++
                    $publicControls.Add([pscustomobject]@{
                        control_index = $controlIndex; control_type = $kind; text = $name
                        enabled = [bool]$current.IsEnabled
                        invoke_supported = [bool]$invoke; toggle_supported = [bool]$toggle
                        selection_supported = [bool]$select; input_value_omitted = [bool]$inputField
                    })
                    $processEntry = @($Context.processes | Where-Object { [int]$_.id -eq [int]$current.ProcessId })
                    if ($processEntry.Count -eq 1 -and -not $inputField) {
                        $privateControls.Add([pscustomobject]@{
                            control_index = $controlIndex; window_handle = [long]$info.NativeWindowHandle
                            process_id = [int]$current.ProcessId; process_created = $processEntry[0].created
                            runtime_id = @($element.GetRuntimeId()); name_hash = (Name-Hash $current.Name)
                            control_type_id = [int]$current.ControlType.Id; input_field = [bool]$inputField
                        })
                    }
                } catch { $skipped++ }
            }
            $modal = $null
            $windowPattern = $null
            if ($window.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$windowPattern)) {
                $modal = [bool]$windowPattern.Current.IsModal
            }
            $publicWindows.Add([pscustomobject]@{
                window_index = $windowIndex; title = (Hide-PrivateText $info.Name)
                is_modal = $modal; controls = @($publicControls.ToArray())
            })
        } catch { $skipped++ }
    }
    Write-PrivateJson $ContextPath $Context
    Write-PrivateJson $MapPath ([pscustomobject]@{ generation = $Context.generation; controls = @($privateControls.ToArray()) })
    return [pscustomobject]@{
        generation = $Context.generation; scope = 'installer-process-tree'
        window_count = $publicWindows.Count; process_count = @($Context.processes).Count
        capture_complete = ($publicWindows.Count -gt 0 -and $skipped -eq 0 -and -not $truncated)
        text_scope = 'visible-accessible-controls-only'
        skipped_controls = $skipped; truncated = $truncated
        windows = @($publicWindows.ToArray())
    }
}

try {
    $workerProcess = [Diagnostics.Process]::GetCurrentProcess()
    Write-PrivateJson (Join-Path $StateDirectory 'worker-context.json') ([pscustomobject]@{
        id = $workerProcess.Id; started = $workerProcess.StartTime.ToUniversalTime().Ticks.ToString()
    })
    $request = Read-PrivateJson $RequestPath
    foreach ($token in @($request.private_tokens)) { if ($token) { $null = $privateTokens.Add([string]$token) } }
    foreach ($token in @($env:USERNAME, $env:USERDOMAIN, $env:COMPUTERNAME, $env:USERPROFILE)) {
        if ($token) { $null = $privateTokens.Add([string]$token) }
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    foreach ($token in $identity.Split([char]92)) { $null = $privateTokens.Add($token) }
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($session -eq 0 -or -not [Environment]::UserInteractive) { throw [InvalidOperationException]::new('Interactive desktop unavailable.') }
    $stage = 'load-ui-automation'
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $contextPath = Join-Path $StateDirectory 'app-context.json'
    $mapPath = Join-Path $StateDirectory 'control-map.json'
    $actionResult = $null
    if ($request.action -eq 'launch') {
        $stage = 'verify-official-installer'
        if (Test-Path -LiteralPath $contextPath) { throw [InvalidOperationException]::new('An app scope is already registered.') }
        if (-not (Test-Path -LiteralPath $request.executable_path -PathType Leaf)) { throw [IO.FileNotFoundException]::new() }
        if ([string]$request.expected_sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw [ArgumentException]::new('Expected fingerprint required.') }
        $digest = (Get-FileHash -LiteralPath $request.executable_path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($digest -ne ([string]$request.expected_sha256).ToLowerInvariant()) { throw [InvalidOperationException]::new('Installer fingerprint mismatch.') }
        $signature = Get-AuthenticodeSignature -LiteralPath $request.executable_path
        if ($signature.Status -ne 'Valid') { throw [InvalidOperationException]::new('Installer signature not valid.') }
        $stage = 'launch-visible-installer'
        $launchTicks = [DateTime]::UtcNow.Ticks
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = [string]$request.executable_path
        $start.WorkingDirectory = Split-Path -Parent $request.executable_path
        $start.UseShellExecute = $true
        $start.Arguments = ''
        $launchAttempted = $true
        $app = [Diagnostics.Process]::Start($start)
        if ($null -eq $app) { throw [InvalidOperationException]::new('Shell launch returned no trackable process.') }
        $returnedRootTicks = $app.StartTime.ToUniversalTime().Ticks
        $rootEntry = Get-CimInstance Win32_Process -Filter "ProcessId=$($app.Id)"
        if (-not $rootEntry -or [int]$rootEntry.SessionId -ne $session -or
            [Math]::Abs(([long](Process-Ticks $rootEntry)) - $returnedRootTicks) -gt 9) {
            throw [InvalidOperationException]::new('Shell launch process identity unavailable.')
        }
        $rootCreated = Process-Ticks $rootEntry
        $context = [pscustomobject]@{
            root_id = [int]$app.Id; root_created = $rootCreated; launch_ticks = $launchTicks.ToString()
            session = $session; generation = 0
            processes = @([pscustomobject]@{ id = [int]$app.Id; created = $rootCreated })
        }
        Write-PrivateJson $contextPath $context
        Start-Sleep -Milliseconds 1000
        $actionResult = [pscustomobject]@{ action = 'launch'; launched = $true; arguments_supplied = $false; installer_sha256 = $digest; signature_status = 'Valid' }
    } else {
        $stage = 'read-existing-app-scope'
        if (-not (Test-Path -LiteralPath $contextPath)) { throw [InvalidOperationException]::new('No installer scope has been launched.') }
        $context = Read-PrivateJson $contextPath
        if ([int]$context.session -ne $session) { throw [InvalidOperationException]::new('Interactive session changed.') }
        if ($request.action -ne 'capture') {
            $stage = 'verify-observed-control'
            $map = Read-PrivateJson $mapPath
            if ([int]$request.generation -le 0 -or [int]$request.generation -ne [int]$map.generation) { throw [InvalidOperationException]::new('Capture generation is stale.') }
            $selected = @($map.controls | Where-Object { [int]$_.control_index -eq [int]$request.control_index })
            if ($selected.Count -ne 1 -or [bool]$selected[0].input_field) { throw [InvalidOperationException]::new('Observed actionable control unavailable.') }
            $saved = $selected[0]
            $liveProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($saved.process_id)"
            if (-not $liveProcess -or (Process-Ticks $liveProcess) -ne [string]$saved.process_created -or [int]$liveProcess.SessionId -ne $session) {
                throw [InvalidOperationException]::new('Observed process identity changed.')
            }
            $window = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]([long]$saved.window_handle))
            $items = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $live = $null
            foreach ($candidate in $items) {
                if ([System.Windows.Automation.Automation]::CompareRuntimeIds($candidate.GetRuntimeId(), [int[]]$saved.runtime_id)) { $live = $candidate; break }
            }
            if ($null -eq $live -or $live.Current.IsOffscreen -or -not $live.Current.IsEnabled -or
                [int]$live.Current.ProcessId -ne [int]$saved.process_id -or
                [int]$live.Current.ControlType.Id -ne [int]$saved.control_type_id -or
                (Name-Hash $live.Current.Name) -ne [string]$saved.name_hash) { throw [InvalidOperationException]::new('Observed element changed or is unavailable.') }
            $stage = 'invoke-explicit-observed-action'
            $pattern = $null
            $changed = $true
            $actionAttempted = $true
            switch ([string]$request.action) {
                'invoke' {
                    if (-not $live.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { throw [InvalidOperationException]::new('Invoke not supported.') }
                    ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
                }
                'toggle' {
                    if ($request.desired_toggle_state -notin @('On', 'Off')) { throw [ArgumentException]::new('An explicit toggle target is required.') }
                    if (-not $live.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) { throw [InvalidOperationException]::new('Toggle not supported.') }
                    $typed = [System.Windows.Automation.TogglePattern]$pattern
                    $changed = $typed.Current.ToggleState.ToString() -ne [string]$request.desired_toggle_state
                    if ($changed) { $typed.Toggle() }
                }
                'select' {
                    if (-not $live.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) { throw [InvalidOperationException]::new('Selection not supported.') }
                    ([System.Windows.Automation.SelectionItemPattern]$pattern).Select()
                }
                default { throw [ArgumentException]::new('Unknown explicit action.') }
            }
            $actionResult = [pscustomobject]@{ action = $request.action; control_index = [int]$request.control_index; prior_generation = [int]$request.generation; completed = $true; changed = $changed }
            Start-Sleep -Milliseconds 700
        }
    }
    $stage = 'capture-visible-app-ui'
    $capture = Capture-AppUI $context $session $contextPath $mapPath
    Write-PrivateJson $ResultPath ([pscustomobject]@{
        status = 'completed'; captured_at_utc = [DateTime]::UtcNow.ToString('o')
        interactive_desktop = $true; account_values_read = $false; private_map_exported = $false
        action_result = $actionResult; capture = $capture
    })
} catch {
    $failure = [pscustomobject]@{
        status = 'failed'; failure_stage = $stage; error_type = $_.Exception.GetType().Name
        hresult = $_.Exception.HResult; account_values_read = $false; private_map_exported = $false
        launch_attempted = $launchAttempted; ui_action_attempted = $actionAttempted
    }
    try { Write-PrivateJson $ResultPath $failure } catch { }
    exit 1
}
