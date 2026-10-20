import Foundation

/// Builds the check-in timeline: which assignment to do when, from the moment you check in until bedtime.
///
/// How it decides:
/// 1. Work window = check-in time → bedtime, minus anything already on your calendar.
///    Checking in after bedtime (or after midnight) gives a short "essentials only" session.
/// 2. Assignments are bucketed by urgency: overdue → due before tomorrow morning → due tomorrow → this week → later.
/// 3. Within a bucket, the order depends on the time you checked in: when energy is usually high
///    (late morning, after school) the hardest work goes first; in low-energy hours it's priority, then shortest first.
///    A quick (≤20 min) task goes first as a warm-up when one is due soon.
/// 4. That order is simulated. If it would make anything late that a strict earliest-deadline order wouldn't,
///    the planner switches to earliest-deadline order instead.
/// 5. Work is chunked into focus blocks with breaks between them. Urgent work that doesn't fit is reported as overflow.
public struct Scheduler {
    public var settings: PlannerSettings
    public var calendar: Calendar

    public init(settings: PlannerSettings, calendar: Calendar = .current) {
        self.settings = settings
        self.calendar = calendar
    }

    enum Tier: Int, Comparable {
        case overdue, beforeMorning, tomorrow, thisWeek, later, someday
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    struct Item {
        var task: BrainTask
        var tier: Tier
        var minutes: Int
        var isWarmUp = false
    }

    struct Simulation {
        var blocks: [PlanBlock] = []
        var overflow: [UUID] = []
        var lateMinutes: Double = 0
        var workMinutes = 0
        var finish: Date?
    }

    // MARK: Public

    /// - Parameters:
    ///   - progress: minutes already done today on partially-finished tasks (from an earlier check-in).
    public func makePlan(checkIn: Date, tasks: [BrainTask], busy: [EventOccurrence],
                         progress: [UUID: Int] = [:]) -> DayPlan {
        let start = roundUp(checkIn)
        let (windowEnd, isLate) = workWindow(from: start)
        let busyBlocks = busy
            .filter { !$0.isAllDay && $0.end > start && $0.start < windowEnd }
            .sorted { $0.start < $1.start }
        let slots = freeSlots(from: start, to: windowEnd, busy: busyBlocks.map(\.interval))

        let items: [Item] = tasks
            .filter { !$0.isCompleted && !$0.deleted }
            .map { t in
                let remaining = max(5, t.estimatedMinutes - (progress[t.id] ?? 0))
                return Item(task: t, tier: tier(for: t.due, from: start), minutes: remaining)
            }

        let energy = energyLevel(at: start)
        let smartOrder = smartOrdering(items, energy: energy)
        let deadlineOrder = items.sorted(by: edfLess)

        let smart = simulate(smartOrder, slots: slots, start: start, energy: energy)
        let edf = simulate(deadlineOrder.map { var i = $0; i.isWarmUp = false; return i }, slots: slots, start: start, energy: energy)

        let useDeadlineOrder = smart.lateMinutes > edf.lateMinutes + 1
        var chosen = useDeadlineOrder ? edf : smart

        // Show calendar events inside the timeline so you can see why there are gaps.
        for o in busyBlocks {
            chosen.blocks.append(PlanBlock(kind: .event, title: o.title, subtitle: o.location ?? o.externalCalendar,
                                           start: max(o.start, start), end: o.end))
        }
        chosen.blocks.sort { ($0.start, $0.kind == .event ? 0 : 1) < ($1.start, $1.kind == .event ? 0 : 1) }

        let strategy: String
        if items.isEmpty {
            strategy = "Nothing on your plate — enjoy the free time."
        } else if useDeadlineOrder {
            strategy = "Deadlines are tight, so this is ordered strictly by due time to keep everything on time."
        } else if energy >= 0.7 {
            strategy = "You checked in at a high-energy time: a quick win first, then the hardest work while you're fresh."
        } else {
            strategy = "Lower-energy time of day: most important first, lighter and shorter tasks over heavy ones."
        }

        let timeFmt = Date.FormatStyle(date: .omitted, time: .shortened)
        var summary = "Checked in at \(checkIn.formatted(timeFmt))"
        if chosen.workMinutes > 0 {
            summary += " · \(Self.durationText(chosen.workMinutes)) of focus"
            if let f = chosen.finish { summary += " · done around \(f.formatted(timeFmt))" }
        }
        if isLate { summary += " · it's late, so just the essentials" }

        return DayPlan(checkInAt: checkIn, windowEnd: windowEnd, blocks: chosen.blocks,
                       overflowTaskIDs: chosen.overflow, summary: summary, strategy: strategy)
    }

