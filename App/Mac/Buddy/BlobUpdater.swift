import AppKit

/// Blob's self-update, with the user in control at every step:
///  1. Only the user starts it — from Settings or by saying it to Blob. Blob's AI brains have no way to trigger it.
///  2. The user approves the request (a click, not a voice "yes").
///  3. Claude Code (on the user's Pro plan) edits the project folder, limited to file edits and build commands.
///  4. The user reviews a summary and the list of changed files, and approves again before anything is installed.
///  5. The old app and old source are backed up, so "undo the last update" always works.
@MainActor
final class BlobUpdater: ObservableObject {
    static let shared = BlobUpdater()

    enum State: Equatable {
        case idle
        case working(request: String, since: Date)
        case review(summary: String, changes: [String])
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Live, plain-English steps from Claude Code while an update runs (newest last).
    @Published private(set) var progress: [String] = []
    private var snapshot: URL?
    private let fm = FileManager.default

    /// Folders and files Claude Code may change — everything else in the project is left alone.
    private static let sourceItems = ["App", "Packages/BrainCore/Sources", "Packages/BrainCore/Tests", "Packages/BrainCore/Package.swift", "project.yml", "scripts", "README.md"]

    // MARK: Locations

    var sourceRoot: URL? {
        let custom = UserDefaults.standard.string(forKey: "blobSourceRoot") ?? ""
        let built = Bundle.main.object(forInfoDictionaryKey: "BlobSourceRoot") as? String ?? ""
        for path in [custom, built] where !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if fm.fileExists(atPath: url.appendingPathComponent("project.yml").path) { return url }
        }
        return nil
    }

