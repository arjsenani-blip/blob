import SwiftUI
import AVFoundation
import Speech
import UserNotifications
import FoundationModels
import BrainCore

// MARK: - Blob on iPhone: tap, talk, done.
//
// Runs entirely on the phone: on-device speech recognition, Apple Intelligence for understanding,
// and the British system voice. iOS doesn't let apps control other apps, so Blob on iPhone handles
// your planner (assignments, events, check-in, schedule), timers, and opening YouTube / music / searches.

@MainActor
final class PhoneBlob: ObservableObject {
    enum Phase { case resting, listening, thinking, speaking }

    @Published private(set) var phase: Phase = .resting
    @Published private(set) var heard = ""
    @Published private(set) var reply = ""
    @Published private(set) var level: Float = 0
    @Published var showBubble = false
    @Published var typed = ""
    @Published private(set) var celebrating = false

    let store: BrainStore
    private let ear = PhoneEar()
    private let voice = PhoneVoice()
    private lazy var brain = PhoneBrain(store: store)
    private var work: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    init(store: BrainStore) {
        self.store = store
        ear.onLevel = { [weak self] l in self?.level = l }
        ear.onFinished = { [weak self] text in self?.heardFinished(text) }
        voice.onFinished = { [weak self] in self?.doneSpeaking() }
        voice.onLevel = { [weak self] l in self?.level = l }
    }

    var mood: BlobMood {
        switch phase {
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .resting: return celebrating ? .happy : .idle
        }
    }

    // MARK: Interaction

    func tapped() {
        switch phase {
        case .listening: ear.stop(deliver: true)
        case .thinking, .speaking:
            work?.cancel(); voice.stop(); listen()
        case .resting: listen()
        }
    }

    func listen() {
        hideTask?.cancel()
        Task {
            if let problem = await PhoneEar.requestPermissions() { show(problem); return }
            heard = ""; reply = ""
            withAnimation(.spring(duration: 0.4)) { phase = .listening; showBubble = true }
            brain.prewarm()
            do { try ear.start() } catch { show(error.localizedDescription) }
        }
    }

    private func heardFinished(_ text: String) {
        guard phase == .listening else { return }
        if text.isEmpty {
            withAnimation { phase = .resting }
            reply = "I didn't catch that, sir. Tap me to try again."
            scheduleHide()
            return
        }
        submit(text)
    }

    func submitTyped() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        typed = ""
        submit(t)
    }

    func submit(_ text: String) {
        ear.stop(deliver: false)
        voice.stop()
        hideTask?.cancel()
        heard = text
        reply = ""
        withAnimation(.spring(duration: 0.4)) { phase = .thinking; showBubble = true }
        work?.cancel()
        work = Task {
            let answer = await brain.respond(to: text)
            guard !Task.isCancelled else { return }
            show(answer)
        }
    }

    private func show(_ text: String) {
        reply = text
        withAnimation(.spring(duration: 0.4)) { showBubble = true }
        if UserDefaults.standard.object(forKey: "buddySpeak") as? Bool ?? true {
            phase = .speaking
            voice.speak(text)
        } else {
            phase = .resting
            celebrate()
            scheduleHide()
        }
    }

    private func doneSpeaking() {
        guard phase == .speaking else { return }
        withAnimation { phase = .resting }
        celebrate()
        scheduleHide()
    }

    private func celebrate() {
        celebrating = true
        Task { try? await Task.sleep(for: .seconds(1.6)); celebrating = false }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, phase == .resting, typed.isEmpty else { return }
            withAnimation(.spring(duration: 0.4)) { showBubble = false }
        }
    }

    func dismiss() {
        work?.cancel(); ear.stop(deliver: false); voice.stop()
        withAnimation(.spring(duration: 0.4)) { phase = .resting; showBubble = false }
    }
}

// MARK: - Listening (on-device)

@MainActor
final class PhoneEar {
    var onFinished: (String) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var transcript = ""
    private var lastChange = Date()
    private var started = Date()
    private var timer: Timer?
    private var active = false

    static func requestPermissions() async -> String? {
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else { return "I need Speech Recognition permission, sir. Turn it on in Settings → Blob." }
        guard await AVAudioApplication.requestRecordPermission() else { return "I need the microphone, sir. Turn it on in Settings → Privacy → Microphone." }
        return nil
    }

