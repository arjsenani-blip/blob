import Foundation
import CryptoKit

/// Anything that syncs between devices. Merging is last-write-wins on `updatedAt`,
/// and deletions are kept as tombstones (`deleted = true`) so they propagate.
public protocol SyncRecord: Identifiable, Codable {
    var id: UUID { get }
    var updatedAt: Date { get }
    var deleted: Bool { get }
}

// MARK: - Recurrence

public struct RecurrenceRule: Codable, Hashable, Sendable {
    public enum Frequency: String, Codable, Sendable, CaseIterable, Identifiable {
        case none, daily, weekdays, weekly, monthly
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .none: return "Never"
            case .daily: return "Every day"
            case .weekdays: return "Every weekday"
            case .weekly: return "Every week"
            case .monthly: return "Every month"
            }
        }
    }

    public var frequency: Frequency
    /// Calendar weekday numbers (1 = Sunday … 7 = Saturday) for weekly rules.
    /// Empty means "the same weekday as the first occurrence".
    public var weekdays: [Int]
    public var until: Date?

    public init(frequency: Frequency = .none, weekdays: [Int] = [], until: Date? = nil) {
        self.frequency = frequency
        self.weekdays = weekdays
        self.until = until
    }

    public static let none = RecurrenceRule()
    public var isRepeating: Bool { frequency != .none }

    public func describe(calendar: Calendar = .current) -> String {
        switch frequency {
        case .weekly where !weekdays.isEmpty:
            let names = weekdays.sorted().map { calendar.shortWeekdaySymbols[$0 - 1] }
            return "Every " + names.joined(separator: ", ")
        default:
            return frequency.label
        }
    }
}

// MARK: - Events

public struct BrainEvent: SyncRecord, Hashable {
    public var id: UUID
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var tag: String?
    public var recurrence: RecurrenceRule
    /// Start-of-day dates of occurrences the user removed from a repeating series.
    public var excludedDays: [Date]
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), title: String, start: Date, end: Date, isAllDay: Bool = false,
                location: String? = nil, notes: String? = nil, tag: String? = nil,
                recurrence: RecurrenceRule = .none, excludedDays: [Date] = [],
                updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.tag = tag
        self.recurrence = recurrence
        self.excludedDays = excludedDays
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

/// One concrete appearance of an event on the calendar (repeating events expand into many).
public struct EventOccurrence: Identifiable, Hashable, Sendable {
    public var id: String
    public var eventID: UUID?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var tag: String?
    /// Set for events read from Apple Calendar; those are read-only here.
    public var externalCalendar: String?
    public var colorHex: String?

    public init(id: String, eventID: UUID?, title: String, start: Date, end: Date, isAllDay: Bool,
                location: String? = nil, tag: String? = nil, externalCalendar: String? = nil, colorHex: String? = nil) {
        self.id = id
        self.eventID = eventID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.tag = tag
        self.externalCalendar = externalCalendar
        self.colorHex = colorHex
    }

    public var interval: DateInterval { DateInterval(start: start, end: max(end, start)) }
}

extension BrainEvent {
    public func occurrences(in range: DateInterval, calendar: Calendar = .current) -> [EventOccurrence] {
        guard !deleted else { return [] }
        let duration = max(end.timeIntervalSince(start), 0)

        func make(_ s: Date) -> EventOccurrence {
            let occStart = isAllDay ? calendar.startOfDay(for: s) : s
            let occEnd = isAllDay
                ? calendar.date(byAdding: .day, value: max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 1), to: occStart)!
                : s.addingTimeInterval(duration)
            return EventOccurrence(id: "\(id.uuidString)@\(Int(occStart.timeIntervalSince1970))", eventID: id,
                                   title: title, start: occStart, end: occEnd, isAllDay: isAllDay,
                                   location: location, tag: tag)
        }
        func overlaps(_ o: EventOccurrence) -> Bool { o.end > range.start && o.start < range.end || (o.start == o.end && range.contains(o.start)) }

        guard recurrence.isRepeating else {
            let o = make(start)
            return overlaps(o) ? [o] : []
        }

