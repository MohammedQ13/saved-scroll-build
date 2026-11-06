import SwiftUI

/// Look: dark, quiet, techy. One cyan accent, monospaced numbers, outlines over fills, few words
/// (glanceable/HUD research: light on dark, heavy type, high contrast, only what matters now; docs/CORE.md).
enum Theme {
    static let bg = Color(red: 0.035, green: 0.043, blue: 0.059)          // near-black, slight blue
    static let panel = Color.white.opacity(0.045)
    static let line = Color.white.opacity(0.10)
    static let text = Color.white.opacity(0.94)
    static let dim = Color.white.opacity(0.52)
    static let accent = Color(red: 0.0, green: 0.86, blue: 1.0)           // cyan
    static let ok = Color(red: 0.27, green: 0.93, blue: 0.56)
    static let warn = Color(red: 1.0, green: 0.76, blue: 0.26)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.42)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func label(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }
}

/// Small status pill: ● LABEL value
struct Chip: View {
    let label: String
    let value: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(Theme.label(10)).foregroundStyle(Theme.dim)
            Text(value).font(Theme.mono(11, .semibold)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }
}

/// Section card with a small caps title.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(Theme.label()).foregroundStyle(Theme.dim).tracking(1.2)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
    }
}

/// Full-width row button: icon, title, optional detail, chevron.
struct RowButton: View {
    let icon: String
    let title: String
    var detail: String = ""
    var tint: Color = Theme.text
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                    if !detail.isEmpty { Text(detail).font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(2) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.dim)
            }
            .padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The one big action: outlined accent capsule.
struct PrimaryButton: View {
    let title: String
    var icon: String = "play.fill"
    var color: Color = Theme.accent
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title.uppercased()).tracking(1.0)
            }
            .font(Theme.mono(14, .bold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }
}

/// Thin progress bar.
struct Bar: View {
    let value: Double   // 0...1
    var color: Color = Theme.accent
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(color).frame(width: max(4, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}
