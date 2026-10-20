import Foundation
import EventKit
import BrainCore

/// Puts Blob into Apple's apps:
/// - assignments (and their steps) become tasks in a "Blob" Reminders list, which the Calendar app shows
///   on their due dates — tick one off in Calendar or Reminders and it's done in Blob too;
/// - Blob's events go into a "Blob" calendar, so they're in Apple Calendar (and on your Watch, widgets…).
/// Each item carries a blob:// link, so the Mac and iPhone (sharing iCloud) update the same items instead of duplicating them.
@MainActor
final class AppleSync {
    static let calendarName = "Blob"
    private let ek: EKEventStore
    private var running = false
    private var dirty = false
    /// Our own writes also fire EKEventStoreChanged; ignore those.
    private(set) var lastOwnWrite = Date.distantPast

    init(store: EKEventStore) { ek = store }

    struct Options {
        var tasks: Bool
        var steps: Bool
        var events: Bool
    }

    struct Result {
        var completedInApple: [UUID] = []
        var reopenedInApple: [UUID] = []
        var stepsDoneInApple: [(task: UUID, step: UUID)] = []
        var dueChanged: [(task: UUID, due: Date)] = []
        var eventsChanged: [BrainEvent] = []
    }

    var isRecentOwnWrite: Bool { Date().timeIntervalSince(lastOwnWrite) < 3 }

