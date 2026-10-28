import SwiftUI
import BrainCore

// The calendar-first look, borrowed from the Extra email app: white and airy, big bold date titles,
// a one-sentence summary of the day, pastel pill labels over each section, emoji tiles, a floating
// pill toolbar, and a floating capsule tab bar with a round purple + button.

enum X {
    static let ink = Color(adaptive: (0.067, 0.067, 0.078), dark: (0.96, 0.96, 0.97))
    static let body = Color(adaptive: (0.165, 0.165, 0.192), dark: (0.86, 0.86, 0.89))
    static let muted = Color(adaptive: (0.373, 0.373, 0.420), dark: (0.66, 0.66, 0.71))
    static let line = Color(adaptive: (0.933, 0.925, 0.949), dark: (0.17, 0.17, 0.20))
    static let page = Color(adaptive: (1, 1, 1), dark: (0.055, 0.055, 0.067))
    static let raised = Color(adaptive: (1, 1, 1), dark: (0.11, 0.11, 0.13))
    static let soft = Color(adaptive: (0.949, 0.945, 0.965), dark: (0.15, 0.15, 0.18))
    static let purple = Color(adaptive: (0.482, 0.247, 0.969), dark: (0.62, 0.45, 1.0))
    static let purpleSoft = Color(adaptive: (0.949, 0.933, 0.988), dark: (0.20, 0.16, 0.30))
    static let now = Color(red: 0.898, green: 0.282, blue: 0.302)

    /// The pastel section labels and their tiles.
    enum Tone: CaseIterable {
        case due, today, good, alert, blue, peach
        var fill: Color {
            switch self {
            case .due: return Color(adaptive: (0.929, 0.894, 1.0), dark: (0.24, 0.18, 0.38))
            case .today: return Color(adaptive: (0.867, 0.965, 0.827), dark: (0.13, 0.27, 0.12))
            case .good: return Color(adaptive: (1.0, 0.937, 0.761), dark: (0.32, 0.25, 0.08))
            case .alert: return Color(adaptive: (1.0, 0.906, 0.890), dark: (0.36, 0.13, 0.11))
            case .blue: return Color(adaptive: (0.902, 0.941, 1.0), dark: (0.12, 0.20, 0.34))
            case .peach: return Color(adaptive: (1.0, 0.929, 0.894), dark: (0.34, 0.19, 0.12))
            }
        }
        var tile: Color {
            switch self {
            case .due: return Color(adaptive: (0.953, 0.933, 1.0), dark: (0.19, 0.15, 0.29))
            case .today: return Color(adaptive: (0.933, 0.980, 0.918), dark: (0.11, 0.21, 0.10))
            case .good: return Color(adaptive: (1.0, 0.969, 0.878), dark: (0.26, 0.21, 0.08))
            case .alert: return Color(adaptive: (1.0, 0.953, 0.945), dark: (0.29, 0.11, 0.10))
            case .blue: return Color(adaptive: (0.949, 0.969, 1.0), dark: (0.10, 0.16, 0.27))
            case .peach: return Color(adaptive: (1.0, 0.961, 0.941), dark: (0.27, 0.15, 0.10))
            }
        }
        var text: Color {
            switch self {
            case .due: return Color(adaptive: (0.294, 0.122, 0.722), dark: (0.80, 0.70, 1.0))
            case .today: return Color(adaptive: (0.141, 0.376, 0.059), dark: (0.62, 0.90, 0.55))
            case .good: return Color(adaptive: (0.431, 0.290, 0.0), dark: (1.0, 0.85, 0.50))
            case .alert: return Color(adaptive: (0.627, 0.157, 0.110), dark: (1.0, 0.62, 0.58))
            case .blue: return Color(adaptive: (0.122, 0.310, 0.639), dark: (0.62, 0.76, 1.0))
            case .peach: return Color(adaptive: (0.604, 0.227, 0.063), dark: (1.0, 0.70, 0.55))
            }
        }
    }

    static let titleFont = Font.system(size: 44, weight: .heavy).width(.standard)
    static let phoneTitleFont = Font.system(size: 34, weight: .heavy)
}

// MARK: - Pieces

