import Foundation
import CoreGraphics
import ImageIO
import Vision

// Decode locally before Vision. No image bytes, paths, or error userInfo are emitted.
// The fast recognizer supports Latin-language text. The current accurate revision
// can fail in the image-reader backend even for a valid synthetic RGB PNG.
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
    request.recognitionLevel = .fast
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    let rows = (request.results ?? []).compactMap { item -> [String: Any]? in
        guard let candidate = item.topCandidates(1).first else { return nil }
        return ["text": candidate.string,
                "x": item.boundingBox.minX, "y": item.boundingBox.minY,
                "width": item.boundingBox.width, "height": item.boundingBox.height,
                "confidence": candidate.confidence,
                "recognizer": "vision-fast-latin"]
    }
    let output = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    print(String(decoding: output, as: UTF8.self))
} catch {
    let detail = error as NSError
    fputs("OCR domain=\(detail.domain) code=\(detail.code)\n", stderr)
    print("[]")
    exit(1)
}
