import SwiftUI
import BrainCore

/// Today: everything for the day in one place — what's due, what's happening, what's coming —
/// plus (on the Mac) the focus timer, the day's schedule and the month.
struct TodayX: View {
    @EnvironmentObject var store: BrainStore
    @Binding var tab: XTab
    var openSettings: () -> Void
    var openSearch: () -> Void

    @State private var day = Date()
    @State private var filter: FeedFilter = .everything
    @State private var openTask: IDBox?
    @State private var editEvent: BrainEvent?
    @ObservedObject private var pomodoro = Pomodoro.shared

    private var feed: DayFeed { DayFeed(store: store, day: day) }

    /// Type and spacing for the window's width: two columns when there's room, one column (smaller type)
    /// in a medium window, phone sizes when narrow — and a smooth step within each, so text never gets crammed.
    struct Metrics {
        enum Layout { case twoColumn, oneColumn, phone }
        var layout: Layout
        var title: CGFloat, summary: CGFloat, row: CGFloat, meta: CGFloat, tile: CGFloat, label: CGFloat
        var gap: CGFloat, padH: CGFloat, side: CGFloat

        init(width w: CGFloat) {
            if w >= 1180 {
                let k = min(1, max(0, (w - 1180) / 320))
                layout = .twoColumn
                title = 36 + 8 * k; summary = 18 + 4 * k; row = 15 + 2 * k; meta = 13 + k; tile = 34 + 6 * k; label = 14 + k
                gap = 18 + 4 * k; padH = 32 + 8 * k; side = 320 + 60 * k
            } else if w >= 700 {
                layout = .oneColumn
                title = 34; summary = 17; row = 15; meta = 13; tile = 34; label = 14; gap = 16; padH = 28; side = 0
            } else {
                layout = .phone
                title = 32; summary = 16; row = 15; meta = 13; tile = 34; label = 13; gap = 14; padH = 20; side = 0
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let m = Metrics(width: geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: m.gap) {
                    header(m)
                    if m.layout == .oneColumn { XAskBar() }
                    Text(xRich(feed.summary, size: m.summary))
                        .font(.system(size: m.summary, weight: .medium))
                        .lineSpacing(m.summary * 0.22)
                        .foregroundStyle(X.body)
                        .frame(maxWidth: 900, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    chips
                    if m.layout != .twoColumn, pomodoro.isActive { FocusStrip { tab = .focus } }
                    if m.layout == .twoColumn {
                        HStack(alignment: .top, spacing: m.padH) {
                            sections(m).frame(maxWidth: .infinity, alignment: .leading)
                            VStack(spacing: 18) {
                                FocusCard { tab = .focus }
                                ScheduleCard(day: day)
                                MiniMonth(selected: $day)
                            }
                            .frame(width: m.side)
                        }
                    } else {
                        sections(m)
                    }
                }
                .padding(.horizontal, m.padH)
                .padding(.top, m.layout == .twoColumn ? 26 : 16)
                .padding(.bottom, 130)
                .frame(maxWidth: 1360)
                .frame(maxWidth: .infinity)
            }
        }
        .background(X.page.ignoresSafeArea())
        .sheet(item: $openTask) { AssignmentDetail(taskID: $0.id).environmentObject(store) }
        .sheet(item: $editEvent) { EventEditor(event: $0).environmentObject(store) }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ m: Metrics) -> some View {
        let wide = m.layout == .twoColumn
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(day.xDayTitle).font(.system(size: m.title, weight: .heavy)).tracking(-m.title * 0.026).foregroundStyle(X.ink)
                    .lineLimit(1).fixedSize()
                if m.layout != .phone {
                    Text(day.formatted(.dateTime.month(.wide)) + " · Week \(Calendar.current.component(.weekOfYear, from: day))")
                        .font(.system(size: m.meta + 2, weight: .medium)).foregroundStyle(X.muted).lineLimit(1)
                }
                if !Calendar.current.isDateInToday(day) {
                    Button("Today") { withAnimation { day = Date() } }
                        .font(.system(size: 13, weight: .bold)).buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(X.purpleSoft, in: Capsule()).foregroundStyle(X.purple)
                }
            }
            Spacer(minLength: 12)
            if wide { XAskBar().frame(minWidth: 260, maxWidth: 480) }
            XToolbarPill(onSearch: openSearch, onSettings: openSettings)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                XChip(text: "Everything", selected: filter == .everything) { filter = .everything }
                ForEach(feed.categories, id: \.self) { c in
                    XChip(text: chipLabel(c), selected: filter == .category(c)) { filter = .category(c) }
                }
                XChip(text: "✅ To-dos", selected: filter == .todos) { filter = .todos }
            }
        }
    }

    private func chipLabel(_ c: String) -> String {
        switch c.lowercased() {
        case "school": return "📚 School"
        case "family": return "🏠 Family"
        case "sports", "fitness": return "🤺 Sports"
        case "personal": return "🙂 Personal"
        default: return c
        }
    }

    // MARK: Feed

    @ViewBuilder
    private func sections(_ m: Metrics) -> some View {
        let list = feed.sections(filter: filter)
        VStack(alignment: .leading, spacing: m.gap + 4) {
            if list.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    XLabel(text: "All clear", tone: .today)
                    Text("Nothing here. Add something with the **+** button, or type it above.").foregroundStyle(X.muted)
                }
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Rectangle().fill(X.line).frame(height: 1) }
                VStack(alignment: .leading, spacing: m.gap - 2) {
                    XLabel(text: s.title, tone: s.tone, size: m.label)
                    ForEach(s.items) { item in row(item, m) }
                }
            }
        }
    }

    private func row(_ item: FeedItem, _ m: Metrics) -> some View {
        HStack(alignment: .top, spacing: 12) {
            XTile(emoji: item.emoji, tone: item.tone, size: m.tile)
            VStack(alignment: .leading, spacing: 4) {
                Text(xRich(item.sentence, size: m.row)).font(.system(size: m.row)).foregroundStyle(X.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                // Details and actions on one line when they fit, stacked when they don't.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        if !item.meta.isEmpty { Text(item.meta).font(.system(size: m.meta)).foregroundStyle(X.muted).lineLimit(1).fixedSize() }
                        HStack(spacing: 12) { actions(item) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if !item.meta.isEmpty { Text(item.meta).font(.system(size: m.meta)).foregroundStyle(X.muted).lineLimit(1) }
                        HStack(spacing: 12) { actions(item) }
                    }
                }
                .environment(\.xActionSize, m.meta + 1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
    }

    @ViewBuilder
    private func actions(_ item: FeedItem) -> some View {
        switch item.kind {
        case .task(let id):
            if let t = store.task(id) {
                XInlineAction(title: "Focus") { Pomodoro.shared.focus(on: t); tab = .focus }
                XInlineAction(title: "Log") { store.logSheetTask = IDBox(id: t.id) }
                XInlineAction(title: "Done") { var c = t; store.markDone(&c); store.upsert(c) }
            }
        case .focusBlock(let id):
            if let t = id.flatMap({ store.task($0) }) { XInlineAction(title: "Start") { Pomodoro.shared.focus(on: t); tab = .focus } }
        case .event(_, let eventID):
            if let e = eventID.flatMap({ store.event($0) }) { XInlineAction(title: "Edit") { editEvent = e } }
        case .routine: XInlineAction(title: "Open") { tab = .routines }
        case .note: EmptyView()
        }
    }

    private func open(_ item: FeedItem) {
        switch item.kind {
        case .task(let id): openTask = IDBox(id: id)
        case .event(_, let eventID): editEvent = eventID.flatMap { store.event($0) }
        case .focusBlock(let id): if let id { openTask = IDBox(id: id) }
        case .routine: tab = .routines
        case .note: break
        }
    }
}

// MARK: - Mac side column

/// The day as a short timeline: events, planned focus blocks, and due times.
struct ScheduleCard: View {
    @EnvironmentObject var store: BrainStore
    var day: Date

    private struct Line: Identifiable { var id: String; var time: Date; var title: String; var detail: String; var tone: X.Tone; var dashed: Bool }

    private var lines: [Line] {
        let start = Calendar.current.startOfDay(for: day), end = start.addingTimeInterval(86_400)
        var out: [Line] = store.occurrences(in: DateInterval(start: start, end: end)).filter { !$0.isAllDay }.map { o in
            let cat = DayFeed.category(for: o)
            return Line(id: o.id, time: o.start, title: o.title,
                        detail: "\(o.start.formatted(date: .omitted, time: .shortened)) – \(o.end.formatted(date: .omitted, time: .shortened))" + (o.location.map { " · \($0.components(separatedBy: ",").first ?? $0)" } ?? ""),
                        tone: cat == "Family" ? .peach : cat == "Sports" || cat == "Fitness" ? .today : .blue, dashed: false)
        }
        if Calendar.current.isDateInToday(day), let plan = store.todayPlan {
            out += plan.blocks.filter { $0.kind == .task && !store.isBlockDone($0) }.map {
                Line(id: "b\($0.id)", time: $0.start, title: "🍅 " + $0.title, detail: "Focus · \($0.minutes) min", tone: .due, dashed: true)
            }
        }
        out += store.pendingTasks.filter { $0.due.map { $0 >= start && $0 < end } ?? false }.map {
            Line(id: "d\($0.id)", time: $0.due!, title: DayFeed.emoji(task: $0) + " " + $0.title + " due", detail: $0.course ?? "Assignment", tone: .alert, dashed: false)
        }
        return out.sorted { $0.time < $1.time }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Schedule").font(.system(size: 17, weight: .bold))
                Spacer()
                if Calendar.current.isDateInToday(day) {
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text("Now " + Date().formatted(date: .omitted, time: .shortened)).font(.system(size: 13, weight: .semibold)).foregroundStyle(X.muted)
                    }
                }
            }
            if lines.isEmpty { Text("Nothing scheduled.").font(.system(size: 14)).foregroundStyle(X.muted) }
            ForEach(lines) { l in
                HStack(alignment: .top, spacing: 10) {
                    Text(l.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 12, weight: .semibold)).foregroundStyle(X.muted)
                        .frame(width: 60, alignment: .leading).padding(.top, 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.title).font(.system(size: 14, weight: .bold)).foregroundStyle(X.ink).lineLimit(1)
                        Text(l.detail).font(.system(size: 13)).foregroundStyle(l.tone.text).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(l.tone.fill.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        if l.dashed { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(X.purple.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                    }
                }
            }
        }
        .xCard()
    }
}