/// "Due soon", "Happening today", "Good to know".
struct XLabel: View {
    var text: String
    var tone: X.Tone
    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .bold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(tone.text)
            .background(tone.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The emoji square at the start of every feed line.
struct XTile: View {
    var emoji: String
    var tone: X.Tone
    var size: CGFloat = 40
    var body: some View {
        Text(emoji)
            .font(.system(size: size * 0.52))
            .frame(width: size, height: size)
            .background(tone.tile, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct XChip: View {
    var text: String
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selected ? X.page : X.ink)
                .background(selected ? AnyShapeStyle(X.ink) : AnyShapeStyle(X.raised), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : X.line, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Underlined inline action, like Extra's "Book it" / "RSVP now".
struct XInlineAction: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold)).underline(true, pattern: .solid).foregroundStyle(X.ink)
        }
        .buttonStyle(.plain)
    }
}

struct XCardBackground: ViewModifier {
    var padding: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(X.raised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(X.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 15, y: 8)
    }
}

extension View {
    func xCard(padding: CGFloat = 20) -> some View { modifier(XCardBackground(padding: padding)) }
}

/// Search · filter · account, floating at the top right.
struct XToolbarPill: View {
    var onSearch: () -> Void
    var onSettings: () -> Void
    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSearch) { Image(systemName: "magnifyingglass").frame(width: 38, height: 38) }
                .accessibilityLabel("Search")
            Button(action: onSettings) { Image(systemName: "line.3.horizontal.decrease").frame(width: 38, height: 38) }
                .accessibilityLabel("Settings")
            Button(action: onSettings) {
                Text("A").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LinearGradient(colors: [X.purple, Color(red: 1, green: 0.54, blue: 0.36)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            }
            .accessibilityLabel("Account and settings")
        }
        .buttonStyle(.plain)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(X.ink)
        .padding(4)
        .background(X.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(X.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 9, y: 4)
    }
}

/// The glowing "Add or ask anything" bar. Understands quick add ("chem lab due thu ~90m") and logging
/// ("worked 45 min on the essay"), same as everywhere else in Blob.
struct XAskBar: View {
    @EnvironmentObject var store: BrainStore
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(X.purple)
            TextField("Add or log anything — “chem lab due thu ~90m”, “worked 30 min on stats”", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .focused($focused)
                .onSubmit(commit)
            if !text.isEmpty {
                Button(action: commit) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(X.purple) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(X.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(X.line, lineWidth: 1))
        .shadow(color: X.purple.opacity(focused ? 0.28 : 0.16), radius: 16, y: 6)
        .shadow(color: Color(red: 1, green: 0.47, blue: 0.35).opacity(0.10), radius: 10, y: 2)
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if store.logPreview(t) != nil { _ = store.applyLog(t) } else { store.add(store.parse(t)) }
        text = ""
    }
}

// MARK: - Floating tab bar

enum XTab: String, CaseIterable, Identifiable {
    case today, calendar, tasks, focus, activity
    var id: String { rawValue }
    var emoji: String {
        switch self {
        case .today: return "🗓️"
        case .calendar: return "📆"
        case .tasks: return "📚"
        case .focus: return "🍅"
        case .activity: return "📈"
        }
    }
    var title: String {
        switch self {
        case .today: return "Today"
        case .calendar: return "Calendar"
        case .tasks: return "Assignments"
        case .focus: return "Focus"
        case .activity: return "Activity"
        }
    }
    var shortTitle: String { self == .tasks ? "Tasks" : title }
    /// The iPhone has room for four; Activity lives under Assignments there.
    static var visible: [XTab] {
        #if os(iOS)
        return [.today, .calendar, .tasks, .focus]
        #else
        return allCases
        #endif
    }
}

struct XTabBar: View {
    @Binding var tab: XTab
    var onAdd: () -> Void
    @ObservedObject private var pomodoro = Pomodoro.shared

    var body: some View {
        HStack(spacing: compact ? 0 : 4) {
            ForEach(XTab.visible) { t in
                Button { withAnimation(.spring(duration: 0.3)) { tab = t } } label: {
                    VStack(spacing: 1) {
                        ZStack(alignment: .topTrailing) {
                            Text(t.emoji).font(.system(size: compact ? 22 : 24))
                            if t == .focus, pomodoro.isRunning {
                                Circle().fill(X.purple).frame(width: 8, height: 8).offset(x: 3, y: -1)
                            }
                        }
                        Text(compact ? t.shortTitle : t.title)
                            .font(.system(size: compact ? 11 : 13, weight: tab == t ? .bold : .semibold))
                            .foregroundStyle(tab == t ? X.ink : X.muted)
                    }
                    .padding(.horizontal, compact ? 9 : 16).padding(.vertical, 5)
                    .background(tab == t ? X.purpleSoft : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(tab == t ? .isSelected : [])
                if compact { Spacer(minLength: 0) }
            }
            Button(action: onAdd) {
                Image(systemName: "plus").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(X.purple, in: Circle())
                    .shadow(color: X.purple.opacity(0.35), radius: 9, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add")
            .padding(.leading, compact ? 0 : 4)
        }
        .padding(.leading, compact ? 10 : 14).padding(.trailing, 7).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .background(X.raised.opacity(0.75), in: Capsule())
        .overlay(Capsule().strokeBorder(X.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 20, y: 10)
    }

    private var compact: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
}

// MARK: - Shared formatting

extension Date {
    /// "Tue 27"
    var xDayTitle: String { formatted(.dateTime.weekday(.abbreviated)) + " " + formatted(.dateTime.day()) }
    var xTime: String {
        let c = Calendar.current.dateComponents([.minute], from: self)
        return formatted(date: .omitted, time: .shortened).replacingOccurrences(of: c.minute == 0 ? ":00" : "\u{0}", with: "")
    }
}

/// Bold the **marked** parts of a sentence (and make them full-strength ink).
func xRich(_ s: String, size: CGFloat = 17) -> AttributedString {
    var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    for run in a.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
        a[run.range].font = .system(size: size, weight: .bold)
        a[run.range].foregroundColor = X.ink
    }
    return a
}
