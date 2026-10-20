import Foundation
import BrainCore

/// Long-term tracking: logging work, finishing steps, grades — from the quick-add bar, the tracker, or Blob.
extension BrainStore {
    // MARK: Understanding a log sentence

    /// "worked 45 min on the history essay" → what it means and which assignment, for the quick-add preview.
    func logPreview(_ text: String) -> (intent: LogIntent, task: BrainTask?)? {
        guard let intent = ProgressLogParser().parse(text) else { return nil }
        return (intent, match(intent))
    }

    func match(_ intent: LogIntent) -> BrainTask? {
        let query: String
        switch intent {
        case .worked(_, let q, _), .finishedStep(_, let q), .completed(let q), .started(let q),
             .progress(_, let q), .grade(_, _, let q), .planSteps(let q):
            query = q
        }
        return TaskMatcher.best(query, in: tasks, fallback: currentBlockTaskID)
    }

    /// The assignment you're working on right now in today's timeline, if any.
    var currentBlockTaskID: UUID? {
        let now = Date()
        return todayPlan?.blocks.first { $0.kind == .task && !$0.isDone && ($0.startedAt != nil || ($0.start...$0.end).contains(now)) }?.taskID
    }

    /// Applies a log sentence and says what happened (shown as a toast, or spoken by Blob).
    @discardableResult
    func applyLog(_ text: String) -> String? {
        guard let intent = ProgressLogParser().parse(text) else { return nil }
        return apply(intent)
    }

    @discardableResult
    func apply(_ intent: LogIntent) -> String {
        guard var t = match(intent) else {
            return "I couldn't tell which assignment you meant. Try including its name or class."
        }
        let message: String
        switch intent {
        case .worked(let minutes, _, let note):
            logWork(&t, minutes: minutes, note: note, milestoneID: t.nextMilestone?.id)
            message = "Logged \(Scheduler.durationText(minutes)) on \(t.title)" + statusSuffix(t)
        case .finishedStep(let step, _):
            if let m = TaskMatcher.step(step, in: t) {
                finishStep(&t, m.id)
                message = t.isCompleted ? "\(t.title) is all done ✓" :
                    "Checked off “\(m.title)” for \(t.title)" + (t.nextMilestone.map { ". Next: \($0.title)" } ?? "") + statusSuffix(t)
            } else {
                // No matching step — just record it as progress.
                logWork(&t, minutes: 0, note: "Finished \(step)", milestoneID: nil)
                message = "Noted: finished \(step) for \(t.title)"
            }
        case .completed:
            markDone(&t)
            message = "\(t.title) — done ✓"
        case .started:
            if t.startDate == nil || t.startDate! > Date() { t.startDate = Date() }
            message = "Started \(t.title)" + (t.nextMilestone.map { ". First step: \($0.title)" } ?? "")
        case .progress(let percent, _):
            setProgress(&t, percent: percent)
            message = "\(t.title) is \(Int(t.progress * 100))% done" + statusSuffix(t)
        case .grade(let earned, let possible, _):
            t.pointsEarned = earned
            t.maxPoints = possible
            if !t.isCompleted { markDone(&t) }
            let pct = Int((earned / possible * 100).rounded())
            message = "Saved \(Self.fmt(earned))/\(Self.fmt(possible)) (\(pct)%) for \(t.title)"
        case .planSteps:
            planSteps(&t)
            message = "Split \(t.title) into \(t.milestones.count) steps: " + t.milestones.map(\.title).joined(separator: ", ")
        }
        upsert(t)
        show(message)
        return message
    }

    private func statusSuffix(_ t: BrainTask) -> String {
        guard !t.isCompleted, t.due != nil else { return "" }
        let pct = Int(t.progress * 100)
        return " — \(pct)% done, \(t.pace().label.lowercased())"
    }