    public static func durationText(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    // MARK: Window

    func roundUp(_ date: Date) -> Date {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let base = calendar.date(from: c) else { return date }
        var rounded = base.addingTimeInterval(Double((5 - (c.minute ?? 0) % 5) % 5) * 60)
        if rounded < date { rounded = rounded.addingTimeInterval(5 * 60) }
        return rounded
    }

    func workWindow(from start: Date) -> (Date, Bool) {
        let sod = calendar.startOfDay(for: start)
        let hour = calendar.component(.hour, from: start)
        let bedtime = sod.addingTimeInterval(Double(settings.bedtimeMinutes) * 60)
        let late = start.addingTimeInterval(Double(settings.lateSessionMinutes) * 60)
        if hour < 4 || start >= bedtime.addingTimeInterval(-20 * 60) { return (late, true) }
        return (bedtime, false)
    }

    func freeSlots(from start: Date, to end: Date, busy: [DateInterval]) -> [DateInterval] {
        var slots: [DateInterval] = []
        var cursor = start
        for b in busy.sorted(by: { $0.start < $1.start }) {
            if b.start > cursor { slots.append(DateInterval(start: cursor, end: min(b.start, end))) }
            cursor = max(cursor, b.end)
            if cursor >= end { break }
        }
        if cursor < end { slots.append(DateInterval(start: cursor, end: end)) }
        return slots.filter { $0.duration >= 5 * 60 }
    }

    // MARK: Ordering

    func tier(for due: Date?, from start: Date) -> Tier {
        guard let due else { return .someday }
        let sod = calendar.startOfDay(for: start)
        let hour = calendar.component(.hour, from: start)
        let morningBase = hour < 4 ? sod : calendar.date(byAdding: .day, value: 1, to: sod)!
        let nextMorning = morningBase.addingTimeInterval(8 * 3600)
        let tomorrowEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: nextMorning))!
        if due < start { return .overdue }
        if due <= nextMorning { return .beforeMorning }
        if due <= tomorrowEnd { return .tomorrow }
        if due <= start.addingTimeInterval(7 * 86_400) { return .thisWeek }
        return .later
    }

    /// Rough typical-student energy curve by hour (0…1).
    func energyLevel(at date: Date) -> Double {
        switch calendar.component(.hour, from: date) {
        case 5..<8: return 0.6
        case 8..<12: return 0.8
        case 12..<14: return 0.65
        case 14..<15: return 0.55
        case 15..<18: return 0.85
        case 18..<20: return 0.75
        case 20..<22: return 0.55
        default: return 0.35
        }
    }

    func edfLess(_ a: Item, _ b: Item) -> Bool {
        let da = a.task.due ?? .distantFuture, db = b.task.due ?? .distantFuture
        if da != db { return da < db }
        if a.task.priority != b.task.priority { return a.task.priority > b.task.priority }
        return a.minutes < b.minutes
    }

