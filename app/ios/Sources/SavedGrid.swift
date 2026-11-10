import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Coordinates are in the engine's top-left 0...65535 space. Zero means there
/// is no verified anchor. The frame and its text stay on the phone.
@_cdecl("ss_screen_anchor")
func ssScreenAnchor(_ bytes: UnsafePointer<UInt8>, _ count: Int, _ kind: Int32) -> Int32 {
    // Kind 3 is the same guard as kind 0, with shadow-only capture for the
    // pre-tap frame. It never changes the anchor or decides arrival.
    let screenKind: Int32 = kind == 3 ? 0 : kind
    let regions = [
        CGRect(x: 0, y: 0.53, width: 1, height: 0.37),      // Saved tabs or pinned search
        CGRect(x: 0.86, y: 0.16, width: 0.14, height: 0.40), // Post's vertical action rail
        CGRect(x: 0, y: 0.11, width: 1, height: 0.36),      // Share sheet
    ]
    guard regions.indices.contains(Int(screenKind)) else { return 0 }
    let region = regions[Int(screenKind)]
    let data = Data(bytes: bytes, count: count)
    for level in [VNRequestTextRecognitionLevel.fast, .accurate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.regionOfInterest = region
        request.minimumTextHeight = 0.006
        let handler = VNImageRequestHandler(data: data, options: [:])
        do { try handler.perform([request]) } catch { return 0 }
        func label(_ text: String, _ box: CGRect) -> ScreenLabel {
            ScreenLabel(text: text.lowercased().trimmingCharacters(in: .whitespaces),
                        x: region.minX + box.midX * region.width, y: 1 - region.minY - box.midY * region.height)
        }
        let phrases = screenKind == 0 ? ["search saved posts", "posts ", "collections", "sounds", "effects"] :
                      screenKind == 2 ? ["send to", "copy link"] : []
        let labels = (request.results ?? []).flatMap { result -> [ScreenLabel] in
            guard let candidate = result.topCandidates(1).first else { return [] }
            let pieces = phrases.compactMap { phrase -> ScreenLabel? in
                guard let range = candidate.string.range(of: phrase, options: .caseInsensitive),
                      let box = try? candidate.boundingBox(for: range) else { return nil }
                return label(phrase, box.boundingBox)
            }
            return [label(candidate.string, result.boundingBox)] + pieces
        }
        let anchor = screenKind == 0 ? gridAnchor(labels) : screenKind == 1 ? shareAnchor(labels, image: data) : copyAnchor(labels)
        if let anchor, (0..<1).contains(anchor) {
            #if os(iOS)
            if kind == 3 { recordViewportShadow(data, anchor: anchor) }
            #endif
            return Int32(anchor * 65535)
        }
    }
    #if os(iOS)
    ssLog.notice("screen anchor \(kind): no matching layout")
    #endif
    return 0
}

