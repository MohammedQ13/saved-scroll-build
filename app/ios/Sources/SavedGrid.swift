import Foundation
import Vision

/// Coordinates are in the engine's top-left 0...65535 space. Zero means there
/// is no verified anchor. The frame and its text stay on the phone.
@_cdecl("ss_screen_anchor")
func ssScreenAnchor(_ bytes: UnsafePointer<UInt8>, _ count: Int, _ kind: Int32) -> Int32 {
    let regions = [
        CGRect(x: 0, y: 0.53, width: 1, height: 0.37),      // Saved tabs or pinned search
        CGRect(x: 0.86, y: 0.16, width: 0.14, height: 0.40), // Post's vertical action rail
        CGRect(x: 0, y: 0.11, width: 1, height: 0.36),      // Share sheet
    ]
    guard regions.indices.contains(Int(kind)) else { return 0 }
    let region = regions[Int(kind)]
    let data = Data(bytes: bytes, count: count)
    for level in [VNRequestTextRecognitionLevel.fast, .accurate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.regionOfInterest = region
        let handler = VNImageRequestHandler(data: data, options: [:])
        do { try handler.perform([request]) } catch { return 0 }
        let labels = (request.results ?? []).compactMap { result -> ScreenLabel? in
            guard let value = result.topCandidates(1).first?.string else { return nil }
            let box = result.boundingBox
            return ScreenLabel(text: value.lowercased().trimmingCharacters(in: .whitespaces),
                               x: region.minX + box.midX * region.width, y: 1 - region.minY - box.midY * region.height)
        }
        let anchor = kind == 0 ? gridAnchor(labels) : kind == 1 ? shareAnchor(labels) : copyAnchor(labels)
        if let anchor, (0..<1).contains(anchor) { return Int32(anchor * 65535) }
    }
    return 0
}

@_cdecl("ss_is_saved_grid")
func ssIsSavedGrid(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
    ssScreenAnchor(bytes, count, 0) > 0 ? 1 : 0
}

private struct ScreenLabel {
    let text: String
    let x: CGFloat
    let y: CGFloat
}

private func gridAnchor(_ labels: [ScreenLabel]) -> CGFloat? {
    // The pinned search field sits immediately above the tiles.
    if let search = labels.first(where: {
        $0.x < 0.55 && (0.12...0.36).contains($0.y) && $0.text.contains("search saved posts")
    }) {
        return search.y + 0.054
    }
    // At the top, search is an icon. Require the three Saved subtabs in order
    // on the same line before treating the content below them as a tile.
    guard let posts = labels.first(where: { $0.x < 0.24 && $0.text.hasPrefix("posts ") }),
          labels.contains(where: { (0.26...0.54).contains($0.x) && $0.text.hasPrefix("collections") && abs($0.y - posts.y) < 0.012 }),
          labels.contains(where: { (0.55...0.76).contains($0.x) && $0.text.hasPrefix("sounds") && abs($0.y - posts.y) < 0.012 })
    else { return nil }
    return posts.y + 0.051
}

private func shareAnchor(_ labels: [ScreenLabel]) -> CGFloat? {
    // Likes, comments and saves form a regularly spaced rail. The Share icon
    // sits below the saves count, at different heights for videos and photos.
    let counts = labels.filter {
        (0.89...0.96).contains($0.x) && $0.text.range(of: #"^\d[\d., ]*[kmb]?$"#, options: .regularExpression) != nil
    }.map(\.y).sorted()
    for index in counts.indices.dropLast(2) {
        let first = counts[index], second = counts[index + 1], third = counts[index + 2]
        let a = second - first, b = third - second
        if (0.07...0.082).contains(a), abs(a - b) < 0.006, (0.47...0.59).contains(first) {
            return third + 0.046
        }
    }
    return nil
}

private func copyAnchor(_ labels: [ScreenLabel]) -> CGFloat? {
    guard let title = labels.first(where: { (0.4...0.6).contains($0.x) && (0.52...0.72).contains($0.y) && $0.text == "send to" }),
          let copy = labels.first(where: {
              (0.21...0.33).contains($0.x) && (0.15...0.28).contains($0.y - title.y) && $0.text == "copy link"
          })
    else { return nil }
    return copy.y - 0.043
}