        let startDay = calendar.startOfDay(for: start)
        let firstCandidate = calendar.startOfDay(for: max(start, range.start.addingTimeInterval(-max(duration, 86_400))))
        let limit = min(range.end, recurrence.until.map { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))! } ?? .distantFuture)
        let time = calendar.dateComponents([.hour, .minute], from: start)
        let startWeekday = calendar.component(.weekday, from: start)
        let startDayOfMonth = calendar.component(.day, from: start)
        let excluded = Set(excludedDays.map { calendar.startOfDay(for: $0) })

        var results: [EventOccurrence] = []
        var day = max(firstCandidate, startDay)
        var steps = 0
        while day < limit && steps < 3_000 {
            steps += 1
            let weekday = calendar.component(.weekday, from: day)
            let matches: Bool
            switch recurrence.frequency {
            case .none: matches = false
            case .daily: matches = true
            case .weekdays: matches = (2...6).contains(weekday)
            case .weekly: matches = recurrence.weekdays.isEmpty ? weekday == startWeekday : recurrence.weekdays.contains(weekday)
            case .monthly: matches = calendar.component(.day, from: day) == startDayOfMonth
            }
            if matches && !excluded.contains(day) {
                let s = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? day
                let o = make(s)
                if overlaps(o) { results.append(o) }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return results
    }
}

// MARK: - Tasks / assignments

public struct BrainTask: SyncRecord, Hashable {
    public enum Source: String, Codable, Sendable { case manual, classroom }
    public enum Priority: Int, Codable, Sendable, CaseIterable, Comparable, Identifiable {
        case low = 0, normal = 1, high = 2
        public var id: Int { rawValue }
        public var label: String { ["Low", "Normal", "High"][rawValue] }
        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: UUID
    public var title: String
    public var course: String?
    public var notes: String?
    public var due: Date?
    public var estimatedMinutes: Int
    /// 1 = easy, 2 = medium, 3 = hard. Used to put hard work where your energy is.
    public var difficulty: Int
    public var priority: Priority
    public var source: Source
    public var externalID: String?
    public var link: String?
    public var isCompleted: Bool
    public var completedAt: Date?
    /// Minutes actually spent (from timeline Start/Done). Used to learn better estimates per course.
    public var actualMinutes: Int?
    public var estimateIsUserSet: Bool
    // Long-term tracking (all optional in the file, so older data still loads).
    /// When the assignment was given / when you plan to start. Used to judge whether you're on pace.
    public var startDate: Date?
    public var createdAt: Date?
    /// Steps of a bigger assignment, each with its own target date.
    public var milestones: [Milestone]
    /// Every stretch of time you've worked on it.
    public var sessions: [WorkSession]
    public var pointsEarned: Double?
    public var maxPoints: Double?
    /// Classroom's submission state: NEW, CREATED, TURNED_IN, RETURNED, RECLAIMED_BY_STUDENT.
    public var submissionState: String?
    public var isLate: Bool
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), title: String, course: String? = nil, notes: String? = nil, due: Date? = nil,
                estimatedMinutes: Int = 30, difficulty: Int = 2, priority: Priority = .normal,
                source: Source = .manual, externalID: String? = nil, link: String? = nil,
                isCompleted: Bool = false, completedAt: Date? = nil, actualMinutes: Int? = nil,
                estimateIsUserSet: Bool = false, startDate: Date? = nil, createdAt: Date? = Date(),
                milestones: [Milestone] = [], sessions: [WorkSession] = [], pointsEarned: Double? = nil,
                maxPoints: Double? = nil, submissionState: String? = nil, isLate: Bool = false,
                updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id
        self.title = title
        self.course = course
        self.notes = notes
        self.due = due
        self.estimatedMinutes = estimatedMinutes
        self.difficulty = difficulty
        self.priority = priority
        self.source = source
        self.externalID = externalID
        self.link = link
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.actualMinutes = actualMinutes
        self.estimateIsUserSet = estimateIsUserSet
        self.startDate = startDate
        self.createdAt = createdAt
        self.milestones = milestones
        self.sessions = sessions
        self.pointsEarned = pointsEarned
        self.maxPoints = maxPoints
        self.submissionState = submissionState
        self.isLate = isLate
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        course = try c.decodeIfPresent(String.self, forKey: .course)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        due = try c.decodeIfPresent(Date.self, forKey: .due)
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes) ?? 30
        difficulty = try c.decodeIfPresent(Int.self, forKey: .difficulty) ?? 2
        priority = try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .normal
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .manual
        externalID = try c.decodeIfPresent(String.self, forKey: .externalID)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        actualMinutes = try c.decodeIfPresent(Int.self, forKey: .actualMinutes)
        estimateIsUserSet = try c.decodeIfPresent(Bool.self, forKey: .estimateIsUserSet) ?? false
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        milestones = try c.decodeIfPresent([Milestone].self, forKey: .milestones) ?? []
        sessions = try c.decodeIfPresent([WorkSession].self, forKey: .sessions) ?? []
        pointsEarned = try c.decodeIfPresent(Double.self, forKey: .pointsEarned)
        maxPoints = try c.decodeIfPresent(Double.self, forKey: .maxPoints)
        submissionState = try c.decodeIfPresent(String.self, forKey: .submissionState)
        isLate = try c.decodeIfPresent(Bool.self, forKey: .isLate) ?? false
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

