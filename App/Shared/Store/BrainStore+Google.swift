import Foundation
import BrainCore

/// Google Calendar (read your calendars, write Blob's events) and Google Tasks (assignments as tasks in Google Calendar).
extension BrainStore {
    /// The account whose Google Calendar is used: whichever one you connected it on (personal first).
    var calendarAccount: GoogleAccount? {
        [personal, school].first { $0.isSignedIn && $0.hasScope(GoogleAccount.calendarScopes[0]) }
    }
    var tasksAccount: GoogleAccount? {
        [personal, school].first { $0.isSignedIn && $0.hasScope(GoogleAccount.tasksScope) }
    }

    func googleCalendarOccurrences(in range: DateInterval) -> [EventOccurrence] {
        guard googleCalendarOn, calendarAccount != nil, !isTestData else { return [] }
        return googleEventCache
            .filter { $0.end > range.start && $0.start < range.end || ($0.start == $0.end && range.contains($0.start)) }
            .map { EventOccurrence(id: $0.id + "@\(Int($0.start.timeIntervalSince1970))", eventID: nil, title: $0.title,
                                   start: $0.start, end: $0.end, isAllDay: $0.isAllDay, location: $0.location,
                                   externalCalendar: $0.calendar, colorHex: $0.colorHex) }
    }

    /// Connect Google Calendar (+ Tasks) on one of your accounts, keeping what it can already do.
    func connectGoogleCalendar(on account: GoogleAccount) async {
        await account.addScopes(GoogleAccount.calendarScopes + [GoogleAccount.tasksScope])
        if account.hasScope(GoogleAccount.calendarScopes[0]) {
            googleCalendarOn = true
            await syncGoogle(force: true)
        }
    }

    func syncGoogle(force: Bool = false) async {
        guard !isSyncingGoogle, !isTestData else { return }
        isSyncingGoogle = true
        defer { isSyncingGoogle = false }
        do {
            if let acct = calendarAccount {
                let sync = GoogleCalendarSync(account: acct)
                if googleCalendarOn, force || (lastGoogleRead ?? .distantPast) < Date().addingTimeInterval(-5 * 60) {
                    let now = Date()
                    googleEventCache = try await sync.fetchEvents(from: now.addingTimeInterval(-30 * 86_400), to: now.addingTimeInterval(180 * 86_400))
                    lastGoogleRead = Date()
                    saveGoogleCache()
                }
                if googleEventsPushOn {
                    var pushed = UserDefaults.standard.dictionary(forKey: "googlePushed") as? [String: Double] ?? [:]
                    defer { UserDefaults.standard.set(pushed, forKey: "googlePushed") }
                    try await sync.pushEvents(doc.events, pushed: &pushed)
                }
            }
            if googleTasksOn, let acct = tasksAccount {
                let r = try await GoogleCalendarSync(account: acct).syncTasks(doc.tasks)
                for id in r.completedInGoogle { if var t = task(id), !t.isCompleted { markDone(&t); upsert(t) } }
                for id in r.reopenedInGoogle { if var t = task(id), t.isCompleted { t.isCompleted = false; t.completedAt = nil; upsert(t) } }
                if !r.completedInGoogle.isEmpty { show("Marked done from Google Calendar ✓") }
            }
            googleCalendarError = nil
        } catch {
            googleCalendarError = error.localizedDescription
        }
    }

    // MARK: Local cache of your Google events (not synced — each device reads Google itself)

    var googleCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArjunsBrain/google-calendar-cache.json")
    }

    func loadGoogleCache() {
        if let d = try? Data(contentsOf: googleCacheURL),
           let c = try? JSONDecoder().decode([GoogleCalendarSync.CachedEvent].self, from: d) { googleEventCache = c }
    }

    func saveGoogleCache() {
        if let d = try? JSONEncoder().encode(googleEventCache) { try? d.write(to: googleCacheURL, options: .atomic) }
    }
}
