import Foundation
import FoundationModels
import BrainCore

/// Blob's assistant: Apple's on-device model (free, private, nothing leaves the device) with tools to read
/// your day and add, move, resize, finish or remove things. Every change it makes can be undone.
@MainActor
final class BlobAssistant: ObservableObject {
    static let shared = BlobAssistant()

    struct Message: Identifiable {
        let id = UUID()
        var fromUser: Bool
        var text: String
        var changes: [UUID] = []
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var thinking = false
    @Published private(set) var undone: Set<UUID> = []
    let desk = AssistantDesk()
    private var session: LanguageModelSession?
    private var lastUsed = Date.distantPast

    weak var store: BrainStore? {
        didSet { desk.store = store }
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This device doesn't support Apple Intelligence, so I can only add things."
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings and I can also answer questions and edit things. For now I can add things."
            case .modelNotReady: return "Apple Intelligence is still downloading. Until it's ready I can only add things."
            @unknown default: return "Apple Intelligence isn't available, so I can only add things."
            }
        }
    }

    func change(_ id: UUID) -> AssistantChange? { desk.changes.first { $0.id == id } }

    func undo(_ id: UUID) {
        guard let c = change(id), !undone.contains(id) else { return }
        c.undo()
        undone.insert(id)
    }

    func clear() {
        messages = []
        session = nil
        desk.refs = [:]
    }

    func prewarm() {
        guard Self.isAvailable else { return }
        if session == nil { session = makeSession() }
        session?.prewarm()
    }

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking, let store else { return }
        messages.append(Message(fromUser: true, text: text))
        thinking = true
        defer { thinking = false }
        let before = desk.changes.count
        desk.userText = text
        var reply: String
        if Self.isAvailable {
            reply = await respond(to: text)
        } else {
            let title = store.add(store.parse(text))
            reply = "Added “\(title)”."
        }
        let made = desk.changes[before...].map(\.id)
        if reply.isEmpty { reply = made.isEmpty ? "Hmm, I'm not sure. Try saying it another way?" : "Done." }
        messages.append(Message(fromUser: false, text: reply, changes: made))
    }

    private func respond(to text: String) async -> String {
        // Start fresh after a long pause; the on-device model has a small memory.
        if session == nil || Date().timeIntervalSince(lastUsed) > 15 * 60 { session = makeSession(); desk.refs = [:] }
        lastUsed = Date()
        let prompt = "(Now: \(Date().formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute())), today is \(AssistantDesk.isoDay(Date())).)\n" + text
        do {
            return try await session!.respond(to: prompt).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            session = makeSession()
            desk.refs = [:]
            return (try? await session!.respond(to: prompt).content) ?? "Sorry, that was too much for me at once. Try a shorter request?"
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            return "I can't help with that one."
        } catch {
            return "Sorry — something went wrong (\(error.localizedDescription))."
        }
    }

    private func makeSession() -> LanguageModelSession {
        let d = desk
        let tools: [any Tool] = [
            ScheduleTool(desk: d), FindTool(desk: d), AddEventTool(desk: d), AddTodoTool(desk: d),
            EditEventTool(desk: d), EditTodoTool(desk: d), CompleteTodoTool(desk: d), DeleteTool(desk: d),
        ]
        return LanguageModelSession(tools: tools, instructions: """
            You are Blob, the assistant inside a high school student's calendar and homework app. Reply in one or two short, friendly sentences. No lists, no markdown.
            Use your tools to look things up and to make changes. Never say you changed something unless a tool did it, and say exactly what the tool reported.
            To change, check off or delete something, find it first with find_items or get_schedule, then call the right tool with its code (like E2 or T5). When the user says they finished something, call complete_todo.
            Homework, chores, errands, sign-ups and anything to get done are to-dos (add_todo). Things that happen at a time or place are events (add_event).
            Titles keep the user's words for what to do, like "Sign up for debate tournament", not just "Debate tournament".
            When editing, fill in only what the user asked to change and leave every other field empty or 0.
            Leave minutes as 0 when the user didn't say how long, and Blob will estimate.
            For days, copy the user's own words ("monday", "tomorrow", "next friday", "nov 3") instead of working out the date. Times are 24-hour HH:MM.
            """)
    }
}

