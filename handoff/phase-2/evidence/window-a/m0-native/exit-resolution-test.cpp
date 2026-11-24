// SPDX-License-Identifier: GPL-3.0-or-later
// Maintainer: @DNPMBHC
// Host-executable regression tests for the exact resolution function used by the broker.
#include "exit-resolution.hpp"
#include <stdio.h>

int main() {
  using desktop_protocol::resolveRelayExit;
  unsigned passed = 0;
  auto check = [&](bool value) { if (value) ++passed; return value; };
  auto naturalCancelRace = resolveRelayExit(0, 0, false, true);
  if (!check(naturalCancelRace.valid && naturalCancelRace.cancelled &&
      naturalCancelRace.sessionExitCode == 1223 && naturalCancelRace.rootExitCode == 0)) return 1;
  auto naturalFailure = resolveRelayExit(42, 42, false, false);
  if (!check(naturalFailure.valid && !naturalFailure.cancelled &&
      naturalFailure.sessionExitCode == 42 && naturalFailure.rootExitCode == 42)) return 1;
  auto relayTreeCancel = resolveRelayExit(1223, 0, true, false);
  if (!check(relayTreeCancel.valid && relayTreeCancel.cancelled &&
      relayTreeCancel.sessionExitCode == 1223 && relayTreeCancel.rootExitCode == 0)) return 1;
  auto invalidNaturalFrame = resolveRelayExit(1223, 0, false, true);
  if (!check(!invalidNaturalFrame.valid)) return 1;
  auto invalidCancelledFrame = resolveRelayExit(0, 0, true, true);
  if (!check(!invalidCancelledFrame.valid)) return 1;
  auto statusBits = resolveRelayExit(0xC0000005, 0xC0000005, false, true);
  if (!check(statusBits.valid && statusBits.cancelled && statusBits.sessionExitCode == 1223 &&
      statusBits.rootExitCode == 0xC0000005)) return 1;
  auto repeatedIntent = resolveRelayExit(1223, 42, true, true);
  if (!check(repeatedIntent.valid && repeatedIntent.cancelled &&
      repeatedIntent.sessionExitCode == 1223 && repeatedIntent.rootExitCode == 42)) return 1;
  printf("{\"schemaVersion\":1,\"test\":\"native-exit-resolution\",\"passed\":%u,\"failed\":0}\n", passed);
  return passed == 7 ? 0 : 1;
}
