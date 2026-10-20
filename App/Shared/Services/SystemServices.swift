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
            MainActor.assumeIsolated {
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
        return store.events(matching: predicate).map { e in
            EventOccurrence(id: "ek:\(e.calendarItemIdentifier)@\(Int(e.startDate.timeIntervalSince1970))", eventID: nil,
                            title: e.title ?? "Busy", start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                            location: e.location, externalCalendar: e.calendar.title,
                            colorHex: e.calendar.cgColor.flatMap(Self.hex))
        }
    }

    private static func hex(_ c: CGColor) -> String? {
        guard let comps = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              comps.count >= 3 else { return nil }
        return String(format: "#%02X%02X%02X", Int(comps[0] * 255), Int(comps[1] * 255), Int(comps[2] * 255))
    }
}

/// Local reminders: a heads-up before events and when each planned work block starts.
enum Reminders {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func reschedule(events: [EventOccurrence], blocks: [PlanBlock], leadMinutes: Int) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()
        var requests: [UNNotificationRequest] = []

        for e in events where !e.isAllDay {
            let fire = e.start.addingTimeInterval(-Double(leadMinutes) * 60)
            guard fire > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = e.title
            content.body = "Starts at \(e.start.formatted(date: .omitted, time: .shortened))" + (e.location.map { " · \($0)" } ?? "")
            content.sound = .default
            requests.append(request(id: "event-\(e.id)", at: fire, content: content))
        }
        for b in blocks where b.kind == .task && !b.isDone && b.start > now {
            let content = UNMutableNotificationContent()
            content.title = "Time for: \(b.title)"
            content.body = [b.subtitle, "\(b.minutes) min"].compactMap { $0 }.joined(separator: " · ")
            content.sound = .default
            requests.append(request(id: "block-\(b.id)", at: b.start, content: content))
        }
        // iOS allows 64 pending notifications.
        for r in requests.sorted(by: { fireDate($0) < fireDate($1) }).prefix(60) { center.add(r) }
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
