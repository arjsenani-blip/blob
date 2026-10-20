import Foundation

// Long-term assignment tracking: milestones, a work log, grades, progress and pace.

/// One step of a bigger assignment ("Outline", "Rough draft"…), with its own target date.
public struct Milestone: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var due: Date?
    public var estimatedMinutes: Int
    public var isDone: Bool
    public var doneAt: Date?

    public init(id: UUID = UUID(), title: String, due: Date? = nil, estimatedMinutes: Int = 30,
                isDone: Bool = false, doneAt: Date? = nil) {
        self.id = id
        self.title = title
        self.due = due
        self.estimatedMinutes = estimatedMinutes
        self.isDone = isDone
        self.doneAt = doneAt
    }
}

/// A stretch of time spent on an assignment.
public struct WorkSession: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var minutes: Int
    public var note: String?
    public var milestoneID: UUID?

    public init(id: UUID = UUID(), date: Date = Date(), minutes: Int, note: String? = nil, milestoneID: UUID? = nil) {
        self.id = id
        self.date = date
        self.minutes = minutes
        self.note = note
        self.milestoneID = milestoneID
    }
}

public enum Pace: String, Sendable {
    case done, ahead, onTrack, behind, atRisk, overdue, notStarted

    public var label: String {
        switch self {
        case .done: return "Done"
        case .ahead: return "Ahead"
        case .onTrack: return "On track"
        case .behind: return "Behind"
        case .atRisk: return "At risk"
        case .overdue: return "Overdue"
        case .notStarted: return "Not started"
        }
    }
}

extension BrainTask {
    /// Minutes logged in the work log (falls back to the older single counter).
    public var loggedMinutes: Int {
        let s = sessions.reduce(0) { $0 + $1.minutes }
        return s > 0 ? s : (actualMinutes ?? 0)
    }

    /// Whole-assignment estimate: the sum of the steps when there are steps.
    public var totalEstimateMinutes: Int {
        milestones.isEmpty ? estimatedMinutes : max(5, milestones.reduce(0) { $0 + $1.estimatedMinutes })
    }

    public var remainingMinutes: Int {
        if isCompleted { return 0 }
        if !milestones.isEmpty {
            let open = milestones.filter { !$0.isDone }
            guard let first = open.first else { return 5 }
            let loggedOnFirst = sessions.filter { $0.milestoneID == first.id }.reduce(0) { $0 + $1.minutes }
            return max(5, open.reduce(0) { $0 + $1.estimatedMinutes } - min(loggedOnFirst, first.estimatedMinutes - 5))
        }
        return max(5, estimatedMinutes - loggedMinutes)
    }

    /// 0…1. Steps count by their size; without steps it's time spent vs. the estimate (never 100% until it's done).
    public var progress: Double {
        if isCompleted { return 1 }
        if !milestones.isEmpty {
            let total = Double(totalEstimateMinutes)
            var done = Double(milestones.filter(\.isDone).reduce(0) { $0 + $1.estimatedMinutes })
            // Partial credit for time already put into the step you're on.
            if let step = nextMilestone {
                let onStep = sessions.filter { $0.milestoneID == step.id }.reduce(0) { $0 + $1.minutes }
                done += min(Double(onStep), Double(step.estimatedMinutes) * 0.9)
            }
            return min(0.97, done / max(total, 1))
        }
        return min(0.9, Double(loggedMinutes) / Double(max(estimatedMinutes, 1)))
    }

    public var nextMilestone: Milestone? { milestones.first { !$0.isDone } }

    /// Big enough to track over days rather than knock out in one sitting.
    public var isLongTerm: Bool {
        if !milestones.isEmpty { return true }
        return totalEstimateMinutes >= 120
    }

    public var percentGrade: Double? {
        guard let e = pointsEarned, let m = maxPoints, m > 0 else { return nil }
        return e / m * 100
    }

    /// When the work window opened: start date, else when it was added, else two weeks before the due date.
    public var effectiveStart: Date? {
        if let s = startDate ?? createdAt { return s }
        return due.map { $0.addingTimeInterval(-14 * 86_400) }
    }

