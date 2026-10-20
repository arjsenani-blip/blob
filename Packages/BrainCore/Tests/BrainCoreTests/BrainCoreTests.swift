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

final class TrackingTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    func d(_ m: Int, _ day: Int, _ h: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day, hour: h))! }

    func testOldFilesStillLoad() throws {
        let json = #"{"id":"6F1C3E9A-1111-4222-8333-944455556666","title":"Old","estimatedMinutes":30,"difficulty":2,"priority":1,"source":"manual","isCompleted":false,"estimateIsUserSet":false,"updatedAt":10,"deleted":false}"#
        let t = try JSONDecoder().decode(BrainTask.self, from: Data(json.utf8))
        XCTAssertEqual(t.title, "Old")
        XCTAssertTrue(t.milestones.isEmpty)
        XCTAssertNil(t.createdAt)
        let block = #"{"id":"6F1C3E9A-1111-4222-8333-944455556666","kind":"task","title":"x","start":0,"end":60,"isDone":false}"#
        XCTAssertNil(try JSONDecoder().decode(PlanBlock.self, from: Data(block.utf8)).milestoneID)
    }

    func testSuggestedStepsFitBeforeDue() {
        let steps = MilestonePlanner.suggest(title: "History research essay", start: d(10, 19, 16), due: d(11, 2, 23), totalMinutes: 300, calendar: cal)
        XCTAssertEqual(steps.map(\.title).first, "Research & sources")
        XCTAssertEqual(steps.count, 5)
        XCTAssertEqual(steps.last?.due, d(11, 2, 23))
        let dates = steps.compactMap(\.due)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertTrue(dates.dropLast().allSatisfy { $0 <= d(11, 1, 23) }, "steps finish a day early")
        XCTAssertEqual(steps.reduce(0) { $0 + $1.estimatedMinutes }, 300)
    }

    func testProgressAndPace() {
        var t = BrainTask(title: "Essay", due: d(10, 31, 23), startDate: d(10, 17), createdAt: d(10, 17))
        t.milestones = [Milestone(title: "A", due: d(10, 22), estimatedMinutes: 60),
                        Milestone(title: "B", due: d(10, 27), estimatedMinutes: 120),
                        Milestone(title: "C", due: d(10, 31), estimatedMinutes: 60)]
        XCTAssertTrue(t.isLongTerm)
        XCTAssertEqual(t.progress, 0)
        XCTAssertEqual(t.pace(now: d(10, 18), calendar: cal), .notStarted)
        XCTAssertEqual(t.pace(now: d(10, 24), calendar: cal), .behind, "step A's date passed")
        t.milestones[0].isDone = true
        XCTAssertEqual(t.progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(t.pace(now: d(10, 18), calendar: cal), .ahead)
        XCTAssertEqual(t.pace(now: d(10, 20), calendar: cal), .onTrack)
        XCTAssertEqual(t.remainingMinutes, 180)
        XCTAssertEqual(t.pace(now: d(11, 1), calendar: cal), .overdue)
    }

    func testGradeAverageIsPointWeighted() {
        let a = BrainTask(title: "Quiz", course: "Chem", isCompleted: true, pointsEarned: 9, maxPoints: 10)
        let b = BrainTask(title: "Test", course: "Chem", isCompleted: true, pointsEarned: 70, maxPoints: 100)
        let s = CourseSummary.build([a, b]).first!
        XCTAssertEqual(s.averageGrade!, 79 / 110 * 100, accuracy: 0.01)
        XCTAssertEqual(s.gradedCount, 2)
    }

    func testPlannerDoesTodaysShareOfABigProject() {
        let now = d(10, 19, 16)
        var project = BrainTask(title: "Science fair project", due: d(10, 30, 23), estimatedMinutes: 600)
        project.createdAt = d(10, 15)
        let plan = Scheduler(settings: PlannerSettings(), calendar: cal).makePlan(checkIn: now, tasks: [project], busy: [])
        let work = plan.blocks.filter { $0.kind == .task }
        let minutes = work.reduce(0) { $0 + $1.minutes }
        XCTAssertGreaterThanOrEqual(minutes, 50)
        XCTAssertLessThan(minutes, 120, "spread over the days left, not 10 hours tonight")
        XCTAssertTrue(work.allSatisfy { $0.sessionOnly == true })
    }

    func testPlannerWorksOnNextStep() {
        let now = d(10, 19, 16)
        var essay = BrainTask(title: "Essay", due: d(10, 30, 23))
        let step = Milestone(title: "Outline", due: d(10, 20, 21), estimatedMinutes: 40)
        essay.milestones = [step, Milestone(title: "Draft", due: d(10, 28), estimatedMinutes: 90)]
        let plan = Scheduler(settings: PlannerSettings(), calendar: cal).makePlan(checkIn: now, tasks: [essay], busy: [])
        let work = plan.blocks.filter { $0.kind == .task }
        XCTAssertEqual(work.first?.title, "Essay — Outline")
        XCTAssertEqual(work.first?.milestoneID, step.id)
        XCTAssertEqual(work.reduce(0) { $0 + $1.minutes }, 40, "due tomorrow, so the whole step")
    }

    func testWorkloadSpreadsOverDays() {
        let now = d(10, 19, 9)
        let t = BrainTask(title: "Big", due: d(10, 23, 23), estimatedMinutes: 240)
        let days = Workload.perDay([t], from: now, days: 7, calendar: cal)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.prefix(4).map(\.minutes), [60, 60, 60, 60])
        XCTAssertEqual(days[4].minutes, 0, "keeps the due day free")
    }
}

