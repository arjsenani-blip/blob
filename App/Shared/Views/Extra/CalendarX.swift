import SwiftUI
import BrainCore

/// The calendar: every calendar you have, your due dates, Blob's focus blocks and the work you logged, in one place.
struct CalendarX: View {
    @EnvironmentObject var store: BrainStore
    var openSettings: () -> Void
    var openSearch: () -> Void

    enum Mode: String, CaseIterable, Identifiable { case day = "Day", week = "Week", month = "Month", agenda = "Agenda"; var id: String { rawValue } }

    @AppStorage("calendarMode") private var modeRaw = ""
    @State private var anchor = Date()
    @State private var hidden: Set<String> = []
    @State private var openTask: IDBox?
    @State private var editEvent: BrainEvent?

    private var cal: Calendar { .current }

    private func mode(wide: Bool) -> Mode { Mode(rawValue: modeRaw) ?? (wide ? .week : .day) }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 760
            let m = mode(wide: wide)
            VStack(alignment: .leading, spacing: wide ? 16 : 12) {
                header(wide: wide, mode: m)
                if wide || m != .day { filterChips }
                Group {
                    switch m {
                    case .day: DayColumnView(day: anchor, wide: wide, hidden: hidden, openTask: { openTask = IDBox(id: $0) }, openEvent: open)
                    case .week: WeekGridView(start: weekStart, hidden: hidden, openTask: { openTask = IDBox(id: $0) }, openEvent: open)
                    case .month: MonthGridView(month: anchor, hidden: hidden) { d in anchor = d; modeRaw = Mode.day.rawValue }
                    case .agenda: AgendaView(start: cal.startOfDay(for: anchor), hidden: hidden, openTask: { openTask = IDBox(id: $0) }, openEvent: open)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, wide ? 40 : 20)
            .padding(.top, wide ? 28 : 16)
            .frame(maxWidth: 1440)
            .frame(maxWidth: .infinity)
        }
        .background(X.page.ignoresSafeArea())
        .sheet(item: $openTask) { AssignmentDetail(taskID: $0.id).environmentObject(store) }
        .sheet(item: $editEvent) { EventEditor(event: $0).environmentObject(store) }
    }

    private var weekStart: Date { cal.dateInterval(of: .weekOfYear, for: anchor)!.start }

    private func open(_ o: EventOccurrence) { if let e = o.eventID.flatMap({ store.event($0) }) { editEvent = e } }

