import Foundation
import BrainCore

/// Everything for one day, written the way Extra writes your inbox: short sentences with the key words in bold,
/// grouped into "Due soon", "Happening today" and "Good to know".
struct FeedItem: Identifiable, Hashable {
    enum Kind: Hashable { case task(UUID), event(String, UUID?), focusBlock(UUID?), note }
    var id: String
    var kind: Kind
    var emoji: String
    var tone: X.Tone
    /// Markdown with **bold**.
    var sentence: String
    var meta: String
    var category: String
    var sort: Date
}

struct FeedSection: Identifiable {
    var id: String { title }
    var title: String
    var tone: X.Tone
    var items: [FeedItem]
}

enum FeedFilter: Hashable, Identifiable {
    case everything, category(String), todos
    var id: String {
        switch self {
        case .everything: return "all"
        case .category(let c): return "c:" + c
        case .todos: return "todos"
        }
    }
}

@MainActor
struct DayFeed {
    let store: BrainStore
    let day: Date
    var now = Date()
    private var cal: Calendar { .current }

    // MARK: Categories & emoji

    static func category(for o: EventOccurrence) -> String {
        if let c = o.externalCalendar, !c.isEmpty {
            if c.localizedCaseInsensitiveContains("holiday") { return "Holidays" }
            if c.localizedCaseInsensitiveContains("birthday") { return "Personal" }
            return c
        }
        return (o.tag?.capitalized).flatMap { $0.isEmpty ? nil : $0 } ?? "Personal"
    }

    static func category(for t: BrainTask) -> String { t.looksLikeSchoolwork ? "School" : "To-dos" }

    static func emoji(event title: String, category: String) -> String {
        let t = title.lowercased()
        let table: [(String, String)] = [
            ("debate", "🗣️"), ("fenc", "🤺"), ("foil", "🤺"), ("saber", "🤺"), ("epee", "🤺"), ("soccer", "⚽️"), ("basketball", "🏀"),
            ("swim", "🏊"), ("gym", "🏋️"), ("workout", "🏋️"), ("run", "🏃"), ("walk", "🚶"), ("birthday", "🎂"), ("dentist", "🦷"),
            ("doctor", "🩺"), ("appointment", "📍"), ("eye", "👓"), ("concert", "🎵"), ("chorus", "🎶"), ("choir", "🎶"), ("music", "🎵"),
            ("flight", "✈️"), ("airline", "✈️"), ("travel", "🧳"), ("cruise", "🛳️"), ("exam", "📝"), ("test", "📝"), ("sat ", "📝"),
            ("payday", "💵"), ("work", "💼"), ("driv", "🚗"), ("permit", "🚗"), ("school", "🏫"), ("class", "🏫"), ("halloween", "🎃"),
            ("christmas", "🎄"), ("thanksgiving", "🦃"), ("new year", "🎆"), ("dinner", "🍽️"), ("lunch", "🥪"), ("breakfast", "🍳"),
            ("party", "🎉"), ("movie", "🎬"), ("hackathon", "💻"), ("meeting", "👥"), ("hangout", "👋"), ("tournament", "🏆"),
            ("cup", "🏆"), ("open", "🏆"), ("workshop", "🧑‍🏫"), ("tutor", "🧑‍🏫"), ("lesson", "🧑‍🏫"),
        ]
        if let hit = table.first(where: { t.contains($0.0) }) { return hit.1 }
        switch category.lowercased() {
        case "family": return "🏠"
        case "school": return "🏫"
        case "sports", "fitness": return "🏅"
        case "holidays": return "🎉"
        default: return "🗓️"
        }
    }

    static func emoji(task t: BrainTask) -> String {
        let s = ((t.course ?? "") + " " + t.title).lowercased()
        let table: [(String, String)] = [
            ("calc", "📐"), ("math", "📐"), ("algebra", "📐"), ("geometry", "📐"), ("stat", "📊"), ("chem", "🧪"), ("bio", "🧬"),
            ("physics", "🧲"), ("macbeth", "🎭"), ("english", "📖"), ("lit", "📖"), ("lang", "📖"), ("read", "📖"), ("history", "🏛️"),
            ("apush", "🏛️"), ("gov", "🏛️"), ("econ", "💹"), ("french", "🇫🇷"), ("spanish", "🇪🇸"), ("latin", "🏺"), ("essay", "✍️"),
            ("paper", "✍️"), ("lab", "🧪"), ("project", "🛠️"), ("presentation", "🎤"), ("test", "📝"), ("quiz", "📝"), ("exam", "📝"),
            ("code", "💻"), ("cs", "💻"), ("debate", "🗣️"), ("sat", "📝"),
        ]
        if let hit = table.first(where: { s.contains($0.0) }) { return hit.1 }
        return t.looksLikeSchoolwork ? "📚" : "✅"
    }

    // MARK: Pieces of the day

