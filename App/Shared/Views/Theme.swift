import SwiftUI
import BrainCore

// Blob's look (borrowed from the Extra email app): white and airy, black type, cards with a thin line and a soft
// shadow, one accent (purple by default) for the main action, and pastel tints for labels. The calendar-first
// screens use the X tokens; these Brand pieces are the same look for the older screens.

// MARK: - Accent

enum AccentChoice: String, CaseIterable, Identifiable {
    case cyan, blue, violet, pink, red, orange, gold, green
    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var rgb: (Double, Double, Double) {
        switch self {
        case .cyan: return (34, 211, 238)
        case .blue: return (59, 130, 246)
        case .violet: return (123, 63, 247)
        case .pink: return (236, 72, 153)
        case .red: return (239, 68, 68)
        case .orange: return (249, 115, 22)
        case .gold: return (234, 179, 8)
        case .green: return (34, 197, 94)
        }
    }
    var color: Color { Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255) }

    static var current: AccentChoice {
        AccentChoice(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .violet
    }
}

enum Brand {
    /// The one accent: washes, rings, glows, dots. Never used for text — use `accentText`.
    static var accent: Color { AccentChoice.current.color }
    /// Accent-colored text: deepened toward black (light) or lifted toward white (dark) so it stays readable.
    static var accentText: Color { accent.legible }

    // Kept so older call sites read naturally; both map to the accent now.
    static var violet: Color { accent }
    static var pink: Color { accent }

    /// The fluid brand gradient (Cooky's orb): accent → blue → violet.
    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Fixed meaning colors (never the accent): match, caution, stop.
    static let ok = Color(adaptive: (0.067, 0.353, 0.216), dark: (0.36, 0.84, 0.56))
    static let caution = Color(adaptive: (0.49, 0.235, 0.024), dark: (0.98, 0.70, 0.36))
    static let stop = Color(adaptive: (0.596, 0.125, 0.102), dark: (1.0, 0.48, 0.44))

    /// A stable color per class, so "Chemistry" looks the same everywhere. Cooky's role colors.
    static let palette: [Color] = [
        Color(red: 34 / 255, green: 211 / 255, blue: 238 / 255),   // cyan
        Color(red: 96 / 255, green: 165 / 255, blue: 250 / 255),   // blue
        Color(red: 167 / 255, green: 139 / 255, blue: 250 / 255),  // violet
        Color(red: 242 / 255, green: 201 / 255, blue: 76 / 255),   // gold
        Color(red: 251 / 255, green: 146 / 255, blue: 60 / 255),   // orange
        Color(red: 244 / 255, green: 63 / 255, blue: 133 / 255),   // pink
        Color(red: 45 / 255, green: 212 / 255, blue: 191 / 255),   // teal
        Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255),    // red
    ]

    /// Your classes, in a fixed order, so each one gets its own palette color (set by the store).
    nonisolated(unsafe) static var courseIndex: [String: Int] = [:]

    static func color(for key: String?) -> Color {
        guard let key, !key.isEmpty else { return accent }
        if let i = courseIndex[key.lowercased()] { return palette[i % palette.count] }
        var h: UInt64 = 5381
        for b in key.lowercased().utf8 { h = (h &* 33) &+ UInt64(b) }
        return palette[Int(h % UInt64(palette.count))]
    }

    static func color(for o: EventOccurrence) -> Color {
        if let hex = o.colorHex, let c = Color(hex: hex) { return c }
        return color(for: o.tag ?? o.title)
    }

    // Neutrals (Cooky light / dark).
    // Neutrals — the same clean set as the calendar-first screens (X).
    static let ink = Color(adaptive: (0.067, 0.067, 0.078), dark: (0.96, 0.96, 0.97))
    static let inkStrong = Color(adaptive: (0.04, 0.04, 0.05), dark: (1, 1, 1))
    static let muted = Color(adaptive: (0.373, 0.373, 0.420), dark: (0.66, 0.66, 0.71))
    static let faint = Color(adaptive: (0.42, 0.42, 0.47), dark: (0.58, 0.58, 0.63))
    static let card = Color(adaptive: (1, 1, 1), dark: (0.11, 0.11, 0.13))
    static let paper = Color(adaptive: (1, 1, 1), dark: (0.13, 0.13, 0.15))
    static let surface = Color(adaptive: (0.949, 0.945, 0.965), dark: (0.15, 0.15, 0.18))
    static let hairline = Color(adaptive: (0.933, 0.925, 0.949), dark: (0.17, 0.17, 0.20))
    /// Plain window color.
    static let canvas = Color(adaptive: (1, 1, 1), dark: (0.055, 0.055, 0.067))
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// A color that switches with light and dark mode.
    init(adaptive light: (Double, Double, Double), dark: (Double, Double, Double)) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let d = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = d ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }

    /// The readable text shade of a color: mixed toward black in light mode, toward white in dark mode.
    var legible: Color {
        #if os(macOS)
        let base = NSColor(self)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let d = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = base.usingColorSpace(.sRGB) ?? base
            let k = d ? 0.45 : 0.58
            let t: CGFloat = d ? 1 : 0
            return NSColor(srgbRed: c.redComponent + (t - c.redComponent) * k, green: c.greenComponent + (t - c.greenComponent) * k,
                           blue: c.blueComponent + (t - c.blueComponent) * k, alpha: 1)
        })
        #else
        let base = UIColor(self)
        return Color(uiColor: UIColor { traits in
            let d = traits.userInterfaceStyle == .dark
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getRed(&r, green: &g, blue: &b, alpha: &a)
            let k: CGFloat = d ? 0.45 : 0.58
            let t: CGFloat = d ? 1 : 0
            return UIColor(red: r + (t - r) * k, green: g + (t - g) * k, blue: b + (t - b) * k, alpha: 1)
        })
        #endif
    }
}

