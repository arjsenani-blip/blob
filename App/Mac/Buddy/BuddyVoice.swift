import AVFoundation
import Speech

/// Listens through the mic and transcribes on-device. Stops by itself after you pause.
@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var isListening = false

    var onFinished: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var lastChange = Date()
    private var started = Date()
    private var watchdog: Timer?

    static func requestPermissions() async -> String? {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speech == .authorized else { return "I need Speech Recognition permission (System Settings → Privacy & Security → Speech Recognition)." }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return "I need Microphone permission (System Settings → Privacy & Security → Microphone)."
        }
        return nil
    }

    func start() throws {
        stop(deliver: false)
        transcript = ""
        guard let recognizer, recognizer.isAvailable else { throw NSError(domain: "Blob", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn't available right now."]) }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let normalized = min(1, max(0, (20 * log10(max(rms, 0.000_01)) + 50) / 40))
            Task { @MainActor in self?.level = self.map { $0.level * 0.5 + normalized * 0.5 } ?? normalized }
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.transcript { self.transcript = text; self.lastChange = Date() }
                    if result.isFinal { self.stop(deliver: true) }
                } else if error != nil, self.isListening {
                    self.stop(deliver: true)
                }
            }
        }

        isListening = true
        started = Date()
        lastChange = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSilence() }
        }
    }

    private func checkSilence() {
        guard isListening else { return }
        let now = Date()
        if !transcript.isEmpty && now.timeIntervalSince(lastChange) > 1.4 { stop(deliver: true) }      // you paused
        else if transcript.isEmpty && now.timeIntervalSince(started) > 7 { stop(deliver: true) }        // never said anything
        else if now.timeIntervalSince(started) > 45 { stop(deliver: true) }                             // safety cap
    }

    func stop(deliver: Bool) {
        let wasListening = isListening
        watchdog?.invalidate()
        watchdog = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        level = 0
        if deliver && wasListening { onFinished?(transcript.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

/// Blob's voice.
@MainActor
final class SpeechOutput: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    /// Rough mouth/glow movement while talking, 0…1.
    @Published private(set) var level: Float = 0

    var onFinished: (() -> Void)?
    private let synth = AVSpeechSynthesizer()
    private var pulse: Timer?
    private var player: AVAudioPlayer?
    private var speakTask: Task<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    static var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.identifier.contains("eloquence") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { a, b in
                let ga = a.language == "en-GB" ? 1 : 0, gb = b.language == "en-GB" ? 1 : 0
                return (a.quality.rawValue, ga, a.name) > (b.quality.rawValue, gb, b.name)
            }
    }

    /// Best installed British voice, male first (JARVIS-style). Everything here runs on the Mac, offline and free.
    static var bestBritishVoice: AVSpeechSynthesisVoice? {
        let gb = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" && !$0.identifier.contains("eloquence") && !$0.voiceTraits.contains(.isNoveltyVoice) }
        return gb.max { a, b in
            (a.quality.rawValue, a.gender == .male ? 1 : 0) < (b.quality.rawValue, b.gender == .male ? 1 : 0)
        }
    }

    /// True when only the basic (robotic) British voice is installed — Settings then offers the free Premium download.
    static var needsBetterVoice: Bool { (bestBritishVoice?.quality ?? .default) == .default }

    /// The chosen voice, or the best British voice installed.
    static var voice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: "buddyVoice"), !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return bestBritishVoice ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    // MARK: Speaking — a sentence queue, so text can stream in while Blob is already talking.

    private var queue: [String] = []
    private var streamOpen = false
    private var consumed = 0

    /// Speak a whole reply.
    func speak(_ text: String) {
        beginStream()
        endStream(finalText: text)
    }

    /// Start talking as soon as the first sentence of a streaming reply is ready.
    func beginStream() {
        stop()
        isSpeaking = true
        streamOpen = true
        consumed = 0
        queue = []
        pulse = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLevel() }
        }
        speakTask = Task { await runQueue() }
    }

    /// `text` is everything received so far; any newly completed sentences are queued.
    func streamUpdate(_ text: String) {
        guard streamOpen else { return }
        let chars = Array(text)
        var i = consumed
        while i < chars.count {
            let c = chars[i]
            let atBoundary = (c == "." || c == "!" || c == "?" || c == "…") && i + 1 < chars.count && chars[i + 1] == " "
            // The very first chunk can end at a comma, so speech starts sooner.
            let firstClause = queue.isEmpty && consumed == 0 && c == "," && i - consumed > 45 && i + 1 < chars.count && chars[i + 1] == " "
            if atBoundary || firstClause {
                enqueue(String(chars[consumed...i]))
                consumed = i + 1
            }
            i += 1
        }
    }

    /// The reply is complete: queue whatever is left.
    func endStream(finalText: String) {
        guard streamOpen else { return }
        let chars = Array(finalText)
        if consumed < chars.count {
            for sentence in NaturalVoice.sentences(String(chars[consumed...])) { enqueue(sentence) }
        }
        consumed = chars.count
        streamOpen = false
    }

    private func enqueue(_ raw: String) {
        let clean = raw
            .replacingOccurrences(of: #"\*\*|__|`|#+ "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"https?://\S+"#, with: "the link", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        queue.append(clean)
    }

    private func speakWithApple(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice
        // Calm, measured butler delivery.
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.98
        u.pitchMultiplier = 0.94
        synth.speak(u)
    }

    /// Plays queued sentences in order. The next sentence renders while the current one plays.
    private func runQueue() async {
        let engine = VoiceEngine.effective
        let natural = engine != .apple && NaturalVoice.isEnabled
        let sid = NaturalVoice.speakerID
        func makeJob(_ s: String) -> Task<URL?, Never> {
            Task {
                if engine == .chatterbox, let url = await ChatterboxServer.shared.render(s) { return url }
                return await NaturalVoice.render(s, speaker: sid)
            }
        }
        var prefetched: (text: String, job: Task<URL?, Never>)?

        while !Task.isCancelled {
            guard !queue.isEmpty else {
                if !streamOpen { break }
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            let sentence = queue.removeFirst()
            if !natural {
                speakWithApple(sentence)
                while synth.isSpeaking, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(40)) }
                continue
            }
            let job = prefetched?.text == sentence ? prefetched!.job : makeJob(sentence)
            prefetched = queue.first.map { ($0, makeJob($0)) }
            guard let url = await job.value, !Task.isCancelled else {
                if !Task.isCancelled {
                    speakWithApple(sentence)       // fall back for this sentence
                    while synth.isSpeaking, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(40)) }
                }
                continue
            }
            if let p = try? AVAudioPlayer(contentsOf: url) {
                p.isMeteringEnabled = true
                player = p
                p.play()
                while p.isPlaying, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(40)) }
            }
            try? FileManager.default.removeItem(at: url)
        }
        if !Task.isCancelled { finish() }
    }

    private func updateLevel() {
        guard isSpeaking else { return }
        if let p = player, p.isPlaying {
            p.updateMeters()
            let db = p.averagePower(forChannel: 0)
            let target = max(0, min(1, (db + 42) / 36))
            level = level * 0.45 + target * 0.55
        } else if synth.isSpeaking {
            level = level * 0.4 + Float.random(in: 0.25...1) * 0.6
        } else {
            level *= 0.6
        }
    }

    func stop() {
        speakTask?.cancel()
        speakTask = nil
        queue = []
        streamOpen = false
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        finish()
    }

    private func finish() {
        pulse?.invalidate()
        pulse = nil
        level = 0
        if isSpeaking {
            isSpeaking = false
            onFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}

/// Kokoro neural voice (Apache-2.0), run on-device by sherpa-onnx. Free and offline.
/// Lives in ~/Library/Application Support/ArjunsBrain/Voice.
enum NaturalVoice {
    static let voices: [(name: String, speaker: Int, note: String)] = [
        ("Daniel", 24, "measured, newsreader"),
        ("George", 26, "warm, refined"),
        ("Fable", 25, "crisp, storyteller"),
        ("Lewis", 27, "deeper, relaxed"),
    ]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArjunsBrain/Voice", isDirectory: true)
    }

    static var binary: URL? {
        let engine = directory.appendingPathComponent("engine")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: engine, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent("bin/sherpa-onnx-offline-tts") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var model: URL? {
        let base = directory.appendingPathComponent("model")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return dirs.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.onnx").path) }
    }

    static var isInstalled: Bool { binary != nil && model != nil }

    static var isEnabled: Bool {
        VoiceEngine.current != .apple && (isInstalled || ChatterboxServer.isInstalled)
    }

    static var speakerID: Int {
        let id = UserDefaults.standard.integer(forKey: "blobKokoroVoice")
        return voices.contains { $0.speaker == id } ? id : 24
    }

    /// Splits into sentences, merging short ones so speech doesn't sound choppy.
    static func sentences(_ text: String) -> [String] {
        let parts = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\u{1F}", options: .regularExpression)
            .components(separatedBy: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        for p in parts {
            if let last = out.last, last.count < 40 { out[out.count - 1] = last + " " + p } else { out.append(p) }
        }
        return out.isEmpty ? [text] : out
    }

    /// Renders one sentence to a temporary WAV. Returns nil on failure.
    static func render(_ text: String, speaker: Int) async -> URL? {
        guard let bin = binary, let m = model else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("blob-\(UUID().uuidString).wav")
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = bin
                p.arguments = [
                    "--kokoro-model=\(m.appendingPathComponent("model.onnx").path)",
                    "--kokoro-voices=\(m.appendingPathComponent("voices.bin").path)",
                    "--kokoro-tokens=\(m.appendingPathComponent("tokens.txt").path)",
                    "--kokoro-data-dir=\(m.appendingPathComponent("espeak-ng-data").path)",
                    "--kokoro-lexicon=\(m.appendingPathComponent("lexicon-gb-en.txt").path)",
                    "--kokoro-dict-dir=\(m.appendingPathComponent("dict").path)",
                    "--num-threads=4", "--sid=\(speaker)", "--output-filename=\(out.path)", text,
                ]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path) ? out : nil)
            }
        }
    }
}
