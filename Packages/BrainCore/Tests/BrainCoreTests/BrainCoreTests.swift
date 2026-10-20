import XCTest
@testable import BrainCore

final class ParserTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    /// Monday, Oct 19 2026, 10:00 AM
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 10))! }

    func parse(_ s: String) -> ParsedEntry { NaturalLanguageParser(calendar: cal, now: now).parse(s) }
    func d(_ m: Int, _ day: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: m, day: day, hour: h, minute: min))!
    }

    func testTomorrowAtTime() {
        let p = parse("Dentist tomorrow at 3pm")
        XCTAssertEqual(p.kind, .event)
        XCTAssertEqual(p.title, "Dentist")
        XCTAssertEqual(p.start, d(10, 20, 15))
        XCTAssertEqual(p.end, d(10, 20, 16))
    }

    func testRecurringRangeWithLocation() {
        let p = parse("soccer practice every tue and thu 5-7pm at Lincoln Field")
        XCTAssertEqual(p.title, "Soccer practice")
        XCTAssertEqual(p.recurrence.frequency, .weekly)
        XCTAssertEqual(p.recurrence.weekdays, [3, 5])
        XCTAssertEqual(p.start, d(10, 20, 17))
        XCTAssertEqual(p.end, d(10, 20, 19))
        XCTAssertEqual(p.location, "Lincoln Field")
    }

    func testTaskWithDue() {
        let p = parse("English essay due friday #school")
        XCTAssertEqual(p.kind, .task)
        XCTAssertEqual(p.title, "English essay")
        XCTAssertEqual(p.tag, "school")
        XCTAssertEqual(p.start, d(10, 23, 23, 59))
    }

    func testNoDateBecomesTask() {
        let p = parse("buy poster board")
        XCTAssertEqual(p.kind, .task)
        XCTAssertNil(p.start)
        XCTAssertEqual(p.title, "Buy poster board")
    }

    func testNextFriday() {
        XCTAssertEqual(parse("game next friday 7pm").start, d(10, 30, 19))
    }

    func testMonthDayAllDay() {
        let p = parse("Halloween party oct 31")
        XCTAssertTrue(p.isAllDay)
        XCTAssertEqual(p.start, d(10, 31))
    }

    func testNumericDateAndDuration() {
        let p = parse("SAT prep 11/7 9:30am for 2 hours")
        XCTAssertEqual(p.title, "SAT prep")
        XCTAssertEqual(p.start, d(11, 7, 9, 30))
        XCTAssertEqual(p.end, d(11, 7, 11, 30))
    }

    func testRelative() {
        let p = parse("call mom in 2 hours")
        XCTAssertEqual(p.title, "Call mom")
        XCTAssertEqual(p.start, d(10, 19, 12))
    }

    func testBareHourAssumesAfternoonAndTodayWhenFuture() {
        let p = parse("lunch with sam at noon @ Chipotle")
        XCTAssertEqual(p.start, d(10, 19, 12))
        XCTAssertEqual(p.location, "Chipotle")
        XCTAssertEqual(p.title, "Lunch with sam")
        XCTAssertEqual(parse("piano at 4").start, d(10, 19, 16))
    }

    func testPastTimeRollsToTomorrow() {
        XCTAssertEqual(parse("standup 9am").start, d(10, 20, 9))
    }

    func testTonight() {
        XCTAssertEqual(parse("movie tonight").start, d(10, 19, 20))
    }

    func testDoesNotEatTitleNumbers() {
        let p = parse("read chapters 3-4 tomorrow")
        XCTAssertEqual(p.title, "Read chapters 3-4")
        XCTAssertEqual(p.kind, .task, "reading is school work, so it's an assignment")
    }

    func testAmbiguousWordsStayInTitle() {
        XCTAssertEqual(parse("watch the sun rise tomorrow 6am").title, "Watch the sun rise")
    }

    func testEveryWeekday() {
        let p = parse("bus every weekday 7:15am")
        XCTAssertEqual(p.recurrence.frequency, .weekdays)
        XCTAssertEqual(p.start, d(10, 20, 7, 15))
    }

    func testTaskEstimate() {
        let p = parse("todo lab report ~90m by thursday !!")
        XCTAssertEqual(p.kind, .task)
        XCTAssertEqual(p.title, "Lab report")
        XCTAssertEqual(p.durationMinutes, 90)
        XCTAssertEqual(p.priority, .high)
        XCTAssertEqual(p.start, d(10, 22, 23, 59))
    }

    func testRangeAcrossNoon() {
        let p = parse("study group sat 11-1pm")
        XCTAssertEqual(p.start, d(10, 24, 11))
        XCTAssertEqual(p.end, d(10, 24, 13))
        XCTAssertEqual(p.title, "Study group")
    }
}

