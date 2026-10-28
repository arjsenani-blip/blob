import Foundation
import SwiftUI
import BrainCore

@MainActor
final class BrainStore: ObservableObject {
    static let shared = BrainStore()
    @Published private(set) var doc: BrainDocument
    @Published var showQuickAdd = false
    @Published var toast: String?
    /// Opens the log sheet (⌘L), optionally on one assignment.
    @Published var logSheetTask: IDBox?
    @Published var showLogSheet = false
    /// The running focus timer (this device only).
    @Published var focus: FocusTimer? {
        didSet {
            if let f = focus, let d = try? JSONEncoder().encode(f) { UserDefaults.standard.set(d, forKey: "focusTimer") }
            else { UserDefaults.standard.removeObject(forKey: "focusTimer") }
        }
    }

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncError: String?
    @Published private(set) var isSyncingClassroom = false
    @Published private(set) var lastClassroomSync: Date?
    @Published private(set) var classroomError: String?

    @AppStorage("displayName") var displayName = "Arjun"
    @AppStorage("useAppleCalendar") var useAppleCalendar = false
    // Notifications (each device). Task reminders default on; event alerts default off (your calendar app sends those).
    @AppStorage("taskRemindersOn") var remindersOn = true
    @AppStorage("eventAlertsOn") var eventAlertsOn = false
    @AppStorage("reminderLead") var reminderLead = 10
    @AppStorage("dueTodayHour") var dueTodayHour = 16
    @AppStorage("dueTomorrowHour") var dueTomorrowHour = 19
    @AppStorage("morningDigestOn") var morningDigestOn = true
    /// Assignments show up as tasks in Apple Calendar (through a "Blob" Reminders list).
    @AppStorage("appleTasksOn") var appleTasksOn = false
    @AppStorage("appleStepsOn") var appleStepsOn = true
    /// Blob's events go into a "Blob" calendar in Apple Calendar.
    @AppStorage("appleEventsOn") var appleEventsOn = false
    /// Which Reminders list homework goes in ("" = a list called Homework).
    @AppStorage("appleReminderList") var appleReminderList = ""
    /// Where non-school to-dos go in Reminders ("" = nowhere, they stay in Blob).
    @AppStorage("appleOtherList") var appleOtherList = ""
    /// Reminders you add to that list come into Blob as assignments.
    @AppStorage("appleImportReminders") var appleImportReminders = true
    /// Which calendar Blob's events go in ("" = a calendar called Blob).
    @AppStorage("appleEventCalendar") var appleEventCalendar = ""
    /// Calendar that shows assignment due dates as events ("" = off). Any calendar on this device: iCloud, Google, Outlook…
    @AppStorage("appleDueCalendar") var appleDueCalendar = ""
    @Published private(set) var appleSyncError: String?
    /// Remove exact duplicate copies of events from your calendars (every half hour, with undo).
    @AppStorage("cleanDuplicateEvents") var cleanDuplicateEvents = true
    var lastDuplicateCleanup: Date? {
        get { UserDefaults.standard.object(forKey: "lastDuplicateCleanup") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastDuplicateCleanup"); objectWillChange.send() }
    }
    var forceDuplicateCleanup = false
    var pendingRestore: [AppleSync.RemovedEvent] = []
    /// What the cleanup removed (newest first), so it can be put back.
    @Published var removedDuplicates: [AppleSync.RemovedEvent] = (UserDefaults.standard.data(forKey: "removedDuplicates")
        .flatMap { try? JSONDecoder().decode([AppleSync.RemovedEvent].self, from: $0) }) ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(removedDuplicates), forKey: "removedDuplicates") }
    }
    @AppStorage("googleCalendarOn") var googleCalendarOn = false
    @AppStorage("googleEventsPushOn") var googleEventsPushOn = false
    @AppStorage("googleTasksOn") var googleTasksOn = false
    /// Assignment due dates as events on your main Google calendar.
    @AppStorage("googleDueEventsOn") var googleDueEventsOn = false
    /// Logged work sessions as events on a Google calendar — your calendar becomes a record of what you did.
    @AppStorage("googleLogEventsOn") var googleLogEventsOn = false
    @Published var googleEventCache: [GoogleCalendarSync.CachedEvent] = []
    @Published var googleCalendarError: String?
    @Published var isSyncingGoogle = false
    var lastGoogleRead: Date?
    private var googleTask: Task<Void, Never>?
    let appleSync = AppleSync()
    private var appleSyncRunning = false
    @Published var tickTickRunning = false
    @Published var lastTickTickSync: Date?
    @Published var tickTickError: String?
    private var tickTickTask: Task<Void, Never>?
    /// When the last Apple sync wrote — its own Calendar/Reminders changes shouldn't trigger another sync.
    var lastAppleWrite = Date.distantPast
    private var appleTask: Task<Void, Never>?

    let school = GoogleAccount(role: .school)
    let personal = GoogleAccount(role: .personal)
    let systemCalendar = SystemCalendarBridge()

    private let fileURL: URL
    /// Running on a test data file: nothing is synced anywhere.
    let isTestData: Bool
    private var syncTask: Task<Void, Never>?
    private var timer: Timer?

    init() {
        // `-dataDir <folder>`: use a separate data file and never sync (for screenshots and testing).
        let testDir = UserDefaults.standard.string(forKey: "dataDir")
        isTestData = testDir != nil
        let dir = testDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArjunsBrain", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("brain.json")
        if let data = try? Data(contentsOf: fileURL), let d = try? JSONDecoder().decode(BrainDocument.self, from: data) {
            doc = d
        } else {
            doc = BrainDocument()
        }
        focus = UserDefaults.standard.data(forKey: "focusTimer").flatMap { try? JSONDecoder().decode(FocusTimer.self, from: $0) }
        lastSync = UserDefaults.standard.object(forKey: "lastSync") as? Date
        lastClassroomSync = UserDefaults.standard.object(forKey: "lastClassroomSync") as? Date
        loadGoogleCache()
        updateCourseColors()
    }

    // MARK: Lifecycle

    func onLaunch() async {
        repairAccidentalSteps()
        convertHomeworkEvents()
        convertToDoEvents()
        _ = await Reminders.requestAuthorization()
        Pomodoro.shared.store = self
        Pomodoro.shared.catchUp()
        systemCalendar.onExternalChange = { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastAppleWrite) > 3 else { return }
            self.scheduleAppleSync(after: 1.5)
        }
        await syncEverything()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.syncDevices()
                await self?.syncGoogle()
                await self?.syncTickTick()
                await self?.cleanDuplicatesIfDue()
            }
        }
    }

    func becameActive() {
        Task { await syncEverything() }
    }

    func syncEverything() async {
        guard !isTestData else { return }
        await syncDevices()
        await syncApple()
        await syncGoogle()
        await syncTickTick()
        if school.isSignedIn, (lastClassroomSync ?? .distantPast) < Date().addingTimeInterval(-10 * 60) {
            await syncClassroom()
        }
    }

    // MARK: Derived data

    var events: [BrainEvent] { doc.events.filter { !$0.deleted } }
    var tasks: [BrainTask] { doc.tasks.filter { !$0.deleted } }
    var pendingTasks: [BrainTask] { tasks.filter { !$0.isCompleted } }
    var settings: PlannerSettings { doc.settings }

    func task(_ id: UUID?) -> BrainTask? { id.flatMap { id in doc.tasks.first { $0.id == id } } }
    func event(_ id: UUID?) -> BrainEvent? { id.flatMap { id in doc.events.first { $0.id == id } } }

    func occurrences(in range: DateInterval) -> [EventOccurrence] {
        var out = events.flatMap { $0.occurrences(in: range) }
        if useAppleCalendar { out += systemCalendar.occurrences(in: range) }
        out += googleCalendarOccurrences(in: range)
        // The same event can arrive from more than one place (Apple's and Google's holiday calendars, an event copied into
        // two accounts, a Google calendar that's also in Apple Calendar). Show one of each.
        out = EventDeduper.dedupe(out)
        return out.sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    func occurrences(on day: Date) -> [EventOccurrence] {
        let start = Calendar.current.startOfDay(for: day)
        return occurrences(in: DateInterval(start: start, duration: 86_400))
    }

    func tasksDue(on day: Date) -> [BrainTask] {
        tasks.filter { $0.due.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// Latest check-in from today (on either device).
    var todayPlan: DayPlan? {
        doc.plans.filter { !$0.deleted && Calendar.current.isDateInToday($0.checkInAt) }
            .max { $0.checkInAt < $1.checkInAt }
    }

    func isBlockDone(_ b: PlanBlock) -> Bool {
        b.isDone || (b.taskID.flatMap { task($0) }?.isCompleted ?? false)
    }

    // MARK: Quick add

    /// The user's class names (Classroom + existing assignments) — lets quick add recognize school work.
    var knownCourses: [String] { Array(Set(tasks.compactMap(\.course))).sorted() }

    func parse(_ text: String) -> ParsedEntry { NaturalLanguageParser(courses: knownCourses).parse(text) }

    @discardableResult
    func add(_ p: ParsedEntry, as kind: ParsedEntry.Kind? = nil) -> String {
        let kind = kind ?? p.kind
        let title = p.title.isEmpty ? "Untitled" : p.title
        if kind == .task {
            let due: Date? = p.start.map { p.hasExplicitTime || p.kind == .task ? $0 : Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: $0)! }
            // "long-term" / "big project" in the text means: track it over days with steps.
            let longPattern = #"\s*\b(long[- ]?term|big project|track (it|this))\b\s*"#
            let explicitLong = title.range(of: longPattern, options: [.regularExpression, .caseInsensitive]) != nil
            let cleanTitle = explicitLong ? title.replacingOccurrences(of: longPattern, with: " ", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces) : title
            let t = BrainTask(title: cleanTitle.isEmpty ? title : cleanTitle, course: p.course ?? p.tag, due: due, estimatedMinutes: p.durationMinutes ?? 30,
                              priority: p.priority, estimateIsUserSet: p.durationMinutes != nil,
                              repeats: p.recurrence.isRepeating ? p.recurrence : nil)
            upsert(t)
            show("Added to-do: \(t.title)" + (t.repeats.map { " · " + $0.frequency.label.lowercased() } ?? ""))
            setUpLongTermIfNeeded(t.id, explicit: explicitLong)
            return t.title
        } else {
            let start = p.start ?? Calendar.current.date(bySettingHour: Calendar.current.component(.hour, from: Date()) + 1, minute: 0, second: 0, of: Date())!
            let end = p.end ?? start.addingTimeInterval(3600)
            upsert(BrainEvent(title: title, start: start, end: end, isAllDay: p.isAllDay, location: p.location,
                              tag: p.tag, recurrence: p.recurrence))
            show("Added: \(title)")
        }
        return title
    }

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if toast == message { toast = nil }
        }
    }

    // MARK: Mutations

    func upsert(_ e: BrainEvent) {
        var e = e
        e.updatedAt = Date()
        if let i = doc.events.firstIndex(where: { $0.id == e.id }) { doc.events[i] = e } else { doc.events.append(e) }
        changed()
    }

    func delete(_ e: BrainEvent) {
        var e = e
        e.deleted = true
        upsert(e)
    }

    /// Removes just one day from a repeating event.
    func deleteOccurrence(_ o: EventOccurrence) {
        guard var e = event(o.eventID) else { return }
        if e.recurrence.isRepeating {
            e.excludedDays.append(Calendar.current.startOfDay(for: o.start))
            upsert(e)
        } else {
            delete(e)
        }
    }

    func upsert(_ r: DailyRoutine) {
        var r = r
        r.updatedAt = Date()
        if let i = doc.routines.firstIndex(where: { $0.id == r.id }) { doc.routines[i] = r } else { doc.routines.append(r) }
        changed()
    }

    func upsert(_ t: BrainTask) {
        var t = t
        t.updatedAt = Date()
        if let i = doc.tasks.firstIndex(where: { $0.id == t.id }) { doc.tasks[i] = t } else { doc.tasks.append(t) }
        changed()
    }

    func delete(_ t: BrainTask) {
        var t = t
        t.deleted = true
        upsert(t)
    }

    func toggle(_ t: BrainTask) {
        var t = t
        t.isCompleted.toggle()
        t.completedAt = t.isCompleted ? Date() : nil
        if t.isCompleted { handOffRepeat(&t) }
        upsert(t)
    }

    func updateSettings(_ change: (inout PlannerSettings) -> Void) {
        var s = doc.settings
        change(&s)
        s.updatedAt = Date()
        doc.settings = s
        changed()
    }

    // MARK: Check-in

    func checkIn() {
        let now = Date()
        // Credit time already spent today on unfinished multi-part tasks.
        var progress: [UUID: Int] = [:]
        if let previous = todayPlan {
            for b in previous.blocks where b.kind == .task && b.isDone {
                if let id = b.taskID { progress[id, default: 0] += b.minutes }
            }
        }
        let horizon = DateInterval(start: now, duration: 30 * 3600)
        let plan = Scheduler(settings: doc.settings)
            .makePlan(checkIn: now, tasks: tasks, busy: occurrences(in: horizon), progress: progress)
        doc.plans.append(plan)
        changed()
        show(plan.blocks.contains { $0.kind == .task } ? "Your plan is ready" : "Nothing due — you're free!")
    }

    func updateBlock(_ blockID: UUID, _ change: (inout PlanBlock) -> Void) {
        guard let plan = todayPlan, let pi = doc.plans.firstIndex(where: { $0.id == plan.id }),
              let bi = doc.plans[pi].blocks.firstIndex(where: { $0.id == blockID }) else { return }
        change(&doc.plans[pi].blocks[bi])
        doc.plans[pi].updatedAt = Date()
        changed()
    }

    func startBlock(_ b: PlanBlock) {
        updateBlock(b.id) { $0.startedAt = Date() }
    }

    func completeBlock(_ b: PlanBlock) {
        updateBlock(b.id) { $0.isDone = true }
        guard let id = b.taskID, var t = task(id) else { return }
        let spent = b.startedAt.map { max(1, Int(Date().timeIntervalSince($0) / 60)) } ?? b.minutes
        logWork(&t, minutes: spent, note: nil, milestoneID: b.milestoneID)
        if b.isFinalPart && b.sessionOnly != true {
            if let m = b.milestoneID {
                finishStep(&t, m)
                show(t.isCompleted ? "Nice — \(t.title) done ✓" : "Step done ✓" + (t.nextMilestone.map { " Next: \($0.title)" } ?? ""))
            } else {
                markDone(&t)
                show("Nice — \(t.title) done ✓")
            }
        } else if b.isFinalPart {
            show("Logged \(Scheduler.durationText(spent)) · \(Int(t.progress * 100))% done")
        }
        upsert(t)
    }

    // MARK: Classroom

    /// Average actual minutes for finished assignments in a course, once there's enough history.
    func learnedEstimate(course: String) -> Int? {
        let samples = tasks.filter { $0.course == course && $0.isCompleted && ($0.actualMinutes ?? 0) > 0 }.compactMap(\.actualMinutes)
        guard samples.count >= 2 else { return nil }
        return Int(Double(samples.reduce(0, +)) / Double(samples.count))
    }

    func syncClassroom() async {
        guard school.isSignedIn, !isSyncingClassroom, !isTestData else { return }
        isSyncingClassroom = true
        classroomError = nil
        defer { isSyncingClassroom = false }
        do {
            let items = try await ClassroomService(account: school).fetchAssignments()
            apply(items)
            lastClassroomSync = Date()
            UserDefaults.standard.set(lastClassroomSync, forKey: "lastClassroomSync")
        } catch {
            classroomError = error.localizedDescription
        }
    }

    private func apply(_ items: [ClassroomItem]) {
        var added = 0, graded: [String] = []
        for item in items {
            let id = UUID.stable(from: "classroom:\(item.externalID)")
            if var t = task(id) {
                let before = t
                t.title = item.title
                t.course = item.course
                t.due = item.due
                t.link = item.link
                t.maxPoints = item.maxPoints ?? t.maxPoints
                t.submissionState = item.state
                t.isLate = item.isLate
                if t.startDate == nil { t.startDate = item.assignedOn }
                if let g = item.assignedGrade, t.pointsEarned != g {
                    t.pointsEarned = g
                    graded.append(t.title)
                }
                if item.isTurnedIn && !t.isCompleted { markDone(&t) }
                // Unsubmitted in Classroom ("reclaimed") → open again.
                if item.state == "RECLAIMED_BY_STUDENT" && t.isCompleted { t.isCompleted = false; t.completedAt = nil }
                if t != before { upsert(t) }
            } else {
                let finished = item.isTurnedIn || item.assignedGrade != nil
                // Old finished work is kept only when it has a grade — that's your grade history.
                if finished, (item.due ?? .distantPast) < Date(), item.assignedGrade == nil { continue }
                if !finished, let due = item.due, due < Date().addingTimeInterval(-21 * 86_400) { continue }
                var (mins, difficulty) = ClassroomService.estimate(for: item)
                if let learned = learnedEstimate(course: item.course) { mins = (mins + learned * 2) / 3 }
                var t = BrainTask(id: id, title: item.title, course: item.course, notes: item.description, due: item.due,
                                  estimatedMinutes: mins, difficulty: difficulty, source: .classroom,
                                  externalID: item.externalID, link: item.link, isCompleted: finished,
                                  completedAt: finished ? (item.due ?? Date()) : nil, startDate: item.assignedOn,
                                  createdAt: item.assignedOn ?? Date(), pointsEarned: item.assignedGrade, maxPoints: item.maxPoints,
                                  submissionState: item.state, isLate: item.isLate)
                upsert(t)
                if !finished {
                    added += 1
                    // Big Classroom projects get steps too.
                    if MilestonePlanner.looksLongTerm(title: t.title, due: t.due) || (item.maxPoints ?? 0) >= 100 && (t.due ?? .distantPast) > Date().addingTimeInterval(5 * 86_400) {
                        if let e = MilestonePlanner.defaultEstimate(title: t.title) { t.estimatedMinutes = max(t.estimatedMinutes, e) }
                        planSteps(&t)
                        upsert(t)
                    }
                }
            }
        }
        if added > 0 { show("\(added) new assignment\(added == 1 ? "" : "s") from Classroom") }
        else if let g = graded.first { show(graded.count == 1 ? "New grade: \(g)" : "\(graded.count) new grades from Classroom") }
    }

    // MARK: Device sync

    /// A separate personal account wins; otherwise the school account handles sync too.
    var syncAccount: GoogleAccount? {
        if personal.isSignedIn { return personal }
        if school.isSignedIn, school.hasScope(GoogleAccount.driveScope) { return school }
        return nil
    }

    func syncDevices() async {
        guard let account = syncAccount, !isSyncing, !isTestData else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let snapshot = doc
            let merged = try await DriveSync(account: account).sync(local: snapshot)
            // Merge again so edits made while the network call was in flight aren't lost.
            let final = SyncMerger.merge(doc, merged)
            if final != doc {
                doc = final
                updateCourseColors()
                save()
                rescheduleReminders()
            }
            syncError = nil
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: "lastSync")
        } catch {
            syncError = error.localizedDescription
        }
    }

    // MARK: Persistence

    // MARK: Apple Calendar & Reminders

    func scheduleAppleSync(after seconds: Double = 1) {
        guard appleTasksOn || appleEventsOn || !appleDueCalendar.isEmpty else { return }
        appleTask?.cancel()
        appleTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await syncApple()
        }
    }

    func syncApple() async {
        SyncLog.write("apple: start tasks=\(appleTasksOn) due=\(!appleDueCalendar.isEmpty) events=\(appleEventsOn)")
        // (Also runs once after due dates are turned off, to take them back off the calendar.)
        let saved = UserDefaults.standard.dictionary(forKey: "appleSyncState") as? [String: String] ?? [:]
        // Duplicate cleanup rides along at most every 30 minutes (or right away when asked).
        let cleanup = cleanDuplicateEvents && systemCalendar.authorized
            && (forceDuplicateCleanup || (lastDuplicateCleanup ?? .distantPast) < Date().addingTimeInterval(-30 * 60))
        let restore = pendingRestore
        guard appleTasksOn || appleEventsOn || !appleDueCalendar.isEmpty || saved["lastDueCalendar"] != nil || cleanup || !restore.isEmpty,
              !isTestData, !appleSyncRunning else { return }
        appleSyncRunning = true
        defer { appleSyncRunning = false }
        do {
            var options = AppleSync.Options(tasks: appleTasksOn, steps: appleStepsOn, events: appleEventsOn,
                                            reminderList: appleReminderList.isEmpty ? nil : appleReminderList,
                                            otherTasksList: appleOtherList.isEmpty ? nil : appleOtherList,
                                            importReminders: appleImportReminders,
                                            eventCalendar: appleEventCalendar.isEmpty ? nil : appleEventCalendar,
                                            dueCalendar: appleDueCalendar.isEmpty ? nil : appleDueCalendar, state: saved)
            options.cleanDuplicates = cleanup
            options.restore = restore
            #if os(macOS)
            let r = try await CalendarHelper.run(tasks: doc.tasks, events: doc.events, options: options)
            #else
            let r = try await appleSync.sync(tasks: doc.tasks, events: doc.events, options: options)
            #endif
            UserDefaults.standard.set(r.state, forKey: "appleSyncState")
            lastAppleWrite = Date()
            if cleanup {
                forceDuplicateCleanup = false
                lastDuplicateCleanup = Date()
                if !r.removedDuplicates.isEmpty {
                    removedDuplicates = Array((r.removedDuplicates + removedDuplicates).prefix(200))
                    show("Removed \(r.removedDuplicates.count) duplicate event\(r.removedDuplicates.count == 1 ? "" : "s")")
                }
                SyncLog.write("apple: duplicate cleanup removed \(r.removedDuplicates.count)")
            }
            if !restore.isEmpty {
                let back = Set(restore.map(\.id))
                pendingRestore = []
                removedDuplicates.removeAll { back.contains($0.id) }
                show("Put back \(r.restored) event\(r.restored == 1 ? "" : "s")")
            }
            appleSyncError = r.warnings.isEmpty ? nil : r.warnings.joined(separator: "\n")
            if !r.warnings.isEmpty { SyncLog.write("apple: warnings \(r.warnings)") }
            // Reminders you added in the Reminders app → assignments (class and long-term setup work like quick add).
            for item in r.imported where task(item.id) == nil {
                let parsed = parse(item.title)
                upsert(BrainTask(id: item.id, title: item.title, course: parsed.course, notes: item.notes,
                                 due: item.due ?? (parsed.kind == .task ? parsed.start : nil),
                                 estimatedMinutes: parsed.durationMinutes ?? 30, priority: item.highPriority ? .high : .normal,
                                 externalID: "reminder:\(item.id.uuidString)"))
                setUpLongTermIfNeeded(item.id, explicit: false)
            }
            if !r.imported.isEmpty { show("\(r.imported.count) new from Reminders") }
            SyncLog.write("apple: ok, imported \(r.imported.count), done-in-apple \(r.completedInApple.count), due moved \(r.dueChanged.count)")
            // Bring back what you changed in Calendar / Reminders.
            for id in r.completedInApple { if var t = task(id), !t.isCompleted { markDone(&t); upsert(t) } }
            for id in r.reopenedInApple { if var t = task(id), t.isCompleted { t.isCompleted = false; t.completedAt = nil; upsert(t) } }
            for s in r.stepsDoneInApple { if var t = task(s.task) { finishStep(&t, s.step); upsert(t) } }
            for d in r.dueChanged { if var t = task(d.task) { t.due = d.due; upsert(t) } }
            for e in r.eventsChanged { upsert(e) }
            if !r.completedInApple.isEmpty { show("Marked done from Apple Calendar ✓") }
        } catch {
            appleSyncError = error.localizedDescription
            SyncLog.write("apple: error \(error)")
        }
    }

    // MARK: Homework that was saved as an event

    /// One-time fix: quick add used to save things like "Study 1 hour for Stats" as a 1-hour event. Those become
    /// assignments (due that day, with the time as the estimate), so they show on Today and can be logged.
    func convertHomeworkEvents() {
        guard !UserDefaults.standard.bool(forKey: "convertedHomeworkEvents") else { return }
        UserDefaults.standard.set(true, forKey: "convertedHomeworkEvents")
        let since = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-14 * 86_400)
        var moved = 0
        for e in events where !e.recurrence.isRepeating && (e.location ?? "").isEmpty && e.start >= since
            && NaturalLanguageParser.looksLikeAssignment(e.title) {
            let p = parse(e.title)
            let minutes = p.durationMinutes ?? (e.isAllDay ? 60 : max(15, Int(e.end.timeIntervalSince(e.start) / 60)))
            let due = e.isAllDay ? Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: e.start)! : e.end
            let id = UUID.stable(from: "event-as-task:\(e.id.uuidString)")
            if task(id) == nil {
                upsert(BrainTask(id: id, title: p.title.isEmpty ? e.title : p.title, course: p.course ?? e.tag, notes: e.notes,
                                 due: due, estimatedMinutes: minutes, estimateIsUserSet: true))
            }
            delete(e)
            moved += 1
        }
        if moved > 0 { show("Moved \(moved) study block\(moved == 1 ? "" : "s") to Assignments") }
    }

    /// Once: chores and errands that older quick-add saved as calendar events ("Clean room") become to-dos.
    /// Ids come from the event's, so the Mac and iPhone doing this at the same time can't make two.
    func convertToDoEvents() {
        guard !UserDefaults.standard.bool(forKey: "convertedToDoEvents") else { return }
        UserDefaults.standard.set(true, forKey: "convertedToDoEvents")
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var moved: [String] = []
        for e in events where (e.location ?? "").isEmpty && NaturalLanguageParser.looksLikeToDo(e.title, allDay: e.isAllDay) {
            let upcoming = e.occurrences(in: DateInterval(start: today, duration: 60 * 86_400)).first?.start
            guard e.end >= today.addingTimeInterval(-14 * 86_400) || upcoming != nil else { continue }
            let day = e.recurrence.isRepeating ? (upcoming ?? e.start) : e.start
            let due = e.isAllDay ? cal.date(bySettingHour: 23, minute: 59, second: 0, of: day)! : day
            let id = UUID.stable(from: "event-as-todo:\(e.id.uuidString)")
            if task(id) == nil, !hasOpenTask(titled: e.title) {
                upsert(BrainTask(id: id, title: e.title, course: e.tag, notes: e.notes, due: due, estimatedMinutes: 30,
                                 repeats: e.recurrence.isRepeating ? e.recurrence : nil))
            }
            delete(e)
            moved.append(e.title)
        }
        if !moved.isEmpty { show("Moved \(moved.count) to-do\(moved.count == 1 ? "" : "s") off the calendar") }
    }

    private func hasOpenTask(titled title: String) -> Bool {
        tasks.contains { !$0.isCompleted && $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    // MARK: Duplicate events

    /// The half-hourly pass (from the 90-second timer).
    func cleanDuplicatesIfDue() async {
        guard cleanDuplicateEvents, systemCalendar.authorized,
              (lastDuplicateCleanup ?? .distantPast) < Date().addingTimeInterval(-30 * 60) else { return }
        await syncApple()
    }

    /// Run the duplicate cleanup now instead of waiting for the next half hour.
    func cleanDuplicatesNow() async {
        forceDuplicateCleanup = true
        await syncApple()
    }

    /// Put back events the cleanup removed.
    func restoreDuplicates(_ items: [AppleSync.RemovedEvent]) async {
        pendingRestore = items
        await syncApple()
    }

    /// Gives each class its own color (first-seen order, so colors don't shuffle when you add a class).
    func updateCourseColors() {
        var index = Brand.courseIndex
        let seen = doc.tasks.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }.compactMap { $0.course?.lowercased() }
        for c in seen where index[c] == nil { index[c] = index.count }
        Brand.courseIndex = index
    }

    private func changed() {
        updateCourseColors()
        save()
        rescheduleReminders()
        scheduleAppleSync()
        if UserDefaults.standard.bool(forKey: "tickTickOn") {
            tickTickTask?.cancel()
            tickTickTask = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await syncTickTick()
            }
        }
        if googleEventsPushOn || googleTasksOn || googleDueEventsOn || googleLogEventsOn {
            googleTask?.cancel()
            googleTask = Task {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await syncGoogle()
            }
        }
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await syncDevices()
        }
    }

    private func save() {
        if let data = try? DriveSync.encoder.encode(doc) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    func rescheduleReminders() {
        guard !isTestData else { return }
        let range = DateInterval(start: Date(), duration: 7 * 86_400)
        Reminders.reschedule(tasks: doc.tasks, blocks: todayPlan?.blocks ?? [], events: (eventAlertsOn || morningDigestOn) ? occurrences(in: range) : [], routines: routines,
                             settings: .init(tasks: remindersOn, dueTodayHour: dueTodayHour, dueTomorrowHour: dueTomorrowHour,
                                             morningDigest: morningDigestOn, events: eventAlertsOn, eventLead: reminderLead))
    }

}

