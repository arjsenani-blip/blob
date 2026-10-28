import Foundation
import EventKit
import UserNotifications
import BrainCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Optional read-only overlay of Apple Calendar (which can include your Google/iCloud calendars),
/// so the planner never schedules homework on top of something you already have.
@MainActor
final class SystemCalendarBridge: ObservableObject {
    let store = EKEventStore()
    @Published private(set) var authorized = false
    @Published var remindersAuthorized = false
    @Published private(set) var changeToken = 0
    /// Called when something changes in Calendar or Reminders (e.g. you tick off a task there).
    var onExternalChange: (() -> Void)?

    init() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remindersAuthorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.changeToken += 1
                self?.onExternalChange?()
            }
        }
    }

    func requestRemindersAccess() async {
        remindersAuthorized = (try? await store.requestFullAccessToReminders()) ?? false
    }

    func requestAccess() async {
        authorized = (try? await store.requestFullAccessToEvents()) ?? false
    }

    func occurrences(in range: DateInterval) -> [EventOccurrence] {
        guard authorized else { return [] }
        // Blob's own calendar is already shown from Blob's data.
        let calendars = store.calendars(for: .event).filter { $0.title != AppleSync.calendarName }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
        // Blob's own items (events, due dates) can live in any calendar now — they're already shown from Blob's data.
        return store.events(matching: predicate).filter { !($0.url?.absoluteString.hasPrefix("blob://") ?? false) }.map { e in
            EventOccurrence(id: "ek:\(e.calendarItemIdentifier)@\(Int(e.startDate.timeIntervalSince1970))", eventID: nil,
                            title: e.title ?? "Busy", start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                            location: e.location, externalCalendar: e.calendar.title,
                            colorHex: e.calendar.cgColor.flatMap(Self.hex))
        }
    }

    struct EditProblem: LocalizedError {
        var errorDescription: String?
    }

    /// The calendar event behind an occurrence id ("ek:<item>@<start>"), the right occurrence of a repeating one.
    private func ekEvent(_ occurrenceID: String) -> EKEvent? {
        guard occurrenceID.hasPrefix("ek:"), let at = occurrenceID.lastIndex(of: "@"),
              let ts = TimeInterval(occurrenceID[occurrenceID.index(after: at)...]) else { return nil }
        let itemID = String(occurrenceID[occurrenceID.index(occurrenceID.startIndex, offsetBy: 3)..<at])
        guard let item = store.calendarItem(withIdentifier: itemID) as? EKEvent else { return nil }
        guard item.hasRecurrenceRules else { return item }
        let start = Date(timeIntervalSince1970: ts)
        let p = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(86_400), calendars: [item.calendar])
        return store.events(matching: p).first { $0.calendarItemIdentifier == itemID && abs($0.startDate.timeIntervalSince(start)) < 60 } ?? item
    }

    /// Change one event in Apple Calendar (which writes through to Google). Only this occurrence of a repeating event.
    /// Returns the new occurrence id.
    func update(_ occurrenceID: String, title: String? = nil, start: Date? = nil, end: Date? = nil, allDay: Bool? = nil, location: String? = nil) throws -> String {
        guard authorized, let ev = ekEvent(occurrenceID) else { throw EditProblem(errorDescription: "I couldn't find that event in your calendar.") }
        guard ev.calendar.allowsContentModifications else {
            throw EditProblem(errorDescription: "“\(ev.title ?? "That event")” is on \(ev.calendar.title), which can't be edited from here.")
        }
        if let title { ev.title = title }
        if let allDay { ev.isAllDay = allDay }
        if let start { ev.startDate = start }
        if let end { ev.endDate = end }
        if let location { ev.location = location.isEmpty ? nil : location }
        do {
            try store.save(ev, span: .thisEvent, commit: true)
        } catch {
            throw EditProblem(errorDescription: "Calendar wouldn't save “\(ev.title ?? "that event")” — it may be an invite someone else owns.")
        }
        changeToken += 1
        return "ek:\(ev.calendarItemIdentifier)@\(Int(ev.startDate.timeIntervalSince1970))"
    }

    private static func hex(_ c: CGColor) -> String? {
        guard let comps = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              comps.count >= 3 else { return nil }
        return String(format: "#%02X%02X%02X", Int(comps[0] * 255), Int(comps[1] * 255), Int(comps[2] * 255))
    }
}

/// Notifications on this device (Mac and iPhone each schedule their own):
/// homework due tonight / tomorrow / within the hour, long-term steps due today, a morning summary,
/// and planned focus blocks. Event alerts are off by default — your calendar app already sends those,
/// and doubling them is what made notifications repeat. Blob's Pomodoro timer manages its own notification.
enum Reminders {
    struct Settings {
        var tasks = true
        var dueTodayHour = 16
        var dueTomorrowHour = 19
        var morningDigest = true
        var digestHour = 7
        var events = false
        var eventLead = 10
    }

    static let prefix = "blob-"

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor
    static func reschedule(tasks: [BrainTask], blocks: [PlanBlock], events: [EventOccurrence], routines: [DailyRoutine] = [], settings s: Settings) {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let cal = Calendar.current
        var requests: [UNNotificationRequest] = []
        func add(_ id: String, at date: Date, title: String, body: String, urgent: Bool = false) {
            guard date > now.addingTimeInterval(5) else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            c.threadIdentifier = "homework"
            if urgent { c.interruptionLevel = .timeSensitive }
            requests.append(request(id: prefix + id, at: date, content: c))
        }
        func at(_ hour: Int, on day: Date) -> Date { cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)! }

