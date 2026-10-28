import Foundation
import EventKit
import BrainCore

/// Puts Blob into Apple's apps:
/// - assignments (and their steps) become tasks in a "Blob" Reminders list, which the Calendar app shows
///   on their due dates — tick one off in Calendar or Reminders and it's done in Blob too;
/// - Blob's events go into a "Blob" calendar, so they're in Apple Calendar (and on your Watch, widgets…).
/// Each item carries a blob:// link, so the Mac and iPhone (sharing iCloud) update the same items instead of duplicating them.
/// Runs on its own background actor with its own EventKit connection: EventKit calls can block and spin the run loop,
/// and doing that on the main thread while a Swift task was running crashed Blob.
actor AppleSync {
    static let calendarName = "Blob"
    /// The Reminders list homework goes in (made for you if you don't pick another).
    static let homeworkListName = "Homework"
    private let ek = EKEventStore()
    private var running = false
    private var dirty = false
    private var state: [String: String] = [:]
    /// Our own writes also fire EKEventStoreChanged; ignore those. (Read from the main thread; a stale value is harmless.)
    nonisolated(unsafe) private(set) var lastOwnWrite = Date.distantPast

    init() {}

    struct Options: Codable {
        var tasks: Bool
        var steps: Bool
        var events: Bool
        /// Reminders list for homework (calendarIdentifier); nil = a list called "Homework".
        var reminderList: String? = nil
        /// Where your other (non-school) to-dos go; nil = they stay only in Blob.
        var otherTasksList: String? = nil
        /// Bring reminders you add to that list into Blob as assignments.
        var importReminders = true
        /// Calendar for Blob's events; nil = a "Blob" calendar.
        var eventCalendar: String? = nil
        /// Calendar to show assignment due dates (and steps) on as events; nil = off.
        var dueCalendar: String? = nil
        /// Which lists/calendars were used last time (so items can be moved when you switch).
        var state: [String: String] = [:]
        /// Remove exact duplicate copies of events from your calendars this run.
        var cleanDuplicates = false
        /// Put back events an earlier cleanup removed.
        var restore: [RemovedEvent] = []
    }

    /// An event the duplicate cleanup removed — everything needed to put it back.
    struct RemovedEvent: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var location: String?
        var notes: String?
        var url: String?
        var calendarID: String
        var calendarTitle: String
        /// Where the copy that stayed lives.
        var keptIn: String
        var removedAt: Date
    }

    /// A reminder you added in the Reminders app, to become a Blob assignment.
    struct ImportedReminder: Codable {
        var id: UUID
        var title: String
        var due: Date?
        var notes: String?
        var isCompleted: Bool
        var highPriority: Bool
    }

    struct StepDone: Codable { var task: UUID; var step: UUID }
    struct DueChange: Codable { var task: UUID; var due: Date }

    struct Result: Codable {
        var completedInApple: [UUID] = []
        var reopenedInApple: [UUID] = []
        var stepsDoneInApple: [StepDone] = []
        var dueChanged: [DueChange] = []
        var state: [String: String] = [:]
        /// Parts that didn't work (the rest still synced).
        var warnings: [String] = []
        var eventsChanged: [BrainEvent] = []
        var imported: [ImportedReminder] = []
        var removedDuplicates: [RemovedEvent] = []
        var restored = 0
    }

    nonisolated var isRecentOwnWrite: Bool { Date().timeIntervalSince(lastOwnWrite) < 3 }

    func sync(tasks: [BrainTask], events: [BrainEvent], options: Options) async throws -> Result {
        guard !running else { return Result() }
        running = true
        defer { running = false }
        state = options.state
        var result = Result()
        // Homework (by context) goes to the Homework list and the calendar. Something you added to that list yourself counts too.
        let isHomework: (BrainTask) -> Bool = { $0.looksLikeSchoolwork || ($0.externalID?.hasPrefix("reminder:") ?? false) }
        // Each part on its own: one failing (e.g. an account that won't take a new calendar) doesn't stop the others.
        func part(_ name: String, _ work: () async throws -> Void) async {
            do { try await work() } catch { result.warnings.append("\(name): \(error.localizedDescription)") }
        }
        if options.tasks, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            await part("Reminders") {
                let list = try calendar(for: .reminder, id: options.reminderList)
                let otherList = options.otherTasksList.flatMap { ek.calendar(withIdentifier: $0) }.flatMap { $0.allowsContentModifications && $0 != list ? $0 : nil }
                if state["lastReminderList"] != list.calendarIdentifier {
                    try await moveOffOtherCalendars(type: .reminder, keeping: list, setting: "lastReminderList", except: otherList)
                }
                try await syncReminders(tasks.filter(isHomework), list: list, includeSteps: options.steps, importNew: options.importReminders, into: &result)
                if let otherList {
                    try await syncReminders(tasks.filter { !isHomework($0) }, list: otherList, includeSteps: false, importNew: false, into: &result)
                }
            }
        }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            if options.events {
                await part("Blob's events") {
                    let cal = try calendar(for: .event, id: options.eventCalendar)
                    try await moveOffOtherCalendars(type: .event, keeping: cal, setting: "lastEventCalendar", prefix: "blob://event/")
                    try syncEvents(events, calendar: cal, into: &result)
                }
            }
            await part("Due dates") {
                if let id = options.dueCalendar, let cal = ek.calendar(withIdentifier: id), cal.allowsContentModifications {
                    try await moveOffOtherCalendars(type: .event, keeping: cal, setting: "lastDueCalendar", prefix: "blob://due/")
                    syncDueDates(tasks.filter(isHomework), calendar: cal, includeSteps: options.steps, into: &result)
                } else if options.dueCalendar == nil, state["lastDueCalendar"] != nil {
                    // Turned off → take the due dates back off the calendar.
                    try await moveOffOtherCalendars(type: .event, keeping: nil, setting: "lastDueCalendar", prefix: "blob://due/")
                }
            }
        }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            if !options.restore.isEmpty {
                await part("Putting events back") { result.restored = try restore(options.restore) }
            }
            if options.cleanDuplicates {
                await part("Duplicate cleanup") { result.removedDuplicates = try removeDuplicateEvents() }
            }
        }
        if dirty {
            lastOwnWrite = Date()
            try ek.commit()
            dirty = false
        }
        result.state = state
        return result
    }

    // MARK: Duplicate cleanup

    /// Removes exact copies of the same event from your calendars: same title (ignoring case, punctuation, emoji) at the
    /// same time, in calendars you can edit. Never touches: invitations (deleting one could send a decline), repeating
    /// events, read-only/subscribed/holiday calendars, or Blob's own items. Keeps the oldest copy.
    private func removeDuplicateEvents() throws -> [RemovedEvent] {
        let now = Date()
        let calendars = ek.calendars(for: .event).filter {
            $0.allowsContentModifications && !$0.isSubscribed && $0.type != .birthday && !$0.isImmutable
        }
        guard calendars.count > 0 else { return [] }
        let range = (now.addingTimeInterval(-14 * 86_400), now.addingTimeInterval(180 * 86_400))
        let events = ek.events(matching: ek.predicateForEvents(withStart: range.0, end: range.1, calendars: calendars)).filter { e in
            !e.hasRecurrenceRules && !e.hasAttendees && !e.isDetached
                && !(e.url?.absoluteString.hasPrefix("blob://") ?? false)
                && !(e.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        // Group by day first so the pairwise check stays small.
        var byDay: [Date: [EKEvent]] = [:]
        for e in events { byDay[Calendar.current.startOfDay(for: e.startDate), default: []].append(e) }
        var removed: [RemovedEvent] = []
        var gone = Set<String>()
        for (_, dayEvents) in byDay {
            let sorted = dayEvents.sorted { ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture) }
            for (i, keep) in sorted.enumerated() where !gone.contains(keep.calendarItemIdentifier) {
                for copy in sorted[(i + 1)...] where !gone.contains(copy.calendarItemIdentifier) {
                    guard EventDeduper.isExactCopy(title: keep.title ?? "", start: keep.startDate, end: keep.endDate, allDay: keep.isAllDay,
                                                   title: copy.title ?? "", start: copy.startDate, end: copy.endDate, allDay: copy.isAllDay)
                    else { continue }
                    removed.append(RemovedEvent(id: copy.calendarItemIdentifier, title: copy.title ?? "", start: copy.startDate, end: copy.endDate,
                                                isAllDay: copy.isAllDay, location: copy.location, notes: copy.notes, url: copy.url?.absoluteString,
                                                calendarID: copy.calendar.calendarIdentifier, calendarTitle: copy.calendar.title,
                                                keptIn: keep.calendar.title, removedAt: now))
                    gone.insert(copy.calendarItemIdentifier)
                }
            }
        }
        // Something looks off if a run would remove a lot — leave everything alone and say so.
        guard removed.count <= 40 else {
            throw NSError(domain: "Blob", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Found \(removed.count) possible duplicates — more than Blob removes on its own. Nothing was removed."])
        }
        var done: [RemovedEvent] = []
        for r in removed {
            guard let e = ek.calendarItem(withIdentifier: r.id) as? EKEvent else { continue }
            try ek.remove(e, span: .thisEvent, commit: false)
            dirty = true
            done.append(r)
        }
        return done
    }

    /// Puts removed events back in their calendars (or your default calendar if that one is gone).
    private func restore(_ items: [RemovedEvent]) throws -> Int {
        var n = 0
        for r in items {
            guard let cal = ek.calendar(withIdentifier: r.calendarID) ?? ek.defaultCalendarForNewEvents, cal.allowsContentModifications else { continue }
            let e = EKEvent(eventStore: ek)
            e.calendar = cal
            e.title = r.title
            e.startDate = r.start
            e.endDate = r.end
            e.isAllDay = r.isAllDay
            e.location = r.location
            e.notes = r.notes
            e.url = r.url.flatMap(URL.init(string:))
            try ek.save(e, span: .thisEvent, commit: false)
            dirty = true
            n += 1
        }
        return n
    }

    // MARK: Lists / calendars

    /// Every list or calendar Blob can write into (iCloud, Google, Exchange/Outlook, Yahoo… whatever is added to this device).
    nonisolated static func writableCalendars(_ ek: EKEventStore, _ type: EKEntityType) -> [EKCalendar] {
        ek.calendars(for: type).filter(\.allowsContentModifications)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    /// The list/calendar you picked, or Blob's own one.
    private func calendar(for type: EKEntityType, id: String?) throws -> EKCalendar {
        if let id, let c = ek.calendar(withIdentifier: id), c.allowsContentModifications { return c }
        return try blobCalendar(for: type)
    }

    /// After you switch lists/calendars, Blob's items in the old one are removed (they're recreated in the new one).
    private func moveOffOtherCalendars(type: EKEntityType, keeping: EKCalendar?, setting: String, prefix: String = "blob://",
                                       except: EKCalendar? = nil) async throws {
        let last = state[setting]
        guard last != keeping?.calendarIdentifier else { return }
        defer { state[setting] = keeping?.calendarIdentifier }
        guard last != nil else { return }      // first run: nothing to clean up
        let others = ek.calendars(for: type).filter {
            $0.calendarIdentifier != keeping?.calendarIdentifier && $0.calendarIdentifier != except?.calendarIdentifier && $0.allowsContentModifications
        }
        guard !others.isEmpty else { return }
        if type == .reminder {
            let all = await fetchReminders(in: others)
            for r in all where r.url?.absoluteString.hasPrefix(prefix) == true {
                try? ek.remove(r, commit: false); dirty = true
            }
            // The old "Blob" list from before Homework existed — remove it once it's empty.
            for c in others where c.title == Self.calendarName {
                let left = all.filter { $0.calendar == c && !($0.url?.absoluteString.hasPrefix(prefix) ?? false) }
                if left.isEmpty { try? ek.removeCalendar(c, commit: false); dirty = true }
            }
        } else {
            let from = Date().addingTimeInterval(-90 * 86_400), to = Date().addingTimeInterval(400 * 86_400)
            for e in ek.events(matching: ek.predicateForEvents(withStart: from, end: to, calendars: others))
            where e.url?.absoluteString.hasPrefix(prefix) == true {
                try? ek.remove(e, span: .futureEvents, commit: false); dirty = true
            }
        }
    }

    private func blobCalendar(for type: EKEntityType) throws -> EKCalendar {
        let name = type == .reminder ? Self.homeworkListName : Self.calendarName
        if let c = ek.calendars(for: type).first(where: { $0.title == name && $0.allowsContentModifications }) { return c }
        // Some accounts (school Google, Exchange) don't let apps add calendars — try iCloud, then the default account, then On My Mac.
        let defaultSource = type == .reminder ? ek.defaultCalendarForNewReminders()?.source : ek.defaultCalendarForNewEvents?.source
        let candidates = [ek.sources.first { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") }, defaultSource,
                          ek.sources.first { $0.sourceType == .local }] + ek.sources.map { Optional($0) }
        var tried = Set<String>()
        for case let source? in candidates where tried.insert(source.sourceIdentifier).inserted {
            guard !source.calendars(for: type).isEmpty || source.sourceType == .local else { continue }
            let cal = EKCalendar(for: type, eventStore: ek)
            cal.title = name
            cal.cgColor = CGColor(red: 0.0, green: 0.78, blue: 0.95, alpha: 1)   // Blob cyan
            cal.source = source
            if (try? ek.saveCalendar(cal, commit: true)) != nil { return cal }
        }
        // Nowhere allows a new one → use your main list/calendar.
        if let fallback = type == .reminder ? ek.defaultCalendarForNewReminders() : ek.defaultCalendarForNewEvents,
           fallback.allowsContentModifications { return fallback }
        throw EKError(.calendarIsImmutable)
    }

    // MARK: Assignments → Reminders (shown in Calendar)

    private func fetchReminders(in cals: [EKCalendar]) async -> [EKReminder] {
        let predicate = ek.predicateForReminders(in: cals)
        return await withCheckedContinuation { cont in
            ek.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
    }

    private func syncReminders(_ tasks: [BrainTask], list: EKCalendar, includeSteps: Bool, importNew: Bool,
                               into result: inout Result) async throws {
        var existing: [String: EKReminder] = [:]
        var wanted = Set<String>()
        let known = Set(tasks.map(\.id))
        for r in await fetchReminders(in: [list]) {
            guard let key = r.url?.absoluteString, key.hasPrefix("blob://") else {
                // Added by you in Reminders → becomes an assignment (same id on every device, so no doubles).
                guard importNew, !r.isCompleted, let title = r.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { continue }
                let id = UUID.stable(from: "reminder:\(r.calendarItemExternalIdentifier ?? r.calendarItemIdentifier)")
                let key = "blob://task/\(id.uuidString)"
                r.url = URL(string: key)
                try? ek.save(r, commit: false); dirty = true
                existing[key] = r
                wanted.insert(key)
                if !known.contains(id) {
                    result.imported.append(ImportedReminder(id: id, title: title, due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                                                            notes: r.notes, isCompleted: false, highPriority: (1...4).contains(r.priority)))
                }
                continue
            }
            if existing[key] != nil { try ek.remove(r, commit: false); dirty = true; continue }   // duplicate from another device
            existing[key] = r
        }

        let recent = Date().addingTimeInterval(-14 * 86_400)
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
                    result.dueChanged.append(DueChange(task: t.id, due: d))
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
                    result.stepsDoneInApple.append(StepDone(task: t.id, step: m.id))
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

    // MARK: Assignment due dates → any calendar you pick

    private func syncDueDates(_ tasks: [BrainTask], calendar cal: EKCalendar, includeSteps: Bool, into result: inout Result) {
        let from = Date().addingTimeInterval(-30 * 86_400), to = Date().addingTimeInterval(400 * 86_400)
        var existing: [String: EKEvent] = [:]
        for e in ek.events(matching: ek.predicateForEvents(withStart: from, end: to, calendars: [cal])) {
            guard let key = e.url?.absoluteString, key.hasPrefix("blob://due/") else { continue }
            if existing[key] != nil { try? ek.remove(e, span: .thisEvent, commit: false); dirty = true; continue }
            existing[key] = e
        }
        var wanted = Set<String>()
        for t in tasks where !t.deleted && !t.isCompleted {
            guard let due = t.due, due > from else { continue }
            let key = "blob://due/\(t.id.uuidString)"
            wanted.insert(key)
            // Dragged to another day in Calendar → that's the new due date.
            if let e = existing[key], (e.lastModifiedDate ?? .distantPast) > t.updatedAt.addingTimeInterval(1) {
                let moved = Self.isEndOfDay(due) ? !Calendar.current.isDate(e.startDate, inSameDayAs: due) : abs(e.endDate.timeIntervalSince(due)) > 60
                if moved {
                    let start: Date = e.startDate, end: Date = e.endDate
                    let newDue: Date = e.isAllDay ? (Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: start) ?? start) : end
                    result.dueChanged.append(DueChange(task: t.id, due: newDue))
                    continue
                }
            }
            var lines = [t.course, t.isLongTerm ? "\(Int(t.progress * 100))% done · \(t.pace().label)" : nil, t.link].compactMap { $0 }
            lines.append(key)
            writeDue(existing[key], calendar: cal, key: key, title: "📚 Due: \(t.title)", due: due, notes: lines.joined(separator: "\n"))
            guard includeSteps else { continue }
            for m in t.milestones where !m.isDone {
                guard let d = m.due, d > from else { continue }
                let mkey = "blob://due/\(t.id.uuidString)/step/\(m.id.uuidString)"
                wanted.insert(mkey)
                writeDue(existing[mkey], calendar: cal, key: mkey, title: "↳ \(m.title) — \(t.title)", due: d,
                         notes: "Step of \(t.title)" + (t.course.map { " · \($0)" } ?? "") + "\n\(mkey)", allDay: true)
            }
        }
        for (key, e) in existing where !wanted.contains(key) { try? ek.remove(e, span: .thisEvent, commit: false); dirty = true }
    }

    nonisolated static func isEndOfDay(_ d: Date) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour == 23 && (c.minute ?? 0) >= 59) || (c.hour == 0 && c.minute == 0)
    }

    /// Due at a set time → a 30-minute marker ending then; due "that day" → an all-day event.
    private func writeDue(_ found: EKEvent?, calendar: EKCalendar, key: String, title: String, due: Date, notes: String, allDay: Bool? = nil) {
        let isAllDay = allDay ?? Self.isEndOfDay(due)
        let start = isAllDay ? Calendar.current.startOfDay(for: due) : due.addingTimeInterval(-30 * 60)
        let end = isAllDay ? Calendar.current.date(byAdding: .day, value: 1, to: start)! : due
        if let e = found, e.title == title, e.isAllDay == isAllDay, e.notes == notes,
           isAllDay ? Calendar.current.isDate(e.startDate, inSameDayAs: start) : (e.startDate == start && e.endDate == end) { return }
        let e = found ?? EKEvent(eventStore: ek)
        if found == nil { e.calendar = calendar }
        e.title = title
        e.url = URL(string: key)
        e.notes = notes
        e.isAllDay = isAllDay
        e.startDate = start
        e.endDate = end
        e.availability = .free          // a due date isn't time you're busy
        try? ek.save(e, span: .thisEvent, commit: false); dirty = true
    }

    private func syncEvents(_ events: [BrainEvent], calendar cal: EKCalendar, into result: inout Result) throws {
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