final class ProgressLogTests: XCTestCase {
    let p = ProgressLogParser()

    func testWorkedTime() {
        XCTAssertEqual(p.parse("worked 45 min on the history essay"), .worked(minutes: 45, query: "history essay", note: nil))
        XCTAssertEqual(p.parse("I spent 2 hours on my chem lab"), .worked(minutes: 120, query: "chem lab", note: nil))
        XCTAssertEqual(p.parse("did an hour of calc homework"), .worked(minutes: 60, query: "calc homework", note: nil))
        XCTAssertEqual(p.parse("worked on the science fair project for 1.5 hours"), .worked(minutes: 90, query: "science fair project", note: nil))
        XCTAssertEqual(p.parse("Hey Blob, log 30 minutes on english essay - wrote the intro"), .worked(minutes: 30, query: "english essay", note: "wrote the intro"))
        XCTAssertEqual(p.parse("studied for 40 minutes for the bio test"), .worked(minutes: 40, query: "bio test", note: nil))
        XCTAssertEqual(p.parse("worked for half an hour"), .worked(minutes: 30, query: "", note: nil))
    }

    func testStepsAndCompletion() {
        XCTAssertEqual(p.parse("finished the outline for my english essay"), .finishedStep(step: "outline", query: "english essay"))
        XCTAssertEqual(p.parse("done with the rough draft of the history paper"), .finishedStep(step: "rough draft", query: "history paper"))
        XCTAssertEqual(p.parse("turned in the chem lab"), .completed(query: "chem lab"))
        XCTAssertEqual(p.parse("I finished my spanish worksheet"), .completed(query: "spanish worksheet"))
        XCTAssertEqual(p.parse("calc problem set is done"), .completed(query: "calc problem set"))
        XCTAssertEqual(p.parse("started the history project"), .started(query: "history project"))
    }

    func testGradesAndPercent() {
        XCTAssertEqual(p.parse("got 92/100 on the chem lab"), .grade(earned: 92, possible: 100, query: "chem lab"))
        XCTAssertEqual(p.parse("I got 18 out of 20 on the spanish quiz"), .grade(earned: 18, possible: 20, query: "spanish quiz"))
        XCTAssertEqual(p.parse("got a 95 on the bio test"), .grade(earned: 95, possible: 100, query: "bio test"))
        XCTAssertEqual(p.parse("got an A- on my essay"), .grade(earned: 92, possible: 100, query: "essay"))
        XCTAssertEqual(p.parse("history essay is 60% done"), .progress(percent: 60, query: "history essay"))
        XCTAssertEqual(p.parse("I'm halfway through the english essay"), .progress(percent: 50, query: "english essay"))
        XCTAssertEqual(p.parse("break the science project into steps"), .planSteps(query: "science project"))
    }

    func testNewThingsAreNotLogs() {
        XCTAssertNil(p.parse("finish the essay by friday"))
        XCTAssertNil(p.parse("history essay due friday"))
        XCTAssertNil(p.parse("soccer practice tomorrow 5pm"))
        XCTAssertNil(p.parse("read chapter 4"))
    }

    func testMatcher() {
        let essay = BrainTask(title: "Unit 3 DBQ Essay", course: "AP World History", due: Date().addingTimeInterval(86_400 * 5))
        let lab = BrainTask(title: "Titration Lab Report", course: "Chemistry Honors", due: Date().addingTimeInterval(86_400 * 2))
        let quiz = BrainTask(title: "Vocab quiz 7", course: "Spanish 3")
        XCTAssertEqual(TaskMatcher.best("history essay", in: [essay, lab, quiz])?.id, essay.id)
        XCTAssertEqual(TaskMatcher.best("chem lab", in: [essay, lab, quiz])?.id, lab.id)
        XCTAssertEqual(TaskMatcher.best("spanish quiz", in: [essay, lab, quiz])?.id, quiz.id)
        XCTAssertNil(TaskMatcher.best("piano recital", in: [essay, lab, quiz]))
        XCTAssertEqual(TaskMatcher.best("", in: [essay, lab, quiz])?.id, lab.id, "empty = soonest due")
        var e = essay
        e.milestones = [Milestone(title: "Research & sources"), Milestone(title: "Outline"), Milestone(title: "Rough draft")]
        XCTAssertEqual(TaskMatcher.step("rough draft", in: e)?.title, "Rough draft")
        XCTAssertEqual(TaskMatcher.step("research", in: e)?.title, "Research & sources")
    }
}
