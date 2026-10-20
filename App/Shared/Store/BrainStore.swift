import Foundation
import SwiftUI
import BrainCore

@MainActor
final class BrainStore: ObservableObject {
    static let shared = BrainStore()
    @Published private(set) var doc: BrainDocument
    @Published var showQuickAdd = false
    @Published var toast: String?

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncError: String?
    @Published private(set) var isSyncingClassroom = false
    @Published private(set) var lastClassroomSync: Date?
    @Published private(set) var classroomError: String?

    @AppStorage("displayName") var displayName = "Arjun"
    @AppStorage("useAppleCalendar") var useAppleCalendar = false
    @AppStorage("remindersOn") var remindersOn = true
    @AppStorage("reminderLead") var reminderLead = 10

    let school = GoogleAccount(role: .school)
    let personal = GoogleAccount(role: .personal)
    let systemCalendar = SystemCalendarBridge()

    private let fileURL: URL
    private var syncTask: Task<Void, Never>?
    private var timer: Timer?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArjunsBrain", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("brain.json")
        if let data = try? Data(contentsOf: fileURL), let d = try? JSONDecoder().decode(BrainDocument.self, from: data) {
            doc = d
        } else {
            doc = BrainDocument()
        }
        lastSync = UserDefaults.standard.object(forKey: "lastSync") as? Date
        lastClassroomSync = UserDefaults.standard.object(forKey: "lastClassroomSync") as? Date
    }

    // MARK: Lifecycle

    func onLaunch() async {
        if remindersOn { _ = await Reminders.requestAuthorization() }
        await syncEverything()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncDevices() }
        }
    }

    func becameActive() {
        Task { await syncEverything() }
    }

    func syncEverything() async {
        await syncDevices()
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
            upsert(BrainTask(title: title, course: p.course ?? p.tag, due: due, estimatedMinutes: p.durationMinutes ?? 30,
                             priority: p.priority, estimateIsUserSet: p.durationMinutes != nil))
            show("Added to-do: \(title)")
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
        show(plan.blocks.contains { $0.kind == .task } ? "Your timeline is ready" : "Nothing due — you're free!")
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
        t.actualMinutes = (t.actualMinutes ?? 0) + spent
        if b.isFinalPart {
            t.isCompleted = true
            t.completedAt = Date()
            show("Nice — \(t.title) done ✓")
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
        guard school.isSignedIn, !isSyncingClassroom else { return }
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
        var added = 0
        for item in items {
            let id = UUID.stable(from: "classroom:\(item.externalID)")
            if var t = task(id) {
                let before = t
                t.title = item.title
                t.course = item.course
                t.due = item.due
                t.link = item.link
                if item.isTurnedIn && !t.isCompleted {
                    t.isCompleted = true
                    t.completedAt = Date()
                }
                if t != before { upsert(t) }
            } else {
                if item.isTurnedIn, (item.due ?? .distantPast) < Date() { continue }
                var (mins, difficulty) = ClassroomService.estimate(for: item)
                if let learned = learnedEstimate(course: item.course) { mins = (mins + learned * 2) / 3 }
                upsert(BrainTask(id: id, title: item.title, course: item.course, notes: item.description, due: item.due,
                                 estimatedMinutes: mins, difficulty: difficulty, source: .classroom,
                                 externalID: item.externalID, link: item.link, isCompleted: item.isTurnedIn))
                added += 1
            }
        }
        if added > 0 { show("\(added) new assignment\(added == 1 ? "" : "s") from Classroom") }
    }

    // MARK: Device sync

    /// A separate personal account wins; otherwise the school account handles sync too.
    var syncAccount: GoogleAccount? {
        if personal.isSignedIn { return personal }
        if school.isSignedIn, school.hasScope(GoogleAccount.driveScope) { return school }
        return nil
    }

    func syncDevices() async {
        guard let account = syncAccount, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let snapshot = doc
            let merged = try await DriveSync(account: account).sync(local: snapshot)
            // Merge again so edits made while the network call was in flight aren't lost.
            let final = SyncMerger.merge(doc, merged)
            if final != doc {
                doc = final
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

    private func changed() {
        save()
        rescheduleReminders()
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
        guard remindersOn else { return }
        let range = DateInterval(start: Date(), duration: 3 * 86_400)
        Reminders.reschedule(events: occurrences(in: range), blocks: todayPlan?.blocks ?? [], leadMinutes: reminderLead)
    }
}