    func start() throws {
        stop(deliver: false)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer?.supportsOnDeviceRecognition == true { req.requiresOnDeviceRecognition = true }
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            req.append(buffer)
            guard let d = buffer.floatChannelData?[0] else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += d[i] * d[i] }
            let rms = sqrt(sum / Float(max(1, buffer.frameLength)))
            let lvl = min(1, max(0, (20 * log10(max(rms, 0.00001)) + 50) / 40))
            Task { @MainActor in self?.onLevel(lvl) }
        }
        engine.prepare()
        try engine.start()
        transcript = ""; started = Date(); lastChange = Date(); active = true
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.active else { return }
                if let result {
                    let t = result.bestTranscription.formattedString
                    if t != self.transcript { self.transcript = t; self.lastChange = Date() }
                    if result.isFinal { self.stop(deliver: true) }
                } else if error != nil { self.stop(deliver: true) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                let now = Date()
                if !self.transcript.isEmpty && now.timeIntervalSince(self.lastChange) > 1.3 { self.stop(deliver: true) }
                else if self.transcript.isEmpty && now.timeIntervalSince(self.started) > 7 { self.stop(deliver: true) }
                else if now.timeIntervalSince(self.started) > 40 { self.stop(deliver: true) }
            }
        }
    }

    func stop(deliver: Bool) {
        let was = active
        active = false
        timer?.invalidate(); timer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel(); request = nil; task = nil
        onLevel(0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if deliver && was { onFinished(transcript.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

// MARK: - Speaking (British system voice)

@MainActor
final class PhoneVoice: NSObject, AVSpeechSynthesizerDelegate {
    var onFinished: () -> Void = {}
    var onLevel: (Float) -> Void = { _ in }
    private let synth = AVSpeechSynthesizer()
    private var pulse: Timer?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Best British voice on the phone (download "Jamie (Premium)" or "Daniel (Enhanced)" in
    /// Settings → Accessibility → Spoken Content → Voices → English for a natural one).
    static var voice: AVSpeechSynthesisVoice? {
        let gb = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" && !$0.voiceTraits.contains(.isNoveltyVoice) }
        return gb.max { ($0.quality.rawValue, $0.gender == .male ? 1 : 0) < ($1.quality.rawValue, $1.gender == .male ? 1 : 0) }
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    func speak(_ text: String) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression))
        u.voice = Self.voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.98
        u.pitchMultiplier = 0.94
        synth.speak(u)
        pulse = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onLevel(Float.random(in: 0.25...0.9)) }
        }
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        pulse?.invalidate(); pulse = nil
        onLevel(0)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            self.pulse?.invalidate(); self.pulse = nil
            self.onLevel(0)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.onFinished()
        }
    }
}

// MARK: - Brain: instant commands first, then Apple Intelligence with planner tools

@MainActor
final class PhoneBrain {
    let store: BrainStore
    private var session: LanguageModelSession?
    private var lastUse = Date.distantPast

    init(store: BrainStore) { self.store = store }

    static var aiAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func prewarm() {
        guard Self.aiAvailable else { return }
        if session == nil || Date().timeIntervalSince(lastUse) > 600 { session = makeSession() }
        session?.prewarm()
    }

    func respond(to raw: String) async -> String {
        // "worked 45 min on the essay", "finished the outline", "got a 95 on the bio test" — instant, offline.
        if let (intent, task) = store.logPreview(raw) {
            return task == nil ? "Which assignment was that for, sir?" : store.apply(intent) + ". Well done, sir."
        }
        if raw.lowercased().range(of: #"\b(am i (on track|behind)|how are my (projects|long[- ]?term)|progress report|status update)\b"#, options: .regularExpression) != nil {
            return store.trackerSummary().replacingOccurrences(of: "\n", with: ". ") + "."
        }
        if let quick = await quickCommand(raw) { return quick }
        if Self.aiAvailable {
            if session == nil || Date().timeIntervalSince(lastUse) > 600 { session = makeSession() }
            lastUse = Date()
            if let s = session, let r = try? await s.respond(to: PhoneTools.context() + "\n" + raw) {
                return r.content
            }
            session = makeSession()
        }
        // No Apple Intelligence: still understand adds.
        let parsed = store.parse(raw)
        if parsed.start != nil || parsed.kind == .task {
            store.add(parsed)
            return "Added \(parsed.title)" + (parsed.start.map { ", \(parsed.kind == .task ? "due " : "")\($0.dueText(includeTime: parsed.hasExplicitTime))" } ?? "") + ", sir."
        }
        return "On this phone I can manage your assignments and calendar, check you in, set timers, and open YouTube, music or a search, sir."
    }

