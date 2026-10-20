import SwiftUI
import BrainCore

/// One design language for Mac and iPhone: rounded type, soft cards, a violet→pink brand gradient,
/// and a stable color per course so "Chemistry" looks the same everywhere.
enum Brand {
    static let violet = Color(red: 0.47, green: 0.36, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.38, blue: 0.62)
    static let gradient = LinearGradient(colors: [violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let palette: [Color] = [
        Color(red: 0.47, green: 0.36, blue: 1.0),
        Color(red: 0.13, green: 0.62, blue: 0.98),
        Color(red: 0.10, green: 0.74, blue: 0.56),
        Color(red: 1.0, green: 0.62, blue: 0.10),
        Color(red: 1.0, green: 0.38, blue: 0.62),
        Color(red: 0.95, green: 0.30, blue: 0.30),
        Color(red: 0.0, green: 0.70, blue: 0.80),
        Color(red: 0.66, green: 0.44, blue: 0.95),
    ]

    static func color(for key: String?) -> Color {
        guard let key, !key.isEmpty else { return violet }
        var h: UInt64 = 5381
        for b in key.lowercased().utf8 { h = (h &* 33) &+ UInt64(b) }
        return palette[Int(h % UInt64(palette.count))]
    }

    static func color(for o: EventOccurrence) -> Color {
        if let hex = o.colorHex, let c = Color(hex: hex) { return c }
        return color(for: o.tag ?? o.title)
    }

    #if os(macOS)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    #else
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    #endif
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.06)))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

struct Chip: View {
    var text: String
    var icon: String?
    var color: Color = Brand.violet

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption2.weight(.bold)) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Brand.gradient, in: Capsule())
            .shadow(color: Brand.violet.opacity(0.35), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct SectionTitle: View {
    var title: String
    var trailing: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

struct EmptyHint: View {
    var icon: String
    var text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(Brand.gradient)
            Text(text).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct ToastView: View {
    var text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThickMaterial, in: Capsule())
            .shadow(radius: 10, y: 4)
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
    /// Consistent page container: grouped background and a comfortable reading width on big Mac windows.
    func page() -> some View {
        frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .background(Brand.canvas)
    }
}