    func smartOrdering(_ items: [Item], energy: Double) -> [Item] {
        let highEnergy = energy >= 0.7
        var ordered = items.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if highEnergy {
                if a.task.difficulty != b.task.difficulty { return a.task.difficulty > b.task.difficulty }
                if a.task.priority != b.task.priority { return a.task.priority > b.task.priority }
            } else {
                if a.task.priority != b.task.priority { return a.task.priority > b.task.priority }
                if a.minutes != b.minutes { return a.minutes < b.minutes }
            }
            return edfLess(a, b)
        }
        // Warm-up: a short, not-hard task that's due soon goes first to build momentum.
        if let first = ordered.first, first.minutes > 20,
           let idx = ordered.firstIndex(where: { $0.tier <= .tomorrow && $0.minutes <= 20 && $0.task.difficulty <= 2 }) {
            var warm = ordered.remove(at: idx)
            warm.isWarmUp = true
            ordered.insert(warm, at: 0)
        }
        return ordered
    }

    // MARK: Simulation

    func simulate(_ order: [Item], slots: [DateInterval], start: Date, energy: Double) -> Simulation {
        var sim = Simulation()
        var slotIndex = 0
        var cursor = slots.first?.start ?? start
        var continuous = 0
        let focus = max(15, settings.focusBlockMinutes)

        for item in order {
            let urgent = item.tier <= .tomorrow
            if !urgent && sim.workMinutes >= settings.dailyWorkTargetMinutes { continue }
            guard slotIndex < slots.count else {
                if urgent { sim.overflow.append(item.task.id) }
                if item.tier <= .beforeMorning { sim.lateMinutes += 600 }
                continue
            }

            var remaining = item.minutes
            var parts: [DateInterval] = []
            // Don't split a task that fits in one focus block just because the current block is partly used — rest first.
            var pendingBreak = continuous >= 25 && remaining <= focus && continuous + remaining > focus + 10
            // After a short warm-up, let this block stretch a little rather than splitting the next task.
            let blockLimit = continuous > 0 && continuous < 25 && continuous + remaining <= focus + 20 ? continuous + remaining : focus

            while remaining > 0 && slotIndex < slots.count {
                let slot = slots[slotIndex]
                if cursor < slot.start { cursor = slot.start; continuous = 0 }
                let available = Int(slot.end.timeIntervalSince(cursor) / 60)
                if available < 5 {
                    slotIndex += 1
                    continuous = 0
                    continue
                }
                if continuous >= blockLimit || pendingBreak {
                    let len = min(settings.breakMinutes, available)
                    if available - len < 10 {
                        // No room to work after the break — skip to the next free slot instead of ending on a break.
                        slotIndex += 1
                        continuous = 0
                        pendingBreak = false
                        continue
                    }
                    let end = cursor.addingTimeInterval(Double(len) * 60)
                    sim.blocks.append(PlanBlock(kind: .breakTime, title: "Break", start: cursor, end: end,
                                                reason: "Stand up, drink water, look away from the screen"))
                    cursor = end
                    continuous = 0
                    pendingBreak = false
                    continue
                }
                var chunk = min(remaining, max(5, blockLimit - continuous), available)
                // Don't leave a tiny leftover chunk after a break — finish it if there's room.
                if remaining - chunk <= 10 && remaining <= available { chunk = remaining }
                let end = cursor.addingTimeInterval(Double(chunk) * 60)
                parts.append(DateInterval(start: cursor, end: end))
                cursor = end
                continuous += chunk
                remaining -= chunk
                sim.workMinutes += chunk
                if remaining > 0 && continuous >= blockLimit { pendingBreak = true }
            }

            if remaining > 0 && urgent { sim.overflow.append(item.task.id) }
            if !parts.isEmpty {
                let reason = reasonText(for: item, energy: energy, start: start)
                let total = parts.count + (remaining > 0 ? 1 : 0)
                for (i, p) in parts.enumerated() {
                    sim.blocks.append(PlanBlock(kind: .task, title: item.task.title, subtitle: item.task.course,
                                                start: p.start, end: p.end, reason: i == 0 ? reason : "Keep going",
                                                taskID: item.task.id,
                                                part: total > 1 ? i + 1 : nil, partsTotal: total > 1 ? total : nil))
                }
                sim.finish = parts.last?.end
            }
            if let due = item.task.due, due > start || item.tier == .overdue {
                let finish = remaining > 0 ? (slots.last?.end ?? start).addingTimeInterval(600 * 60) : (parts.last?.end ?? start)
                if finish > due { sim.lateMinutes += finish.timeIntervalSince(max(due, start)) / 60 }
            }
        }
        return sim
    }

    func reasonText(for item: Item, energy: Double, start: Date) -> String {
        let t = item.task
        var base: String
        switch item.tier {
        case .overdue: base = "Overdue — knock it out first"
        case .beforeMorning: base = "Due \(relativeDue(t.due!, from: start))"
        case .tomorrow: base = "Due tomorrow — get it done tonight"
        case .thisWeek: base = "Getting ahead — due \(t.due!.formatted(.dateTime.weekday(.wide)))"
        case .later: base = "Getting ahead — due \(t.due!.formatted(.dateTime.month(.abbreviated).day()))"
        case .someday: base = "No due date — chipping away at it"
        }
        if item.isWarmUp { return "Quick win to build momentum · " + base }
        if energy >= 0.7 && t.difficulty >= 3 { base += " · hardest work while you're fresh" }
        else if energy < 0.6 && item.minutes <= 25 { base += " · lighter task for this time of day" }
        return base
    }

    func relativeDue(_ due: Date, from start: Date) -> String {
        let time = due.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(due, inSameDayAs: start) { return "today at \(time)" }
        return "tomorrow at \(time)"
    }
}
