// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// The observer runs in the same limited Interactive task as the selected executable.
// Guest-agent commands only read its scoped result; Session 0 is never foreground evidence.
enum GuestAppShellScripts {
  // Literal PowerShell remains adjacent to its session binding for review.
  // swiftlint:disable function_body_length line_length
  static func observer(for session: GuestAppShellSession) -> String {
    let literal = ContainerGuestDispatcher.powerShellLiteral
    return """
      $ErrorActionPreference='Stop';
      $root=\(literal(session.guestRoot));
      $target=\(literal(session.targetExecutable));
      $signalPath=\(literal(session.signalPath));
      $stopPath=\(literal(session.stopPath));
      $receiptPath=Join-Path $root 'launch-receipt.json';
      $sourcePath=Join-Path $root 'signal.json';
      $context=Get-Content -LiteralPath \(literal(session.contextPath)) -Raw | ConvertFrom-Json;
      $started=[double]$context.sessionStartedAt;
      $deadline=[DateTime]::UtcNow.AddHours(12);
      $sequence=0; $rootPID=0; $creationTicks=''; $createdAt=0.0; $processPath='';
      $sourceEvent=''; $sourceAction=''; $sourcePID=0; $sourceObservedAt=0.0;
      Add-Type -TypeDefinition @'
      using System;
      using System.Runtime.InteropServices;
      public static class ScopedForegroundObserver {
          [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
          [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
      }
      '@;
      function Get-UnixTime([DateTime]$value) {
          return ([DateTimeOffset]$value.ToUniversalTime()).ToUnixTimeMilliseconds()/1000.0;
      }
      function Write-Signal([string]$eventName, [int]$foregroundPID) {
          $script:sequence++;
          $payload=[ordered]@{
              schemaVersion=1; sessionID=\(literal(session.id.uuidString)); vmIdentifier=\(literal(session.vmIdentifier));
              targetExecutable=$target; sequence=$script:sequence; event=$eventName;
              observedAt=(Get-UnixTime ([DateTime]::UtcNow)); sessionStartedAt=$started;
              rootPID=$script:rootPID; processCreationTicks=$script:creationTicks; processCreatedAt=$script:createdAt;
              processPath=$script:processPath; processName=([IO.Path]::GetFileNameWithoutExtension($target)).ToLowerInvariant();
              foregroundPID=$foregroundPID; sourceEvent=$script:sourceEvent; sourceAction=$script:sourceAction;
              sourcePID=$script:sourcePID; sourceObservedAt=$script:sourceObservedAt;
          };
          $temporary=$signalPath+'.tmp';
          $payload | ConvertTo-Json -Compress -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8;
          Move-Item -LiteralPath $temporary -Destination $signalPath -Force;
      }
      try {
          while ([DateTime]::UtcNow -lt $deadline -and !(Test-Path -LiteralPath $stopPath)) {
              if ($rootPID -eq 0) {
                  if (!(Test-Path -LiteralPath $receiptPath)) {
                      Write-Signal 'waiting' 0;
                      if ((Get-UnixTime ([DateTime]::UtcNow))-$started -gt 185) { Write-Signal 'failed' 0; break };
                      Start-Sleep -Milliseconds 500; continue;
                  };
                  $receipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json;
                  if ($receipt.state -eq 'failed') { Write-Signal 'failed' 0; break };
                  if ($receipt.state -ne 'started' -or [int]$receipt.pid -le 0 -or $receipt.targetExecutable -ine $target) {
                      Write-Signal 'failed' 0; break;
                  };
                  $candidate=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$receipt.pid);
                  if ($null -eq $candidate) { Write-Signal 'exited' 0; break };
                  if ([string]$candidate.ExecutablePath -ine $target) { Write-Signal 'failed' 0; break };
                  $rootPID=[int]$candidate.ProcessId;
                  $creationTicks=([DateTime]$candidate.CreationDate).ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture);
                  $createdAt=Get-UnixTime ([DateTime]$candidate.CreationDate);
                  $processPath=[string]$candidate.ExecutablePath;
              };
              $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$rootPID);
              if ($null -eq $current) { Write-Signal 'exited' 0; break };
              $currentTicks=([DateTime]$current.CreationDate).ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture);
              if ($currentTicks -ne $creationTicks -or [string]$current.ExecutablePath -ine $processPath) {
                  Write-Signal 'exited' 0; break;
              };
              [uint32]$foregroundPID=0;
              $window=[ScopedForegroundObserver]::GetForegroundWindow();
              if ($window -ne [IntPtr]::Zero) {
                  [ScopedForegroundObserver]::GetWindowThreadProcessId($window,[ref]$foregroundPID) | Out-Null;
              };
              if ($sourceObservedAt -eq 0 -and (Test-Path -LiteralPath $sourcePath)) {
                  $source=Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json;
                  if ($source.event -eq 'game_foreground_detected' -and $source.action -eq 'enter_fullscreen_gamemode' -and [int]$source.pid -eq $rootPID -and $source.process_name -ieq ([IO.Path]::GetFileNameWithoutExtension($target))) {
                      $sourceEvent=[string]$source.event; $sourceAction=[string]$source.action; $sourcePID=[int]$source.pid;
                      $sourceObservedAt=Get-UnixTime ([DateTime]::Parse([string]$source.timestamp_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind));
                  };
              };
              if ($foregroundPID -eq $rootPID -and $sourceObservedAt -gt 0) {
                  Write-Signal 'game_foreground' ([int]$foregroundPID);
              } else { Write-Signal 'compact' ([int]$foregroundPID) };
              Start-Sleep -Milliseconds 500;
          };
      } catch { try { Write-Signal 'failed' 0 } catch {} };
      """
  }

  static func readEnvelope(for session: GuestAppShellSession, challenge: String) -> String {
    let literal = ContainerGuestDispatcher.powerShellLiteral
    return """
      $ErrorActionPreference='Stop';
      $path=\(literal(session.signalPath)); $raw='null';
      if (Test-Path -LiteralPath $path -PathType Leaf) {
          if ((Get-Item -LiteralPath $path).Length -gt 16384) { throw 'Signal exceeds limit' };
          $raw=[IO.File]::ReadAllText($path).TrimStart([char]0xFEFF);
      };
      $now=([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0).ToString('R',[Globalization.CultureInfo]::InvariantCulture);
      Write-Output ('{"schemaVersion":1,"challenge":"\(challenge)","guestNow":'+$now+',"signal":'+$raw+'}');
      """
  }
  // swiftlint:enable function_body_length line_length
}