final class SchedulerTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    func d(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    func testOrdersAndAvoidsEvents() {
        let s = Scheduler(settings: PlannerSettings(), calendar: cal)
        let tasks = [
            BrainTask(title: "Essay", course: "English", due: d(23, 23, 59), estimatedMinutes: 90, difficulty: 3),
            BrainTask(title: "Math HW", course: "Math", due: d(19, 23, 59), estimatedMinutes: 40, difficulty: 2),
            BrainTask(title: "Vocab quiz", course: "Spanish", due: d(20, 8), estimatedMinutes: 15, difficulty: 1),
            BrainTask(title: "Done thing", due: d(19, 23), isCompleted: true),
        ]
        let practice = EventOccurrence(id: "p", eventID: nil, title: "Practice", start: d(19, 17), end: d(19, 18), isAllDay: false)
        let plan = s.makePlan(checkIn: d(19, 15, 32), tasks: tasks, busy: [practice])

        let work = plan.blocks.filter { $0.kind == .task }
        XCTAssertEqual(work.first?.title, "Vocab quiz", "short task due soon goes first as a warm-up")
        XCTAssertEqual(work.first?.start, d(19, 15, 35), "starts at the rounded check-in time")
        XCTAssertTrue(work.contains { $0.title == "Math HW" })
        XCTAssertFalse(work.contains { $0.title == "Done thing" })
        for b in work { XCTAssertFalse(b.start < practice.end && b.end > practice.start, "\(b.title) overlaps practice") }
        XCTAssertTrue(plan.blocks.contains { $0.kind == .event && $0.title == "Practice" })
        XCTAssertTrue(plan.overflowTaskIDs.isEmpty)
        XCTAssertTrue(plan.blocks.allSatisfy { $0.end <= d(19, 22, 30) })
    }

    func testFallsBackToDeadlineOrder() {
        let s = Scheduler(settings: PlannerSettings(), calendar: cal)
        // Hard task due late tonight vs. easy one due very soon — smart order (hard first) would make the easy one late.
        let tasks = [
            BrainTask(title: "Hard project", due: d(19, 23, 59), estimatedMinutes: 60, difficulty: 3),
            BrainTask(title: "Form", due: d(19, 16, 30), estimatedMinutes: 30, difficulty: 2),
        ]
        let plan = s.makePlan(checkIn: d(19, 15, 30), tasks: tasks, busy: [])
        XCTAssertEqual(plan.blocks.first { $0.kind == .task }?.title, "Form")
    }

    func testLateCheckInIsShort() {
        let s = Scheduler(settings: PlannerSettings(), calendar: cal)
        let tasks = [BrainTask(title: "Big essay", due: d(20, 8), estimatedMinutes: 180)]
        let plan = s.makePlan(checkIn: d(19, 23, 10), tasks: tasks, busy: [])
        XCTAssertLessThanOrEqual(plan.blocks.filter { $0.kind == .task }.reduce(0) { $0 + $1.minutes }, 60)
        XCTAssertEqual(plan.overflowTaskIDs.count, 1)
    }

    func testBreaksBetweenLongWork() {
        let s = Scheduler(settings: PlannerSettings(), calendar: cal)
        let tasks = [BrainTask(title: "Project", due: d(20, 9), estimatedMinutes: 120)]
        let plan = s.makePlan(checkIn: d(19, 16), tasks: tasks, busy: [])
        XCTAssertTrue(plan.blocks.contains { $0.kind == .breakTime })
        XCTAssertEqual(plan.blocks.filter { $0.kind == .task }.reduce(0) { $0 + $1.minutes }, 120)
    }
}

final class SyncTests: XCTestCase {
    func testNewestWinsAndTombstonesPropagate() {
        let id = UUID()
        let old = BrainTask(id: id, title: "Old", updatedAt: Date(timeIntervalSinceNow: -100))
        var new = old; new.title = "New"; new.updatedAt = Date()
        let gone = BrainTask(title: "Gone", updatedAt: Date(), deleted: true)
        let merged = SyncMerger.merge(BrainDocument(tasks: [old, gone]), BrainDocument(tasks: [new]))
        XCTAssertEqual(merged.tasks.first { $0.id == id }?.title, "New")
        XCTAssertTrue(merged.tasks.first { $0.id == gone.id }?.deleted == true)
    }