/// One thing the assistant changed, with how to put it back.
struct AssistantChange: Identifiable {
    let id = UUID()
    var summary: String
    var undo: () -> Void
}

/// What the tools work on: your data, plus short codes (E1, T3) for the things the model has seen.
@MainActor
final class AssistantDesk {
    enum Ref { case event(EventOccurrence), task(UUID) }
    weak var store: BrainStore?
    var refs: [String: Ref] = [:]
    /// What the user just said. The small model sometimes makes up codes or fills in fields nobody asked to change,
    /// so lookups fall back to these words, and renames and moves need them to ask for it.
    var userText = ""
    private(set) var changes: [AssistantChange] = []
    private var counter = 0
    private let cal = Calendar.current

    // MARK: Codes and lines

    private func code(_ ref: Ref) -> String {
        if let hit = refs.first(where: { same($0.value, ref) }) { return hit.key }
        counter += 1
        let c: String
        switch ref {
        case .event: c = "E\(counter)"
        case .task: c = "T\(counter)"
        }
        refs[c] = ref
        return c
    }

    private func same(_ a: Ref, _ b: Ref) -> Bool {
        switch (a, b) {
        case (.event(let x), .event(let y)): return x.id == y.id
        case (.task(let x), .task(let y)): return x == y
        default: return false
        }
    }

    private func editable(_ o: EventOccurrence) -> Bool { o.eventID != nil || o.id.hasPrefix("ek:") }

    func line(_ o: EventOccurrence) -> String {
        let day = o.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let when = o.isAllDay ? "all day" : "\(o.start.formatted(date: .omitted, time: .shortened))–\(o.end.formatted(date: .omitted, time: .shortened)) (\(Scheduler.durationText(Int(o.end.timeIntervalSince(o.start) / 60))))"
        let where_ = o.location.map { " at \($0)" } ?? ""
        return "\(code(.event(o))): event · \(day) \(when) · \(o.title)\(where_)" + (o.externalCalendar.map { " [\($0) calendar]" } ?? "") + (editable(o) ? "" : " [read-only]")
    }

