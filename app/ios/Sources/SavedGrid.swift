import Foundation
import Vision

/// Called on the Rust engine thread with an in-memory developer-service frame.
/// The search label is visible on the observed Saved grid even after scrolling.
@_cdecl("ss_is_saved_grid")
func ssIsSavedGrid(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
    let data = Data(bytes: bytes, count: count)
    let levels: [VNRequestTextRecognitionLevel] = [.fast, .accurate]
    for level in levels {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.regionOfInterest = CGRect(x: 0, y: 0.64, width: 1, height: 0.26)
        let handler = VNImageRequestHandler(data: data, options: [:])
        do { try handler.perform([request]) } catch { return 0 }
        let text = request.results?.compactMap { $0.topCandidates(1).first?.string.lowercased() }.joined(separator: " ") ?? ""
        let words = text.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if words.joined(separator: " ").contains("search saved posts") { return 1 }
    }
    return 0
}
