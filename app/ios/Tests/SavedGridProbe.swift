import AppKit
import Foundation

/// The public builder exercises Apple's Vision implementation on synthetic
/// frames. The fixture contains no screenshots, accounts, or video thumbnails.
@main
enum SavedGridProbe {
    struct Fixture {
        let name: String
        let text: String
        let fromTop: CGFloat
        let font: CGFloat
        let dark: Bool
        let expected: Bool
    }

    static func png(_ lines: [(String, CGFloat, CGFloat)], font: CGFloat, dark: Bool) -> Data {
        let size = NSSize(width: 1206, height: 2622)
        let picture = NSImage(size: size)
        picture.lockFocus()
        let background = dark ? NSColor(white: 0.08, alpha: 1) : .white
        background.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let foreground = dark ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.28, alpha: 1)
        let face = NSFont.systemFont(ofSize: font)
        for (label, x, fromTop) in lines {
            let text = NSAttributedString(string: label, attributes: [.font: face, .foregroundColor: foreground])
            text.draw(at: NSPoint(x: x * size.width - text.size().width / 2, y: size.height * (1 - fromTop) - text.size().height / 2))
        }
        picture.unlockFocus()
        return NSBitmapImageRep(data: picture.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    static func main() {
        let fixtures = [
            Fixture(name: "saved-light", text: "Search saved posts", fromTop: 0.24, font: 34, dark: false, expected: true),
            Fixture(name: "saved-dark-small", text: "Search saved posts", fromTop: 0.30, font: 28, dark: true, expected: true),
            Fixture(name: "saved-narrow", text: "Search saved posts", fromTop: 0.17, font: 31, dark: false, expected: true),
            Fixture(name: "feed", text: "For You", fromTop: 0.24, font: 44, dark: true, expected: false),
            Fixture(name: "search-field", text: "Search saved posts", fromTop: 0.07, font: 38, dark: false, expected: false),
            Fixture(name: "caption", text: "Search saved posts", fromTop: 0.79, font: 50, dark: true, expected: false),
            Fixture(name: "profile", text: "Search posts", fromTop: 0.24, font: 36, dark: false, expected: false),
        ]
        for fixture in fixtures {
            let image = png([(fixture.text, 0.3, fixture.fromTop)], font: fixture.font, dark: fixture.dark)
            let hit = image.withUnsafeBytes { ssIsSavedGrid($0.bindMemory(to: UInt8.self).baseAddress!, image.count) == 1 }
            guard hit == fixture.expected else {
                FileHandle.standardError.write(Data("Unexpected screen classification for \(fixture.name)\n".utf8))
                exit(1)
            }
        }
        checkAnchor("Saved tabs at top", kind: 0, expected: 0.488, lines: [
            ("Posts 35K", 0.14, 0.437), ("Collections 25", 0.42, 0.437), ("Sounds 1", 0.68, 0.437),
        ])
        checkAnchor("Video Share", kind: 1, expected: 0.741, lines: [
            ("289.1K", 0.924, 0.543), ("11.1K", 0.924, 0.619), ("20.4K", 0.924, 0.695),
        ])
        checkAnchor("Photo Share", kind: 1, expected: 0.775, lines: [
            ("2,551", 0.924, 0.577), ("6", 0.924, 0.653), ("468", 0.924, 0.729),
        ])
        checkAnchor("Copy link", kind: 2, expected: 0.784, lines: [
            ("Send to", 0.5, 0.593), ("Copy link", 0.27, 0.827),
        ])
        checkAnchor("Copy link in a merged row", kind: 2, expected: 0.784, lines: [
            ("Send to", 0.5, 0.593), ("Repost  Copy link  WhatsApp", 0.29, 0.827),
        ])
        checkAnchor("Copy without share sheet", kind: 2, expected: 0, lines: [("Copy link", 0.27, 0.827)])
        print("Vision passed \(fixtures.count + 6) synthetic screen checks.")
    }

    static func checkAnchor(_ name: String, kind: Int32, expected: CGFloat, lines: [(String, CGFloat, CGFloat)]) {
        let image = png(lines, font: 34, dark: false)
        let result = image.withUnsafeBytes { ssScreenAnchor($0.bindMemory(to: UInt8.self).baseAddress!, image.count, kind) }
        guard abs(CGFloat(result) / 65535 - expected) < 0.015 else {
            FileHandle.standardError.write(Data("Unexpected anchor for \(name): \(result)\n".utf8))
            exit(1)
        }
    }
}