        let open = tasks.filter { !$0.isCompleted && !$0.deleted }
        if s.tasks {
            for t in open {
                guard let due = t.due, due > now, due < now.addingTimeInterval(14 * 86_400) else { continue }
                let emoji = t.looksLikeSchoolwork ? "📚" : "✅"
                let course = t.course.map { " (\($0))" } ?? ""
                let left = t.remainingMinutes >= 20 ? " About \(Scheduler.durationText(t.remainingMinutes)) of work left." : ""
                let dueDay = cal.startOfDay(for: due)
                if AppleSync.isEndOfDay(due) {
                    add("today-\(t.id)", at: at(s.dueTodayHour, on: dueDay), title: "\(emoji) Due tonight: \(t.title)", body: "Due by the end of today\(course).\(left)", urgent: true)
                } else {
                    add("hour-\(t.id)", at: due.addingTimeInterval(-3600), title: "\(emoji) Due in 1 hour: \(t.title)",
                        body: "Due at \(due.formatted(date: .omitted, time: .shortened))\(course).\(left)", urgent: true)
                    if cal.component(.hour, from: due) >= 12 {
                        add("today-\(t.id)", at: at(min(s.dueTodayHour, cal.component(.hour, from: due) - 2), on: dueDay),
                            title: "\(emoji) Due today: \(t.title)", body: "Due at \(due.formatted(date: .omitted, time: .shortened))\(course).\(left)")
                    }
                }
                let dayBefore = cal.date(byAdding: .day, value: -1, to: dueDay)!
                add("tomorrow-\(t.id)", at: at(s.dueTomorrowHour, on: dayBefore), title: "\(emoji) Due tomorrow: \(t.title)",
                    body: (t.loggedMinutes > 0 ? "\(Int(t.progress * 100))% done." : "Not started yet.") + left + course)
                // Long-term: each step on its day.
                for m in t.milestones where !m.isDone {
                    guard let md = m.due, md > now, cal.startOfDay(for: md) != dueDay else { continue }
                    add("step-\(m.id)", at: at(s.dueTodayHour, on: cal.startOfDay(for: md)), title: "🧭 Step due today: \(m.title)",
                        body: "For \(t.title). Keeps you on pace.")
                }
            }
            // Planned focus blocks from your check-in.
            for b in blocks where b.kind == .task && !b.isDone && b.start > now {
                add("block-\(b.id)", at: b.start, title: "🍅 Time for: \(b.title)", body: [b.subtitle, "\(b.minutes) min"].compactMap { $0 }.joined(separator: " · "))
            }
        }
        if s.morningDigest {
            for offset in 0..<7 {
                let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))!
                let next = cal.date(byAdding: .day, value: 1, to: day)!
                let dueThatDay = open.filter { $0.due.map { $0 >= day && $0 < next } ?? false }
                let evs = events.filter { !$0.isAllDay && $0.start >= day && $0.start < next }
                guard !dueThatDay.isEmpty || !evs.isEmpty else { continue }
                var body: [String] = []
                if !dueThatDay.isEmpty { body.append("Due: " + dueThatDay.prefix(3).map(\.title).joined(separator: ", ") + (dueThatDay.count > 3 ? " +\(dueThatDay.count - 3)" : "")) }
                if let e = evs.first { body.append("First up: \(e.title) at \(e.start.formatted(date: .omitted, time: .shortened))") }
                add("digest-\(Int(day.timeIntervalSince1970))", at: at(s.digestHour, on: day),
                    title: "☀️ Today: \(dueThatDay.count) due · \(evs.count) event\(evs.count == 1 ? "" : "s")", body: body.joined(separator: "\n"))
            }
        }
        // Routines: a nudge when each one starts, for the next few days.
        for r in routines where r.remind && !r.deleted {
            for offset in 0..<3 {
                let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))!
                guard r.runs(on: day), let first = r.timeline(on: day).first else { continue }
                let steps = r.steps.prefix(3).map(\.title).joined(separator: ", ")
                add("routine-\(r.id)-\(offset)", at: first.start, title: "🌙 Time for your \(r.name.lowercased())",
                    body: steps + (r.steps.count > 3 ? " and \(r.steps.count - 3) more" : "") + " · \(Scheduler.durationText(r.totalMinutes))")
            }
        }
        if s.events {
            for e in events where !e.isAllDay {
                add("event-\(e.id)", at: e.start.addingTimeInterval(-Double(s.eventLead) * 60), title: e.title,
                    body: "Starts at \(e.start.formatted(date: .omitted, time: .shortened))" + (e.location.map { " · \($0)" } ?? ""))
            }
        }

        // Replace only Blob's own scheduled notifications (older versions used other ids; clear those too).
        center.getPendingNotificationRequests { pending in
            let old = pending.map(\.identifier).filter { $0 != "pomodoro" && !$0.hasPrefix("buddy-timer") }
            center.removePendingNotificationRequests(withIdentifiers: old)
            // iOS keeps at most 64 pending; the soonest matter most.
            for r in requests.sorted(by: { fireDate($0) < fireDate($1) }).prefix(58) { center.add(r) }
        }
    }

    private static func request(id: String, at date: Date, content: UNNotificationContent) -> UNNotificationRequest {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return UNNotificationRequest(identifier: id, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
    }

    private static func fireDate(_ r: UNNotificationRequest) -> Date {
        (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
    }
}

enum Platform {
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