    static func fmt(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v) }

    // MARK: Changes

    func logWork(_ t: inout BrainTask, minutes: Int, note: String?, milestoneID: UUID?, on date: Date = Date()) {
        // Keep older logged time when switching to the work log.
        if t.sessions.isEmpty, let old = t.actualMinutes, old > 0 {
            t.sessions.append(WorkSession(date: t.completedAt ?? date, minutes: old, note: "Earlier work"))
        }
        if minutes > 0 || note != nil {
            t.sessions.append(WorkSession(date: date, minutes: minutes, note: note, milestoneID: milestoneID))
        }
        t.actualMinutes = t.sessions.reduce(0) { $0 + $1.minutes }
        if t.startDate == nil { t.startDate = date }
        // A step is probably done once you've spent its whole estimate on it — but let the user say so.
    }

    func finishStep(_ t: inout BrainTask, _ id: UUID) {
        guard let i = t.milestones.firstIndex(where: { $0.id == id }) else { return }
        t.milestones[i].isDone = true
        t.milestones[i].doneAt = Date()
        if t.startDate == nil { t.startDate = Date() }
        if t.milestones.allSatisfy(\.isDone) { markDone(&t) }
    }

    func markDone(_ t: inout BrainTask) {
        t.isCompleted = true
        t.completedAt = Date()
        for i in t.milestones.indices where !t.milestones[i].isDone {
            t.milestones[i].isDone = true
            t.milestones[i].doneAt = Date()
        }
    }

    func setProgress(_ t: inout BrainTask, percent: Int) {
        if percent >= 100 { markDone(&t); return }
        if !t.milestones.isEmpty {
            // Check off steps in order until their share reaches the percentage.
            let total = Double(t.totalEstimateMinutes)
            var acc = 0.0
            for i in t.milestones.indices {
                acc += Double(t.milestones[i].estimatedMinutes)
                let shouldBeDone = acc / total <= Double(percent) / 100 + 0.02
                if shouldBeDone && !t.milestones[i].isDone { t.milestones[i].isDone = true; t.milestones[i].doneAt = Date() }
            }
        } else {
            let target = Int(Double(t.estimatedMinutes) * Double(percent) / 100)
            let missing = target - t.loggedMinutes
            if missing > 0 { logWork(&t, minutes: missing, note: "Marked \(percent)% done", milestoneID: nil) }
        }
        if t.startDate == nil { t.startDate = Date() }
    }

    func planSteps(_ t: inout BrainTask) {
        let now = Date()
        let due = t.due ?? Calendar.current.date(byAdding: .day, value: 14, to: now)!
        if t.due == nil { t.due = due }
        var total = t.estimateIsUserSet ? t.estimatedMinutes : max(t.estimatedMinutes, MilestonePlanner.defaultEstimate(title: t.title) ?? 180)
        total = max(total - t.loggedMinutes, 30)
        let start = max(now, t.startDate ?? now)
        let doneSteps = t.milestones.filter(\.isDone)
        t.milestones = doneSteps + MilestonePlanner.suggest(title: t.title, start: start, due: due, totalMinutes: total)
        if t.startDate == nil { t.startDate = t.createdAt ?? now }
    }

    /// Called after quick add: big assignments with a date far enough out get steps automatically.
    func setUpLongTermIfNeeded(_ id: UUID, explicit: Bool) {
        guard var t = task(id), t.milestones.isEmpty,
              MilestonePlanner.looksLongTerm(title: t.title, due: t.due, explicit: explicit) else { return }
        if !t.estimateIsUserSet, let e = MilestonePlanner.defaultEstimate(title: t.title) { t.estimatedMinutes = e }
        t.startDate = Date()
        planSteps(&t)
        upsert(t)
        show("Tracking \(t.title) long-term · \(t.milestones.count) steps")
    }

    // MARK: Summaries Blob can read out

    func trackerSummary(now: Date = Date()) -> String {
        let long = pendingTasks.filter(\.isLongTerm).sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        guard !long.isEmpty else { return "You don't have any long-term assignments right now." }
        return long.prefix(6).map { t in
            var s = "\(t.title): \(Int(t.progress * 100))% done, \(t.pace(now: now).label.lowercased())"
            if let d = t.due { s += ", due \(d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))" }
            if let m = t.nextMilestone { s += ". Next step: \(m.title)" + (m.due.map { " by \($0.formatted(.dateTime.weekday(.wide)))" } ?? "") }
            if let need = t.minutesPerDayNeeded(now: now), need > 0 { s += " (about \(Scheduler.durationText(need)) a day)" }
            return s
        }.joined(separator: "\n")
    }
}
