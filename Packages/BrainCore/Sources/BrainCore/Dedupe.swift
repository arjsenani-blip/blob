import Foundation

/// Finds the same event showing up more than once — e.g. a holiday in both Apple's and Google's holiday calendars,
/// or an event copied into two accounts. Two levels:
/// - `isDuplicate` (loose): for what Blob *shows*. Titles that mean the same thing ("Daylight Saving Time ends" /
///   "Daylight Saving Time End", "🎃 Halloween" / "Halloween") at the same time count as one event.
/// - `isExactCopy` (strict): for what Blob *removes* from your calendars. Same title (ignoring case, punctuation and
///   emoji) at exactly the same time. Nothing is ever deleted on a loose match.
public enum EventDeduper {
    // MARK: Titles

    /// Lowercased, accents folded, emoji/punctuation gone, a leading "Due:" dropped, simple plurals trimmed.
    public static func normalize(_ title: String) -> String {
        tokens(title).joined(separator: " ")
    }

    static func tokens(_ title: String) -> [String] {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        var words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if words.first == "due" && words.count > 1 { words.removeFirst() }
        return words.map { w in
            // "ends" ~ "end", "classes" ~ "class"; leave short words and "ss" endings alone.
            if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
            return w
        }
    }

    /// Strict: same words in the same order.
    public static func sameTitle(_ a: String, _ b: String) -> Bool {
        let na = normalize(a), nb = normalize(b)
        return !na.isEmpty && na == nb
    }

    /// Loose: same words, nearly the same set of words, or one title inside the other (when it's most of it).
    public static func similarTitle(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let na = ta.joined(separator: " "), nb = tb.joined(separator: " ")
        if na == nb { return true }
        let sa = Set(ta), sb = Set(tb)
        if min(sa.count, sb.count) >= 2 {
            let jaccard = Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
            if jaccard >= 0.75 { return true }
        }
        let (short, long) = na.count <= nb.count ? (na, nb) : (nb, na)
        return short.count >= 6 && long.contains(short) && Double(short.count) / Double(long.count) >= 0.6
    }

    // MARK: Times

    static func sameTime(start a: Date, end ae: Date, allDay aAll: Bool, start b: Date, end be: Date, allDay bAll: Bool,
                         loose: Bool, calendar: Calendar) -> Bool {
        guard aAll == bAll else { return false }
        if aAll {
            guard calendar.isDate(a, inSameDayAs: b) else { return false }
            // Same length in days (a one-day holiday vs a week-long trip aren't the same thing).
            let da = calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: ae)).day ?? 0
            let db = calendar.dateComponents([.day], from: calendar.startOfDay(for: b), to: calendar.startOfDay(for: be)).day ?? 0
            return loose ? abs(da - db) <= 1 : da == db
        }
        if loose { return abs(a.timeIntervalSince(b)) <= 5 * 60 && abs(ae.timeIntervalSince(be)) <= 15 * 60 }
        return abs(a.timeIntervalSince(b)) < 60 && abs(ae.timeIntervalSince(be)) < 60
    }

    public static func isDuplicate(_ a: EventOccurrence, _ b: EventOccurrence, calendar: Calendar = .current) -> Bool {
        sameTime(start: a.start, end: a.end, allDay: a.isAllDay, start: b.start, end: b.end, allDay: b.isAllDay, loose: true, calendar: calendar)
            && similarTitle(a.title, b.title)
    }

    public static func isExactCopy(title a: String, start: Date, end: Date, allDay: Bool,
                                   title b: String, start bs: Date, end be: Date, allDay bAll: Bool, calendar: Calendar = .current) -> Bool {
        sameTime(start: start, end: end, allDay: allDay, start: bs, end: be, allDay: bAll, loose: false, calendar: calendar)
            && sameTitle(a, b)
    }

    // MARK: Showing

    /// One of each event. Keeps the best copy: Blob's own event first, then one with a location, then the first seen.
    public static func dedupe(_ items: [EventOccurrence], calendar: Calendar = .current) -> [EventOccurrence] {
        func rank(_ o: EventOccurrence) -> Int { (o.eventID != nil ? 0 : 2) + (o.location?.isEmpty == false ? 0 : 1) }
        let ordered = items.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        // Compare only within the same day bucket (and the next, for events near midnight) to stay fast.
        var kept: [EventOccurrence] = []
        var byDay: [Date: [Int]] = [:]
        for o in ordered {
            let day = calendar.startOfDay(for: o.start)
            let nearby = [calendar.date(byAdding: .day, value: -1, to: day)!, day, calendar.date(byAdding: .day, value: 1, to: day)!]
            let clash = nearby.contains { d in (byDay[d] ?? []).contains { isDuplicate(kept[$0], o, calendar: calendar) } }
            if clash { continue }
            byDay[day, default: []].append(kept.count)
            kept.append(o)
        }
        // Back in the original order.
        let order = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return kept.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }
}
