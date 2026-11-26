// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// The observer runs in the same limited Interactive task as the selected executable.
// Guest-agent commands only read its scoped result; Session 0 is never foreground evidence.
enum GuestAppShellScripts {
  // Literal PowerShell remains adjacent to its session binding for review.
  // swiftlint:disable function_body_length line_length
  static func observer(for session: GuestAppShellSession) -> String {
    let literal = ContainerGuestDispatcher.powerShellLiteral
    let knownList = GuestAppShellSignalValidator.knownGameProcessNames
      .union(session.expectedGameProcessNames)
      .sorted()
      .map(literal)
      .joined(separator: ",")
    return """
      $ErrorActionPreference='Stop';
      $root=\(literal(session.guestRoot));
      $target=\(literal(session.targetExecutable));
      $signalPath=\(literal(session.signalPath));
      $stopPath=\(literal(session.stopPath));
      $receiptPath=Join-Path $root 'launch-receipt.json';
      $sourcePath=Join-Path $root 'signal.json';
      $knownGames=@(\(knownList));
      $excludedUtils=@('explorer','cmd','powershell','pwsh','conhost','msiexec','taskmgr','rundll32','svchost','searchhost','shellexperiencehost','startmenuexperiencehost','applicationframehost','werfault','notepad');
      $context=Get-Content -LiteralPath \(literal(session.contextPath)) -Raw | ConvertFrom-Json;
      $started=[double]$context.sessionStartedAt;
      $deadline=[DateTime]::UtcNow.AddHours(12);
      $sequence=0; $rootPID=0; $creationTicks=''; $createdAt=0.0; $processPath='';
      $sourceEvent=''; $sourceAction=''; $sourcePID=0; $sourceObservedAt=0.0;
      $knownTree=@{}; $activeDescendants=@{};
      Add-Type -TypeDefinition @'
      using System;
      using System.Runtime.InteropServices;
      public static class ScopedForegroundObserver {
          [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
          [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
          [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
          [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
          [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
          [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out RECT rect);
          [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
          [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
          [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
          public static bool IsFullscreen(IntPtr window) {
              if (window == IntPtr.Zero || !IsWindowVisible(window)) return false;
              RECT r; if (!GetWindowRect(window, out r)) return false;
              int w = r.Right - r.Left, h = r.Bottom - r.Top;
              if (w < 640 || h < 480) return false;
              int mw = Math.Max(800, GetSystemMetrics(0)), mh = Math.Max(600, GetSystemMetrics(1));
              IntPtr m = MonitorFromWindow(window, 2);
              if (m != IntPtr.Zero) {
                  MONITORINFO info = new MONITORINFO(); info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                  if (GetMonitorInfo(m, ref info)) { mw = Math.Max(800, info.rcMonitor.Right - info.rcMonitor.Left); mh = Math.Max(600, info.rcMonitor.Bottom - info.rcMonitor.Top); }
              }
              return w >= (int)(mw * 0.95) && h >= (int)(mh * 0.95);
          }
      }
      '@;
      function Get-UnixTime([DateTime]$value) {
          return ([DateTimeOffset]$value.ToUniversalTime()).ToUnixTimeMilliseconds()/1000.0;
      }
      function Get-ProcMap {
          $m=@{};
          foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
              $id=[int]$p.ProcessId; if ($id -le 0 -or $null -eq $p.CreationDate) { continue };
              $dt=[DateTime]$p.CreationDate;
              $m[$id]=[ordered]@{
                  pid=$id; parentPID=[int]$p.ParentProcessId;
                  creationTicks=$dt.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture);
                  createdAt=(Get-UnixTime $dt);
                  processName=([IO.Path]::GetFileNameWithoutExtension([string]$p.Name)).ToLowerInvariant();
                  processPath=[string]$p.ExecutablePath;
              };
          };
          return $m;
      }
      function Resolve-Lineage([hashtable]$snap, [int]$targetPid) {
          if ($targetPid -le 0 -or $rootPID -le 0 -or !$snap.ContainsKey($targetPid)) { return $null };
          $rev=New-Object 'System.Collections.Generic.List[object]';
          $seen=New-Object 'System.Collections.Generic.HashSet[int]';
          $cur=$targetPid;
          for ($d=0; $d -lt 12; $d++) {
              if (!$seen.Add($cur)) { return $null };
              $n=if ($snap.ContainsKey($cur)) { $snap[$cur] } elseif ($knownTree.ContainsKey($cur)) { $knownTree[$cur] } else { $null };
              if ($null -eq $n) { return $null };
              $rev.Add($n);
              if ($cur -eq $rootPID) {
                  if ($n.creationTicks -ne $creationTicks) { return $null };
                  $chain=@(); for ($i=$rev.Count-1; $i -ge 0; $i--) { $chain+=$rev[$i] };
                  for ($j=1; $j -lt $chain.Count; $j++) {
                      if ([int]$chain[$j].parentPID -ne [int]$chain[$j-1].pid) { return $null };
                      if ([double]$chain[$j].createdAt -lt ([double]$chain[$j-1].createdAt - 1.0)) { return $null };
                  };
                  return ,$chain;
              };
              $pp=[int]$n.parentPID; if ($pp -le 0 -or $pp -eq $cur) { return $null }; $cur=$pp;
          };
          return $null;
      }
      function Write-Signal([string]$eventName, [int]$foregroundPID, $fgMeta, [bool]$isFs, $chain) {
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
          if ($null -ne $fgMeta) {
              $payload['foregroundProcessName']=[string]$fgMeta.processName;
              $payload['foregroundProcessPath']=[string]$fgMeta.processPath;
              $payload['foregroundCreationTicks']=[string]$fgMeta.creationTicks;
              $payload['foregroundCreatedAt']=[double]$fgMeta.createdAt;
              $payload['foregroundWindowFullscreen']=[bool]$isFs;
          };
          if ($null -ne $chain -and $chain.Count -ge 2) { $payload['lineageChain']=@($chain) };
          $temporary=$signalPath+'.tmp';
          $payload | ConvertTo-Json -Compress -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8;
          Move-Item -LiteralPath $temporary -Destination $signalPath -Force;
      }
      try {
          while ([DateTime]::UtcNow -lt $deadline -and !(Test-Path -LiteralPath $stopPath)) {
              if ($rootPID -eq 0) {
                  if (!(Test-Path -LiteralPath $receiptPath)) {
                      Write-Signal 'waiting' 0 $null $false $null;
                      if ((Get-UnixTime ([DateTime]::UtcNow))-$started -gt 185) { Write-Signal 'failed' 0 $null $false $null; break };
                      Start-Sleep -Milliseconds 500; continue;
                  };
                  $receipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json;
                  if ($receipt.state -eq 'failed') { Write-Signal 'failed' 0 $null $false $null; break };
                  if ($receipt.state -ne 'started' -or [int]$receipt.pid -le 0 -or $receipt.targetExecutable -ine $target) {
                      Write-Signal 'failed' 0 $null $false $null; break;
                  };
                  $candidate=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$receipt.pid);
                  if ($null -eq $candidate) { Write-Signal 'exited' 0 $null $false $null; break };
                  if ([string]$candidate.ExecutablePath -ine $target) { Write-Signal 'failed' 0 $null $false $null; break };
                  $rootPID=[int]$candidate.ProcessId;
                  $creationTicks=([DateTime]$candidate.CreationDate).ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture);
                  $createdAt=Get-UnixTime ([DateTime]$candidate.CreationDate);
                  $processPath=[string]$candidate.ExecutablePath;
                  $knownTree[$rootPID]=[ordered]@{
                      pid=$rootPID; parentPID=[int]$candidate.ParentProcessId; creationTicks=$creationTicks;
                      createdAt=$createdAt; processName=([IO.Path]::GetFileNameWithoutExtension($target)).ToLowerInvariant();
                      processPath=$processPath;
                  };
              };
              $snap=Get-ProcMap;
              $rootAlive=($snap.ContainsKey($rootPID) -and $snap[$rootPID].creationTicks -eq $creationTicks -and $snap[$rootPID].processPath -ieq $processPath);
              foreach ($entry in $snap.Values) {
                  $cpid=[int]$entry.pid; if ($cpid -eq $rootPID) { continue };
                  $cchain=Resolve-Lineage $snap $cpid;
                  if ($null -ne $cchain) {
                      foreach ($cn in $cchain) { $knownTree[[int]$cn.pid]=$cn };
                      $activeDescendants[$cpid]=[string]$entry.creationTicks;
                  };
              };
              foreach ($tpid in @($activeDescendants.Keys)) {
                  if (!$snap.ContainsKey($tpid) -or $snap[$tpid].creationTicks -ne $activeDescendants[$tpid]) { $activeDescendants.Remove($tpid) };
              };
              if (!$rootAlive -and $activeDescendants.Count -eq 0) { Write-Signal 'exited' 0 $null $false $null; break };
              [uint32]$foregroundPID=0; $isFs=$false;
              $window=[ScopedForegroundObserver]::GetForegroundWindow();
              if ($window -ne [IntPtr]::Zero) {
                  [ScopedForegroundObserver]::GetWindowThreadProcessId($window,[ref]$foregroundPID) | Out-Null;
                  $isFs=[ScopedForegroundObserver]::IsFullscreen($window);
              };
              $fgInt=[int]$foregroundPID;
              $fgChain=if ($fgInt -gt 0) { Resolve-Lineage $snap $fgInt } else { $null };
              $fgMeta=if ($fgInt -gt 0 -and $snap.ContainsKey($fgInt)) { $snap[$fgInt] } else { $null };
              if (Test-Path -LiteralPath $sourcePath) {
                  try {
                      $source=Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json;
                      $spid=[int]$source.pid;
                      if ($source.event -eq 'game_foreground_detected' -and $source.action -eq 'enter_fullscreen_gamemode' -and $spid -gt 0) {
                          $sChain=Resolve-Lineage $snap $spid;
                          if ($null -ne $sChain -and $spid -ne $sourcePID) {
                              $sourceEvent=[string]$source.event; $sourceAction=[string]$source.action; $sourcePID=$spid;
                              $sourceObservedAt=Get-UnixTime ([DateTime]::Parse([string]$source.timestamp_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind));
                          };
                      };
                  } catch {};
              };
              $emitGame=$false;
              if ($null -ne $fgChain -and $null -ne $fgMeta -and $sourceObservedAt -gt 0 -and $sourcePID -eq $fgInt) {
                  $fn=[string]$fgMeta.processName;
                  if ($fgInt -eq $rootPID) {
                      $emitGame=($knownGames -contains $fn);
                  } else {
                      $emitGame=(($knownGames -contains $fn) -or ($isFs -and !($excludedUtils -contains $fn)));
                  };
              };
              if ($emitGame) {
                  Write-Signal 'game_foreground' $fgInt $fgMeta $isFs $fgChain;
              } else { Write-Signal 'compact' $fgInt $fgMeta $isFs $fgChain };
              Start-Sleep -Milliseconds 500;
          };
      } catch { try { Write-Signal 'failed' 0 $null $false $null } catch {} };
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