    @ViewBuilder
    private func header(wide: Bool, mode m: Mode) -> some View {
        let title = anchor.formatted(.dateTime.month(.wide))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(wide ? X.titleFont : X.phoneTitleFont).tracking(wide ? -1.2 : -0.8).foregroundStyle(X.ink)
                    if wide { Text(rangeText(m)).font(.system(size: 16, weight: .medium)).foregroundStyle(X.muted) }
                }
                Spacer()
                if wide { modePicker(m) }
                navPill(m)
                if wide { XToolbarPill(onSearch: openSearch, onSettings: openSettings) }
            }
            if !wide {
                HStack {
                    modePicker(m)
                    Spacer()
                }
                if m == .day { WeekStrip(selected: $anchor) }
            }
        }
    }

    private func rangeText(_ m: Mode) -> String {
        switch m {
        case .day: return anchor.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        case .week:
            let s = weekStart, e = cal.date(byAdding: .day, value: 6, to: s)!
            return s.formatted(.dateTime.month(.abbreviated).day()) + " – " + e.formatted(.dateTime.month(.abbreviated).day().year())
        case .month: return anchor.formatted(.dateTime.year())
        case .agenda: return "Next two weeks"
        }
    }

    private func modePicker(_ m: Mode) -> some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases) { x in
                Button { withAnimation(.snappy) { modeRaw = x.rawValue } } label: {
                    Text(x.rawValue).font(.system(size: 14, weight: m == x ? .bold : .semibold))
                        .foregroundStyle(m == x ? X.ink : X.muted)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(m == x ? X.raised : .clear, in: Capsule())
                        .shadow(color: .black.opacity(m == x ? 0.12 : 0), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(X.soft, in: Capsule())
    }

    private func navPill(_ m: Mode) -> some View {
        let unit: Calendar.Component = m == .month ? .month : m == .week ? .weekOfYear : m == .agenda ? .weekOfYear : .day
        return HStack(spacing: 2) {
            Button { anchor = cal.date(byAdding: unit, value: -1, to: anchor)! } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }
                .accessibilityLabel("Previous")
            Button("Today") { anchor = Date() }.font(.system(size: 14, weight: .bold)).padding(.horizontal, 6)
            Button { anchor = cal.date(byAdding: unit, value: 1, to: anchor)! } label: { Image(systemName: "chevron.right").frame(width: 34, height: 34) }
                .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
        .foregroundStyle(X.ink)
        .padding(3)
        .background(X.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(X.line))
    }

    private var filterChips: some View {
        let cats = store.calendarCategories
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(cats, id: \.self) { c in
                    Button { if hidden.contains(c) { hidden.remove(c) } else { hidden.insert(c) } } label: {
                        HStack(spacing: 6) {
                            Circle().fill(CalTone.color(c)).frame(width: 8, height: 8)
                            Text(c).font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(hidden.contains(c) ? X.muted : X.ink)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(X.raised, in: Capsule())
                        .overlay(Capsule().strokeBorder(hidden.contains(c) ? X.line : CalTone.color(c).opacity(0.5)))
                        .opacity(hidden.contains(c) ? 0.6 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - What goes on a day

/// Colors per calendar category.
enum CalTone {
    static func tone(_ category: String) -> X.Tone {
        switch category.lowercased() {
        case "family": return .peach
        case "sports", "fitness": return .today
        case "school": return .blue
        case "assignments": return .alert
        case "focus", "routines": return .due
        case "holidays": return .good
        default: return .due
        }
    }
    static func color(_ category: String) -> Color {
        switch category.lowercased() {
        case "family": return Color(red: 0.90, green: 0.39, blue: 0.18)
        case "sports", "fitness": return Color(red: 0.18, green: 0.62, blue: 0.30)
        case "school": return Color(red: 0.23, green: 0.48, blue: 0.94)
        case "assignments": return Color(red: 0.86, green: 0.27, blue: 0.23)
        case "focus": return X.purple
        case "routines": return Color(red: 0.36, green: 0.42, blue: 0.86)
        case "holidays": return Color(red: 0.94, green: 0.71, blue: 0.16)
        default: return Color(red: 0.55, green: 0.35, blue: 0.95)
        }
    }
}

struct DayBlock: Identifiable {
    enum Kind { case event(EventOccurrence), focus(UUID?), logged(UUID), routine(UUID) }
    var id: String
    var kind: Kind
    var title: String
    var detail: String
    var start: Date
    var end: Date
    var category: String
    var dashed: Bool
}

extension BrainStore {
    /// The calendar categories to filter by: your calendars plus Assignments and Focus.
    var calendarCategories: [String] {
        let now = Date()
        var set = Set(occurrences(in: DateInterval(start: now.addingTimeInterval(-30 * 86_400), duration: 90 * 86_400)).map(DayFeed.category(for:)))
        set.formUnion(["Assignments", "Focus"])
        if !routines.isEmpty { set.insert("Routines") }
        let order = ["School", "Family", "Sports", "Personal", "Assignments", "Focus", "Routines", "Holidays"]
        return set.sorted { (order.firstIndex(of: $0) ?? 7, $0) < (order.firstIndex(of: $1) ?? 7, $1) }
    }

    /// Timed things on a day: events, Blob's planned focus blocks, and logged work.
    func blocks(on day: Date, hidden: Set<String>) -> [DayBlock] {
        let cal = Calendar.current
        let s = cal.startOfDay(for: day), e = cal.date(byAdding: .day, value: 1, to: s)!
        var out: [DayBlock] = occurrences(in: DateInterval(start: s, end: e)).filter { !$0.isAllDay }.compactMap { o in
            let c = DayFeed.category(for: o)
            guard !hidden.contains(c) else { return nil }
            return DayBlock(id: o.id, kind: .event(o), title: o.title,
                            detail: o.start.formatted(date: .omitted, time: .shortened) + " – " + o.end.formatted(date: .omitted, time: .shortened) + (o.location.map { " · " + ($0.components(separatedBy: ",").first ?? $0) } ?? ""),
                            start: max(o.start, s), end: min(o.end, e), category: c, dashed: false)
        }
        if !hidden.contains("Routines") {
            for r in routines(on: day) {
                let t = r.timeline(on: day)
                guard let first = t.first, let last = t.last else { continue }
                out.append(DayBlock(id: "r\(r.id)", kind: .routine(r.id), title: "🌙 " + r.name,
                                    detail: r.steps.map(\.title).joined(separator: " · "),
                                    start: max(first.start, s), end: min(last.end, e), category: "Routines", dashed: false))
            }
        }
        guard !hidden.contains("Focus") else { return out.sorted { $0.start < $1.start } }
        if cal.isDateInToday(day), let plan = todayPlan {
            out += plan.blocks.filter { $0.kind == .task && !isBlockDone($0) }.map {
                DayBlock(id: "b\($0.id)", kind: .focus($0.taskID), title: "🍅 " + $0.title, detail: "Focus · \($0.minutes) min",
                         start: $0.start, end: $0.end, category: "Focus", dashed: true)
            }
        }
        for t in tasks {
            for w in t.sessions where w.minutes > 0 && w.date >= s && w.date < e {
                let start = w.date.addingTimeInterval(-Double(w.minutes) * 60)
                out.append(DayBlock(id: "w\(w.id)", kind: .logged(t.id), title: "✓ " + t.title, detail: "Logged \(Scheduler.durationText(w.minutes))",
                                    start: max(start, s), end: w.date, category: "Focus", dashed: true))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    func allDay(on day: Date, hidden: Set<String>) -> [EventOccurrence] {
        let s = Calendar.current.startOfDay(for: day)
        return occurrences(in: DateInterval(start: s, duration: 86_400)).filter { $0.isAllDay && !hidden.contains(DayFeed.category(for: $0)) }
    }

    func due(on day: Date, hidden: Set<String>) -> [BrainTask] {
        guard !hidden.contains("Assignments") else { return [] }
        return tasks.filter { $0.due.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
            .sorted { ($0.isCompleted ? 1 : 0, $0.due!) < ($1.isCompleted ? 1 : 0, $1.due!) }
    }
}

/// Side-by-side lanes for overlapping blocks.
private func lanes(_ blocks: [DayBlock]) -> [(DayBlock, Int, Int)] {
    var result: [(DayBlock, Int, Int)] = []
    var group: [(DayBlock, Int)] = []
    var groupEnd = Date.distantPast
    func flush() {
        let n = (group.map(\.1).max() ?? 0) + 1
        result += group.map { ($0.0, $0.1, n) }
        group = []
    }
    // Short blocks are drawn at least ~30 minutes tall, so lay them out by that size or their text collides.
    func shown(_ b: DayBlock) -> Date { max(b.end, b.start.addingTimeInterval(30 * 60)) }
    for b in blocks {
        if b.start >= groupEnd { flush() }
        var laneEnds: [Int: Date] = [:]
        for (g, l) in group { laneEnds[l] = max(laneEnds[l] ?? .distantPast, shown(g)) }
        let lane = (0...group.count).first { (laneEnds[$0] ?? .distantPast) <= b.start } ?? group.count
        group.append((b, lane))
        groupEnd = max(groupEnd, shown(b))
    }
    flush()
    return result
}

private struct BlockView: View {
    var b: DayBlock
    var compact: Bool
    var body: some View {
        let tone = CalTone.tone(b.category)
        VStack(alignment: .leading, spacing: 1) {
            Text(b.title).font(.system(size: compact ? 12 : 13, weight: .bold)).foregroundStyle(X.ink).lineLimit(2)
            Text(b.detail).font(.system(size: compact ? 11 : 12)).foregroundStyle(tone.text).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tone.fill.opacity(b.dashed ? 0.55 : 0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if b.dashed { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(X.purple.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
        }
        .overlay(alignment: .leading) {
            if !b.dashed { RoundedRectangle(cornerRadius: 2).fill(CalTone.color(b.category)).frame(width: 3).padding(.vertical, 6).padding(.leading, 2) }
        }
    }
}

/// A due-date chip: tap to open, the circle checks it off.
private struct DueChip: View {
    @EnvironmentObject var store: BrainStore
    var t: BrainTask
    var open: (UUID) -> Void
    var body: some View {
        HStack(spacing: 6) {
            Button { var c = t; if c.isCompleted { c.isCompleted = false; c.completedAt = nil } else { store.markDone(&c) }; store.upsert(c) } label: {
                Image(systemName: t.isCompleted ? "checkmark.circle.fill" : "circle").font(.system(size: 13, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t.isCompleted ? "Mark not done" : "Mark done")
            Text(t.title).font(.system(size: 12, weight: .bold)).lineLimit(1).strikethrough(t.isCompleted)
        }
        .foregroundStyle(t.isCompleted ? X.muted : X.Tone.alert.text)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(X.Tone.alert.fill.opacity(t.isCompleted ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open(t.id) }
    }
}

// MARK: - Week

private let hourHeight: CGFloat = 48
private let firstHour = 6, lastHour = 24

struct WeekGridView: View {
    @EnvironmentObject var store: BrainStore
    var start: Date
    var hidden: Set<String>
    var openTask: (UUID) -> Void
    var openEvent: (EventOccurrence) -> Void

    var body: some View {
        let cal = Calendar.current
        let days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
        VStack(spacing: 0) {
            // Day headers + due lane
            HStack(alignment: .top, spacing: 0) {
                Text("").frame(width: 58)
                ForEach(days, id: \.self) { d in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.system(size: 13, weight: .bold))
                                .foregroundStyle(cal.isDateInToday(d) ? X.purple : X.muted)
                            Text(d.formatted(.dateTime.day())).font(.system(size: 20, weight: .bold))
                                .foregroundStyle(cal.isDateInToday(d) ? X.page : X.ink)
                                .padding(.horizontal, cal.isDateInToday(d) ? 8 : 0)
                                .background(cal.isDateInToday(d) ? X.ink : .clear, in: Capsule())
                        }
                        ForEach(store.allDay(on: d, hidden: hidden).prefix(2)) { o in
                            Text(o.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(CalTone.tone(DayFeed.category(for: o)).fill, in: RoundedRectangle(cornerRadius: 6))
                        }
                        ForEach(store.due(on: d, hidden: hidden)) { t in DueChip(t: t, open: openTask) }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(cal.isDateInToday(d) ? X.purpleSoft.opacity(0.5) : .clear)
                }
            }
            .padding(.bottom, 4)
            Rectangle().fill(X.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        hourLabels
                        ForEach(days, id: \.self) { d in
                            DayTimeline(day: d, hidden: hidden, compact: true, openTask: openTask, openEvent: openEvent)
                                .background(cal.isDateInToday(d) ? X.purpleSoft.opacity(0.25) : .clear)
                                .overlay(alignment: .leading) { Rectangle().fill(X.line).frame(width: 1) }
                        }
                    }
                    .padding(.bottom, X.barClearance - 10)
                }
                .onAppear { proxy.scrollTo("h\(max(firstHour, Calendar.current.component(.hour, from: Date()) - 2))", anchor: .top) }
            }
        }
        .background(X.raised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(X.line))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(firstHour..<lastHour, id: \.self) { h in
                Text(hourText(h)).font(.system(size: 11, weight: .semibold)).foregroundStyle(X.muted)
                    .frame(width: 58, height: hourHeight, alignment: .topTrailing).padding(.trailing, 8)
                    .id("h\(h)")
            }
        }
    }
}

func hourText(_ h: Int) -> String {
    let d = Calendar.current.date(bySettingHour: h % 24, minute: 0, second: 0, of: Date())!
    return d.formatted(.dateTime.hour())
}

/// One day's hours with its blocks laid out in lanes, plus the now line.
struct DayTimeline: View {
    @EnvironmentObject var store: BrainStore
    var day: Date
    var hidden: Set<String>
    var compact: Bool
    var openTask: (UUID) -> Void
    var openEvent: (EventOccurrence) -> Void

    var body: some View {
        let cal = Calendar.current
        let dayStart = cal.date(bySettingHour: firstHour, minute: 0, second: 0, of: cal.startOfDay(for: day))!
        let placed = lanes(store.blocks(on: day, hidden: hidden))
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(firstHour..<lastHour, id: \.self) { _ in
                        Rectangle().fill(.clear).frame(height: hourHeight - 1)
                        Rectangle().fill(X.line).frame(height: 1)
                    }
                }
                ForEach(placed, id: \.0.id) { b, lane, of in
                    let top = max(0, b.start.timeIntervalSince(dayStart) / 3600 * hourHeight)
                    let h = max(hourHeight / 2 - 2, b.end.timeIntervalSince(b.start) / 3600 * hourHeight - 2)
                    let w = (geo.size.width - 8) / CGFloat(of)
                    BlockView(b: b, compact: compact)
                        .frame(width: w - 2, height: h)
                        .offset(x: 4 + CGFloat(lane) * w, y: top)
                        .onTapGesture {
                            switch b.kind {
                            case .event(let o): openEvent(o)
                            case .focus(let id): if let id { openTask(id) }
                            case .logged(let id): openTask(id)
                            case .routine: break
                            }
                        }
                }
                if cal.isDateInToday(day) {
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in
                        let y = ctx.date.timeIntervalSince(dayStart) / 3600 * hourHeight
                        HStack(spacing: 0) {
                            Circle().fill(X.now).frame(width: 9, height: 9)
                            Rectangle().fill(X.now).frame(height: 2)
                        }
                        .offset(x: -4, y: y - 4.5)
                    }
                }
            }
        }
        .frame(height: CGFloat(lastHour - firstHour) * hourHeight)
    }
}

// MARK: - Day (iPhone)

struct WeekStrip: View {
    @EnvironmentObject var store: BrainStore
    @Binding var selected: Date
    var body: some View {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: selected)!.start
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                let d = cal.date(byAdding: .day, value: i, to: start)!
                let sel = cal.isDate(d, inSameDayAs: selected)
                let busy = !store.due(on: d, hidden: []).filter { !$0.isCompleted }.isEmpty
                Button { withAnimation(.snappy) { selected = d } } label: {
                    VStack(spacing: 4) {
                        Text(d.formatted(.dateTime.weekday(.narrow))).font(.system(size: 12, weight: .bold))
                        Text(d.formatted(.dateTime.day())).font(.system(size: 17, weight: .bold))
                        Circle().fill(busy ? (sel ? X.page : X.purple) : .clear).frame(width: 5, height: 5)
                    }
                    .foregroundStyle(sel ? X.page : (cal.isDateInToday(d) ? X.purple : X.ink))
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(sel ? X.ink : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct DayColumnView: View {
    @EnvironmentObject var store: BrainStore
    var day: Date
    var wide: Bool
    var hidden: Set<String>
    var openTask: (UUID) -> Void
    var openEvent: (EventOccurrence) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.allDay(on: day, hidden: hidden)) { o in
                        HStack(spacing: 10) {
                            Text(DayFeed.emoji(event: o.title, category: DayFeed.category(for: o)))
                            Text(o.title).font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text("All day").font(.system(size: 12)).foregroundStyle(X.muted)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(CalTone.tone(DayFeed.category(for: o)).fill.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    ForEach(store.due(on: day, hidden: hidden)) { t in
                        HStack(spacing: 10) {
                            Text(DayFeed.emoji(task: t))
                            Text(xRich("**\(t.title)** due " + (t.due.map { AppleSync.isEndOfDay($0) ? "tonight" : $0.formatted(date: .omitted, time: .shortened) } ?? "")))
                                .font(.system(size: 14)).strikethrough(t.isCompleted)
                            Spacer()
                            Button { var c = t; if c.isCompleted { c.isCompleted = false; c.completedAt = nil } else { store.markDone(&c) }; store.upsert(c) } label: {
                                Image(systemName: t.isCompleted ? "checkmark.circle.fill" : "circle").font(.system(size: 22)).foregroundStyle(X.Tone.alert.text)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(t.isCompleted ? "Mark not done" : "Mark done")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(X.Tone.alert.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { openTask(t.id) }
                    }
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(firstHour..<lastHour, id: \.self) { h in
                                Text(hourText(h)).font(.system(size: 11, weight: .semibold)).foregroundStyle(X.muted)
                                    .frame(width: 48, height: hourHeight, alignment: .topLeading)
                                    .id("d\(h)")
                            }
                        }
                        DayTimeline(day: day, hidden: hidden, compact: false, openTask: openTask, openEvent: openEvent)
                    }
                }
                .padding(.bottom, X.barClearance)
            }
            .onAppear { proxy.scrollTo("d\(max(firstHour, Calendar.current.component(.hour, from: Date()) - 1))", anchor: .top) }
        }
    }
}

// MARK: - Month

struct MonthGridView: View {
    @EnvironmentObject var store: BrainStore
    var month: Date
    var hidden: Set<String>
    var pick: (Date) -> Void

    var body: some View {
        let cal = Calendar.current
        let first = cal.dateInterval(of: .month, for: month)!.start
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let days = (0..<42).map { cal.date(byAdding: .day, value: $0 - lead, to: first)! }
        let weeks = days.chunked(7).filter { $0.contains { cal.isDate($0, equalTo: first, toGranularity: .month) } }
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(cal.shortWeekdaySymbols[(i + cal.firstWeekday - 1) % 7].uppercased()).font(.system(size: 12, weight: .bold)).foregroundStyle(X.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                ForEach(weeks, id: \.first) { week in
                    HStack(spacing: 0) {
                        ForEach(week, id: \.self) { d in
                            let inMonth = cal.isDate(d, equalTo: first, toGranularity: .month)
                            let events = store.occurrences(on: d).filter { !hidden.contains(DayFeed.category(for: $0)) }
                            let due = store.due(on: d, hidden: hidden).filter { !$0.isCompleted }
                            Button { pick(d) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(d.formatted(.dateTime.day())).font(.system(size: 14, weight: cal.isDateInToday(d) ? .heavy : .semibold))
                                        .foregroundStyle(cal.isDateInToday(d) ? X.page : (inMonth ? X.ink : X.muted.opacity(0.5)))
                                        .frame(width: 26, height: 26)
                                        .background(cal.isDateInToday(d) ? X.ink : .clear, in: Circle())
                                    ForEach(events.prefix(2)) { o in
                                        HStack(spacing: 4) {
                                            Circle().fill(CalTone.color(DayFeed.category(for: o))).frame(width: 6, height: 6)
                                            Text(o.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        }
                                    }
                                    if !due.isEmpty {
                                        Text("📚 \(due.count) due").font(.system(size: 11, weight: .bold)).foregroundStyle(X.Tone.alert.text)
                                    } else if events.count > 2 {
                                        Text("+\(events.count - 2) more").font(.system(size: 11)).foregroundStyle(X.muted)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                                .overlay(alignment: .top) { Rectangle().fill(X.line).frame(height: 1) }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.bottom, X.barClearance - 10)
        }
    }
}

// MARK: - Agenda (Extra's date-column list)

struct AgendaView: View {
    @EnvironmentObject var store: BrainStore
    var start: Date
    var hidden: Set<String>
    var openTask: (UUID) -> Void
    var openEvent: (EventOccurrence) -> Void

    var body: some View {
        let cal = Calendar.current
        let days = (0..<14).map { cal.date(byAdding: .day, value: $0, to: start)! }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days, id: \.self) { d in
                    let events = store.occurrences(on: d).filter { !hidden.contains(DayFeed.category(for: $0)) }
                    let due = store.due(on: d, hidden: hidden)
                    if !events.isEmpty || !due.isEmpty {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 0) {
                                Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(cal.isDateInToday(d) ? X.purple : X.muted)
                                Text(d.formatted(.dateTime.day())).font(.system(size: 26, weight: .heavy)).foregroundStyle(X.ink)
                            }
                            .frame(width: 48)
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(due) { t in
                                    agendaRow(emoji: DayFeed.emoji(task: t), top: t.course ?? "Assignment",
                                              title: t.title, sub: "Due " + (t.due.map { AppleSync.isEndOfDay($0) ? "end of day" : $0.formatted(date: .omitted, time: .shortened) } ?? ""),
                                              tone: .alert, done: t.isCompleted)
                                        .onTapGesture { openTask(t.id) }
                                }
                                ForEach(events) { o in
                                    let c = DayFeed.category(for: o)
                                    agendaRow(emoji: DayFeed.emoji(event: o.title, category: c),
                                              top: c + (o.isAllDay ? "" : " · " + o.start.formatted(date: .omitted, time: .shortened)),
                                              title: o.title, sub: o.isAllDay ? "All day" : (o.location ?? (o.start.formatted(date: .omitted, time: .shortened) + " – " + o.end.formatted(date: .omitted, time: .shortened))),
                                              tone: CalTone.tone(c), done: false)
                                        .onTapGesture { openEvent(o) }
                                }
                            }
                        }
                        .padding(.vertical, 14)
                        Rectangle().fill(X.line).frame(height: 1)
                    }
                }
            }
            .padding(.bottom, X.barClearance - 10)
        }
    }

    private func agendaRow(emoji: String, top: String, title: String, sub: String, tone: X.Tone, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            XTile(emoji: emoji, tone: tone, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(top).font(.system(size: 13, weight: .semibold)).foregroundStyle(X.muted)
                Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(X.ink).strikethrough(done)
                Text(sub).font(.system(size: 13)).foregroundStyle(X.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
