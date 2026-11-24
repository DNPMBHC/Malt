// SPDX-License-Identifier: GPL-3.0-or-later
// Maintainer: @DNPMBHC
#pragma once
#include <stdint.h>

namespace desktop_protocol {
constexpr uint32_t cancelledSessionCode = 1223;
struct ExitResolution {
  bool valid;
  bool cancelled;
  uint32_t sessionExitCode;
  uint32_t rootExitCode;
};

// Validate the relay's ORIGINAL frame before merging any controller cancellation intent.
// A controller intent may change session semantics, but cannot legitimize malformed wire data.
constexpr ExitResolution resolveRelayExit(uint32_t relayExitCode, uint32_t rootExitCode,
                                         bool relayCancelled, bool controllerCancelIntent) {
  bool valid = relayExitCode == (relayCancelled ? cancelledSessionCode : rootExitCode);
  bool merged = relayCancelled || controllerCancelIntent;
  return {valid, merged, merged ? cancelledSessionCode : rootExitCode, rootExitCode};
}
} // namespace desktop_protocol
