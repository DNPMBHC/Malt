// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

let guestSurfaceDPISettingsScriptBody = #"""
  # Standard Windows Display Settings experiment. Owner: @DNPMBHC.
  # Run only in Session 1 of the authorized independent clone.
  [CmdletBinding()]
  param(
      [ValidateSet('Discover', 'RoundTrip', 'Restore', 'Apply', 'Query')][string]$Mode = 'Discover',
      [ValidatePattern('^[A-Za-z0-9_.-]{1,128}$')][string]$ScaleAutomationId,
      [ValidateSet(100,125,150,175,200,225,250,300)][int]$DesiredPercent = 150,
      [switch]$AllowMissingJournal,
      [switch]$RuntimeManaged,
      [string]$OutputPath = 'C:\guest-shell-lab\dpi-settings-probe.json'
  )
  $ErrorActionPreference = 'Stop'
  $report = [ordered]@{
      owner = '@DNPMBHC'; schema_version = 1; experiment = 'signed_settings_uia';
      mode = $Mode; executed = $false; succeeded = $false; runtime_integrated = [bool]$RuntimeManaged;
      current_percent = $null; baseline_percent = $null; requested_percent = $DesiredPercent; applied_percent = $null;
      restored_percent = $null; restore_required = $false; restore_verified = $null;
      settings_window_closed = $null; error_code = $null; controls = @()
  }
  $settings = $null
  $settingsOwned = $false
  $baseline = $null
  $restoreRequired = $false
  $journalPath = 'C:\guest-shell-lab\dpi-recovery.json'
  $journal = $null
  $skipRestore = $false
  try {
      if ([Diagnostics.Process]::GetCurrentProcess().SessionId -ne 1) { throw 'session1_required' }
      if ($OutputPath -notmatch '^C:\\guest-shell-lab\\[A-Za-z0-9_.-]+\.json$') { throw 'evidence_path_invalid' }
      if ($Mode -in @('RoundTrip','Apply') -and -not $ScaleAutomationId) { throw 'discovered_control_id_required' }
      function Write-RecoveryJournal($Value) {
          New-Item -ItemType Directory -Force -Path 'C:\guest-shell-lab' | Out-Null
          $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 4 -Compress))
          $stream = [IO.FileStream]::new($journalPath, [IO.FileMode]::Create,
              [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
          try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
      }
      if ($Mode -eq 'Restore') {
          if (-not (Test-Path -LiteralPath $journalPath)) {
              if (-not $AllowMissingJournal) { throw 'recovery_journal_missing' }
              $skipRestore = $true
          } else {
              $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
              if ($journal.owner -ne '@DNPMBHC' -or $journal.schema_version -ne 1 -or
                  $journal.state -notin @('pending','restored') -or
                  $journal.control_id -notmatch '^[A-Za-z0-9_.-]{1,128}$' -or
                  [int]$journal.baseline_percent -notin @(100,125,150,175,200,225,250,300)) {
                  throw 'recovery_journal_invalid'
              }
              if ($AllowMissingJournal -and $journal.state -eq 'restored') { $skipRestore = $true }
              elseif ($journal.state -ne 'pending') { throw 'recovery_journal_invalid' }
              $ScaleAutomationId = [string]$journal.control_id
              $DesiredPercent = [int]$journal.baseline_percent
              $report.requested_percent = $DesiredPercent
          }
      } elseif ($Mode -in @('RoundTrip','Apply') -and (Test-Path -LiteralPath $journalPath)) {
          $previousJournal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
          if ($previousJournal.owner -ne '@DNPMBHC' -or $previousJournal.state -ne 'restored') {
              throw 'pending_recovery_requires_restore'
          }
      }
      Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes | Out-Null
      Add-Type -TypeDefinition @'
  using System;
  using System.Runtime.InteropServices;
  public static class ShellDpiProbe {
      [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
      [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateWindowExW(
          uint exStyle, string className, string name, uint style, int x, int y, int width,
          int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
      [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr window);
      [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr window);
      [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
      public static int PrimaryPercent() {
          if (GetSystemMetrics(80) != 1) throw new InvalidOperationException("single_monitor_required");
          IntPtr old = SetThreadDpiAwarenessContext(new IntPtr(-4));
          if (old == IntPtr.Zero) throw new InvalidOperationException("dpi_context_unavailable");
          IntPtr window = IntPtr.Zero;
          try {
              window = CreateWindowExW(0, "STATIC", "guest-shell-dpi-probe", 0, 0, 0, 1, 1,
                  IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
              if (window == IntPtr.Zero) throw new InvalidOperationException("dpi_window_unavailable");
              uint dpi = GetDpiForWindow(window);
              if (dpi < 96 || dpi > 288) throw new InvalidOperationException("dpi_out_of_bounds");
              return (int)Math.Round(dpi * 100.0 / 96.0);
          } finally {
              if (window != IntPtr.Zero) DestroyWindow(window);
              SetThreadDpiAwarenessContext(old);
          }
      }
  }
  '@ -Language CSharp | Out-Null

      function Get-SafePercent([string]$Text) {
          if ($Text -match '^\s*(100|125|150|175|200|225|250|300)\s*%(?:\s|$)') {
              return [int]$Matches[1]
          }
          return $null
      }
      function Get-SettingsRoot {
          $settings.Refresh()
          if ($settings.HasExited -or $settings.MainWindowHandle -eq [IntPtr]::Zero) {
              throw 'settings_window_unavailable'
          }
          $root = [Windows.Automation.AutomationElement]::FromHandle($settings.MainWindowHandle)
          if ($root.Current.ProcessId -ne $settings.Id) { throw 'settings_automation_owner_mismatch' }
          return $root
      }
      function Get-ScaleControl {
          $id = [Windows.Automation.PropertyCondition]::new(
              [Windows.Automation.AutomationElement]::AutomationIdProperty, $ScaleAutomationId)
          $type = [Windows.Automation.PropertyCondition]::new(
              [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ComboBox)
          $condition = [Windows.Automation.AndCondition]::new($id, $type)
          $deadline = [DateTime]::UtcNow.AddSeconds(10)
          do {
              $matches = (Get-SettingsRoot).FindAll([Windows.Automation.TreeScope]::Descendants, $condition)
              if ($matches.Count -gt 1) { throw 'scale_control_not_unique' }
              if ($matches.Count -eq 1) {
                  $control = $matches[0]
                  if ($control.Current.ProcessId -ne $settings.Id) { throw 'scale_control_unavailable' }
                  if ($control.Current.IsEnabled) { return $control }
              }
              Start-Sleep -Milliseconds 200
          } while ([DateTime]::UtcNow -lt $deadline)
          throw 'scale_control_unavailable'
      }
      function Read-SelectedPercent($Control) {
          $pattern = $null
          if ($Control.TryGetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern, [ref]$pattern)) {
              $selection = $pattern.Current.GetSelection()
              if ($selection.Count -eq 1) { return Get-SafePercent $selection[0].Current.Name }
          }
          $pattern = $null
          if ($Control.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
              return Get-SafePercent $pattern.Current.Value
          }
          return $null
      }
      function Select-Scale([int]$Percent) {
          $control = Get-ScaleControl
          $expand = $null
          if (-not $control.TryGetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expand)) {
              throw 'scale_expand_pattern_unavailable'
          }
          $expanded = $false
          try {
              $expand.Expand(); $expanded = $true
              $condition = [Windows.Automation.PropertyCondition]::new(
                  [Windows.Automation.AutomationElement]::ControlTypeProperty,
                  [Windows.Automation.ControlType]::ListItem)
              $items = $control.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)
              $candidates = @($items | Where-Object {
                  $_.Current.ProcessId -eq $settings.Id -and $_.Current.IsEnabled -and
                  (Get-SafePercent $_.Current.Name) -eq $Percent
              })
              if ($candidates.Count -ne 1) { throw 'scale_option_not_unique_within_control' }
              $select = $null
              if (-not $candidates[0].TryGetCurrentPattern(
                  [Windows.Automation.SelectionItemPattern]::Pattern, [ref]$select)) {
                  throw 'scale_selection_pattern_unavailable'
              }
              $select.Select()
          } finally {
              if ($expanded) { try { $expand.Collapse() } catch {} }
          }
      }
      function Wait-Scale([int]$Percent) {
          $deadline = [DateTime]::UtcNow.AddSeconds(10)
          do {
              $dpi = [ShellDpiProbe]::PrimaryPercent()
              $selected = Read-SelectedPercent (Get-ScaleControl)
              if ($dpi -eq $Percent -and $selected -eq $Percent) { return $dpi }
              Start-Sleep -Milliseconds 200
          } while ([DateTime]::UtcNow -lt $deadline)
          throw 'scale_selection_and_fresh_window_dpi_not_confirmed'
      }

      if ($Mode -eq 'Query' -or $skipRestore) {
          $report.executed = $true
          $report.baseline_percent = [ShellDpiProbe]::PrimaryPercent()
          $report.current_percent = $report.baseline_percent
          if ($skipRestore) {
              $report.restored_percent = $report.current_percent
              $report.restore_verified = $true
          }
          $report.succeeded = $true
          return
      }

      $expected = Join-Path $env:SystemRoot 'ImmersiveControlPanel\SystemSettings.exe'
      if (-not (Test-Path -LiteralPath $expected)) { throw 'settings_executable_missing' }
      if ((Get-AuthenticodeSignature -LiteralPath $expected).Status -ne 'Valid') { throw 'settings_signature_invalid' }
      $visible = @(Get-Process -Name SystemSettings -ErrorAction SilentlyContinue | Where-Object {
          $_.SessionId -eq 1 -and $_.MainWindowHandle -ne [IntPtr]::Zero
      })
      if ($visible.Count) {
          if ($Mode -ne 'Restore' -or $visible.Count -ne 1 -or $visible[0].Id -ne $journal.settings_pid -or
              $visible[0].StartTime.ToUniversalTime().ToString('o') -ne $journal.settings_start_utc -or
              -not [string]::Equals($visible[0].Path, $expected, [StringComparison]::OrdinalIgnoreCase)) {
              throw 'existing_settings_session_requires_handoff'
          }
          $settings = $visible[0]; $settingsOwned = $true
      }
      $baseline = [ShellDpiProbe]::PrimaryPercent()
      $report.baseline_percent = $baseline
      Start-Process 'ms-settings:display' | Out-Null
      $settingsOwned = $true
      $deadline = [DateTime]::UtcNow.AddSeconds(15)
      do {
          $found = @(Get-Process -Name SystemSettings -ErrorAction SilentlyContinue | Where-Object {
              $_.SessionId -eq 1
          })
          if ($found.Count -eq 1) {
              $candidate = $found[0]
              if (-not [string]::Equals($candidate.Path, $expected, [StringComparison]::OrdinalIgnoreCase)) {
                  throw 'settings_executable_owner_mismatch'
              }
              $settings = $candidate
              $candidate.Refresh()
              if ($candidate.MainWindowHandle -ne [IntPtr]::Zero) { $settings = $candidate; break }
          }
          Start-Sleep -Milliseconds 200
      } while ([DateTime]::UtcNow -lt $deadline)
      if ($null -eq $settings -or $settings.MainWindowHandle -eq [IntPtr]::Zero) { throw 'settings_launch_timeout' }
      $report.executed = $true
      $comboCondition = [Windows.Automation.PropertyCondition]::new(
          [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ComboBox)
      $combos = (Get-SettingsRoot).FindAll([Windows.Automation.TreeScope]::Descendants, $comboCondition)
      if ($combos.Count -gt 40) { throw 'settings_control_count_out_of_bounds' }
      $report.controls = @($combos | ForEach-Object {
          $id = $_.Current.AutomationId
          if ($id -notmatch '^[A-Za-z0-9_.-]{1,128}$') { $id = '[unavailable]' }
          @{automation_id = $id; selected_percent = (Read-SelectedPercent $_);
            enabled = [bool]$_.Current.IsEnabled; owner_matches = ($_.Current.ProcessId -eq $settings.Id)}
      })
      if ($Mode -in @('RoundTrip','Apply')) {
          $selected = Read-SelectedPercent (Get-ScaleControl)
          if ($selected -ne $baseline) { throw 'baseline_control_and_fresh_window_dpi_mismatch' }
          if ($DesiredPercent -ne $baseline) {
              $journal = [ordered]@{owner = '@DNPMBHC'; schema_version = 1; state = 'pending';
                  baseline_percent = $baseline; requested_percent = $DesiredPercent;
                  control_id = $ScaleAutomationId; settings_pid = $settings.Id;
                  settings_start_utc = $settings.StartTime.ToUniversalTime().ToString('o');
                  created_at_utc = [DateTime]::UtcNow.ToString('o')}
              Write-RecoveryJournal $journal
              $restoreRequired = $true; $report.restore_required = $true
              Select-Scale $DesiredPercent
              $report.applied_percent = Wait-Scale $DesiredPercent
          } else { $report.applied_percent = $baseline }
      }
      if ($Mode -eq 'Restore') {
          Select-Scale $DesiredPercent
          $report.restored_percent = Wait-Scale $DesiredPercent
          $report.restore_verified = $true
          $journal.state = 'restored'
          Write-RecoveryJournal $journal
      }
      $report.succeeded = $true
  } catch {
      $allowed = @('session1_required','evidence_path_invalid','discovered_control_id_required',
          'dpi_context_unavailable','single_monitor_required','dpi_window_unavailable','dpi_out_of_bounds',
          'settings_window_unavailable','settings_automation_owner_mismatch','scale_control_not_unique',
          'scale_control_unavailable','scale_expand_pattern_unavailable','scale_option_not_unique_within_control',
          'scale_selection_pattern_unavailable','scale_selection_and_fresh_window_dpi_not_confirmed',
          'settings_executable_missing','settings_signature_invalid','existing_settings_session_requires_handoff',
          'settings_executable_owner_mismatch','settings_launch_timeout','settings_control_count_out_of_bounds',
          'baseline_control_and_fresh_window_dpi_mismatch','recovery_journal_missing',
          'recovery_journal_invalid','pending_recovery_requires_restore')
      $message = [string]$_.Exception.Message
      $report.error_code = if ($allowed -contains $message) { $message } else { 'settings_probe_failed' }
      $report.succeeded = $false
  } finally {
      if ($restoreRequired -and ($Mode -ne 'Apply' -or -not $report.succeeded)) {
          try {
              Select-Scale $baseline
              $report.restored_percent = Wait-Scale $baseline
              $report.restore_verified = $true
              $journal.state = 'restored'
              Write-RecoveryJournal $journal
          } catch {
              $report.restore_verified = $false; $report.succeeded = $false
              $report.error_code = 'scale_restore_not_confirmed'
          }
      } elseif ($Mode -eq 'RoundTrip' -and $report.succeeded) {
          $report.restored_percent = $baseline; $report.restore_verified = $true
      }
      if ($settingsOwned -and $null -ne $settings) {
          try {
              $handle = $settings.MainWindowHandle
              $closed = $settings.CloseMainWindow()
              $deadline = [DateTime]::UtcNow.AddSeconds(5)
              do {
                  $settings.Refresh()
                  if ($settings.HasExited -or $settings.MainWindowHandle -eq [IntPtr]::Zero) { break }
                  Start-Sleep -Milliseconds 100
              } while ([DateTime]::UtcNow -lt $deadline)
              $report.settings_window_closed = $closed -and (
                  $settings.HasExited -or $settings.MainWindowHandle -eq [IntPtr]::Zero)
          } catch { $report.settings_window_closed = $false }
      }
      if ($settingsOwned -and $report.settings_window_closed -ne $true) {
          $report.succeeded = $false
          if (-not $report.error_code) { $report.error_code = 'settings_window_close_not_confirmed' }
      }
      if ($Mode -eq 'Apply' -and $restoreRequired -and -not $report.succeeded -and $report.restore_verified -ne $true) {
          try {
              Select-Scale $baseline
              $report.restored_percent = Wait-Scale $baseline
              $report.restore_verified = $true
              $journal.state = 'restored'
              Write-RecoveryJournal $journal
          } catch { $report.restore_verified = $false; $report.error_code = 'scale_restore_not_confirmed' }
      }
      if ($report.executed) {
          try { $report.current_percent = [ShellDpiProbe]::PrimaryPercent() }
          catch { $report.succeeded = $false; $report.error_code = 'dpi_readback_failed' }
      }
      $report.captured_at_utc = [DateTime]::UtcNow.ToString('o')
      $json = $report | ConvertTo-Json -Depth 6 -Compress
      if ($OutputPath -match '^C:\\guest-shell-lab\\[A-Za-z0-9_.-]+\.json$') {
          New-Item -ItemType Directory -Force -Path 'C:\guest-shell-lab' | Out-Null
          [IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
      }
      $json
  }
  if (-not $report.succeeded) { exit 2 }
  """#