/// A small month; tap a day to see it in Today.
struct MiniMonth: View {
    @EnvironmentObject var store: BrainStore
    @Binding var selected: Date
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start

    var body: some View {
        let cal = Calendar.current
        let first = month
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let days = (0..<42).map { cal.date(byAdding: .day, value: $0 - lead, to: first)! }
        let rows = days.chunked(7).filter { $0.contains { cal.isDate($0, equalTo: first, toGranularity: .month) } }
        let dueDays = Set(store.pendingTasks.compactMap { $0.due.map { cal.startOfDay(for: $0) } })
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(first.formatted(.dateTime.month(.wide))).font(.system(size: 17, weight: .bold))
                Spacer()
                Button { month = cal.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month")
                Button { month = cal.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain).foregroundStyle(X.ink)
            Grid(horizontalSpacing: 4, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<7, id: \.self) { i in
                        Text(cal.veryShortWeekdaySymbols[(i + cal.firstWeekday - 1) % 7]).font(.system(size: 12, weight: .bold)).foregroundStyle(X.muted)
                    }
                }
                ForEach(rows, id: \.first) { week in
                    GridRow {
                        ForEach(week, id: \.self) { d in
                            let inMonth = cal.isDate(d, equalTo: first, toGranularity: .month)
                            let isSel = cal.isDate(d, inSameDayAs: selected)
                            Button { withAnimation { selected = d } } label: {
                                VStack(spacing: 2) {
                                    Text("\(cal.component(.day, from: d))")
                                        .font(.system(size: 13, weight: isSel || cal.isDateInToday(d) ? .bold : .regular))
                                        .foregroundStyle(isSel ? X.page : (inMonth ? X.ink : X.muted.opacity(0.5)))
                                        .frame(width: 28, height: 28)
                                        .background(isSel ? X.ink : (cal.isDateInToday(d) ? X.purpleSoft : .clear), in: Circle())
                                    Circle().fill(dueDays.contains(cal.startOfDay(for: d)) ? X.purple : .clear).frame(width: 5, height: 5)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .xCard(padding: 18)
    }
}

extension Array {
    func chunked(_ n: Int) -> [[Element]] { stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) } }
}
