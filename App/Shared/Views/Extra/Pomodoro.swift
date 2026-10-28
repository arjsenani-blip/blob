import SwiftUI
import UserNotifications
import BrainCore

/// Pomodoro: focus rounds and breaks, 4 rounds to a set (the 4th break is a long one).
/// It runs on wall-clock time (an end date), so it keeps going when the app is closed — a notification
/// fires when each phase ends — and every finished focus round is logged to the assignment you picked.
@MainActor
final class Pomodoro: ObservableObject {
    static let shared = Pomodoro()

    enum Phase: String, Codable { case focus, shortBreak, longBreak
        var label: String { self == .focus ? "FOCUS" : self == .shortBreak ? "BREAK" : "LONG BREAK" }
    }

    struct Preset: Identifiable, Hashable {
        var focus: Int, short: Int, long: Int
        var id: String { "\(focus)/\(short)" }
        var label: String { "\(focus) / \(short)" }
        static let all = [Preset(focus: 25, short: 5, long: 15), Preset(focus: 50, short: 10, long: 20), Preset(focus: 15, short: 3, long: 10)]
    }

    private struct Saved: Codable {
        var phase: Phase, round: Int, endsAt: Date?, remaining: Int, taskID: UUID?
        var focusMin: Int, shortMin: Int, longMin: Int
        var countDay: Date, countToday: Int, minutesToday: Int
    }

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var round = 1
    /// Set while running.
    @Published private(set) var endsAt: Date?
    /// Seconds left while paused.
    @Published private(set) var remaining = 25 * 60
    @Published var taskID: UUID?
    @Published private(set) var preset = Preset.all[0]
    @Published private(set) var roundsToday = 0
    @Published private(set) var focusMinutesToday = 0
    @Published private(set) var tick = Date()

    private var timer: Timer?
    weak var store: BrainStore?

    var isRunning: Bool { endsAt != nil }
    var secondsLeft: Int { endsAt.map { max(0, Int(ceil($0.timeIntervalSince(tick)))) } ?? remaining }
    var phaseLength: Int { 60 * (phase == .focus ? preset.focus : phase == .shortBreak ? preset.short : preset.long) }
    var progress: Double { 1 - Double(secondsLeft) / Double(max(1, phaseLength)) }
    var clock: String { String(format: "%02d:%02d", secondsLeft / 60, secondsLeft % 60) }
    var isActive: Bool { isRunning || secondsLeft < phaseLength }

    init() {
        if let d = UserDefaults.standard.data(forKey: "pomodoro"), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            phase = s.phase; round = s.round; endsAt = s.endsAt; remaining = s.remaining; taskID = s.taskID
            preset = Preset(focus: s.focusMin, short: s.shortMin, long: s.longMin)
            if Calendar.current.isDateInToday(s.countDay) { roundsToday = s.countToday; focusMinutesToday = s.minutesToday }
        }
        startTicking()
    }

    // MARK: Controls

    func start(task: UUID? = nil) {
        if let task { taskID = task }
        guard endsAt == nil else { return }
        endsAt = Date().addingTimeInterval(TimeInterval(remaining))
        scheduleNotification()
        save()
    }

    func pause() {
        guard let e = endsAt else { return }
        remaining = max(1, Int(ceil(e.timeIntervalSinceNow)))
        endsAt = nil
        cancelNotification()
        save()
    }

    func toggle() { isRunning ? pause() : start() }

    func reset() {
        endsAt = nil
        remaining = phaseLength
        cancelNotification()
        save()
    }

    /// Ends this phase now (a focus round skipped this way isn't logged).
    func skip() { advance(completed: false) }

    func choose(_ p: Preset) {
        preset = p
        endsAt = nil
        phase = .focus
        remaining = p.focus * 60
        cancelNotification()
        save()
    }

    /// Start a focus round on an assignment right away.
    func focus(on task: BrainTask) {
        if taskID != task.id || phase != .focus { endsAt = nil; phase = .focus; remaining = preset.focus * 60 }
        taskID = task.id
        start()
    }

    // MARK: Engine

    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func onTick() {
        tick = Date()
        if let e = endsAt, e <= tick { advance(completed: true) }
    }

    /// Catch up after the app was closed or asleep.
    func catchUp() { onTick() }

    private func advance(completed: Bool) {
        cancelNotification()
        if phase == .focus {
            if completed { logRound() }
            phase = round % 4 == 0 ? .longBreak : .shortBreak
        } else {
            phase = .focus
            round = round % 4 + 1
        }
        remaining = phaseLength
        // Breaks start on their own after a focus round; the next focus round waits for you.
        endsAt = (completed && phase != .focus) ? Date().addingTimeInterval(TimeInterval(remaining)) : nil
        if endsAt != nil { scheduleNotification() }
        save()
    }

    private func logRound() {
        rollDay()
        roundsToday += 1
        focusMinutesToday += preset.focus
        guard let id = taskID, let store, store.task(id) != nil else { return }
        store.log(taskID: id, minutes: preset.focus, note: "Pomodoro round", finishStep: false, markDone: false)
    }

    private func rollDay() {
        let saved = UserDefaults.standard.data(forKey: "pomodoro").flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        if let s = saved, !Calendar.current.isDateInToday(s.countDay) { roundsToday = 0; focusMinutesToday = 0 }
    }

    private func save() {
        let s = Saved(phase: phase, round: round, endsAt: endsAt, remaining: remaining, taskID: taskID,
                      focusMin: preset.focus, shortMin: preset.short, longMin: preset.long,
                      countDay: Date(), countToday: roundsToday, minutesToday: focusMinutesToday)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "pomodoro") }
        tick = Date()
    }

    // MARK: Notifications

    private func scheduleNotification() {
        guard let e = endsAt else { return }
        let content = UNMutableNotificationContent()
        let title = taskID.flatMap { store?.task($0)?.title }
        if phase == .focus {
            content.title = "🍅 Focus round done"
            content.body = (title.map { "Nice work on \($0). " } ?? "") + "Take a \(round % 4 == 0 ? preset.long : preset.short)-minute break."
        } else {
            content.title = "Break's over"
            content.body = "Ready for round \(round % 4 + 1)?" + (title.map { " (\($0))" } ?? "")
        }
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, e.timeIntervalSinceNow), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pomodoro", content: content, trigger: trigger))
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["pomodoro"])
    }
}