    func sync(tasks: [BrainTask], events: [BrainEvent], options: Options) async throws -> Result {
        guard !running else { return Result() }
        running = true
        defer { running = false }
        var result = Result()
        if options.tasks, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            try await syncReminders(tasks, includeSteps: options.steps, into: &result)
        }
        if options.events, EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            try syncEvents(events, into: &result)
        }
        if dirty {
            lastOwnWrite = Date()
            try ek.commit()
            dirty = false
        }
        return result
    }

    // MARK: Lists / calendars

    private func blobCalendar(for type: EKEntityType) throws -> EKCalendar {
        if let c = ek.calendars(for: type).first(where: { $0.title == Self.calendarName && $0.allowsContentModifications }) { return c }
        let cal = EKCalendar(for: type, eventStore: ek)
        cal.title = Self.calendarName
        cal.cgColor = CGColor(red: 0.0, green: 0.78, blue: 0.95, alpha: 1)   // Blob cyan
        // iCloud first so it reaches your other devices; otherwise wherever new items normally go.
        let preferred = type == .reminder ? ek.defaultCalendarForNewReminders()?.source : ek.defaultCalendarForNewEvents?.source
        cal.source = preferred
            ?? ek.sources.first { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") }
            ?? ek.sources.first { $0.sourceType == .local }
        try ek.saveCalendar(cal, commit: true)
        return cal
    }

    // MARK: Assignments → Reminders (shown in Calendar)

    private func fetchReminders(in cal: EKCalendar) async -> [EKReminder] {
        let predicate = ek.predicateForReminders(in: [cal])
        return await withCheckedContinuation { cont in
            ek.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
    }

    private func syncReminders(_ tasks: [BrainTask], includeSteps: Bool, into result: inout Result) async throws {
        let list = try blobCalendar(for: .reminder)
        var existing: [String: EKReminder] = [:]
        for r in await fetchReminders(in: list) {
            guard let key = r.url?.absoluteString, key.hasPrefix("blob://") else { continue }
            if existing[key] != nil { try ek.remove(r, commit: false); dirty = true; continue }   // duplicate from another device
            existing[key] = r
        }

        let recent = Date().addingTimeInterval(-14 * 86_400)
        var wanted = Set<String>()
        for t in tasks {
            let key = "blob://task/\(t.id.uuidString)"
            let keep = !t.deleted && (!t.isCompleted || (t.completedAt ?? .distantPast) > recent)
            if keep {
                wanted.insert(key)
                let r = existing[key]
                // Ticked off (or un-ticked) in Calendar/Reminders after Blob last changed it → Apple wins.
                if let r, r.isCompleted != t.isCompleted, (r.lastModifiedDate ?? .distantPast) > t.updatedAt.addingTimeInterval(1) {
                    if r.isCompleted { result.completedInApple.append(t.id) } else { result.reopenedInApple.append(t.id) }
                } else if let r, let d = r.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }),
                          let due = t.due, abs(d.timeIntervalSince(due)) > 60,
                          (r.lastModifiedDate ?? .distantPast) > t.updatedAt.addingTimeInterval(1) {
                    result.dueChanged.append((t.id, d))
                } else {
                    write(r ?? EKReminder(eventStore: ek), list: list, key: key, title: t.title, due: t.due,
                          done: t.isCompleted, notes: notes(for: t), priority: t.priority)
                }
            }
            guard includeSteps, keep, !t.isCompleted else { continue }
            for m in t.milestones where !m.isDone || (m.doneAt ?? .distantPast) > recent {
                let mkey = "blob://task/\(t.id.uuidString)/step/\(m.id.uuidString)"
                wanted.insert(mkey)
                let r = existing[mkey]
                if let r, r.isCompleted, !m.isDone, (r.lastModifiedDate ?? .distantPast) > t.updatedAt.addingTimeInterval(1) {
                    result.stepsDoneInApple.append((t.id, m.id))
                } else {
                    write(r ?? EKReminder(eventStore: ek), list: list, key: mkey, title: "\(t.title): \(m.title)",
                          due: m.due, done: m.isDone, notes: "Step of \(t.title)" + (t.course.map { " · \($0)" } ?? ""), priority: .normal)
                }
            }
        }
        // Gone from Blob (deleted, or finished a while ago) → remove from Reminders.
        for (key, r) in existing where !wanted.contains(key) { try ek.remove(r, commit: false); dirty = true }
    }

    private func notes(for t: BrainTask) -> String {
        var lines: [String] = []
        if let c = t.course { lines.append(c) }
        if t.isLongTerm && !t.isCompleted {
            var l = "\(Int(t.progress * 100))% done · \(t.pace().label)"
            if let m = t.nextMilestone { l += " · next: \(m.title)" }
            lines.append(l)
        }
        if let link = t.link { lines.append(link) }
        return lines.joined(separator: "\n")
    }

    private func write(_ r: EKReminder, list: EKCalendar, key: String, title: String, due: Date?, done: Bool,
                       notes: String, priority: BrainTask.Priority) {
        let comps = due.map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
        let ekPriority = priority == .high ? 1 : (priority == .low ? 9 : 0)
        let isNew = r.calendar == nil
        // Only touch what changed, so iCloud isn't flooded with no-op edits.
        if isNew || r.title != title || r.isCompleted != done || r.notes != notes || r.priority != ekPriority
            || r.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) != comps.flatMap({ Calendar.current.date(from: $0) }) {
            if isNew { r.calendar = list }
            r.title = title
            r.url = URL(string: key)
            r.notes = notes
            r.priority = ekPriority
            r.dueDateComponents = comps
            r.isCompleted = done
            try? ek.save(r, commit: false); dirty = true
        }
    }

    // MARK: Blob events → Apple Calendar

    private func syncEvents(_ events: [BrainEvent], into result: inout Result) throws {
        let cal = try blobCalendar(for: .event)
        let from = Date().addingTimeInterval(-60 * 86_400), to = Date().addingTimeInterval(400 * 86_400)
        var existing: [String: EKEvent] = [:]
        for e in ek.events(matching: ek.predicateForEvents(withStart: from, end: to, calendars: [cal])) {
            guard let key = e.url?.absoluteString, key.hasPrefix("blob://") else { continue }
            if let first = existing[key] {
                // Repeating events come back once per occurrence; only a true copy is a duplicate.
                if first.calendarItemExternalIdentifier != e.calendarItemExternalIdentifier { try? ek.remove(e, span: .futureEvents, commit: false); dirty = true }
                continue
            }
            existing[key] = e
        }
        var wanted = Set<String>()
        for ev in events where !ev.deleted {
            let key = "blob://event/\(ev.id.uuidString)"
            wanted.insert(key)
            if let e = existing[key], !ev.recurrence.isRepeating,
               (e.lastModifiedDate ?? .distantPast) > ev.updatedAt.addingTimeInterval(1),
               e.title != ev.title || e.startDate != ev.start || e.endDate != ev.end || (e.location ?? "") != (ev.location ?? "") {
                // Moved or renamed in Apple Calendar → bring that back into Blob.
                var changed = ev
                changed.title = e.title ?? ev.title
                changed.start = e.startDate
                changed.end = e.endDate
                changed.isAllDay = e.isAllDay
                changed.location = e.location
                result.eventsChanged.append(changed)
                continue
            }
            write(existing[key], ev, key: key, calendar: cal)
        }
        for (key, e) in existing where !wanted.contains(key) { try? ek.remove(e, span: .futureEvents, commit: false); dirty = true }
    }

    private func write(_ found: EKEvent?, _ ev: BrainEvent, key: String, calendar: EKCalendar) {
        // For a repeating series, edit its first event so the change covers the whole series.
        let existing = found.flatMap { ($0.hasRecurrenceRules ? ek.calendarItem(withIdentifier: $0.calendarItemIdentifier) as? EKEvent : nil) ?? $0 }
        let rules = recurrence(ev)
        let end = max(ev.end, ev.start.addingTimeInterval(ev.isAllDay ? 86_400 : 60))
        if let e = existing {
            let unchanged = e.title == ev.title && e.isAllDay == ev.isAllDay && (e.location ?? "") == (ev.location ?? "")
                && (e.notes ?? "") == (ev.notes ?? "") && e.startDate == ev.start && e.endDate == end
                && Self.signature(e.recurrenceRules ?? []) == Self.signature(rules)
            if unchanged { removeExcluded(ev, key: key, calendar: calendar); return }
        }
        let e = existing ?? EKEvent(eventStore: ek)
        if existing == nil { e.calendar = calendar }
        e.title = ev.title
        e.url = URL(string: key)
        e.isAllDay = ev.isAllDay
        e.location = ev.location
        e.notes = ev.notes
        e.startDate = ev.start
        e.endDate = end
        e.recurrenceRules = rules
        try? ek.save(e, span: .futureEvents, commit: false); dirty = true
        removeExcluded(ev, key: key, calendar: calendar)
    }

    /// Days you removed from a repeating event in Blob → remove just that day in Apple Calendar too.
    private func removeExcluded(_ ev: BrainEvent, key: String, calendar: EKCalendar) {
        guard ev.recurrence.isRepeating else { return }
        for day in ev.excludedDays where day > Date().addingTimeInterval(-60 * 86_400) {
            let start = Calendar.current.startOfDay(for: day)
            let matches = ek.events(matching: ek.predicateForEvents(withStart: start, end: start.addingTimeInterval(86_400), calendars: [calendar]))
            for o in matches where o.url?.absoluteString == key { try? ek.remove(o, span: .thisEvent, commit: false); dirty = true }
        }
    }

    private static func signature(_ rules: [EKRecurrenceRule]) -> String {
        rules.map { r in
            "\(r.frequency.rawValue)/\(r.interval)/\((r.daysOfTheWeek ?? []).map { $0.dayOfTheWeek.rawValue }.sorted())/\(r.recurrenceEnd?.endDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ";")
    }

    private func recurrence(_ ev: BrainEvent) -> [EKRecurrenceRule] {
        let end = ev.recurrence.until.map { EKRecurrenceEnd(end: $0) }
        let r = ev.recurrence
        switch r.frequency {
        case .none: return []
        case .daily: return [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: end)]
        case .monthly: return [EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: end)]
        case .weekdays, .weekly:
            let days = r.frequency == .weekdays ? [2, 3, 4, 5, 6] : (r.weekdays.isEmpty ? [Calendar.current.component(.weekday, from: ev.start)] : r.weekdays)
            return [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                     daysOfTheWeek: days.compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) } },
                                     daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)]
        }
    }
}
