#requires -Version 5.1
<#
.SYNOPSIS
    100% compliant desktop-less Kiosk application shell for Phase 13A (@DNPMBHC).
.DESCRIPTION
    Hides the Windows taskbar and desktop icons, sets a solid black background,
    launches the requested installer or game launcher centered in the viewport,
    monitors the foreground process read-only to emit a JSON signal for the host
    app-shell window and safely elevate the foreground game process to High priority,
    and cleanly restores the desktop on exit.
    Zero DWM hooks, zero process injection, zero driver/anti-cheat tampering.
#>
[CmdletBinding()]
param(
    [ValidateSet('Enter', 'Exit', 'Status')]
    [string]$Mode = 'Enter',
    [string]$TargetExecutable = '',
    [string]$TargetArguments = '',
    [string]$TargetWorkingDirectory = '',
    [string[]]$GameProcessNames = @('VALORANT-Win64-Shipping', 'DeltaForceClient-Win64-Shipping', 'd3d11_probe'),
    [int]$PollIntervalMs = 500,
    [int]$MaxWaitSeconds = 0,
    [string]$StatePath = 'C:\graphics-lab\guest-optimizer\kiosk-shell-state.json',
    [string]$LaunchReceiptPath = '',
    [string]$SignalOutputPath = 'C:\graphics-lab\guest-optimizer\kiosk-shell-signal.json',
    [switch]$PreserveDesktopState,
    [switch]$KeepKioskOnExit
)

$ErrorActionPreference = 'Stop'

# Hard-protected system and anti-cheat process prefixes: never alter their priority or state.
$ProtectedProcessPrefixes = @(
    'ACE-', 'AntiCheat', 'vgc', 'vgk', 'BEService', 'EasyAntiCheat',
    'csrss', 'lsass', 'services', 'smss', 'wininit', 'winlogon', 'System', 'svchost'
)