    private func makeSession() -> LanguageModelSession {
        let tools: [any Tool] = [PhoneScheduleTool(store: store), PhoneAssignmentsTool(store: store), PhoneAddTaskTool(store: store),
                                 PhoneAddEventTool(store: store), PhoneCompleteTool(store: store), PhoneCheckInTool(store: store),
                                 PhoneLogTool(store: store), PhoneStatusTool(store: store), PhoneOpenTool()]
        return LanguageModelSession(tools: tools, instructions: """
            You are Blob, a polite British AI butler like JARVIS, living in the user's planner app on their iPhone. Always call the user "sir".
            Answer in one or two short spoken sentences, no lists or markdown. Use the tools to read and change their planner.
            Homework, essays, projects, readings and "study for" are assignments: use add_assignment, never add_event.
            Only practices, games, appointments, meetings and the test itself are events. Dates use YYYY-MM-DDTHH:MM local time.
            Big projects, essays and test studying are long-term: set long_term true. When the user says what they did, use log_progress.
            For "how am I doing" use assignment_status.
            """)
    }

    private func quickCommand(_ raw: String) async -> String? {
        var t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        t = t.replacingOccurrences(of: #"^(?:hey blob|blob|can you|could you|please)[, ]+"#, with: "", options: .regularExpression)
        func m(_ p: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
                  let r = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
            return (0..<r.numberOfRanges).map { Range(r.range(at: $0), in: t).map { String(t[$0]) } ?? "" }
        }
        if let g = m(#"^(?:play|put on|watch) (.+?) on youtube$|^youtube (.+)$"#) {
            let q = g[1].isEmpty ? g[2] : g[1]
            await PhoneTools.playYouTube(q)
            return "Here you are, sir."
        }
        if let g = m(#"^play (.+?) on spotify$"#) {
            PhoneTools.open("spotify:search:" + (g[1].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? g[1]))
            return "Opening Spotify, sir."
        }
        if let g = m(#"^(?:play|put on) (.+)$"#), !["music", "it", "something"].contains(g[1]) {
            PhoneTools.open("music://music.apple.com/search?term=" + (g[1].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? g[1]))
            return "Pulling that up in Music, sir."
        }
        if let g = m(#"^(?:search|google|look up)(?: for)? (.+)$"#) {
            PhoneTools.open("https://www.google.com/search?q=" + (g[1].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? g[1]))
            return "Here are the results, sir."
        }
        if m(#"^what(?:'s| is) the time|^what time is it"#) != nil { return "It's \(Date().shortTime), sir." }
        if m(#"^(?:check (?:me )?in|plan my (?:day|night|evening|afternoon))$"#) != nil {
            store.checkIn()
            if let first = store.todayPlan?.blocks.first(where: { $0.kind == .task }) {
                return "You're checked in, sir. First up: \(first.title) at \(first.start.shortTime)."
            }
            return "Checked in, sir. Nothing's due — the evening is yours."
        }
        if let g = m(#"^(?:set (?:a )?)?timer (?:for )?(\d+) ?(minutes?|mins?|hours?|seconds?)$"#), let n = Double(g[1]) {
            let secs = g[2].hasPrefix("h") ? n * 3600 : g[2].hasPrefix("s") ? n : n * 60
            PhoneTools.timer(seconds: secs)
            return "Timer set for \(g[1]) \(g[2]), sir."
        }
        return nil
    }
}

enum PhoneTools {
    static func context() -> String {
        "[Now: \(Date().formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute()))]"
    }

    static func open(_ s: String) {
        if let u = URL(string: s) { UIApplication.shared.open(u) }
    }

    /// Opens the top YouTube result (no account or API key).
    static func playYouTube(_ q: String) async {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        var req = URLRequest(url: URL(string: "https://www.youtube.com/results?search_query=\(enc)")!, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        if let (d, _) = try? await URLSession.shared.data(for: req), let html = String(data: d, encoding: .utf8),
           let r = html.range(of: #""videoId":"([A-Za-z0-9_-]{11})""#, options: .regularExpression) {
            open("https://www.youtube.com/watch?v=\(html[r].dropFirst(11).prefix(11))")
        } else {
            open("https://www.youtube.com/results?search_query=\(enc)")
        }
    }

    static func timer(seconds: Double) {
        let c = UNMutableNotificationContent()
        c.title = "⏰ Timer done"
        c.body = "Your Blob timer is up, sir."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "blob-timer-\(UUID())", content: c,
                                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)))
    }

