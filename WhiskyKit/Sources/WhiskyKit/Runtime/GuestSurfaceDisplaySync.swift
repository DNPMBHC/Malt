// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public protocol GuestDisplaySynchronizing: Sendable {
  func queryGuestDisplaySnapshot(configuration: RuntimeGuestConfiguration) async throws -> GuestDisplaySyncSnapshot
  func queryGuestDisplayMode(
    configuration: RuntimeGuestConfiguration
  ) async throws
    -> GuestDisplayMode
  func applyGuestDisplayMode(
    _ targetMode: GuestDisplayMode, configuration: RuntimeGuestConfiguration
  ) async throws -> GuestDisplaySyncSnapshot
  func restoreGuestDisplayMode(
    _ snapshot: GuestDisplaySyncSnapshot, configuration: RuntimeGuestConfiguration
  ) async throws -> GuestDisplayMode
}

extension GuestDisplaySynchronizing {
  public func queryGuestDisplaySnapshot(
    configuration: RuntimeGuestConfiguration
  ) async throws -> GuestDisplaySyncSnapshot {
    let mode = try await queryGuestDisplayMode(configuration: configuration)
    return GuestDisplaySyncSnapshot(previousMode: mode, appliedMode: mode)
  }
}

public enum GuestDisplaySyncError: Error, Equatable, Sendable {
  case invalidResponsePayload
  case changeDisplaySettingsFailed(Int)
  case interactiveDesktopRequired
}

struct GuestDisplaySyncResponse: Codable, Equatable, Sendable {
  let succeeded: Bool
  let deviceName: String
  let previousWidth: Int
  let previousHeight: Int
  let previousRefreshHz: Int
  let currentWidth: Int
  let currentHeight: Int
  let currentRefreshHz: Int
  let statusCode: Int
  let sessionID: UInt32
  let dpiPercent: Int

  enum CodingKeys: String, CodingKey {
    case succeeded = "ok"
    case deviceName = "device_name"
    case previousWidth = "previous_width"
    case previousHeight = "previous_height"
    case previousRefreshHz = "previous_refresh_hz"
    case currentWidth = "current_width"
    case currentHeight = "current_height"
    case currentRefreshHz = "current_refresh_hz"
    case statusCode = "status_code"
    case sessionID = "session_id"
    case dpiPercent = "dpi_percent"
  }

  var currentMode: GuestDisplayMode {
    GuestDisplayMode(
      width: currentWidth, height: currentHeight, refreshRateHz: currentRefreshHz,
      dpiScalePercent: dpiPercent)
  }

  var previousMode: GuestDisplayMode {
    GuestDisplayMode(
      width: previousWidth, height: previousHeight, refreshRateHz: previousRefreshHz,
      dpiScalePercent: dpiPercent)
  }
}

