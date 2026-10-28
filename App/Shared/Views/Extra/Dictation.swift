import Foundation
import Speech
import AVFoundation

/// Speak instead of typing: live transcript from the microphone, on-device when the device supports it.
/// The mic is only on while you're dictating.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published var problem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    func toggle(startingWith text: String = "") { isListening ? stop() : start(startingWith: text) }

    func start(startingWith text: String = "") {
        problem = nil
        Task {
            let speechOK = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
            let micOK = await AVCaptureDevice.requestAccess(for: .audio)
            guard speechOK, micOK else {
                problem = "Allow Microphone and Speech Recognition for Blob in Settings to dictate."
                return
            }
            begin(prefix: text)
        }
    }

    private func begin(prefix: String) {
        guard let recognizer, recognizer.isAvailable else { problem = "Speech recognition isn't available right now."; return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let base = prefix.isEmpty ? "" : prefix + (prefix.hasSuffix(" ") ? "" : " ")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = base + result.bestTranscription.formattedString }
                if error != nil || (result?.isFinal ?? false) { self.stop() }
            }
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in req?.append(buffer) }
        engine.prepare()
        do {
            try engine.start()
            transcript = base
            isListening = true
        } catch {
            problem = "Couldn't start the microphone."
            stop()
        }
    }

    func stop() {
        guard isListening || task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