    /// How much of the work should be done by now if it were spread evenly from start to due.
    public func expectedProgress(now: Date = Date()) -> Double? {
        guard let due, let start = effectiveStart, due > start else { return nil }
        // Plan to finish a little early: aim for 100% by 90% of the window.
        let window = due.timeIntervalSince(start) * 0.9
        return min(1, max(0, now.timeIntervalSince(start) / window))
    }

    /// Minutes per day you'd need from now on to finish a day early (or by the due time if it's close).
    public func minutesPerDayNeeded(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard !isCompleted, let due, due > now else { return nil }
        let days = Self.workDays(from: now, to: due, calendar: calendar)
        return Int((Double(remainingMinutes) / Double(days)).rounded(.up))
    }

    /// Whole days available to work, keeping the day it's due as a buffer when there's room.
    static func workDays(from now: Date, to due: Date, calendar: Calendar) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        return max(1, days >= 3 ? days : days + 1)
    }

    public func pace(now: Date = Date(), calendar: Calendar = .current) -> Pace {
        if isCompleted { return .done }
        guard let due else { return loggedMinutes > 0 || milestones.contains(where: \.isDone) ? .onTrack : .notStarted }
        if due < now { return .overdue }
        if let perDay = minutesPerDayNeeded(now: now, calendar: calendar), perDay > 150 { return .atRisk }
        if milestones.contains(where: { !$0.isDone && ($0.due ?? .distantFuture) < now }) { return .behind }
        guard let expected = expectedProgress(now: now) else { return .onTrack }
        let actual = progress
        if actual <= 0.001 && expected < 0.15 { return .notStarted }
        if actual >= expected + 0.15 { return .ahead }
        if actual < expected - 0.2 { return expected - actual > 0.45 ? .atRisk : .behind }
        return .onTrack
    }
}

// MARK: - Breaking a big assignment into steps

public enum MilestonePlanner {
    /// Suggested steps for an assignment, spread from `start` to a little before `due`.
    public static func suggest(title: String, start: Date, due: Date, totalMinutes: Int,
                               calendar: Calendar = .current) -> [Milestone] {
        let t = title.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        let steps: [(String, Double)]
        if has("essay", "paper", "report", "dbq", "writing", "research", "thesis") {
            steps = [("Research & sources", 0.2), ("Outline", 0.15), ("Rough draft", 0.35), ("Revise & edit", 0.2), ("Final read-through & submit", 0.1)]
        } else if has("test", "exam", "final", "midterm", "quiz", "ap ", "sat", "act") {
            steps = [("Make a study guide", 0.25), ("Review weak topics", 0.3), ("Practice test", 0.3), ("Final review", 0.15)]
        } else if has("presentation", "slides", "speech") {
            steps = [("Research", 0.25), ("Build the slides", 0.4), ("Practice out loud", 0.25), ("Final polish", 0.1)]
        } else if has("lab") {
            steps = [("Organize data", 0.25), ("Analysis & graphs", 0.3), ("Write it up", 0.3), ("Check & submit", 0.15)]
        } else if has("project", "portfolio", "model", "build", "video") {
            steps = [("Plan & research", 0.2), ("Build the main part", 0.45), ("Finish & polish", 0.25), ("Submit", 0.1)]
        } else if has("read", "book", "novel", "chapters") {
            steps = [("Read the first third", 0.33), ("Read the middle", 0.33), ("Finish & take notes", 0.34)]
        } else {
            steps = [("Get started", 0.25), ("Main work", 0.5), ("Finish & check", 0.25)]
        }

        // Finish a day early when there's more than a few days; otherwise a few hours early.
        let span = due.timeIntervalSince(start)
        let buffer: TimeInterval = span > 4 * 86_400 ? 86_400 : span * 0.1
        let end = due.addingTimeInterval(-buffer)
        let usable = max(end.timeIntervalSince(start), 3600)

        var cumulative = 0.0
        return steps.enumerated().map { i, step in
            cumulative += step.1
            let isLast = i == steps.count - 1
            var date = isLast ? due : start.addingTimeInterval(usable * cumulative)
            if !isLast, span > 2 * 86_400 {
                // Steps land at the end of a day, which is how students actually work.
                date = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: date) ?? date
                date = min(date, end)
            }
            let mins = max(10, Int((Double(totalMinutes) * step.1 / 5).rounded()) * 5)
            return Milestone(title: step.0, due: date, estimatedMinutes: mins)
        }
    }
}

