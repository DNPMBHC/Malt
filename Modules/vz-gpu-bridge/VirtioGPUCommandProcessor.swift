// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

import Foundation

public enum VirtioGPUCommandProcessor {
    public static func response(to command: Data, width: UInt32 = 1280, height: UInt32 = 720) -> Data {
        guard let header = VirtioGPUCtrlHeader.decode(command) else {
            return VirtioGPUCtrlHeader(type: VirtioGPUSpec.respErrInvalidParameter).encode()
        }
        guard header.flags & ~UInt32(3) == 0,
              command.count == VirtioGPUCtrlHeader.byteSize,
              header.type == VirtioGPUSpec.cmdGetDisplayInfo else {
            return reply(header: header, type: VirtioGPUSpec.respErrUnspec)
        }
        var result = reply(header: header, type: VirtioGPUSpec.respOkDisplayInfo)
        for index in 0..<16 {
            let fields: [UInt32] = [0, 0, index == 0 ? width : 0, index == 0 ? height : 0,
                                    index == 0 ? 1 : 0, 0]
            for field in fields {
                var value = field.littleEndian
                withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
            }
        }
        return result
    }

    private static func reply(header: VirtioGPUCtrlHeader, type: UInt32) -> Data {
        VirtioGPUCtrlHeader(type: type, flags: header.flags & 3,
                           fenceID: header.fenceID, ctxID: header.ctxID, ringIdx: header.ringIdx).encode()
    }

    public static func selfTest() -> [String: Bool] {
        let request = VirtioGPUCtrlHeader(type: VirtioGPUSpec.cmdGetDisplayInfo, flags: 1, fenceID: 123)
        let display = response(to: request.encode())
        let unsupported = response(to: VirtioGPUCtrlHeader(type: VirtioGPUSpec.cmdResourceCreateBlob).encode())
        let truncated = response(to: Data([0, 1]))
        return [
            "display_response_size": display.count == 408,
            "display_response_type": VirtioGPUCtrlHeader.decode(display)?.type == VirtioGPUSpec.respOkDisplayInfo,
            "fence_preserved": VirtioGPUCtrlHeader.decode(display)?.fenceID == 123,
            "unimplemented_blob_rejected": VirtioGPUCtrlHeader.decode(unsupported)?.type == VirtioGPUSpec.respErrUnspec,
            "truncated_rejected": VirtioGPUCtrlHeader.decode(truncated)?.type == VirtioGPUSpec.respErrInvalidParameter,
            "features_not_overclaimed": VirtioGPUSpec.defaultOptionalFeatures == 0
        ]
    }
}
