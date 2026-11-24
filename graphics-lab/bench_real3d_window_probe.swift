// Read-only window inventory and image statistics for owned Wine runs. @DNPMBHC.
// list: prints JSON windows for owner PIDs given as arguments (no titles, no pixels).
// stats <png>: prints JSON luminance statistics of a capture; never re-encodes pixels.
import CoreGraphics
import Foundation
import ImageIO

func emit(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func listWindows(_ pids: Set<Int>) {
    let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    var rows: [[String: Any]] = []
    for item in (info as? [[String: Any]]) ?? [] {
        let pid = (item[kCGWindowOwnerPID as String] as? Int) ?? -1
        if !pids.contains(pid) { continue }
        let bounds = (item[kCGWindowBounds as String] as? [String: Any]) ?? [:]
        rows.append([
            "window_id": (item[kCGWindowNumber as String] as? Int) ?? -1,
            "owner_pid": pid,
            "layer": (item[kCGWindowLayer as String] as? Int) ?? 0,
            "onscreen": (item[kCGWindowIsOnscreen as String] as? Bool) ?? false,
            "alpha": (item[kCGWindowAlpha as String] as? Double) ?? 0,
            "width": (bounds["Width"] as? Double) ?? 0,
            "height": (bounds["Height"] as? Double) ?? 0,
        ])
    }
    emit(["windows": rows])
}

func imageStats(_ path: String) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        emit(["error": "unreadable"]); return
    }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var sum = 0.0, lit = 0, distinct = Set<UInt32>()
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let luma = 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        sum += luma
        if luma > 16 { lit += 1 }
        if distinct.count < 4096 {
            distinct.insert(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
        }
    }
    let count = max(1, width * height)
    emit(["width": width, "height": height, "mean_luma": sum / Double(count),
          "lit_fraction": Double(lit) / Double(count), "distinct_colors_capped_4096": distinct.count])
}

let args = CommandLine.arguments
if args.count >= 2 && args[1] == "list" {
    listWindows(Set(args.dropFirst(2).compactMap { Int($0) }))
} else if args.count == 3 && args[1] == "stats" {
    imageStats(args[2])
} else {
    FileHandle.standardError.write("usage: list <pid>... | stats <png>\n".data(using: .utf8)!)
    exit(2)
}