// MARK: - Per-class summaries and workload ahead

public struct CourseSummary: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var openCount: Int
    public var overdueCount: Int
    public var longTermCount: Int
    public var completedCount: Int
    public var remainingMinutes: Int
    public var loggedMinutes: Int
    public var averageGrade: Double?
    public var gradedCount: Int
    public var nextDue: Date?

    public static func build(_ tasks: [BrainTask], now: Date = Date()) -> [CourseSummary] {
        let live = tasks.filter { !$0.deleted }
        let byCourse = Dictionary(grouping: live) { $0.course?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Other" }
        return byCourse.map { name, ts in
            let open = ts.filter { !$0.isCompleted }
            let graded = ts.filter { $0.percentGrade != nil }
            // Weighted by points, like most gradebooks.
            let earned = graded.reduce(0.0) { $0 + ($1.pointsEarned ?? 0) }
            let possible = graded.reduce(0.0) { $0 + ($1.maxPoints ?? 0) }
            return CourseSummary(
                name: name, openCount: open.count,
                overdueCount: open.filter { ($0.due ?? .distantFuture) < now }.count,
                longTermCount: open.filter(\.isLongTerm).count,
                completedCount: ts.count - open.count,
                remainingMinutes: open.reduce(0) { $0 + $1.remainingMinutes },
                loggedMinutes: ts.reduce(0) { $0 + $1.loggedMinutes },
                averageGrade: possible > 0 ? earned / possible * 100 : nil,
                gradedCount: graded.count,
                nextDue: open.compactMap(\.due).filter { $0 >= now }.min())
        }
        .sorted { ($0.name == "Other" ? 1 : 0, $0.name) < ($1.name == "Other" ? 1 : 0, $1.name) }
    }
}

public enum Workload {
    /// Remaining work spread evenly over the days until each step/assignment is due → minutes per day.
    /// Overdue work and work with no date lands on today.
    public static func perDay(_ tasks: [BrainTask], from now: Date = Date(), days: Int,
                              calendar: Calendar = .current) -> [(day: Date, minutes: Int)] {
        let today = calendar.startOfDay(for: now)
        var buckets = [Int](repeating: 0, count: days)

        func spread(_ minutes: Int, until due: Date?) {
            guard minutes > 0 else { return }
            guard let due, due > now else { buckets[0] += minutes; return }
            let n = BrainTask.workDays(from: now, to: due, calendar: calendar)
            let per = Double(minutes) / Double(n)
            for i in 0..<n where i < days { buckets[i] += Int(per.rounded()) }
        }

        for t in tasks where !t.deleted && !t.isCompleted {
            if t.milestones.isEmpty {
                // No date: assume it'll be done over the next week.
                spread(t.remainingMinutes, until: t.due ?? calendar.date(byAdding: .day, value: 7, to: today))
            } else {
                var from = now
                for m in t.milestones where !m.isDone {
                    let due = m.due ?? t.due
                    // Each step is spread over its own stretch, after the previous step's date.
                    if let due, due > from {
                        let n = BrainTask.workDays(from: from, to: due, calendar: calendar)
                        let offset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: from)).day ?? 0
                        let per = Double(m.estimatedMinutes) / Double(n)
                        for i in 0..<n where offset + i < days && offset + i >= 0 { buckets[offset + i] += Int(per.rounded()) }
                        from = due
                    } else {
                        buckets[0] += m.estimatedMinutes
                    }
                }
            }
        }
        return buckets.enumerated().map { (calendar.date(byAdding: .day, value: $0.offset, to: today)!, $0.element) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
