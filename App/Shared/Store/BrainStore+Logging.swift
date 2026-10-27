import Foundation
import BrainCore

/// A running focus timer on one assignment. Kept per device; stopping it logs the time into the assignment's work log,
/// which syncs everywhere (and to Google Calendar / TickTick when those are on).
struct FocusTimer: Codable, Equatable {
    var taskID: UUID
    var stepID: UUID?
    var start: Date
    var minutes: Int { max(1, Int(Date().timeIntervalSince(start) / 60)) }
}

struct DayCourseMinutes: Identifiable, Hashable {
    var day: Date
    var course: String
    var minutes: Int
    var id: String { "\(day.timeIntervalSince1970)|\(course)" }
}

/// One line of the activity feed.
struct LoggedWork: Identifiable, Hashable {
    var task: BrainTask
    var session: WorkSession
    var id: UUID { session.id }
    var stepTitle: String? { session.milestoneID.flatMap { id in task.milestones.first { $0.id == id }?.title } }
}

extension BrainStore {
    // MARK: Focus timer

    func startFocus(_ t: BrainTask) {
        if let f = focus, f.taskID != t.id { stopFocus(log: true) }
        focus = FocusTimer(taskID: t.id, stepID: t.nextMilestone?.id, start: Date())
        var c = t
        if c.startDate == nil || c.startDate! > Date() { c.startDate = Date(); upsert(c) }
        show("Timer started · \(t.title)")
    }

    /// Stops the timer; `log` puts the time in the work log. Returns the minutes logged.
    @discardableResult
    func stopFocus(log: Bool, note: String? = nil, finishedStep: Bool = false) -> Int {
        guard let f = focus else { return 0 }
        focus = nil
        guard log, var t = task(f.taskID) else { return 0 }
        let minutes = f.minutes
        logWork(&t, minutes: minutes, note: note, milestoneID: f.stepID ?? t.nextMilestone?.id)
        if finishedStep, let s = f.stepID ?? t.nextMilestone?.id { finishStep(&t, s) }
        upsert(t)
        show("Logged \(Scheduler.durationText(minutes)) · \(t.title)" + (t.isCompleted ? " ✓" : " · \(Int(t.progress * 100))%"))
        return minutes
    }

    // MARK: Quick log

    /// The log card's one action: time, an optional note, and optionally the next step or the whole assignment done.
    func log(taskID: UUID, minutes: Int, note: String?, finishStep step: Bool, markDone done: Bool, on date: Date = Date()) {
        guard var t = task(taskID) else { return }
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let stepID = t.nextMilestone?.id
        logWork(&t, minutes: minutes, note: note, milestoneID: stepID, on: date)
        if done { markDone(&t) } else if step, let s = stepID { finishStep(&t, s) }
        upsert(t)
        var parts: [String] = []
        if minutes > 0 { parts.append("Logged \(Scheduler.durationText(minutes))") }
        if done { parts.append("done ✓") } else if step { parts.append("step checked off") }
        if parts.isEmpty { parts.append("Noted") }
        show(parts.joined(separator: ", ") + " · \(t.title)")
    }

    func deleteSession(_ w: LoggedWork) {
        guard var t = task(w.task.id) else { return }
        t.sessions.removeAll { $0.id == w.session.id }
        t.actualMinutes = t.sessions.reduce(0) { $0 + $1.minutes }
        upsert(t)
    }

    // MARK: What to log against

    /// Assignments you'd most likely log right now: the running timer, the current block, recently logged, then due soonest.
    var logSuggestions: [BrainTask] {
        var out: [BrainTask] = []
        func add(_ t: BrainTask?) { if let t, !t.isCompleted, !t.deleted, !out.contains(where: { $0.id == t.id }) { out.append(t) } }
        add(focus.flatMap { task($0.taskID) })
        add(currentBlockTaskID.flatMap { task($0) })
        for w in recentWork(limit: 20) { add(task(w.task.id)) }
        for t in pendingTasks.sorted(by: { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }) { add(t) }
        return Array(out.prefix(8))
    }

    // MARK: Activity

    func recentWork(limit: Int = 200, since: Date? = nil) -> [LoggedWork] {
        var out: [LoggedWork] = []
        for t in tasks {
            for s in t.sessions where since.map({ s.date >= $0 }) ?? true { out.append(LoggedWork(task: t, session: s)) }
        }
        return Array(out.sorted { $0.session.date > $1.session.date }.prefix(limit))
    }

    func minutesLogged(from start: Date, to end: Date) -> Int {
        tasks.reduce(0) { sum, t in sum + t.sessions.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.minutes } }
    }

    var minutesToday: Int {
        let s = Calendar.current.startOfDay(for: Date())
        return minutesLogged(from: s, to: s.addingTimeInterval(86_400))
    }

    var minutesThisWeek: Int {
        let cal = Calendar.current
        let s = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        return minutesLogged(from: s, to: Date().addingTimeInterval(60))
    }

    /// Days in a row (ending today, or yesterday if nothing yet today) with some work logged.
    var streak: Int {
        let cal = Calendar.current
        let days = Set(tasks.flatMap { $0.sessions.filter { $0.minutes > 0 }.map { cal.startOfDay(for: $0.date) } })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(day) { n += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
        return n
    }

    /// Minutes per day per class for the last `days` days (for the activity chart).
    func dailyByCourse(days: Int = 14) -> [DayCourseMinutes] {
        let cal = Calendar.current
        let first = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
        var bucket: [String: Int] = [:]
        for t in tasks {
            for s in t.sessions where s.date >= first && s.minutes > 0 {
                let key = "\(cal.startOfDay(for: s.date).timeIntervalSince1970)|\(t.course ?? "Other")"
                bucket[key, default: 0] += s.minutes
            }
        }
        return bucket.map { k, v in
            let p = k.split(separator: "|", maxSplits: 1)
            return DayCourseMinutes(day: Date(timeIntervalSince1970: Double(p[0]) ?? 0), course: String(p[1]), minutes: v)
        }.sorted { $0.day < $1.day }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