/// A small local log of background syncs (~/Library/Logs/Blob/sync.log), for figuring out sync problems.
enum SyncLog {
    static func write(_ line: String) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Blob")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sync.log")
        let entry = "\(Date().formatted(.iso8601)) \(line)\n"
        // Start over past ~500 KB.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 500_000 { try? FileManager.default.removeItem(at: url) }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(entry.utf8))
            try? h.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

#if os(macOS)
import AppKit

/// Runs Blob's Calendar & Reminders helper (Contents/MacOS/BlobCalendarHelper) for one sync.
enum CalendarHelper {
    struct Input: Encodable { var tasks: [BrainTask]; var events: [BrainEvent]; var options: AppleSync.Options }
    struct Output: Decodable { var result: AppleSync.Result?; var error: String? }
    struct Failure: LocalizedError { var message: String; var errorDescription: String? { message } }

    static func run(tasks: [BrainTask], events: [BrainEvent], options: AppleSync.Options) async throws -> AppleSync.Result {
        let exe = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BlobCalendarHelper")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { throw Failure(message: "Blob's calendar helper is missing — reinstall Blob.") }
        let input = try JSONEncoder().encode(Input(tasks: tasks, events: events, options: options))
        let data: Data = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = exe
                let inPipe = Pipe(), outPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: error); return }
                inPipe.fileHandleForWriting.write(input)
                try? inPipe.fileHandleForWriting.close()
                // Give up after two minutes rather than hang.
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + 120)
                timer.setEventHandler { if p.isRunning { p.terminate() } }
                timer.resume()
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: out)
            }
        }
        let output = try JSONDecoder().decode(Output.self, from: data)
        if let r = output.result { return r }
        throw Failure(message: output.error ?? "Calendar sync didn't finish.")
    }
}
#endif
