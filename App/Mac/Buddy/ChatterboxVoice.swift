import Foundation

/// Which voice Blob speaks with.
enum VoiceEngine: String, CaseIterable, Identifiable {
    case chatterbox, kokoro, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chatterbox: return "Chatterbox Daniel — most natural (a few seconds slower)"
        case .kokoro: return "Kokoro — natural and fast"
        case .apple: return "Apple system voice"
        }
    }

    static var current: VoiceEngine {
        if let raw = UserDefaults.standard.string(forKey: "blobVoiceEngine"), let e = VoiceEngine(rawValue: raw) { return e }
        // Earlier versions stored an on/off switch for Kokoro.
        if UserDefaults.standard.object(forKey: "blobNaturalVoice") as? Bool == false { return .apple }
        return .chatterbox
    }

    /// What actually speaks right now: on battery, Chatterbox (heavy GPU work) hands over to Kokoro
    /// unless "Natural voice on battery" is turned on.
    static var effective: VoiceEngine {
        let chosen = current
        let allowOnBattery = UserDefaults.standard.bool(forKey: "blobChatterboxOnBattery")
        if chosen == .chatterbox, PowerSource.onBattery, !allowOnBattery { return .kokoro }
        return chosen
    }
}

/// Keeps Chatterbox loaded in a small local Python process (no network, no cost) and renders sentences on request.
/// Voice: Chatterbox conditioned on the Kokoro "Daniel" voice, calm settings (exaggeration 0.35, cfg 0.5).
@MainActor
final class ChatterboxServer {
    static let shared = ChatterboxServer()

    private(set) var isReady = false
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var waiting: [(id: String, cont: CheckedContinuation<URL?, Never>)] = []

    nonisolated static var voiceDir: URL { NaturalVoice.directory }
    nonisolated static var python: URL { voiceDir.appendingPathComponent("chatterbox-env/bin/python") }
    nonisolated static var reference: URL { voiceDir.appendingPathComponent("daniel_reference.wav") }
    nonisolated static var script: URL { voiceDir.appendingPathComponent("blob_voice_server.py") }

    nonisolated static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: reference.path)
    }

    /// Starts the server if Chatterbox is the chosen voice. Safe to call repeatedly.
    func startIfNeeded() {
        guard VoiceEngine.effective == .chatterbox, Self.isInstalled, process?.isRunning != true else { return }
        try? Self.serverSource.write(to: Self.script, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = Self.python
        p.arguments = [Self.script.path, Self.reference.path]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"                   // weights are already on disk — never touch the network
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            Task { @MainActor in ChatterboxServer.shared.received(data) }
        }
        p.terminationHandler = { _ in
            Task { @MainActor in ChatterboxServer.shared.stopped() }
        }
        do {
            try p.run()
            process = p
            stdin = inPipe.fileHandleForWriting
        } catch {
            process = nil
        }
    }

    func stop() {
        process?.terminate()
        stopped()
    }

    /// Renders one sentence. Returns nil if the server isn't ready yet or fails (the caller then uses Kokoro).
    func render(_ text: String) async -> URL? {
        guard isReady, let stdin else { return nil }
        let id = UUID().uuidString
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("blob-cb-\(id).wav")
        guard let line = try? JSONSerialization.data(withJSONObject: ["id": id, "text": text, "out": out.path]) else { return nil }
        return await withCheckedContinuation { cont in
            waiting.append((id, cont))
            stdin.write(line + Data("\n".utf8))
            // Don't wait forever on one sentence.
            Task {
                try? await Task.sleep(for: .seconds(60))
                ChatterboxServer.shared.resolve(id, url: nil)
            }
        }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if json["ready"] as? Bool == true { isReady = true; continue }
            if let id = json["id"] as? String {
                let ok = json["ok"] as? Bool == true
                resolve(id, url: ok ? (json["out"] as? String).map { URL(fileURLWithPath: $0) } : nil)
            }
        }
    }

    private func resolve(_ id: String, url: URL?) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: i).cont.resume(returning: url)
    }

    private func stopped() {
        isReady = false
        process = nil
        stdin = nil
        let pending = waiting
        waiting = []
        pending.forEach { $0.cont.resume(returning: nil) }
    }

    /// The Python side, written next to the model each launch so it always matches this app version.
    private static let serverSource = #"""
    # Blob's local voice server: loads Chatterbox once, then renders one sentence per JSON line on stdin.
    import sys, json, warnings
    warnings.filterwarnings("ignore")
    import torch, soundfile as sf
    from chatterbox.tts import ChatterboxTTS

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model = ChatterboxTTS.from_pretrained(device=device)
    model.prepare_conditionals(sys.argv[1], exaggeration=0.35)
    print(json.dumps({"ready": True}), flush=True)

    for line in sys.stdin:
        try:
            req = json.loads(line)
            with torch.inference_mode():
                wav = model.generate(req["text"], exaggeration=0.35, cfg_weight=0.5)
            sf.write(req["out"], wav.squeeze(0).cpu().numpy(), model.sr)
            print(json.dumps({"id": req["id"], "ok": True, "out": req["out"]}), flush=True)
        except Exception as e:
            print(json.dumps({"id": req.get("id"), "ok": False, "error": str(e)}), flush=True)
    """#
}