    static let iso: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm"; return f }()
    static let day: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    static func date(_ s: String) -> (Date, Bool)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let d = iso.date(from: String(t.prefix(16))) { return (d, false) }
        if let d = day.date(from: String(t.prefix(10))) { return (d, true) }
        return nil
    }
}

// MARK: Apple Intelligence tools

struct PhoneScheduleTool: Tool {
    let store: BrainStore
    let name = "get_schedule"
    let description = "Events and assignments due for a day."
    @Generable struct Arguments { @Guide(description: "Date YYYY-MM-DD, or empty for today") var date: String }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let day = PhoneTools.date(arguments.date)?.0 ?? Date()
            let ev = store.occurrences(on: day).map { "\($0.isAllDay ? "all day" : $0.start.shortTime): \($0.title)" }
            let due = store.tasksDue(on: day).map { "due \($0.due!.shortTime): \($0.title)\($0.isCompleted ? " (done)" : "")" }
            let all = ev + due
            return all.isEmpty ? "Nothing that day." : all.joined(separator: "\n")
        }
    }
}

struct PhoneAssignmentsTool: Tool {
    let store: BrainStore
    let name = "list_assignments"
    let description = "Open homework and to-dos with due dates."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let open = store.pendingTasks.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(15)
            return open.isEmpty ? "No open assignments." : open.map {
                "\($0.title)\($0.course.map { " [\($0)]" } ?? "")\($0.due.map { " due \($0.dueText())" } ?? "")"
                    + ($0.isLongTerm ? " · \(Int($0.progress * 100))% \($0.pace().label)" : "")
            }.joined(separator: "\n")
        }
    }
}

struct PhoneAddTaskTool: Tool {
    let store: BrainStore
    let name = "add_assignment"
    let description = "Add homework or a to-do with a due date."
    @Generable struct Arguments {
        @Guide(description: "What to do") var title: String
        @Guide(description: "Due YYYY-MM-DDTHH:MM or empty") var due: String
        @Guide(description: "Class name or empty") var course: String
        @Guide(description: "True for a big project/essay/test worked on over days") var long_term: Bool
    }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let due = PhoneTools.date(arguments.due).map { $0.1 ? Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: $0.0)! : $0.0 }
            let course = arguments.course.isEmpty ? store.parse(arguments.title).course : arguments.course
            let t = BrainTask(title: arguments.title, course: course, due: due)
            store.upsert(t)
            store.setUpLongTermIfNeeded(t.id, explicit: arguments.long_term)
            if let s = store.task(t.id), !s.milestones.isEmpty {
                return "Added \(arguments.title), tracked long-term in \(s.milestones.count) steps: " + s.milestones.map(\.title).joined(separator: ", ")
            }
            return "Added assignment \(arguments.title)."
        }
    }
}

struct PhoneAddEventTool: Tool {
    let store: BrainStore
    let name = "add_event"
    let description = "Add a calendar event (something happening at a time or place)."
    @Generable struct Arguments {
        @Guide(description: "Event title") var title: String
        @Guide(description: "Start YYYY-MM-DDTHH:MM") var start: String
        @Guide(description: "End YYYY-MM-DDTHH:MM or empty") var end: String
    }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            guard let (start, allDay) = PhoneTools.date(arguments.start) else { return "I need a start time." }
            let end = PhoneTools.date(arguments.end)?.0 ?? (allDay ? Calendar.current.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(3600))
            store.upsert(BrainEvent(title: arguments.title, start: start, end: end, isAllDay: allDay))
            return "Added \(arguments.title)."
        }
    }
}

