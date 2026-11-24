import Foundation
import CoreGraphics
import ImageIO
import Vision

// Explicit revision 2 recognizes simplified Chinese on the current host.
// Verified with synthetic Chinese text; this does not validate any Guest screen.
// Do not emit image bytes, input paths, NSError userInfo, or barcode payloads.
func redactPrivateText(_ text: String) -> String {
    let rules: [(String, String)] = [
        (#"/(?:Users|Volumes|home)/[^\s<>\"']+"#, "[private-path]"),
        (#"\b[A-Za-z]:\\[^\r\n<>\"']+"#, "[guest-path]"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email-x]"),
        (#"\b[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\b"#, "[identifier-x]")
    ]
    return rules.reduce(text) { value, rule in
        value.replacingOccurrences(of: rule.0, with: rule.1, options: .regularExpression)
    }
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "screen-x", code: 1)
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width > 0, image.height > 0 else {
        throw NSError(domain: "screen-x", code: 2)
    }
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision2
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    // Vision's documented barcode request supplies normalized bounding boxes.
    // All supported symbologies remain enabled. Never access decoded payloads.
    let privateCodeRequest = VNDetectBarcodesRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    // Barcode detection must succeed before any OCR text can be exported.
    try handler.perform([privateCodeRequest])
    let privateBoxes = (privateCodeRequest.results ?? []).map(\.boundingBox)
    try handler.perform([request])
    var rows = (request.results ?? []).compactMap { item -> [String: Any]? in
        // A recognized string overlapping a code can disclose printed payloads.
        guard !privateBoxes.contains(where: { $0.intersects(item.boundingBox) }) else {
            return nil
        }
        guard let candidate = item.topCandidates(1).first else { return nil }
        return ["text": redactPrivateText(candidate.string),
                "x": item.boundingBox.minX, "y": item.boundingBox.minY,
                "width": item.boundingBox.width, "height": item.boundingBox.height,
                "confidence": candidate.confidence,
                "recognizer": "vision-accurate-cn-revision2",
                "recognizerRevision": request.revision]
    }
    for box in privateBoxes {
        rows.append(["text": "[private-barcode]", "private": true,
                     "x": box.minX, "y": box.minY,
                     "width": box.width, "height": box.height,
                     "confidence": 1.0,
                     "recognizer": "vision-barcode-private-marker"])
    }
    let output = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    print(String(decoding: output, as: UTF8.self))
} catch {
    let detail = error as NSError
    fputs("OCR domain=\(detail.domain) code=\(detail.code)\n", stderr)
    print("[]")
    exit(1)
}