    private var supportDir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ArjunsBrain", isDirectory: true)
    }
    private var backupsDir: URL { supportDir.appendingPathComponent("Backups", isDirectory: true) }

    /// Newest first. Each backup holds the previous app and its source.
    var backups: [URL] {
        ((try? fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    var statusText: String {
        switch state {
        case .idle: return backups.isEmpty ? "No updates yet." : "Last update installed. You can undo it."
        case .working(_, let since): return "Claude Code is working… (\(max(1, Int(Date().timeIntervalSince(since) / 60))) min)"
        case .review: return "An update is ready for your review."
        case .failed(let m): return "Last attempt failed: \(m)"
        }
    }

    // MARK: Step 3 — run Claude Code (called only after the user approved the request)

    func run(_ request: String) async -> State {
        guard !state.isBusy else { return state }
        guard let root = sourceRoot else {
            state = .failed("I can't find my source folder. Set it in Settings → Blob updates.")
            return state
        }
        guard let claude = await ClaudeCodeBrain.findClaude() else {
            state = .failed("Claude Code isn't installed.")
            return state
        }
        state = .working(request: request, since: Date())
        progress = ["Starting Claude Code…"]
        do {
            snapshot = try takeSnapshot(of: root)
        } catch {
            state = .failed("Couldn't back up the source first: \(error.localizedDescription)")
            return state
        }

        let result = await Self.runClaudeCode(claude: claude, root: root, request: request) { step in
            Task { @MainActor in
                let u = BlobUpdater.shared
                if u.progress.last != step { u.progress.append(step) }
                if u.progress.count > 40 { u.progress.removeFirst(u.progress.count - 40) }
            }
        }
        let product = root.appendingPathComponent("build/dd/Build/Products/Release/ArjunsBrain.app")
        let builtAt = (try? product.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let changes = changedFiles(root: root)

        guard result.ok, !changes.isEmpty else {
            restoreSnapshot(to: root)
            state = .failed(result.ok ? "Claude Code didn't change anything. \(result.summary)" : result.summary)
            return state
        }
        guard case .working(_, let since) = state, builtAt > since else {
            restoreSnapshot(to: root)
            state = .failed("The new version didn't build, so I put the code back the way it was.")
            return state
        }
        state = .review(summary: result.summary, changes: changes)
        return state
    }

    private nonisolated static func runClaudeCode(claude: String, root: URL, request: String,
                                                  onStep: @escaping @Sendable (String) -> Void) async -> (ok: Bool, summary: String) {
        let prompt = """
        You are updating "Blob" (the app was formerly called Arjun's Brain; its window is titled Blob's Brain), a SwiftUI app for macOS and iOS. Its Mac version includes Blob, a voice assistant \
        in the screen corner (code in App/Mac/Buddy). Shared app code is in App/Shared; core logic and unit tests are in \
        Packages/BrainCore. The Xcode project is generated by XcodeGen from project.yml (run `xcodegen generate` after adding files).

        The user asked for this change: "\(request)"

        Rules:
        - Only edit files inside this project folder.
        - Do not change code signing, bundle identifiers, the BlobSourceRoot key, BlobUpdater.swift, or the self-update approval flow.
        - Keep Blob free to run: no paid APIs or services, no new network calls unless the request needs them.
        - Never add code that deletes user files or data.
        - When done, run ./scripts/build_dmg.sh and fix every error until it prints a line starting with "✓ build/".
        - If the request is unclear, unsafe, or impossible, make no changes and explain why.

        End your reply with one or two plain sentences, addressed to the user as "sir", summarizing what you changed. Blob will read it to them before they decide whether to install it.
        """
        // Claude Code may only read/edit files (in this folder) and run these build commands. Everything else is denied.
        let allowed = ["Read", "Edit", "Write", "Glob", "Grep",
                       "Bash(xcodegen generate)", "Bash(xcodebuild:*)", "Bash(swift build:*)", "Bash(swift test:*)", "Bash(./scripts/build_dmg.sh)"]
        let denied = ["WebFetch", "WebSearch", "Bash(rm:*)", "Bash(curl:*)", "Bash(git push:*)"]
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let allowedArgs: String = allowed.map(quote).joined(separator: " ")
        let deniedArgs: String = denied.map(quote).joined(separator: " ")
        var command: String = "cd " + quote(root.path) + " && " + quote(claude) + " -p " + quote(prompt)
        command += " --output-format stream-json --verbose --permission-mode acceptEdits"
        command += " --allowedTools " + allowedArgs
        command += " --disallowedTools " + deniedArgs

        // Stream Claude Code's events and turn each one into a short, readable step.
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle(forWritingAtPath: "/dev/null")
            let state = StreamState()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty else { return }
                for line in state.append(data) {
                    guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if json["type"] as? String == "result" {
                        state.finish(text: json["result"] as? String ?? "", isError: json["is_error"] as? Bool == true)
                    } else if let step = describe(json) {
                        onStep(step)
                    }
                }
            }
            p.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                let (text, isError, gotResult) = state.result
                let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                var summary: String = lines.suffix(2).joined(separator: " ")
                if summary.isEmpty { summary = gotResult ? "Update finished." : "Claude Code stopped unexpectedly." }
                let ok: Bool = gotResult && !isError
                cont.resume(returning: (ok, summary))
            }
            do { try p.run() } catch { cont.resume(returning: (false, "Couldn't start Claude Code.")) ; return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45 * 60) { if p.isRunning { p.terminate() } }
        }
    }

    /// One Claude Code stream event → a short step for the bubble ("Editing BlobCharacter.swift…").
    private nonisolated static func describe(_ event: [String: Any]) -> String? {
        guard event["type"] as? String == "assistant",
              let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return nil }
        var step: String?
        for block in content {
            switch block["type"] as? String {
            case "text":
                let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let first = t.components(separatedBy: .newlines).first, !first.isEmpty {
                    step = "💭 " + String(first.prefix(90))
                }
            case "tool_use":
                let input = block["input"] as? [String: Any] ?? [:]
                let file = (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
                switch block["name"] as? String {
                case "Read": step = "Reading \(file ?? "code")…"
                case "Edit", "MultiEdit": step = "Editing \(file ?? "code")…"
                case "Write": step = "Writing \(file ?? "a file")…"
                case "Glob", "Grep": step = "Searching the code…"
                case "Bash":
                    let cmd = input["command"] as? String ?? ""
                    if cmd.contains("build_dmg") { step = "Building and testing Blob…" }
                    else if cmd.contains("xcodegen") { step = "Updating the Xcode project…" }
                    else if cmd.contains("swift test") { step = "Running tests…" }
                    else { step = "Building…" }
                default: break
                }
            default: break
            }
        }
        return step
    }

    // MARK: Step 4 — the user approved the review: install, or discard

    func installReviewedUpdate() throws {
        guard case .review(let summary, _) = state, let root = sourceRoot else { return }
        let product = root.appendingPathComponent("build/dd/Build/Products/Release/ArjunsBrain.app")
        let current = URL(fileURLWithPath: Bundle.main.bundlePath)
        guard !current.path.hasPrefix("/Volumes/") else {
            throw NSError(domain: "Blob", code: 1, userInfo: [NSLocalizedDescriptionKey: "Move Blob into Applications first — it can't update itself while running from the installer disk."])
        }

        // Back up the running app and the pre-update source together.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = backupsDir.appendingPathComponent(stamp, isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try fm.copyItem(at: current, to: backup.appendingPathComponent("App.app"))
        if let snapshot { try? fm.moveItem(at: snapshot, to: backup.appendingPathComponent("Source")) }
        snapshot = nil
        for old in backups.dropFirst(3) { try? fm.removeItem(at: old) }

        try replaceApp(current, with: product)
        UserDefaults.standard.set("I'm back, sir. \(summary)", forKey: "blobUpdateNote")
        state = .idle
        relaunch()
    }

    func discardReviewedUpdate() {
        if let root = sourceRoot { restoreSnapshot(to: root) }
        state = .idle
    }

    // MARK: Step 5 — undo

    func undoLastUpdate() throws {
        guard let backup = backups.first else {
            throw NSError(domain: "Blob", code: 2, userInfo: [NSLocalizedDescriptionKey: "There's no earlier version to go back to."])
        }
        try replaceApp(URL(fileURLWithPath: Bundle.main.bundlePath), with: backup.appendingPathComponent("App.app"))
        if let root = sourceRoot, fm.fileExists(atPath: backup.appendingPathComponent("Source").path) {
            snapshot = backup.appendingPathComponent("Source")
            restoreSnapshot(to: root)
        }
        try? fm.removeItem(at: backup)
        UserDefaults.standard.set("I've gone back to the previous version, sir.", forKey: "blobUpdateNote")
        relaunch()
    }

    // MARK: Helpers

    private func takeSnapshot(of root: URL) throws -> URL {
        let dir = supportDir.appendingPathComponent("UpdateSnapshot", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for item in Self.sourceItems {
            let src = root.appendingPathComponent(item)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = dir.appendingPathComponent(item)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
        }
        return dir
    }

    private func restoreSnapshot(to root: URL) {
        guard let snapshot else { return }
        for item in Self.sourceItems {
            let saved = snapshot.appendingPathComponent(item)
            guard fm.fileExists(atPath: saved.path) else { continue }
            let target = root.appendingPathComponent(item)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: saved, to: target)
        }
        try? fm.removeItem(at: snapshot)
        self.snapshot = nil
    }

    /// Files added, removed or edited compared with the snapshot (paths relative to the project).
    private func changedFiles(root: URL) -> [String] {
        guard let snapshot else { return [] }
        func files(under base: URL) -> [String: URL] {
            var out: [String: URL] = [:]
            for item in Self.sourceItems {
                let url = base.appendingPathComponent(item)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if !isDir.boolValue { out[item] = url; continue }
                let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        out[String(f.path.dropFirst(base.path.count + 1))] = f
                    }
                }
            }
            return out
        }
        let before = files(under: snapshot), after = files(under: root)
        var changes: [String] = []
        for (path, url) in after.sorted(by: { $0.key < $1.key }) {
            if let old = before[path] {
                if !fm.contentsEqual(atPath: old.path, andPath: url.path) { changes.append("edited  \(path)") }
            } else {
                changes.append("added   \(path)")
            }
        }
        for path in before.keys.sorted() where after[path] == nil { changes.append("removed \(path)") }
        return changes
    }

    private func replaceApp(_ current: URL, with new: URL) throws {
        let staging = current.deletingLastPathComponent().appendingPathComponent(".blob-update-\(UUID().uuidString).app")
        try fm.copyItem(at: new, to: staging)
        _ = try fm.replaceItemAt(current, withItemAt: staging)
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        Task {
            try? await Task.sleep(for: .seconds(3))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", path]
            try? p.run()
            NSApplication.shared.terminate(nil)
        }
    }
}

private extension BlobUpdater.State {
    var isBusy: Bool {
        if case .working = self { return true }
        if case .review = self { return true }
        return false
    }
}

/// Collects streamed bytes into lines and remembers the final result (used from Process callbacks).
private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var text = ""
    private var isError = false
    private var gotResult = false

    func append(_ data: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }

    func finish(text: String, isError: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.text = text; self.isError = isError; gotResult = true
    }

    var result: (String, Bool, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (text, isError, gotResult)
    }
}