#if os(iOS)
/// Coarse pixels stay on the phone and are only for offline shadow analysis.
/// An exact visual match is not a position witness, especially after a re-save.
private func recordViewportShadow(_ image: Data, anchor: CGFloat) {
    guard let source = CGImageSourceCreateWithData(image as CFData, nil),
          let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
    let bounds = CGRect(x: CGFloat(frame.width) * 0.02, y: CGFloat(frame.height) * 0.27,
                        width: CGFloat(frame.width) * 0.96, height: CGFloat(frame.height) * 0.61).integral
    guard let grid = frame.cropping(to: bounds),
          let context = CGContext(data: nil, width: 48, height: 64, bitsPerComponent: 8,
                                  bytesPerRow: 48 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    context.interpolationQuality = .medium
    context.draw(grid, in: CGRect(x: 0, y: 0, width: 48, height: 64))
    guard let pixels = context.data else { return }
    let record: [String: Any] = ["version": 1, "at": Date().timeIntervalSince1970 * 1000,
                                 "anchor": Double(anchor), "width": 48, "height": 64,
                                 "rgba": Data(bytes: pixels, count: 48 * 64 * 4).base64EncodedString()]
    guard let json = try? JSONSerialization.data(withJSONObject: record),
          let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let url = directory.appendingPathComponent("ss-viewport-shadow.jsonl")
    do {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        var line = json
        line.append(10)
        try file.write(contentsOf: line)
    } catch {
        ssLog.notice("viewport shadow write failed")
    }
}
#endif

@_cdecl("ss_screen_capture_failed")
func ssScreenCaptureFailed(_ kind: Int32, _ timedOut: Int32) {
    #if os(iOS)
    ssLog.notice("screen anchor \(kind): capture \(timedOut == 1 ? "timed out" : "failed")")
    #endif
}

@_cdecl("ss_macro_retry_event")
func ssMacroRetryEvent(_ stage: Int32) {
    #if os(iOS)
    ssLog.notice("tile retry stage \(stage)")
    #endif
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
    // At the top, search is an icon. Require three Saved subtabs in order
    // on the same line before treating the content below them as a tile.
    guard let posts = labels.first(where: { $0.x < 0.24 && (0.15...0.46).contains($0.y) && ($0.text == "posts" || $0.text.hasPrefix("posts ")) }),
          labels.contains(where: { (0.26...0.54).contains($0.x) && $0.text.hasPrefix("collections") && abs($0.y - posts.y) < 0.012 }),
          labels.contains(where: {
              let rightEdge: CGFloat = $0.text.contains("effe") ? 0.82 : 0.76
              let sounds = (0.55...rightEdge).contains($0.x) && $0.text.hasPrefix("sounds")
              let effects = (0.71...0.94).contains($0.x) && $0.text.hasPrefix("effects")
              return (sounds || effects) && abs($0.y - posts.y) < 0.012
          })
    else { return nil }
    return posts.y + 0.051
}

private func shareAnchor(_ labels: [ScreenLabel], image: Data) -> CGFloat? {
    // Likes, comments, saves and shares form a regularly spaced rail. Allow
    // one unread count, such as a single digit over a busy photo background.
    let onRail = labels.filter { (0.89...0.96).contains($0.x) }
    let counts = onRail.filter {
        // OCR can merge a short icon fragment or bullet with a count. The
        // rail's spacing still has to corroborate three separate positions.
        $0.text.range(of: #"^[^\d]{0,3}\d[\d., ]*[kmb]?\s*[-–—]?$"#, options: .regularExpression) != nil
    }.map(\.y)
    let emptyComments = onRail.first { $0.text == "add 1st" }?.y
    let rail: [CGFloat] = [0, 0.076, 0.152, 0.228]
    if let emptyComments {
        let start = emptyComments - rail[1]
        if (0.50...0.61).contains(start) && counts.contains(where: { center in
            [rail[0], rail[2], rail[3]].contains { abs(center - (start + $0)) < 0.010 }
        }) {
            return start + 0.198
        }
    }
    var best: (score: CGFloat, start: CGFloat)?
    for center in counts {
        for offset in rail {
            let start = center - offset
            guard (0.50...0.61).contains(start) else { continue }
            let errors = rail.compactMap { slot in counts.map { abs($0 - (start + slot)) }.min() }
                .filter { $0 < 0.010 }
            guard errors.count >= 3 else { continue }
            let score = CGFloat(errors.count) - errors.reduce(0, +)
            if score > (best?.score ?? 0) {
                best = (score, start)
            }
        }
    }
    if let best { return best.start + 0.198 }
    // A bright background can merge a trailing dash into the likes count and
    // hide the other counts. Only accept that lone reading when the saved
    // bookmark independently appears at the expected third rail position.
    if let likes = onRail.first(where: {
        (0.50...0.61).contains($0.y) &&
        $0.text.range(of: #"^\d[\d., ]*[kmb]?\s*[-–—]?$"#, options: .regularExpression) != nil &&
        hasSavedBookmark(image, above: $0.y + 0.152)
    }) {
        return likes.y + 0.198
    }
    // A saved post has a yellow bookmark directly above its save count.
    // Use that independent cue when white action counts blend into the post.
    // The macro still verifies the Share sheet before any Copy link tap.
    return counts.first { (0.652...0.762).contains($0) && hasSavedBookmark(image, above: $0) }
        .map { $0 + 0.046 }
}

private func hasSavedBookmark(_ image: Data, above count: CGFloat) -> Bool {
    let width = 150, height = 326
    guard let source = CGImageSourceCreateWithData(image as CFData, nil),
          let frame = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    context.draw(frame, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
    let center = Int(0.925 * CGFloat(width))
    let first = Int((count - 0.048) * CGFloat(height))
    let last = Int((count - 0.013) * CGFloat(height))
    var matchingRows = 0
    for y in first...last {
        let yellow = ((center - 5)...(center + 5)).filter { x in
            let i = (y * width + x) * 4
            return pixels[i] >= 200 && pixels[i + 1] >= 165 && pixels[i + 2] <= 85
        }
        if (5...10).contains(yellow.count) && yellow.contains(center) { matchingRows += 1 }
    }
    return matchingRows >= 6
}

private func copyAnchor(_ labels: [ScreenLabel]) -> CGFloat? {
    guard let title = labels.first(where: { (0.4...0.6).contains($0.x) && (0.52...0.72).contains($0.y) && $0.text == "send to" }),
          let copy = labels.first(where: {
              (0.21...0.33).contains($0.x) && (0.15...0.28).contains($0.y - title.y) && $0.text == "copy link"
          })
    else { return nil }
    return copy.y - 0.043
}