struct PhoneCompleteTool: Tool {
    let store: BrainStore
    let name = "complete_assignment"
    let description = "Mark an assignment done."
    @Generable struct Arguments { @Guide(description: "Title or part of it") var title: String }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            guard var t = TaskMatcher.best(arguments.title, in: store.pendingTasks) else {
                return "No open assignment matches that."
            }
            store.markDone(&t)
            store.upsert(t)
            return "Marked \(t.title) done."
        }
    }
}

struct PhoneLogTool: Tool {
    let store: BrainStore
    let name = "log_progress"
    let description = "Log progress on an assignment: time spent, a step finished, done, percent, or a grade."
    @Generable struct Arguments {
        @Guide(description: "The user's sentence, e.g. 'worked 45 min on the history essay'") var sentence: String
    }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run { store.applyLog(arguments.sentence) ?? "Say it like 'worked 30 min on X' or 'finished the outline for X'." }
    }
}

struct PhoneStatusTool: Tool {
    let store: BrainStore
    let name = "assignment_status"
    let description = "How long-term assignments are going: progress, pace, next step."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String { await MainActor.run { store.trackerSummary() } }
}

struct PhoneCheckInTool: Tool {
    let store: BrainStore
    let name = "check_in"
    let description = "Plan what homework to do in what order until bedtime."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            store.checkIn()
            guard let plan = store.todayPlan else { return "No plan." }
            return ([plan.summary] + plan.blocks.filter { $0.kind == .task }.map { "\($0.start.shortTime) \($0.title)" }).joined(separator: "\n")
        }
    }
}

struct PhoneOpenTool: Tool {
    let name = "open"
    let description = "Open YouTube (play a video), Apple Music, Spotify or a web search."
    @Generable struct Arguments {
        @Guide(description: "Where", .anyOf(["youtube", "music", "spotify", "search"])) var target: String
        @Guide(description: "What to look for") var query: String
    }
    func call(arguments: Arguments) async throws -> String {
        let q = arguments.query
        switch arguments.target {
        case "youtube": await PhoneTools.playYouTube(q)
        case "spotify": await MainActor.run { PhoneTools.open("spotify:search:" + (q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q)) }
        case "music": await MainActor.run { PhoneTools.open("music://music.apple.com/search?term=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)) }
        default: await MainActor.run { PhoneTools.open("https://www.google.com/search?q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)) }
        }
        return "Opened."
    }
}

// MARK: - Overlay: Blob floating in the corner of every screen

struct PhoneBlobOverlay: View {
    @ObservedObject var blob: PhoneBlob
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if blob.showBubble { bubble.transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity)) }
            BlobCharacter(mood: blob.mood, level: CGFloat(blob.level), look: .zero,
                          tucked: blob.phase == .resting && !blob.showBubble)
                .frame(width: 70, height: 70)
                .contentShape(Circle())
                .onTapGesture { blob.tapped() }
                .onLongPressGesture { withAnimation { blob.showBubble = true }; typing = true }
                .accessibilityLabel("Blob. Tap to talk, hold to type.")
        }
        .padding(.trailing, 14)
        .padding(.bottom, 64)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(BuddyColors.cyan).frame(width: 7, height: 7).shadow(color: BuddyColors.cyan, radius: 4)
                Text("Blob").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(BuddyColors.light)
                Spacer()
                Button { blob.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.6)) }
            }
            if !blob.heard.isEmpty { Text("“\(blob.heard)”").font(.system(size: 13, design: .rounded)).italic().foregroundStyle(.white.opacity(0.7)) }
            if blob.phase == .listening { Text("Listening…").font(.system(size: 13, design: .rounded)).foregroundStyle(.white.opacity(0.5)) }
            if blob.phase == .thinking { Text("Thinking…").font(.system(size: 13, design: .rounded)).foregroundStyle(BuddyColors.light) }
            if !blob.reply.isEmpty {
                Text(blob.reply).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                TextField("Type to Blob…", text: $blob.typed)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.white)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit { blob.submitTyped() }
                Button { blob.tapped() } label: {
                    Image(systemName: blob.phase == .listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 28, height: 28).background(Circle().fill(BuddyColors.cyan))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
        }
        .padding(14)
        .frame(maxWidth: 320)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(red: 0.03, green: 0.07, blue: 0.11).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(BuddyColors.cyan.opacity(0.5), lineWidth: 1))
        .shadow(color: BuddyColors.cyan.opacity(0.3), radius: 14)
        .environment(\.colorScheme, .dark)
    }
}