    var dayStart: Date { cal.startOfDay(for: day) }
    var dayEnd: Date { cal.date(byAdding: .day, value: 1, to: dayStart)! }
    var isToday: Bool { cal.isDateInToday(day) }

    var occurrences: [EventOccurrence] { store.occurrences(in: DateInterval(start: dayStart, end: dayEnd)) }

    private func dueWords(_ d: Date) -> String {
        let time = d.formatted(date: .omitted, time: .shortened)
        let endOfDay = AppleSync.isEndOfDay(d)
        if cal.isDate(d, inSameDayAs: dayStart) { return endOfDay ? "tonight" : (isToday ? "today at \(time)" : "at \(time)") }
        if cal.isDate(d, inSameDayAs: dayEnd) { return endOfDay ? "tomorrow" : "tomorrow at \(time)" }
        if d < dayStart { return "was due " + d.formatted(.dateTime.weekday(.wide)) }
        let days = cal.dateComponents([.day], from: dayStart, to: cal.startOfDay(for: d)).day ?? 0
        return days < 7 ? d.formatted(.dateTime.weekday(.wide)) : d.formatted(.dateTime.month(.abbreviated).day())
    }

    func taskItem(_ t: BrainTask, tone: X.Tone) -> FeedItem {
        let due = t.due ?? dayEnd
        var s: String
        if let m = t.nextMilestone, t.isLongTerm {
            s = "**\(t.title)** is due \(dueWords(due)) — next step **\(m.title)**."
            if t.pace(now: now) == .behind || t.pace(now: now) == .atRisk { s += " You're a little behind." }
            else if t.pace(now: now) == .onTrack || t.pace(now: now) == .ahead { s += " You're **\(t.pace(now: now).label.lowercased())**." }
        } else if due < now {
            s = "**\(t.title)** \(dueWords(due)). Still worth finishing."
        } else {
            s = "**\(t.title)** is due \(dueWords(due))."
            let left = t.remainingMinutes
            if t.loggedMinutes >= t.totalEstimateMinutes { s += " **\(Scheduler.durationText(t.loggedMinutes))** in so far — almost there?" }
            else if t.loggedMinutes > 0 { s += " **\(Scheduler.durationText(t.loggedMinutes))** of ~\(Scheduler.durationText(t.totalEstimateMinutes)) done." }
            else if left >= 20 { s += " About **\(Scheduler.durationText(left))** of work." }
        }
        var meta = [t.course].compactMap { $0 }
        if let d = t.due { meta.append(AppleSync.isEndOfDay(d) ? d.formatted(.dateTime.weekday(.abbreviated)) : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())) }
        return FeedItem(id: "t-\(t.id)", kind: .task(t.id), emoji: Self.emoji(task: t), tone: due < now ? .alert : tone,
                        sentence: s, meta: meta.joined(separator: " · "), category: Self.category(for: t), sort: due)
    }

    func eventItem(_ o: EventOccurrence, tone: X.Tone) -> FeedItem {
        let cat = Self.category(for: o)
        var s: String
        if o.isAllDay {
            s = o.title.lowercased().contains("birthday") ? "It's **\(o.title.replacingOccurrences(of: "’s Birthday", with: "'s birthday"))** 🎉" : "All day: **\(o.title)**."
        } else {
            s = "**\(o.title)** at \(o.start.formatted(date: .omitted, time: .shortened))"
            if let l = o.location, !l.isEmpty { s += " · \(l.components(separatedBy: ",").first ?? l)" }
            s += o.start <= now && o.end > now ? " — happening now." : "."
        }
        let meta = o.isAllDay ? cat : "\(o.start.formatted(date: .omitted, time: .shortened)) – \(o.end.formatted(date: .omitted, time: .shortened)) · \(cat)"
        return FeedItem(id: "e-\(o.id)", kind: .event(o.id, o.eventID), emoji: Self.emoji(event: o.title, category: cat), tone: tone,
                        sentence: s, meta: meta, category: cat, sort: o.start)
    }

    // MARK: Sections

    func sections(filter: FeedFilter) -> [FeedSection] {
        let open = store.pendingTasks
        let tomorrowEnd = cal.date(byAdding: .day, value: 1, to: dayEnd)!

        // Due soon: overdue, today, tomorrow.
        let dueSoon = open.filter { ($0.due ?? .distantFuture) < tomorrowEnd }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            .map { taskItem($0, tone: .due) }

        // Happening today: events still ahead (or now), all-day items, and Blob's planned focus blocks.
        var happening = occurrences.filter { !$0.isAllDay ? ($0.end > (isToday ? now : dayStart)) : true }
            .filter { DayFeed.category(for: $0) != "Holidays" || $0.isAllDay }
            .map { eventItem($0, tone: .today) }
        // Blob's plan: just the next focus block, with how many follow (the rest are on the calendar).
        if isToday, let plan = store.todayPlan {
            let left = plan.blocks.filter { $0.kind == .task && !store.isBlockDone($0) && $0.end > now }
            if let b = left.first {
                let t = store.task(b.taskID)
                let total = left.reduce(0) { $0 + $1.minutes }
                var s = "**Focus block** for \(t.map { "**\($0.title)**" } ?? b.title) at \(b.start.formatted(date: .omitted, time: .shortened))"
                s += left.count > 1 ? ", then \(left.count - 1) more — **\(Scheduler.durationText(total))** planned in all." : "."
                happening.append(FeedItem(id: "b-\(b.id)", kind: .focusBlock(b.taskID), emoji: "🍅", tone: .today, sentence: s,
                                          meta: "\(b.minutes) min · planned by Blob", category: t.map(Self.category(for:)) ?? "School", sort: b.start))
            }
        }
        happening.sort { $0.sort < $1.sort }

        // Good to know: the week ahead, and tomorrow's first thing.
        var good = open.filter { d in (d.due.map { $0 >= tomorrowEnd && $0 < dayStart.addingTimeInterval(8 * 86_400) } ?? false) }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            .prefix(5).map { taskItem($0, tone: .good) }
        let tomorrow = store.occurrences(in: DateInterval(start: dayEnd, end: tomorrowEnd))
        if let first = tomorrow.first(where: { !$0.isAllDay }) {
            var i = eventItem(first, tone: .good)
            i.id = "tm-" + first.id
            i.sentence = "Tomorrow starts with **\(first.title)** at \(first.start.formatted(date: .omitted, time: .shortened))."
            good.append(i)
        }
        for b in tomorrow where b.isAllDay && b.title.lowercased().contains("birthday") {
            var i = eventItem(b, tone: .good)
            i.id = "tb-" + b.id
            i.sentence = "**\(b.title)** is tomorrow."
            good.append(i)
        }

        func keep(_ items: [FeedItem]) -> [FeedItem] {
            switch filter {
            case .everything: return items
            case .todos: return items.filter { if case .task = $0.kind { return true }; return false }
            case .category(let c): return items.filter { $0.category == c }
            }
        }
        return [FeedSection(title: "Due soon", tone: .due, items: keep(dueSoon)),
                FeedSection(title: isToday ? "Happening today" : "That day", tone: .today, items: keep(happening)),
                FeedSection(title: "Good to know", tone: .good, items: keep(Array(good)))]
            .filter { !$0.items.isEmpty }
    }

    /// The categories that actually have something in them today, for the filter chips.
    var categories: [String] {
        var set = Set(occurrences.map(DayFeed.category(for:)))
        if store.pendingTasks.contains(where: \.looksLikeSchoolwork) { set.insert("School") }
        set.remove("Holidays")
        let order = ["School", "Family", "Sports", "Personal"]
        return set.sorted { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }
    }

    // MARK: The one-sentence summary

    var summary: String {
        var parts: [String] = []
        let open = store.pendingTasks
        let tonight = open.filter { $0.due.map { $0 >= (isToday ? now : dayStart) && $0 < dayEnd } ?? false }.sorted { $0.due! < $1.due! }
        let overdue = open.filter { ($0.due ?? .distantFuture) < (isToday ? now : dayStart) }
        let upcoming = occurrences.filter { !$0.isAllDay && $0.end > (isToday ? now : dayStart) && DayFeed.category(for: $0) != "Holidays" }

        if let t = tonight.first {
            parts.append("**\(t.title)** is due \(dueWords(t.due!))" + (tonight.count > 1 ? " (plus \(tonight.count - 1) more)" : ""))
        } else if !overdue.isEmpty {
            parts.append("**\(overdue.count) assignment\(overdue.count == 1 ? " is" : "s are")** overdue")
        }
        if let e = upcoming.first {
            parts.append((parts.isEmpty ? "" : "then ") + "**\(e.title)** at \(e.start.formatted(date: .omitted, time: .shortened))")
        }
        var s = parts.isEmpty ? "" : parts.joined(separator: ", ") + ". "
        if let first = s.first { s = first.uppercased() + s.dropFirst() }
        let minutes = open.filter { ($0.due ?? .distantFuture) < dayEnd.addingTimeInterval(86_400) }.reduce(0) { $0 + $1.remainingMinutes }
        if minutes > 0 { s += "You've got about **\(Scheduler.durationText(minutes))** of homework due by tomorrow" }
        if let big = open.filter({ ($0.due ?? .distantPast) > dayEnd.addingTimeInterval(86_400) }).min(by: { $0.due! < $1.due! }) {
            s += (minutes > 0 ? ", and " : "Next up: ") + "**\(big.title)** is due \(dueWords(big.due!))."
        } else if minutes > 0 { s += "." }
        if s.isEmpty { s = upcoming.isEmpty ? "Nothing on the calendar and nothing due — **enjoy the free time**." : "No homework due. Enjoy it." }
        return s
    }
}