/// Session 1 display modes are transient: no registry persistence or undocumented DPI setter.
public enum GuestDisplaySyncScriptBuilder {
  private static let helper = #"""
    using System;
    using System.Runtime.InteropServices;
    public static class GuestDisplayModeHelper {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct Mode {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string device;
            public ushort spec, driver, size, extra;
            public uint fields;
            public int x, y;
            public uint orientation, fixedOutput;
            public short color, duplex, yResolution, ttOption, collate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string form;
            public ushort logPixels;
            public uint bits, width, height, flags, frequency, icmMethod, icmIntent;
            public uint media, dither, reserved1, reserved2, panningWidth, panningHeight;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct Display {
            public uint size;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string description;
            public uint flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string id;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string key;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplayDevicesW(string device, uint index, ref Display display, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplaySettingsW(string device, int index, ref Mode mode);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int ChangeDisplaySettingsExW(
        string device, ref Mode mode, IntPtr window, uint flags, IntPtr param);
        [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(
            uint exStyle, string className, string title, uint style, int x, int y, int width,
            int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
        [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr window);
        [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr window);
        public static int CurrentScalePercent() {
            IntPtr window = CreateWindowExW(0, "STATIC", "guest-shell-display-dpi", 0,
                0, 0, 1, 1, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (window == IntPtr.Zero) throw new InvalidOperationException("dpiWindowUnavailable");
            try {
                uint dpi = GetDpiForWindow(window);
                if (dpi < 96 || dpi > 288) throw new InvalidOperationException("dpiOutOfBounds");
                return (int)Math.Round(dpi * 100.0 / 96.0);
            } finally { DestroyWindow(window); }
        }
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        public static void SetAwareness() {
            if (SetThreadDpiAwarenessContext(new IntPtr(-4)) == IntPtr.Zero)
            throw new InvalidOperationException("dpiQueryAwarenessFailed");
        }
        public static string Primary() {
            for (uint index = 0; index < 32; index++) {
                var display = new Display(); display.size = (uint)Marshal.SizeOf(typeof(Display));
                if (!EnumDisplayDevicesW(null, index, ref display, 0)) break;
                if ((display.flags & 5) == 5) return display.name;
            }
            throw new InvalidOperationException("primaryDisplayUnavailable");
        }
        public static Mode Query(string device, int index) {
            var mode = new Mode(); mode.size = (ushort)Marshal.SizeOf(typeof(Mode));
            if (!EnumDisplaySettingsW(device, index, ref mode))
            throw new InvalidOperationException("displayQueryFailed");
            return mode;
        }
        public static int Apply(string device, uint width, uint height, uint refresh) {
            Mode current = Query(device, -1);
        Mode selected = new Mode(); bool found = false;
            for (int index = 0; index < 4096; index++) {
                var mode = new Mode(); mode.size = (ushort)Marshal.SizeOf(typeof(Mode));
                if (!EnumDisplaySettingsW(device, index, ref mode)) break;
                if (mode.width != width || mode.height != height
            || mode.frequency > refresh || mode.bits != current.bits)
                continue;
                if (!found || mode.frequency > selected.frequency) { selected = mode; found = true; }
            }
            if (!found) return -2;
            selected.fields = 0x80000 | 0x100000 | 0x400000 | 0x40000;
            int test = ChangeDisplaySettingsExW(device, ref selected, IntPtr.Zero, 2, IntPtr.Zero);
            return test == 0
            ? ChangeDisplaySettingsExW(device, ref selected, IntPtr.Zero, 0, IntPtr.Zero) : test;
        }
    }
    """#

  public static func queryScript() -> String { script(mode: nil, deviceName: nil) }

  public static func applyScript(
    for mode: GuestDisplayMode, deviceName: String? = nil
  ) throws -> String {
    try GuestDisplayResolutionPolicy.validate(mode)
    if let deviceName {
      guard
        deviceName.range(of: #"^\\\\\.\\DISPLAY[0-9]{1,3}$"#, options: .regularExpression) != nil
      else {
        throw GuestDisplaySyncError.invalidResponsePayload
      }
    }
    return script(mode: mode, deviceName: deviceName)
  }

  private static func script(mode: GuestDisplayMode?, deviceName: String?) -> String {
    let encodedDevice = Data((deviceName ?? "").utf8).base64EncodedString()
    let apply =
      mode.map {
        "$rc = [GuestDisplayModeHelper]::Apply($device, "
          + "[uint32]\($0.width), [uint32]\($0.height), [uint32]\($0.refreshRateHz));"
      } ?? "$rc = 0;"
    return """
      $ErrorActionPreference='Stop';
      $session = [Diagnostics.Process]::GetCurrentProcess().SessionId;
      if ($session -ne 1) { throw 'interactiveSession1Required' };
      $code = @'
      \(helper)
      '@;
      Add-Type -TypeDefinition $code -Language CSharp | Out-Null;
      [GuestDisplayModeHelper]::SetAwareness();
      $device = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(encodedDevice)'));
      if (-not $device) { $device = [GuestDisplayModeHelper]::Primary() };
      $before = [GuestDisplayModeHelper]::Query($device, -1);
      \(apply)
      $after = [GuestDisplayModeHelper]::Query($device, -1);
      @{ ok = ($rc -eq 0); device_name = $device; session_id = $session;
         previous_width = [int]$before.width; previous_height = [int]$before.height;
         previous_refresh_hz = [int]$before.frequency; current_width = [int]$after.width;
         current_height = [int]$after.height; current_refresh_hz = [int]$after.frequency;
         dpi_percent = [GuestDisplayModeHelper]::CurrentScalePercent();
         status_code = [int]$rc } | ConvertTo-Json -Compress
      """
  }

  public static func encodedPowerShellArguments(for script: String) -> [String] {
    [
      "-NoProfile", "-NonInteractive", "-EncodedCommand",
      Data(
        script.utf16.flatMap {
          [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]
        }
      ).base64EncodedString()
    ]
  }
}

extension UTMWindowsGuestProvider: GuestDisplaySynchronizing {
  public func queryGuestDisplayMode(configuration config: RuntimeGuestConfiguration) async throws -> GuestDisplayMode {
    try await runDisplaySyncScript(
      GuestDisplaySyncScriptBuilder.queryScript(), configuration: config
    ).currentMode
  }

  public func queryGuestDisplaySnapshot(
    configuration config: RuntimeGuestConfiguration
  ) async throws -> GuestDisplaySyncSnapshot {
    let response = try await runDisplaySyncScript(GuestDisplaySyncScriptBuilder.queryScript(), configuration: config)
    return GuestDisplaySyncSnapshot(
      previousMode: response.currentMode, appliedMode: response.currentMode,
      displayDeviceName: response.deviceName)
  }

  public func applyGuestDisplayMode(
    _ targetMode: GuestDisplayMode, configuration config: RuntimeGuestConfiguration
  ) async throws -> GuestDisplaySyncSnapshot {
    let response = try await runDisplaySyncScript(
      GuestDisplaySyncScriptBuilder.applyScript(for: targetMode), configuration: config)
    guard response.currentWidth == targetMode.width, response.currentHeight == targetMode.height,
      response.currentRefreshHz <= targetMode.refreshRateHz
    else {
      throw GuestDisplaySyncError.invalidResponsePayload
    }
    return GuestDisplaySyncSnapshot(
      previousMode: response.previousMode, appliedMode: response.currentMode,
      displayDeviceName: response.deviceName, changeDisplayStatusCode: response.statusCode,
      dpiSynchronizationStatus: response.dpiPercent == targetMode.dpiScalePercent
        ? .unchanged : .unsupported)
  }

  public func restoreGuestDisplayMode(
    _ snapshot: GuestDisplaySyncSnapshot, configuration config: RuntimeGuestConfiguration
  ) async throws -> GuestDisplayMode {
    let response = try await runDisplaySyncScript(
      GuestDisplaySyncScriptBuilder.applyScript(
        for: snapshot.previousMode, deviceName: snapshot.displayDeviceName),
      configuration: config)
    guard response.currentMode == snapshot.previousMode else {
      throw GuestDisplaySyncError.invalidResponsePayload
    }
    return response.currentMode
  }

  private func runDisplaySyncScript(
    _ script: String, configuration config: RuntimeGuestConfiguration
  ) async throws -> GuestDisplaySyncResponse {
    try GuestConfigurationValidator.validate(config)
    guard installed else { throw UTMGuestError.utmNotInstalled }
    let deadline = ContinuousClock.now + .seconds(config.startupTimeoutSeconds)
    return try await UTMGuestOperationDeadline.$value.withValue(deadline) {
      let helper = try resolveInteractiveConfiguration(configuration: config)
      let initial = try await transport.inspect(config.identifier)
      guard initial.identifier == config.identifier else { throw UTMGuestError.vmUnavailable }
      try validate(initial, config: config)
      let launched = try await prepareVM(initial, config: config, until: deadline)
      do {
        return try await executeDisplayCommand(script, helper: helper, config: config, deadline: deadline)
      } catch {
        if launched {
          let cleanup = Task {
            try await UTMGuestOperationDeadline.$value.withValue(nil) {
              if initial.status == .paused {
                try await self.suspendGuest(configuration: config)
              } else {
                try await self.rollbackGuest(config.identifier)
              }
            }
          }
          do { try await cleanup.value } catch { throw UTMGuestError.rollbackFailed }
        }
        throw error
      }
    }
  }
  private func executeDisplayCommand(
    _ script: String, helper: WindowsGuestInteractiveConfiguration,
    config: RuntimeGuestConfiguration, deadline: ContinuousClock.Instant
  ) async throws -> GuestDisplaySyncResponse {
    try await waitForAgent(config, until: deadline)
    try await ensureInteractiveHelper(helper, configuration: config, until: deadline)
    let handle = try await transport.executeInteractive(
      config.identifier,
      request: WindowsGuestInteractiveLaunchRequest(
        helperGuestPath: helper.guestHelperPath,
        executable: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#,
        arguments: GuestDisplaySyncScriptBuilder.encodedPowerShellArguments(for: script),
        environment: [:]),
      timing: WindowsGuestInteractiveTiming(deadline: deadline, pollInterval: pollInterval))
    let session = WindowsGuestInteractiveSession(
      transport: transport, vmID: config.identifier, handle: handle, interval: pollInterval)
    guard handle.sessionID == 1 else {
      await session.cancel()
      throw GuestDisplaySyncError.interactiveDesktopRequired
    }
    let exit = try await session.wait()
    guard exit.status == 0 else { throw GuestDisplaySyncError.invalidResponsePayload }
    let snapshot = try await session.latestSnapshot()
    guard
      let response = try? JSONDecoder().decode(
        GuestDisplaySyncResponse.self, from: snapshot.standardOutput),
      response.sessionID == 1
    else { throw GuestDisplaySyncError.invalidResponsePayload }
    guard response.succeeded, response.statusCode == 0 else {
      throw GuestDisplaySyncError.changeDisplaySettingsFailed(response.statusCode)
    }
    try GuestDisplayResolutionPolicy.validate(response.currentMode)
    try GuestDisplayResolutionPolicy.validate(response.previousMode)
    _ = try GuestDisplaySyncScriptBuilder.applyScript(for: response.currentMode, deviceName: response.deviceName)
    return response
  }

}
