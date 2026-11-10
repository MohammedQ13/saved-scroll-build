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

    static func png(_ lines: [(String, CGFloat, CGFloat)], font: CGFloat, dark: Bool, bookmark: Bool = false) -> Data {
        let size = NSSize(width: 1206, height: 2622)
        let picture = NSImage(size: size)
        picture.lockFocus()
        let background = dark ? NSColor(white: 0.08, alpha: 1) : .white
        background.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        if bookmark {
            NSColor(srgbRed: 1, green: 0.84, blue: 0.1, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 1080, y: size.height * (1 - 0.72), width: 70, height: 70)).fill()
        }
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
        checkAnchor("Saved with out-of-order dates on tiles", kind: 0, expected: 0.294, lines: [
            ("Search saved posts", 0.30, 0.24), ("Oct 21", 0.14, 0.32),
            ("Sep 28", 0.48, 0.32), ("Oct 5", 0.81, 0.32),
        ])
        checkAnchor("Shadow Saved guard", kind: 3, expected: 0.294,
                    lines: [("Search saved posts", 0.30, 0.24)])
        checkAnchor("Shadow rejects a feed", kind: 3, expected: 0,
                    lines: [("For You", 0.52, 0.22)])
        checkAnchor("For You with an old publication date", kind: 0, expected: 0, lines: [
            ("For You", 0.52, 0.22), ("Sep 28", 0.18, 0.35), ("Search saved posts", 0.32, 0.78),
        ])
        checkAnchor("Video Share", kind: 1, expected: 0.741, lines: [
            ("123.4K", 0.924, 0.543), ("12.3K", 0.924, 0.619), ("34.5K", 0.924, 0.695),
        ])
        checkAnchor("Share counts with merged icon fragments", kind: 1, expected: 0.782, lines: [
            ("YM17.2K", 0.924, 0.584), ("26", 0.924, 0.660), ("•1226", 0.924, 0.812),
        ])
        checkAnchor("One merged count cannot locate Share", kind: 1, expected: 0,
                    lines: [("•1226", 0.924, 0.812)])
        checkAnchor("Photo Share", kind: 1, expected: 0.775, lines: [
            ("2,147", 0.924, 0.577), ("4", 0.924, 0.653), ("789", 0.924, 0.729),
        ])
        checkAnchor("Photo Share with an unread count", kind: 1, expected: 0.786, lines: [
            ("2,147", 0.924, 0.588), ("789", 0.924, 0.740), ("451", 0.924, 0.816),
        ])
        checkAnchor("Video Share with no comments", kind: 1, expected: 0.786, lines: [
            ("71", 0.924, 0.588), ("Add 1st", 0.924, 0.664),
        ])
        checkAnchor("Saved post with only its save count readable", kind: 1, expected: 0.781,
                    lines: [("28", 0.924, 0.735)], bookmark: true)
        checkAnchor("A lone numeral cannot locate Share", kind: 1, expected: 0,
                    lines: [("28", 0.924, 0.735)])
        checkAnchor("Likes and saved bookmark with unread remaining counts", kind: 1, expected: 0.782,
                    lines: [("788—", 0.924, 0.584)], bookmark: true)
        checkAnchor("Lone likes count cannot locate Share", kind: 1, expected: 0,
                    lines: [("788—", 0.924, 0.584)])
        checkAnchor("Saved tabs with merged Sounds and Effects", kind: 0, expected: 0.488, lines: [
            ("Posts 36K", 0.14, 0.437), ("Collections 27", 0.42, 0.437), ("Sounds 1 Effects", 0.78, 0.437),
        ])
        checkAnchor("Saved tabs when only Effects is readable on the right", kind: 0, expected: 0.488, lines: [
            ("Posts 36K", 0.14, 0.437), ("Collections 27", 0.42, 0.437), ("Effects", 0.84, 0.437),
        ])
        checkAnchor("Copy link", kind: 2, expected: 0.784, lines: [
            ("Send to", 0.5, 0.593), ("Copy link", 0.27, 0.827),
        ])
        checkAnchor("Copy link in a merged row", kind: 2, expected: 0.784, lines: [
            ("Send to", 0.5, 0.593), ("Repost  Copy link  WhatsApp", 0.29, 0.827),
        ])
        checkAnchor("Copy without share sheet", kind: 2, expected: 0, lines: [("Copy link", 0.27, 0.827)])
        print("Vision passed \(fixtures.count + 20) synthetic screen checks.")
    }

    static func checkAnchor(_ name: String, kind: Int32, expected: CGFloat, lines: [(String, CGFloat, CGFloat)], bookmark: Bool = false) {
        let image = png(lines, font: 34, dark: false, bookmark: bookmark)
        let result = image.withUnsafeBytes { ssScreenAnchor($0.bindMemory(to: UInt8.self).baseAddress!, image.count, kind) }
        guard abs(CGFloat(result) / 65535 - expected) < 0.015 else {
            FileHandle.standardError.write(Data("Unexpected anchor for \(name): \(result)\n".utf8))
            exit(1)
        }
    }
}