// MARK: - The frame

/// The window background: Cooky's cool gradient plus a slowly drifting mesh of the accent, blue, violet and pink.
struct FrameBackground: View {
    var body: some View { Brand.canvas.ignoresSafeArea().allowsHitTesting(false) }
}

// MARK: - Floating cards

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    var bloom = true
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Brand.hairline))
            .shadow(color: .black.opacity(0.05), radius: 14, y: 7)
    }
}

extension View {
    func card(padding: CGFloat = 16, bloom: Bool = true) -> some View { modifier(CardModifier(padding: padding, bloom: bloom)) }

    /// A smaller paper card for rows inside lists.
    func paper(padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline))
    }
}

// MARK: - Tinted glass controls

/// The one control recipe: a wash of the color, a thin inner ring, and a glow when it matters.
struct TintButtonStyle: ButtonStyle {
    enum Kind { case primary, glass, quiet }
    var kind: Kind = .primary
    var color: Color? = nil
    var fullWidth = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        GlassLabel(configuration: configuration, kind: kind, tint: color ?? Brand.accent, fullWidth: fullWidth, compact: compact)
    }

    private struct GlassLabel: View {
        let configuration: Configuration
        let kind: Kind
        let tint: Color
        let fullWidth: Bool
        let compact: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let shape = Capsule()
            configuration.label
                .font((compact ? Font.subheadline : .body).weight(.semibold))
                .foregroundStyle(kind == .primary ? Color.white : Brand.ink)
                .padding(.horizontal, compact ? 12 : 18)
                .padding(.vertical, compact ? 6 : 11)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background {
                    switch kind {
                    case .primary: shape.fill(tint.opacity(configuration.isPressed ? 0.85 : 1))
                    case .glass: shape.fill(hover || configuration.isPressed ? Brand.surface : Brand.card)
                    case .quiet: shape.fill(Brand.surface)
                    }
                }
                .overlay { if kind == .glass { shape.strokeBorder(Brand.hairline, lineWidth: 1) } }
                .shadow(color: kind == .primary ? tint.opacity(0.3) : .clear, radius: 8, y: 4)
                .opacity(enabled ? 1 : 0.5)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                .contentShape(shape)
                .onHover { hover = $0 }
        }
    }
}

/// Old name, same glass look.
typealias GradientButtonStyle = TintButtonStyle

