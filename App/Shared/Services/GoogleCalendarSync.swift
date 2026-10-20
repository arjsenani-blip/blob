import Foundation
import BrainCore

/// Google Calendar + Google Tasks:
/// - reads the calendars you have turned on in Google Calendar, so they show in Blob and the planner works around them;
/// - optionally writes Blob's events into your main Google calendar (fixed ids, so the Mac and iPhone never duplicate them);
/// - optionally writes assignments into a "Blob" Google Tasks list — Google Calendar shows those as tasks on their due dates,
///   and ticking one off there marks it done in Blob.
@MainActor
struct GoogleCalendarSync {
    let account: GoogleAccount

    // MARK: Reading calendars

    struct CachedEvent: Codable, Hashable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var location: String?
        var calendar: String
        var colorHex: String?
    }

    private struct CalendarList: Decodable { let items: [Cal]?; let nextPageToken: String? }
    private struct Cal: Decodable { let id: String; let summary: String?; let backgroundColor: String?; let selected: Bool?; let accessRole: String? }
    private struct EventList: Decodable { let items: [GEvent]?; let nextPageToken: String? }
    private struct GTime: Decodable { let dateTime: String?; let date: String? }
    private struct GEvent: Decodable {
        let id: String
        let status: String?
        let summary: String?
        let location: String?
        let start: GTime?
        let end: GTime?
        let transparency: String?
        let extendedProperties: Ext?
        struct Ext: Decodable { let `private`: [String: String]? }
    }

    func fetchEvents(from: Date, to: Date) async throws -> [CachedEvent] {
        let list: CalendarList = try await get("https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=100")
        let calendars = (list.items ?? []).filter { $0.selected ?? ($0.accessRole == "owner") }
        let iso = ISO8601DateFormatter()
        let tmin = iso.string(from: from), tmax = iso.string(from: to)
        var out: [CachedEvent] = []
        for c in calendars {
            var token: String?
            repeat {
                var url = "https://www.googleapis.com/calendar/v3/calendars/\(Self.escape(c.id))/events?singleEvents=true&orderBy=startTime&maxResults=250&timeMin=\(Self.escape(tmin))&timeMax=\(Self.escape(tmax))"
                if let token { url += "&pageToken=\(token)" }
                let page: EventList = try await get(url)
                for e in page.items ?? [] where e.status != "cancelled" {
                    // Skip Blob's own events (they're already in Blob).
                    if e.id.hasPrefix("blob") || e.extendedProperties?.private?["blob"] != nil { continue }
                    guard let (s, en, allDay) = Self.times(e.start, e.end) else { continue }
                    out.append(CachedEvent(id: "gcal:\(e.id)", title: e.summary ?? "Busy", start: s, end: en, isAllDay: allDay,
                                           location: e.location, calendar: c.summary ?? "Google Calendar", colorHex: c.backgroundColor))
                }
                token = page.nextPageToken
            } while token != nil && out.count < 3000
        }
        return out
    }

    private static func times(_ s: GTime?, _ e: GTime?) -> (Date, Date, Bool)? {
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let a = s?.dateTime, let start = iso.date(from: a) ?? isoFrac.date(from: a) {
            let end = e?.dateTime.flatMap { iso.date(from: $0) ?? isoFrac.date(from: $0) } ?? start.addingTimeInterval(3600)
            return (start, end, false)
        }
        if let a = s?.date, let start = day(a) {
            return (start, e?.date.flatMap(day) ?? start.addingTimeInterval(86_400), true)
        }
        return nil
    }

    private static func day(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    // MARK: Writing Blob's events

    /// Google accepts our own event ids (letters a–v and digits), so each Blob event has exactly one Google twin.
    static func googleID(_ id: UUID) -> String { "blob" + id.uuidString.lowercased().replacingOccurrences(of: "-", with: "") }

    /// Pushes events changed since the last push. `pushed` maps event id → the `updatedAt` last sent.
    func pushEvents(_ events: [BrainEvent], pushed: inout [String: Double]) async throws {
        let base = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
        for ev in events {
            let key = ev.id.uuidString
            let stamp = ev.updatedAt.timeIntervalSinceReferenceDate
            if let last = pushed[key], last >= stamp { continue }
            let gid = Self.googleID(ev.id)
            if ev.deleted {
                if pushed[key] != nil {
                    do { _ = try await send("DELETE", base + "/" + gid, body: nil) }
                    catch GoogleError.http(let c, _) where c == 404 || c == 410 {}
                }
                pushed[key] = stamp
                continue
            }
            let body = Self.body(for: ev, id: gid)
            do {
                _ = try await send("PUT", base + "/" + gid, body: body)
            } catch GoogleError.http(let c, _) where c == 404 {
                do { _ = try await send("POST", base, body: body) }
                catch GoogleError.http(let c2, _) where c2 == 409 {
                    // Deleted in Google earlier: the id is taken by a cancelled event — bring it back.
                    _ = try await send("PUT", base + "/" + gid, body: body.merging(["status": "confirmed"]) { $1 })
                }
            }
            pushed[key] = stamp
        }
    }

    private static func body(for ev: BrainEvent, id: String) -> [String: Any] {
        let tz = TimeZone.current.identifier
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        func dateOnly(_ d: Date) -> String {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        var b: [String: Any] = [
            "id": id,
            "summary": ev.title,
            "extendedProperties": ["private": ["blob": ev.id.uuidString]],
            "source": ["title": "Blob", "url": "https://github.com/arjsenani-blip/blob"],
        ]
        if let l = ev.location { b["location"] = l }
        if let n = ev.notes { b["description"] = n }
        if ev.isAllDay {
            let endDay = max(Calendar.current.startOfDay(for: ev.end), Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: ev.start))!)
            b["start"] = ["date": dateOnly(ev.start)]
            b["end"] = ["date": dateOnly(endDay)]
        } else {
            b["start"] = ["dateTime": iso.string(from: ev.start), "timeZone": tz]
            b["end"] = ["dateTime": iso.string(from: max(ev.end, ev.start.addingTimeInterval(60))), "timeZone": tz]
        }
        if let rule = rrule(ev) {
            var lines = [rule]
            if !ev.excludedDays.isEmpty {
                let fmt = DateFormatter()
                fmt.dateFormat = ev.isAllDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
                let comps = Calendar.current.dateComponents([.hour, .minute], from: ev.start)
                let stamps = ev.excludedDays.map { d -> String in
                    let at = Calendar.current.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: d) ?? d
                    return fmt.string(from: at)
                }
                lines.append(ev.isAllDay ? "EXDATE;VALUE=DATE:" + stamps.joined(separator: ",") : "EXDATE;TZID=\(tz):" + stamps.joined(separator: ","))
            }
            b["recurrence"] = lines
        }
        return b
    }

    private static func rrule(_ ev: BrainEvent) -> String? {
        let days = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        var r: String
        switch ev.recurrence.frequency {
        case .none: return nil
        case .daily: r = "RRULE:FREQ=DAILY"
        case .weekdays: r = "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        case .monthly: r = "RRULE:FREQ=MONTHLY"
        case .weekly:
            let w = ev.recurrence.weekdays.isEmpty ? [Calendar.current.component(.weekday, from: ev.start)] : ev.recurrence.weekdays.sorted()
            r = "RRULE:FREQ=WEEKLY;BYDAY=" + w.map { days[$0 - 1] }.joined(separator: ",")
        }
        if let until = ev.recurrence.until {
            let f = DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            r += ";UNTIL=" + f.string(from: Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: until) ?? until)
        }
        return r
    }

    // MARK: Assignments → Google Tasks

    private struct TaskLists: Decodable { let items: [TL]?; struct TL: Decodable { let id: String; let title: String? } }
    private struct GTasks: Decodable { let items: [GTask]?; let nextPageToken: String? }
    private struct GTask: Decodable { let id: String; let title: String?; let notes: String?; let status: String?; let due: String?; let updated: String?; let deleted: Bool? }

    struct TaskResult {
        var completedInGoogle: [UUID] = []
        var reopenedInGoogle: [UUID] = []
    }

    func syncTasks(_ tasks: [BrainTask]) async throws -> TaskResult {
        let lists: TaskLists = try await get("https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=100")
        let listID: String
        if let l = lists.items?.first(where: { $0.title == "Blob" }) {
            listID = l.id
        } else {
            let data = try await send("POST", "https://tasks.googleapis.com/tasks/v1/users/@me/lists", body: ["title": "Blob"])
            listID = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String) ?? ""
        }
        let base = "https://tasks.googleapis.com/tasks/v1/lists/\(Self.escape(listID))/tasks"

        // What's there now, keyed by the blob:// link in the notes (works across devices).
        var existing: [String: GTask] = [:]
        var token: String?
        repeat {
            var url = base + "?showCompleted=true&showHidden=true&maxResults=100"
            if let token { url += "&pageToken=\(token)" }
            let page: GTasks = try await get(url)
            for t in page.items ?? [] where t.deleted != true {
                guard let key = t.notes?.components(separatedBy: "\n").last, key.hasPrefix("blob://task/") else { continue }
                if existing[key] != nil { _ = try? await send("DELETE", base + "/" + t.id, body: nil); continue }
                existing[key] = t
            }
            token = page.nextPageToken
        } while token != nil

        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let recent = Date().addingTimeInterval(-14 * 86_400)
        var result = TaskResult()
        var wanted = Set<String>()
        for t in tasks {
            let key = "blob://task/\(t.id.uuidString)"
            guard !t.deleted, !t.isCompleted || (t.completedAt ?? .distantPast) > recent else { continue }
            wanted.insert(key)
            let g = existing[key]
            let gDone = g?.status == "completed"
            let gUpdated = g?.updated.flatMap { isoFrac.date(from: $0) ?? iso.date(from: $0) } ?? .distantPast
            if let g, gDone != t.isCompleted, gUpdated > t.updatedAt.addingTimeInterval(1) {
                if gDone { result.completedInGoogle.append(t.id) } else { result.reopenedInGoogle.append(t.id) }
                _ = g
                continue
            }
            var notes: [String] = []
            if let c = t.course { notes.append(c) }
            if t.isLongTerm && !t.isCompleted {
                notes.append("\(Int(t.progress * 100))% done · \(t.pace().label)" + (t.nextMilestone.map { " · next: \($0.title)" } ?? ""))
            }
            notes.append(key)
            var body: [String: Any] = ["title": t.title, "notes": notes.joined(separator: "\n"),
                                       "status": t.isCompleted ? "completed" : "needsAction"]
            // Google Tasks keeps only the date.
            if let d = t.due {
                let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
                body["due"] = String(format: "%04d-%02d-%02dT00:00:00.000Z", c.year!, c.month!, c.day!)
            }
            if let g {
                let same = g.title == t.title && g.notes == (body["notes"] as? String) && gDone == t.isCompleted
                    && (g.due?.prefix(10) ?? "") == ((body["due"] as? String)?.prefix(10) ?? "")
                if !same { _ = try await send("PATCH", base + "/" + g.id, body: body) }
            } else if !t.isCompleted {
                _ = try await send("POST", base, body: body)
            }
        }
        for (key, g) in existing where !wanted.contains(key) { _ = try? await send("DELETE", base + "/" + g.id, body: nil) }
        return result
    }

    // MARK: HTTP

    private func get<T: Decodable>(_ url: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await account.send(URLRequest(url: URL(string: url)!)))
    }

    private func send(_ method: String, _ url: String, body: [String: Any]?) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await account.send(req)
    }

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }
}
