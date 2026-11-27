// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension ContainerGuestDispatcher {
  func readAppShellEnvelope(session: GuestAppShellSession, challenge: String) async throws -> Data {
    guard UUID(uuidString: challenge) != nil,
      UUID(uuidString: session.vmIdentifier) == UUID(uuidString: vmIdentifier)
    else { throw GuestAppShellValidationError.invalidResponse }
    let script = GuestAppShellScripts.readEnvelope(for: session, challenge: challenge)
    let result = try await commandRunner(
      controlBinaryPath,
      ["exec", vmIdentifier, "--cmd", "powershell.exe", "-NoProfile", "-EncodedCommand",
        Self.encodedPowerShell(script)],
      ["__DEMOAPP_TIMEOUT_SECONDS": "5"])
    try Self.requireAutomationAccess(result)
    guard result.exitCode == 0, let data = result.stdout.data(using: .utf8) else {
      throw GuestAppShellValidationError.invalidResponse
    }
    return data
  }

  func stopAppShellObserver(session: GuestAppShellSession) async {
    guard UUID(uuidString: session.vmIdentifier) == UUID(uuidString: vmIdentifier) else { return }
    let script = """
      if (Test-Path -LiteralPath \(Self.powerShellLiteral(session.guestRoot)) -PathType Container) {
          New-Item -ItemType File -Path \(Self.powerShellLiteral(session.stopPath)) -Force | Out-Null;
      };
      """
    let cleanup = Task.detached {
      _ = try? await commandRunner(
        controlBinaryPath,
        ["exec", vmIdentifier, "--cmd", "powershell.exe", "-NoProfile", "-EncodedCommand",
          Self.encodedPowerShell(script)], ["__DEMOAPP_TIMEOUT_SECONDS": "5"])
    }
    await cleanup.value
  }

}