extension ButtonStyle where Self == TintButtonStyle {
    static var tint: TintButtonStyle { TintButtonStyle(kind: .glass) }
    static var tintPrimary: TintButtonStyle { TintButtonStyle(kind: .primary) }
}

/// A small tinted pill: class names, due dates, durations.
struct Chip: View {
    var text: String
    var icon: String?
    var color: Color = Brand.accent

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption2.weight(.bold)) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(color.legible)
        .background(color.opacity(0.13), in: Capsule())
    }
}

/// A selectable chip (glass, deeper when on). The state shows with a check too, never by color alone.
struct ToggleChip: View {
    var text: String
    var icon: String?
    var isOn: Bool
    var color: Color = Brand.accent
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isOn { Image(systemName: "checkmark").font(.caption2.weight(.heavy)) }
                else if let icon { Image(systemName: icon).font(.caption2.weight(.bold)) }
                Text(text).lineLimit(1)
            }
            .font(.subheadline.weight(isOn ? .bold : .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isOn ? Brand.canvas : Brand.ink)
            .background(isOn ? Brand.ink : Brand.card, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? .clear : Brand.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25), value: isOn)
    }
}

/// Glass segmented control: a quiet track, the chosen segment in tinted glass.
struct GlassSegmented<T: Hashable & Identifiable>: View {
    var options: [T]
    @Binding var selection: T
    var label: (T) -> String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { o in
                let on = o == selection
                Button { withAnimation(.spring(duration: 0.3)) { selection = o } } label: {
                    Text(label(o))
                        .font(.subheadline.weight(on ? .bold : .medium))
                        .foregroundStyle(on ? Brand.ink : Brand.muted)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            if on { Capsule().fill(Brand.card).shadow(color: .black.opacity(0.12), radius: 2, y: 1) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Brand.surface, in: Capsule())
    }
}

/// A glass icon tile (icons on cards).
struct Glyph: View {
    var icon: String
    var color: Color = Brand.accent
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(color.legible)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.31, style: .continuous))
    }
}

/// The app mark: a glass tile with the brand gradient and a check — replaces the old Blob character.
struct AppMark: View {
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Brand.gradient)
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: size * 0.7))
            Image(systemName: "checkmark").font(.system(size: size * 0.46, weight: .heavy)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
        }
        .frame(width: size, height: size)

    }
}

// MARK: - Type

/// Cooky's overline label: small, wide-tracked, uppercase.
struct Overline: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(Brand.faint)
    }
}

struct SectionTitle: View {
    var title: String
    var trailing: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold)).tracking(-0.3).foregroundStyle(Brand.inkStrong)
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(Brand.muted) }
        }
    }
}

extension Text {
    /// Tight headline, like Cooky's screen titles.
    func screenTitle() -> some View { font(.system(size: 32, weight: .bold)).tracking(-0.9).foregroundStyle(Brand.inkStrong) }
}

struct EmptyHint: View {
    var icon: String
    var text: String
    var body: some View {
        HStack(spacing: 12) {
            Glyph(icon: icon, size: 32)
            Text(text).foregroundStyle(Brand.muted)
        }
        .padding(.vertical, 6)
    }
}

struct ToastView: View {
    var text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThickMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Brand.accent.opacity(0.45), lineWidth: 1))
            .shadow(color: Brand.accent.opacity(0.3), radius: 14, y: 6)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension Date {
    var shortTime: String { formatted(date: .omitted, time: .shortened) }

    /// "Today 3:00 PM", "Tomorrow", "Fri 11:59 PM", "Oct 31"
    func dueText(includeTime: Bool = true) -> String {
        let cal = Calendar.current
        let time = includeTime ? " " + shortTime : ""
        if cal.isDateInToday(self) { return "Today" + time }
        if cal.isDateInTomorrow(self) { return "Tomorrow" + time }
        if cal.isDateInYesterday(self) { return "Yesterday" + time }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: self)).day ?? 0
        if (0..<7).contains(days) { return formatted(.dateTime.weekday(.abbreviated)) + time }
        return formatted(.dateTime.month(.abbreviated).day()) + time
    }
}

extension View {
    /// Page container: a comfortable reading width on big Mac windows, over the frame.
    func page() -> some View {
        frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
    }
}