    func line(_ t: BrainTask) -> String {
        let due = t.due.map { "due " + $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) } ?? "no due date"
        return "\(code(.task(t.id))): to-do · \(due) · \(t.title) · about \(Scheduler.durationText(t.estimatedMinutes))" + (t.isCompleted ? " · done" : "")
    }

    // MARK: Reading

    func schedule(from dateText: String, days: Int) -> String {
        guard let store else { return "Unavailable." }
        let start = day(dateText) ?? cal.startOfDay(for: Date())
        let n = min(max(days, 1), 7)
        let end = cal.date(byAdding: .day, value: n, to: start)!
        let evs = store.occurrences(in: DateInterval(start: start, end: end))
        var tasks = store.tasks.filter { t in t.due.map { $0 >= start && $0 < end } ?? false }
        if cal.isDateInToday(start) { tasks += store.tasks.filter { !$0.isCompleted && ($0.due ?? .distantFuture) < start } }
        tasks.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        let lines = evs.map(line) + tasks.prefix(25).map(line)
        return lines.isEmpty ? "Nothing scheduled and nothing due." : lines.joined(separator: "\n")
    }

    func find(_ query: String) -> String {
        let hits = search(query, limit: 8)
        return hits.isEmpty ? "Nothing matches “\(query)”." : "Use these codes with complete_todo, edit_todo, edit_event or delete_item:\n" + hits.map { r -> String in
            switch r {
            case .event(let o): return line(o)
            case .task(let id): return store?.task(id).map(line) ?? ""
            }
        }.joined(separator: "\n")
    }

    private func search(_ query: String, limit: Int) -> [Ref] {
        guard let store else { return [] }
        let stop: Set<String> = ["the", "my", "a", "an", "to", "for", "and", "it", "is", "i", "im", "i'm", "done", "with", "finished", "finish",
                                 "make", "take", "takes", "move", "push", "delete", "remove", "mark", "set", "on", "at", "of", "that", "this",
                                 "minutes", "min", "mins", "hour", "hours", "today", "tomorrow", "please", "can", "you", "just"]
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 && !stop.contains($0) }
        guard !words.isEmpty else { return [] }
        func score(_ title: String) -> Int {
            let t = title.lowercased()
            return words.reduce(0) { $0 + (t.contains($1) ? 1 : 0) }
        }
        let now = Date()
        let evs = store.occurrences(in: DateInterval(start: now.addingTimeInterval(-7 * 86_400), duration: 67 * 86_400))
            .map { (Ref.event($0), score($0.title), abs($0.start.timeIntervalSince(now)), $0.end > now) }
        let ts = store.tasks.filter { !$0.isCompleted || ($0.completedAt ?? .distantPast) > now.addingTimeInterval(-7 * 86_400) }
            .map { (Ref.task($0.id), score($0.title), abs(($0.due ?? now).timeIntervalSince(now)), !$0.isCompleted) }
        // Best match first; among equals, the next upcoming one, then the most recent.
        return (evs + ts).filter { $0.1 > 0 }.sorted { ($0.1, $0.3 ? 1 : 0, -$0.2) > ($1.1, $1.3 ? 1 : 0, -$1.2) }.prefix(limit).map(\.0)
    }

    /// A code the model saw, or failing that the closest match by name, or by what the user said.
    private func resolve(_ item: String, allowGuess: Bool = true) -> Ref? {
        let key = item.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let r = refs[key] { return r }
        if let r = search(item, limit: 1).first { return r }
        return allowGuess ? search(userText, limit: 1).first : nil
    }

    private func userAsks(_ pattern: String) -> Bool {
        userText.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private var asksRename: Bool { userAsks(#"\b(rename|call it|retitle|change the (name|title)|name it)\b"#) }
    private var asksDay: Bool {
        userAsks(#"\b(today|tonight|tomorrow|tmrw|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun|\w+day|next|week|weekend|jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|postpone|reschedule|delay|\d{1,2}/\d{1,2})\b"#)
    }
    private var asksTime: Bool {
        userAsks(#"(\d{1,2}(:\d{2})?\s*(am|pm)\b|\b\d{1,2}:\d{2}\b|\b(noon|midnight|morning|afternoon|evening|tonight|earlier|later)\b)"#)
    }


    // MARK: Dates

    static func isoDay(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// "2026-10-30", or anything quick add understands ("friday", "tomorrow").
    func day(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: "-").compactMap { Int($0) }
        if parts.count == 3, let d = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) { return d }
        return NaturalLanguageParser().parse("x " + t).start.map { cal.startOfDay(for: $0) }
    }

    /// "18:30", "6:30pm", "6pm".
    func time(_ s: String) -> (Int, Int)? {
        let t = s.lowercased().replacingOccurrences(of: " ", with: "")
        guard let m = t.firstMatch(of: /^(\d{1,2})(?::(\d{2}))?(am|pm)?$/) else { return nil }
        var h = Int(m.1) ?? 0
        let min = m.2.flatMap { Int($0) } ?? 0
        if m.3 == "pm", h < 12 { h += 12 }
        if m.3 == "am", h == 12 { h = 0 }
        return (0...23).contains(h) && (0...59).contains(min) ? (h, min) : nil
    }

    private func at(_ day: Date, _ hm: (Int, Int)) -> Date { cal.date(bySettingHour: hm.0, minute: hm.1, second: 0, of: day)! }

    private func when(_ d: Date, allDay: Bool = false) -> String {
        let day = cal.isDateInToday(d) ? "today" : cal.isDateInTomorrow(d) ? "tomorrow" : d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return allDay ? day : "\(day) at \(d.formatted(date: .omitted, time: .shortened))"
    }

    private func record(_ summary: String, undo: @escaping () -> Void) -> String {
        changes.append(AssistantChange(summary: summary, undo: undo))
        return summary
    }

    // MARK: Changes

    private func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    func addEvent(title raw: String, date: String, time timeText: String, minutes: Int, location: String) -> String {
        let title = capitalized(raw.trimmingCharacters(in: .whitespaces))
        guard let store, !title.isEmpty else { return "Need a title." }
        let d = day(date) ?? cal.startOfDay(for: Date())
        let e: BrainEvent
        if let hm = time(timeText) {
            let start = at(d, hm)
            let m = minutes > 0 ? minutes : Estimates.eventMinutes(for: title)
            e = BrainEvent(title: title, start: start, end: start.addingTimeInterval(Double(m) * 60), location: location.isEmpty ? nil : location)
        } else {
            e = BrainEvent(title: title, start: d, end: cal.date(byAdding: .day, value: 1, to: d)!, isAllDay: true, location: location.isEmpty ? nil : location)
        }
        store.upsert(e)
        let id = e.id
        return record("Added event “\(title)” \(when(e.start, allDay: e.isAllDay))" + (e.isAllDay ? " (all day)" : " for \(Scheduler.durationText(Int(e.end.timeIntervalSince(e.start) / 60)))") + ".") {
            if let e = store.event(id) { store.delete(e) }
        }
    }

    func addTodo(title raw: String, dueDate: String, dueTime: String, minutes: Int) -> String {
        let title = capitalized(raw.trimmingCharacters(in: .whitespaces))
        guard let store, !title.isEmpty else { return "Need a title." }
        let d = day(dueDate)
        let due = d.map { at($0, time(dueTime) ?? (23, 59)) }
        let m = minutes > 0 ? minutes : Estimates.taskMinutes(for: title)
        let t = BrainTask(title: title, due: due, estimatedMinutes: m, estimateIsUserSet: minutes > 0)
        store.upsert(t)
        let id = t.id
        return record("Added to-do “\(title)”" + (due.map { ", due \(when($0, allDay: dueTime.isEmpty))" } ?? "") + ", about \(Scheduler.durationText(m)).") {
            if let t = store.task(id) { store.delete(t) }
        }
    }

    func editEvent(item: String, title: String, date: String, time timeText: String, minutes: Int, location: String) -> String {
        guard let store else { return "Unavailable." }
        guard case .event(let o)? = resolve(item) else { return "I couldn't find that event." }
        let newDay = (asksDay ? day(date) : nil) ?? cal.startOfDay(for: o.start)
        let hm = asksTime ? time(timeText) : nil
        let wasAllDay = o.isAllDay
        let allDay = wasAllDay && hm == nil
        let oldLength = o.end.timeIntervalSince(o.start)
        let length = minutes > 0 ? Double(minutes) * 60 : (wasAllDay && !allDay ? Double(Estimates.eventMinutes(for: o.title)) * 60 : oldLength)
        let start: Date = allDay ? newDay : at(newDay, hm ?? (cal.component(.hour, from: o.start), cal.component(.minute, from: o.start)))
        let end = allDay ? cal.date(byAdding: .day, value: max(1, Int((oldLength / 86_400).rounded())), to: start)! : start.addingTimeInterval(length)
        let newTitle = title.isEmpty || !asksRename || title.caseInsensitiveCompare(o.title) == .orderedSame ? nil : title
        let newLocation = location.isEmpty || location == o.location ? nil : location
        let name = newTitle ?? o.title
        let summary = "Changed “\(name)” to \(when(start, allDay: allDay))" + (allDay ? "" : " for \(Scheduler.durationText(Int(end.timeIntervalSince(start) / 60)))") + "."

        if let id = o.eventID, let e0 = store.event(id) {
            var e = e0
            e.start = e0.start.addingTimeInterval(start.timeIntervalSince(o.start))
            e.end = e.start.addingTimeInterval(end.timeIntervalSince(start))
            e.isAllDay = allDay
            if let newTitle { e.title = newTitle }
            if let newLocation { e.location = newLocation }
            store.upsert(e)
            return record(summary + (e0.recurrence.isRepeating ? " (every time it repeats)" : "")) { store.upsert(e0) }
        }
        guard o.id.hasPrefix("ek:"), !store.isTestData else { return "“\(o.title)” comes from a calendar I can only read, so I can't change it." }
        do {
            let newID = try store.systemCalendar.update(o.id, title: newTitle, start: start, end: end, allDay: allDay, location: newLocation)
            let moved = EventOccurrence(id: newID, eventID: nil, title: name, start: start, end: end, isAllDay: allDay,
                                        location: newLocation ?? o.location, externalCalendar: o.externalCalendar, colorHex: o.colorHex)
            if let k = refs.first(where: { same($0.value, .event(o)) })?.key { refs[k] = .event(moved) }
            return record(summary) {
                _ = try? store.systemCalendar.update(newID, title: newTitle == nil ? nil : o.title, start: o.start, end: o.end,
                                                     allDay: wasAllDay, location: newLocation == nil ? nil : (o.location ?? ""))
            }
        } catch {
            return error.localizedDescription
        }
    }

    func editTodo(item: String, title: String, dueDate: String, dueTime: String, minutes: Int, status: String) -> String {
        guard let store else { return "Unavailable." }
        guard case .task(let id)? = resolve(item), let t0 = store.task(id) else { return "I couldn't find that to-do." }
        var t = t0
        var said: [String] = []
        // The model often repeats the current values; only real differences count.
        if !title.isEmpty, asksRename, title.caseInsensitiveCompare(t.title) != .orderedSame { t.title = title; said.append("renamed it") }
        // Checking something off never moves it, whatever dates came along.
        if status.isEmpty, asksDay || asksTime, !dueDate.isEmpty || !dueTime.isEmpty {
            let d = (asksDay ? day(dueDate) : nil) ?? cal.startOfDay(for: t.due ?? Date())
            let hm = (asksTime ? time(dueTime) : nil) ?? t.due.map { (cal.component(.hour, from: $0), cal.component(.minute, from: $0)) } ?? (23, 59)
            let due = at(d, hm)
            if t.due.map({ abs($0.timeIntervalSince(due)) > 59 }) ?? true {
                t.due = due
                said.append("due \(when(due, allDay: hm == (23, 59)))")
            }
        }
        if minutes > 0, minutes != t.estimatedMinutes || !t.estimateIsUserSet {
            t.estimatedMinutes = minutes; t.estimateIsUserSet = true; said.append("about \(Scheduler.durationText(minutes))")
        }
        switch status.lowercased() {
        case "done": if !t.isCompleted { store.markDone(&t); said.append("checked off") }
        case "open": if t.isCompleted { t.isCompleted = false; t.completedAt = nil; said.append("reopened") }
        default: break
        }
        guard !said.isEmpty else { return "Nothing to change." }
        store.upsert(t)
        return record("“\(t.title)”: " + said.joined(separator: ", ") + ".") { store.upsert(t0) }
    }

    func delete(item: String) -> String {
        guard let store else { return "Unavailable." }
        switch resolve(item, allowGuess: false) {
        case .task(let id)?:
            guard let t = store.task(id) else { return "I couldn't find that." }
            store.delete(t)
            return record("Deleted to-do “\(t.title)”.") { var r = t; r.deleted = false; store.upsert(r) }
        case .event(let o)?:
            guard let id = o.eventID, let e = store.event(id) else {
                return "“\(o.title)” is on your \(o.externalCalendar ?? "other") calendar. Delete it in Calendar so nothing gets removed by mistake."
            }
            store.delete(e)
            return record("Deleted “\(e.title)”" + (e.recurrence.isRepeating ? " and its repeats" : "") + ".") { var r = e; r.deleted = false; store.upsert(r) }
        case nil:
            return "I couldn't find that."
        }
    }
}

// MARK: - Tools

struct ScheduleTool: Tool {
    let desk: AssistantDesk
    let name = "get_schedule"
    let description = "List events and to-dos for one or more days, each with a code, time and length."
    @Generable struct Arguments {
        @Guide(description: "First day in the user's words, like 'tomorrow'; empty for today") var date: String
        @Guide(description: "How many days", .range(1...7)) var days: Int
    }
    func call(arguments a: Arguments) async throws -> String { await desk.schedule(from: a.date, days: a.days) }
}

struct FindTool: Tool {
    let desk: AssistantDesk
    let name = "find_items"
    let description = "Search events and to-dos by name. Returns codes to use with edit and delete tools."
    @Generable struct Arguments { @Guide(description: "Words from the name, like 'fencing' or 'chem lab'") var query: String }
    func call(arguments a: Arguments) async throws -> String { await desk.find(a.query) }
}

struct AddEventTool: Tool {
    let desk: AssistantDesk
    let name = "add_event"
    let description = "Add something that happens at a time or place to the calendar."
    @Generable struct Arguments {
        @Guide(description: "Short title") var title: String
        @Guide(description: "Day in the user's words, like 'friday' or 'nov 3'") var date: String
        @Guide(description: "Start time HH:MM (24-hour); empty for all day") var time: String
        @Guide(description: "Length in minutes; 0 if not said") var minutes: Int
        @Guide(description: "Place; empty if none") var location: String
    }
    func call(arguments a: Arguments) async throws -> String {
        await desk.addEvent(title: a.title, date: a.date, time: a.time, minutes: a.minutes, location: a.location)
    }
}

struct AddTodoTool: Tool {
    let desk: AssistantDesk
    let name = "add_todo"
    let description = "Add a to-do: homework, chores, errands, sign-ups, anything to get done."
    @Generable struct Arguments {
        @Guide(description: "Short title") var title: String
        @Guide(description: "Due day in the user's words, like 'friday'; empty if none") var dueDate: String
        @Guide(description: "Due time HH:MM (24-hour); empty for end of day") var dueTime: String
        @Guide(description: "Minutes it takes; 0 if not said") var minutes: Int
    }
    func call(arguments a: Arguments) async throws -> String {
        await desk.addTodo(title: a.title, dueDate: a.dueDate, dueTime: a.dueTime, minutes: a.minutes)
    }
}

struct EditEventTool: Tool {
    let desk: AssistantDesk
    let name = "edit_event"
    let description = "Move an event, change how long it is, rename it or change its place. Empty or 0 keeps the current value."
    @Generable struct Arguments {
        @Guide(description: "The event's code, like E2") var item: String
        @Guide(description: "New title, or empty") var title: String
        @Guide(description: "New day in the user's words, like 'monday'; or empty") var date: String
        @Guide(description: "New start time HH:MM (24-hour), or empty") var time: String
        @Guide(description: "New length in minutes, or 0") var minutes: Int
        @Guide(description: "New place, or empty") var location: String
    }
    func call(arguments a: Arguments) async throws -> String {
        await desk.editEvent(item: a.item, title: a.title, date: a.date, time: a.time, minutes: a.minutes, location: a.location)
    }
}

struct EditTodoTool: Tool {
    let desk: AssistantDesk
    let name = "edit_todo"
    let description = "Change a to-do's title, due date or how long it takes, or reopen it. Empty or 0 keeps the current value."
    @Generable struct Arguments {
        @Guide(description: "The to-do's code, like T3") var item: String
        @Guide(description: "New title, or empty") var title: String
        @Guide(description: "New due day in the user's words, like 'monday'; or empty") var dueDate: String
        @Guide(description: "New due time HH:MM (24-hour), or empty") var dueTime: String
        @Guide(description: "New time it takes in minutes, or 0") var minutes: Int
        @Guide(description: "'open' to un-check it; otherwise empty", .anyOf(["", "open"])) var status: String
    }
    func call(arguments a: Arguments) async throws -> String {
        await desk.editTodo(item: a.item, title: a.title, dueDate: a.dueDate, dueTime: a.dueTime, minutes: a.minutes, status: a.status)
    }
}

struct CompleteTodoTool: Tool {
    let desk: AssistantDesk
    let name = "complete_todo"
    let description = "Check off a to-do the user finished."
    @Generable struct Arguments { @Guide(description: "The to-do's code, like T3") var item: String }
    func call(arguments a: Arguments) async throws -> String {
        await desk.editTodo(item: a.item, title: "", dueDate: "", dueTime: "", minutes: 0, status: "done")
    }
}

struct DeleteTool: Tool {
    let desk: AssistantDesk
    let name = "delete_item"
    let description = "Delete a to-do or an event Blob made. Only when the user asks to delete or remove it."
    @Generable struct Arguments { @Guide(description: "The code, like E2 or T3") var item: String }
    func call(arguments a: Arguments) async throws -> String { await desk.delete(item: a.item) }
}