$Win32HelperCode = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class KioskShellNative {
    public const int SW_HIDE = 0;
    public const int SW_SHOW = 5;
    public const uint SPI_SETDESKWALLPAPER = 0x0014;
    public const uint SPIF_UPDATEINIFILE = 0x01;
    public const uint SPIF_SENDCHANGE = 0x02;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public static readonly IntPtr HWND_TOP = IntPtr.Zero;

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowEx(IntPtr parentHandle, IntPtr childAfter, string className, string windowTitle);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    public static IntPtr FindDesktopDefView() {
        IntPtr progman = FindWindow("Progman", null);
        IntPtr defView = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (defView != IntPtr.Zero) {
            return defView;
        }
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lParam) => {
            IntPtr child = FindWindowEx(hWnd, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (child != IntPtr.Zero) {
                found = child;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool SetTaskbarVisibility(bool visible) {
        int cmd = visible ? SW_SHOW : SW_HIDE;
        bool ok = false;
        IntPtr tray = FindWindow("Shell_TrayWnd", null);
        if (tray != IntPtr.Zero) {
            ShowWindow(tray, cmd);
            ok = true;
        }
        IntPtr secondary = FindWindow("Shell_SecondaryTrayWnd", null);
        if (secondary != IntPtr.Zero) {
            ShowWindow(secondary, cmd);
        }
        return ok;
    }

    public static bool SetDesktopIconsVisibility(bool visible) {
        IntPtr defView = FindDesktopDefView();
        if (defView == IntPtr.Zero) {
            return false;
        }
        ShowWindow(defView, visible ? SW_SHOW : SW_HIDE);
        return true;
    }

    public static bool IsTaskbarVisible() {
        IntPtr tray = FindWindow("Shell_TrayWnd", null);
        return tray != IntPtr.Zero && IsWindowVisible(tray);
    }

    public static bool IsDesktopIconsVisible() {
        IntPtr defView = FindDesktopDefView();
        return defView != IntPtr.Zero && IsWindowVisible(defView);
    }

    public static bool CenterAndFitWindow(IntPtr hWnd, double widthRatio, double heightRatio) {
        if (hWnd == IntPtr.Zero) {
            return false;
        }
        int screenW = Math.Max(800, GetSystemMetrics(0));
        int screenH = Math.Max(600, GetSystemMetrics(1));
        int targetW = Math.Max(640, (int)(screenW * widthRatio));
        int targetH = Math.Max(480, (int)(screenH * heightRatio));
        int x = Math.Max(0, (screenW - targetW) / 2);
        int y = Math.Max(0, (screenH - targetH) / 2);
        return SetWindowPos(hWnd, HWND_TOP, x, y, targetW, targetH, SWP_SHOWWINDOW);
    }
}
'@

if (-not ('KioskShellNative' -as [type])) {
    Add-Type -TypeDefinition $Win32HelperCode -Language CSharp
}

function Ensure-ParentDir([string]$Path) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Test-ProtectedProcess([string]$ProcessName) {
    if ([string]::IsNullOrWhiteSpace($ProcessName)) {
        return $true
    }
    foreach ($prefix in $ProtectedProcessPrefixes) {
        if ($ProcessName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Save-DesktopState([string]$Path) {
    Ensure-ParentDir $Path
    if (Test-Path -LiteralPath $Path) {
        return
    }
    $desktopKey = 'HKCU:\Control Panel\Desktop'
    $colorsKey = 'HKCU:\Control Panel\Colors'
    $advKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $wallpaper = ''
    $bgColor = '0 0 0'
    $hideIcons = 0
    try { $wallpaper = (Get-ItemProperty -Path $desktopKey -Name WallPaper -ErrorAction Stop).WallPaper } catch {}
    try { $bgColor = (Get-ItemProperty -Path $colorsKey -Name Background -ErrorAction Stop).Background } catch {}
    try { $hideIcons = [int](Get-ItemProperty -Path $advKey -Name HideIcons -ErrorAction Stop).HideIcons } catch {}

    $state = [ordered]@{
        schema_version = 1
        owner = '@DNPMBHC'
        captured_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        wallpaper = $wallpaper
        background_color = $bgColor
        hide_icons = $hideIcons
        taskbar_visible_before = [KioskShellNative]::IsTaskbarVisible()
        desktop_icons_visible_before = [KioskShellNative]::IsDesktopIconsVisible()
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Enter-KioskDesktop {
    Save-DesktopState -Path $StatePath
    $taskbarHidden = [KioskShellNative]::SetTaskbarVisibility($false)
    $iconsHidden = [KioskShellNative]::SetDesktopIconsVisibility($false)

    $advKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $colorsKey = 'HKCU:\Control Panel\Colors'
    if (Test-Path -LiteralPath $advKey) {
        Set-ItemProperty -Path $advKey -Name HideIcons -Value 1 -Type DWord -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $colorsKey) {
        Set-ItemProperty -Path $colorsKey -Name Background -Value '0 0 0' -ErrorAction SilentlyContinue
    }
    [KioskShellNative]::SystemParametersInfo(
        [KioskShellNative]::SPI_SETDESKWALLPAPER,
        0,
        '',
        [KioskShellNative]::SPIF_UPDATEINIFILE -bor [KioskShellNative]::SPIF_SENDCHANGE
    ) | Out-Null

    return [ordered]@{
        kiosk_active = $true
        taskbar_hidden = (-not [KioskShellNative]::IsTaskbarVisible())
        taskbar_api_invoked = $taskbarHidden
        desktop_icons_hidden = (-not [KioskShellNative]::IsDesktopIconsVisible())
        desktop_icons_api_invoked = $iconsHidden
        background_solid_black = $true
    }
}

function Restore-KioskDesktop {
    $restoredWallpaper = ''
    $restoredBg = '0 0 0'
    $restoredHideIcons = 0
    if (Test-Path -LiteralPath $StatePath) {
        $saved = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $saved.wallpaper) { $restoredWallpaper = [string]$saved.wallpaper }
        if ($null -ne $saved.background_color) { $restoredBg = [string]$saved.background_color }
        if ($null -ne $saved.hide_icons) { $restoredHideIcons = [int]$saved.hide_icons }
    }

    $advKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $colorsKey = 'HKCU:\Control Panel\Colors'
    if (Test-Path -LiteralPath $advKey) {
        Set-ItemProperty -Path $advKey -Name HideIcons -Value $restoredHideIcons -Type DWord -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $colorsKey) {
        Set-ItemProperty -Path $colorsKey -Name Background -Value $restoredBg -ErrorAction SilentlyContinue
    }
    [KioskShellNative]::SystemParametersInfo(
        [KioskShellNative]::SPI_SETDESKWALLPAPER,
        0,
        $restoredWallpaper,
        [KioskShellNative]::SPIF_UPDATEINIFILE -bor [KioskShellNative]::SPIF_SENDCHANGE
    ) | Out-Null

    [KioskShellNative]::SetTaskbarVisibility($true) | Out-Null
    [KioskShellNative]::SetDesktopIconsVisibility($true) | Out-Null

    return [ordered]@{
        restored = $true
        taskbar_visible = [KioskShellNative]::IsTaskbarVisible()
        desktop_icons_visible = [KioskShellNative]::IsDesktopIconsVisible()
        wallpaper_restored = $true
    }
}

function Write-HostSignal([hashtable]$Payload) {
    Ensure-ParentDir $SignalOutputPath
    $Payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $SignalOutputPath -Encoding UTF8
}

function Start-TargetApp([string]$ExePath, [string]$ArgsText, [string]$WorkingDirectory) {
    if ([string]::IsNullOrWhiteSpace($ExePath)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $ExePath)) {
        throw "Target executable not found: $ExePath"
    }
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $WorkingDirectory = [System.IO.Path]::GetDirectoryName($ExePath)
    }
    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw 'Target working directory is unavailable.'
    }
    $ext = [System.IO.Path]::GetExtension($ExePath).ToLowerInvariant()
    if ($ext -eq '.msi') {
        $msiArgs = "/i `"$ExePath`" $ArgsText".Trim()
        return Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -WorkingDirectory $WorkingDirectory -PassThru
    }
    if ([string]::IsNullOrWhiteSpace($ArgsText)) {
        return Start-Process -FilePath $ExePath -WorkingDirectory $WorkingDirectory -PassThru
    }
    return Start-Process -FilePath $ExePath -ArgumentList $ArgsText -WorkingDirectory $WorkingDirectory -PassThru
}

function Get-ForegroundProcessInfo {
    $hwnd = [KioskShellNative]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) {
        return $null
    }
    [uint32]$fgPid = 0
    [KioskShellNative]::GetWindowThreadProcessId($hwnd, [ref]$fgPid) | Out-Null
    if ($fgPid -eq 0) {
        return $null
    }
    try {
        $proc = Get-Process -Id $fgPid -ErrorAction Stop
        return [ordered]@{
            pid = [int]$fgPid
            process_name = $proc.ProcessName
            window_title = $proc.MainWindowTitle
            process = $proc
        }
    } catch {
        return $null
    }
}

if ($Mode -eq 'Status') {
    $status = [ordered]@{
        mode = 'Status'
        taskbar_visible = [KioskShellNative]::IsTaskbarVisible()
        desktop_icons_visible = [KioskShellNative]::IsDesktopIconsVisible()
        state_file_present = (Test-Path -LiteralPath $StatePath)
        signal_file_present = (Test-Path -LiteralPath $SignalOutputPath)
    }
    $status | ConvertTo-Json -Depth 4
    exit 0
}

if ($Mode -eq 'Exit') {
    $res = Restore-KioskDesktop
    $res['mode'] = 'Exit'
    $res | ConvertTo-Json -Depth 4
    exit 0
}

function Write-LaunchReceipt {
    param([string]$State, [int]$TargetPid = 0)
    if ([string]::IsNullOrWhiteSpace($LaunchReceiptPath)) { return }
    $parent = Split-Path -Parent $LaunchReceiptPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $receipt = [ordered]@{
        schema_version = 1
        state = $State
        pid = $TargetPid
        targetExecutable = $TargetExecutable
    }
    $temporaryReceipt = $LaunchReceiptPath + '.tmp'
    $receipt | ConvertTo-Json -Depth 3 -Compress | Set-Content -LiteralPath $temporaryReceipt -Encoding UTF8
    Move-Item -LiteralPath $temporaryReceipt -Destination $LaunchReceiptPath -Force
}

$enterInfo = $null
if (-not $PreserveDesktopState) {
    $enterInfo = Enter-KioskDesktop
}
$launchedProc = $null
$detectedGameSignal = $null
$windowCentered = $false

try {
    $launchedProc = Start-TargetApp -ExePath $TargetExecutable -ArgsText $TargetArguments -WorkingDirectory $TargetWorkingDirectory
    if (-not [string]::IsNullOrWhiteSpace($LaunchReceiptPath)) {
        if ($null -eq $launchedProc -or $launchedProc.Id -le 0) {
            throw 'No target process was started.'
        }
        Write-LaunchReceipt -State 'started' -TargetPid ([int]$launchedProc.Id)
    }
    if ($null -ne $launchedProc) {
        for ($i = 0; $i -lt 30; $i++) {
            $launchedProc.Refresh()
            if ($launchedProc.HasExited) { break }
            if ($launchedProc.MainWindowHandle -ne [IntPtr]::Zero) {
                $windowCentered = [KioskShellNative]::CenterAndFitWindow($launchedProc.MainWindowHandle, 0.82, 0.82)
                break
            }
            Start-Sleep -Milliseconds 200
        }
    }

    $deadline = if ($MaxWaitSeconds -gt 0) {
        (Get-Date).AddSeconds($MaxWaitSeconds)
    } else {
        $null
    }

    $elevatedPids = @{}
    while ($true) {
        $fg = Get-ForegroundProcessInfo
        if ($null -ne $fg) {
            $matched = $false
            foreach ($name in $GameProcessNames) {
                if ($fg.process_name -ieq $name) {
                    $matched = $true
                    break
                }
            }
            if ($matched -and -not $elevatedPids.ContainsKey($fg.pid)) {
                $priorityElevated = $false
                if (-not (Test-ProtectedProcess $fg.process_name)) {
                    try {
                        $fg.process.PriorityClass = 'High'
                        $priorityElevated = $true
                    } catch {}
                }
                $elevatedPids[$fg.pid] = $true
                $detectedGameSignal = [ordered]@{
                    schema_version = 1
                    owner = '@DNPMBHC'
                    event = 'game_foreground_detected'
                    action = 'enter_fullscreen_gamemode'
                    process_name = $fg.process_name
                    pid = $fg.pid
                    priority_elevated = $priorityElevated
                    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
                }
                Write-HostSignal -Payload $detectedGameSignal
            }
        }

        if ($null -ne $launchedProc) {
            $launchedProc.Refresh()
            if ($launchedProc.HasExited) {
                break
            }
        }
        if ($null -ne $deadline -and (Get-Date) -ge $deadline) {
            break
        }
        if ($null -eq $launchedProc -and $null -eq $deadline) {
            break
        }
        Start-Sleep -Milliseconds ([Math]::Max(100, $PollIntervalMs))
    }
} catch {
    Write-LaunchReceipt -State 'failed'
    throw
} finally {
    $restoreInfo = $null
    if (-not $PreserveDesktopState -and -not $KeepKioskOnExit) {
        $restoreInfo = Restore-KioskDesktop
    }
    $summary = [ordered]@{
        mode = 'Enter'
        compliance = [ordered]@{
            zero_dwm_hook = $true
            zero_process_injection = $true
            read_only_foreground_polling = $true
        }
        enter = $enterInfo
        target_launched = ($null -ne $launchedProc)
        target_window_centered = $windowCentered
        game_foreground_signal = $detectedGameSignal
        restore = $restoreInfo
    }
    $summary | ConvertTo-Json -Depth 6
}
