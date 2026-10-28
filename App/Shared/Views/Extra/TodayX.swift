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

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 900
            ScrollView {
                VStack(alignment: .leading, spacing: wide ? 22 : 14) {
                    header(wide: wide)
                    Text(xRich(feed.summary, size: wide ? 22 : 17))
                        .font(.system(size: wide ? 22 : 17, weight: .medium))
                        .lineSpacing(wide ? 5 : 3)
                        .foregroundStyle(X.body)
                        .frame(maxWidth: 980, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    chips
                    if !wide, pomodoro.isActive { FocusStrip { tab = .focus } }
                    if wide {
                        HStack(alignment: .top, spacing: 40) {
                            sections.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(spacing: 20) {
                                FocusCard { tab = .focus }
                                ScheduleCard(day: day)
                                MiniMonth(selected: $day)
                            }
                            .frame(width: 380)
                        }
                    } else {
                        sections
                    }
                }
                .padding(.horizontal, wide ? 40 : 20)
                .padding(.top, wide ? 28 : 16)
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
    private func header(wide: Bool) -> some View {
        HStack(alignment: .center, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(day.xDayTitle).font(wide ? X.titleFont : X.phoneTitleFont).tracking(wide ? -1.2 : -0.8).foregroundStyle(X.ink)
                if wide {
                    Text(day.formatted(.dateTime.month(.wide)) + " · Week \(Calendar.current.component(.weekOfYear, from: day))")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(X.muted)
                }
                if !Calendar.current.isDateInToday(day) {
                    Button("Today") { withAnimation { day = Date() } }
                        .font(.system(size: 13, weight: .bold)).buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(X.purpleSoft, in: Capsule()).foregroundStyle(X.purple)
                }
            }
            Spacer(minLength: 12)
            if wide { XAskBar().frame(maxWidth: 520) }
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
    private var sections: some View {
        let list = feed.sections(filter: filter)
        VStack(alignment: .leading, spacing: 24) {
            if list.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    XLabel(text: "All clear", tone: .today)
                    Text("Nothing here. Add something with the **+** button, or type it above.").foregroundStyle(X.muted)
                }
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Rectangle().fill(X.line).frame(height: 1) }
                VStack(alignment: .leading, spacing: 14) {
                    XLabel(text: s.title, tone: s.tone)
                    ForEach(s.items) { item in row(item) }
                }
            }
        }
    }

    private func row(_ item: FeedItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            XTile(emoji: item.emoji, tone: item.tone)
            VStack(alignment: .leading, spacing: 4) {
                Text(xRich(item.sentence)).font(.system(size: 17)).foregroundStyle(X.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    if !item.meta.isEmpty { Text(item.meta).font(.system(size: 14)).foregroundStyle(X.muted).lineLimit(1) }
                    actions(item)
                }
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
        case .note: EmptyView()
        }
    }

    private func open(_ item: FeedItem) {
        switch item.kind {
        case .task(let id): openTask = IDBox(id: id)
        case .event(_, let eventID): editEvent = eventID.flatMap { store.event($0) }
        case .focusBlock(let id): if let id { openTask = IDBox(id: id) }
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