// MARK: - Check-in plans

public struct PlanBlock: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case task, event, breakTime }
    public var id: UUID
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var start: Date
    public var end: Date
    public var reason: String?
    public var taskID: UUID?
    public var part: Int?
    public var partsTotal: Int?
    public var isDone: Bool
    public var startedAt: Date?
    /// The step of a long-term assignment this block works on.
    public var milestoneID: UUID?
    /// True when this block is just today's share of a bigger assignment — finishing it doesn't finish the assignment.
    public var sessionOnly: Bool?

    public init(id: UUID = UUID(), kind: Kind, title: String, subtitle: String? = nil, start: Date, end: Date,
                reason: String? = nil, taskID: UUID? = nil, part: Int? = nil, partsTotal: Int? = nil,
                isDone: Bool = false, startedAt: Date? = nil, milestoneID: UUID? = nil, sessionOnly: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.start = start
        self.end = end
        self.reason = reason
        self.taskID = taskID
        self.part = part
        self.partsTotal = partsTotal
        self.isDone = isDone
        self.startedAt = startedAt
        self.milestoneID = milestoneID
        self.sessionOnly = sessionOnly
    }

    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
    public var isFinalPart: Bool { part == nil || part == partsTotal }
}

public struct DayPlan: SyncRecord, Hashable {
    public var id: UUID
    public var checkInAt: Date
    public var windowEnd: Date
    public var blocks: [PlanBlock]
    /// Urgent tasks that didn't fit before bedtime.
    public var overflowTaskIDs: [UUID]
    public var summary: String
    public var strategy: String
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), checkInAt: Date, windowEnd: Date, blocks: [PlanBlock], overflowTaskIDs: [UUID],
                summary: String, strategy: String, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id
        self.checkInAt = checkInAt
        self.windowEnd = windowEnd
        self.blocks = blocks
        self.overflowTaskIDs = overflowTaskIDs
        self.summary = summary
        self.strategy = strategy
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

public struct PlannerSettings: Codable, Hashable, Sendable {
    /// Minutes after midnight you want to be done working.
    public var bedtimeMinutes: Int
    public var focusBlockMinutes: Int
    public var breakMinutes: Int
    /// After urgent work, keep adding "get ahead" work until this many minutes are planned.
    public var dailyWorkTargetMinutes: Int
    /// How long a session is when you check in after bedtime.
    public var lateSessionMinutes: Int
    public var updatedAt: Date

    public init(bedtimeMinutes: Int = 22 * 60 + 30, focusBlockMinutes: Int = 45, breakMinutes: Int = 10,
                dailyWorkTargetMinutes: Int = 180, lateSessionMinutes: Int = 60, updatedAt: Date = .distantPast) {
        self.bedtimeMinutes = bedtimeMinutes
        self.focusBlockMinutes = focusBlockMinutes
        self.breakMinutes = breakMinutes
        self.dailyWorkTargetMinutes = dailyWorkTargetMinutes
        self.lateSessionMinutes = lateSessionMinutes
        self.updatedAt = updatedAt
    }
}

/// Everything that syncs between your Mac and iPhone.
public struct BrainDocument: Codable, Hashable {
    public static let currentSchema = 1
    public var schemaVersion: Int
    public var events: [BrainEvent]
    public var tasks: [BrainTask]
    public var plans: [DayPlan]
    public var settings: PlannerSettings

    public init(events: [BrainEvent] = [], tasks: [BrainTask] = [], plans: [DayPlan] = [], settings: PlannerSettings = .init()) {
        self.schemaVersion = Self.currentSchema
        self.events = events
        self.tasks = tasks
        self.plans = plans
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        events = try c.decodeIfPresent([BrainEvent].self, forKey: .events) ?? []
        tasks = try c.decodeIfPresent([BrainTask].self, forKey: .tasks) ?? []
        plans = try c.decodeIfPresent([DayPlan].self, forKey: .plans) ?? []
        settings = try c.decodeIfPresent(PlannerSettings.self, forKey: .settings) ?? .init()
    }
}

extension UUID {
    /// A UUID derived from a string, so the same Classroom assignment gets the same id on every device.
    public static func stable(from key: String) -> UUID {
        var bytes = Array(Insecure.SHA1.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
