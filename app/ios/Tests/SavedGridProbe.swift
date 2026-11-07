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

    static func png(_ fixture: Fixture) -> Data {
        let size = NSSize(width: 1206, height: 2622)
        let picture = NSImage(size: size)
        picture.lockFocus()
        let background = fixture.dark ? NSColor(white: 0.08, alpha: 1) : .white
        background.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let foreground = fixture.dark ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.28, alpha: 1)
        let y = size.height * (1 - fixture.fromTop)
        let font = NSFont.systemFont(ofSize: fixture.font)
        NSAttributedString(string: fixture.text, attributes: [.font: font, .foregroundColor: foreground])
            .draw(at: NSPoint(x: 96, y: y))
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
            let image = png(fixture)
            let hit = image.withUnsafeBytes { ssIsSavedGrid($0.bindMemory(to: UInt8.self).baseAddress!, image.count) == 1 }
            guard hit == fixture.expected else {
                FileHandle.standardError.write(Data("Unexpected screen classification for \(fixture.name)\n".utf8))
                exit(1)
            }
        }
        print("Vision passed \(fixtures.count) synthetic grid checks.")
    }
}