    func testStableIDs() {
        XCTAssertEqual(UUID.stable(from: "classroom:1:2"), UUID.stable(from: "classroom:1:2"))
        XCTAssertNotEqual(UUID.stable(from: "classroom:1:2"), UUID.stable(from: "classroom:1:3"))
    }

    func testRecurringExpansion() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 17))!
        let e = BrainEvent(title: "Soccer", start: start, end: start.addingTimeInterval(7200),
                           recurrence: RecurrenceRule(frequency: .weekly, weekdays: [3, 5]))
        let range = DateInterval(start: cal.date(from: DateComponents(year: 2026, month: 10, day: 19))!, duration: 14 * 86_400)
        XCTAssertEqual(e.occurrences(in: range, calendar: cal).count, 4)
    }
}

final class SchedulerSplitTests: XCTestCase {
    func testDoesNotSplitTaskThatFitsInOneBlock() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func d(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))! }
        let tasks = [
            BrainTask(title: "Quiz prep", due: d(20, 8), estimatedMinutes: 15, difficulty: 1),
            BrainTask(title: "Problem set", due: d(19, 23, 59), estimatedMinutes: 45),
        ]
        let plan = Scheduler(settings: PlannerSettings(), calendar: cal).makePlan(checkIn: d(19, 20, 18), tasks: tasks, busy: [])
        XCTAssertEqual(plan.blocks.filter { $0.title == "Problem set" }.count, 1)
    }
}

final class SchedulerEdgeTests: XCTestCase {
    func testNeverEndsOnABreak() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func d(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))! }
        for minute in stride(from: 0, to: 60, by: 7) {
            let tasks = [BrainTask(title: "A", due: d(20, 8), estimatedMinutes: 120), BrainTask(title: "B", due: d(20, 23), estimatedMinutes: 90)]
            let plan = Scheduler(settings: PlannerSettings(), calendar: cal).makePlan(checkIn: d(19, 20, minute), tasks: tasks, busy: [])
            XCTAssertNotEqual(plan.blocks.last?.kind, .breakTime, "check-in at 8:\(minute)")
        }
    }
}

final class AssignmentVsEventTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 10))! }
    func parse(_ s: String, courses: [String] = []) -> ParsedEntry { NaturalLanguageParser(calendar: cal, now: now, courses: courses).parse(s) }
    func d(_ m: Int, _ day: Int, _ h: Int = 0, _ min: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day, hour: h, minute: min))! }

    func testAssignmentsBecomeTasks() {
        let lab = parse("chem lab report friday")
        XCTAssertEqual(lab.kind, .task)
        XCTAssertEqual(lab.start, d(10, 23, 23, 59))
        XCTAssertEqual(lab.course, "Chemistry")

        XCTAssertEqual(parse("study for math test thursday").kind, .task)
        XCTAssertEqual(parse("read chapter 7 for APUSH tomorrow").kind, .task)
        XCTAssertEqual(parse("final draft english essay tuesday").kind, .task)
        XCTAssertEqual(parse("do the calc worksheet tonight").kind, .task)
        let proj = parse("history project monday 8am")
        XCTAssertEqual(proj.kind, .task)
        XCTAssertEqual(proj.start, d(10, 26, 8))
    }

    func testEventsStayEvents() {
        XCTAssertEqual(parse("soccer practice friday 5pm").kind, .event)
        XCTAssertEqual(parse("math test friday").kind, .event)
        XCTAssertEqual(parse("dentist tomorrow 3pm").kind, .event)
        XCTAssertEqual(parse("chem study group thu 4-5pm").kind, .event, "a time range is an event")
        XCTAssertEqual(parse("SAT prep class every saturday 9am").kind, .event)
    }

    func testKnownCoursesFromClassroom() {
        let p = parse("lang essay due fri", courses: ["AP Language & Composition (P2)", "AP Calculus BC"])
        XCTAssertEqual(p.kind, .task)
        XCTAssertEqual(p.course, "AP Language & Composition (P2)")
        XCTAssertEqual(parse("calc problem set tomorrow", courses: ["AP Calculus BC"]).course, "AP Calculus BC")
    }
}
