import AppKit
import Carbon.HIToolbox
import IOKit.ps
import ScreenCaptureKit
import UserNotifications
import PDFKit
import Vision
import BrainCore

/// What a tool hands back to Blob's brain.
struct ToolOutput {
    var text: String
    var imageJPEGBase64: String?
    var isError = false

    static func error(_ s: String) -> ToolOutput { ToolOutput(text: s, isError: true) }
}

/// Everything Blob can do on the Mac. Safe actions run immediately; shell commands and
/// (by default) AppleScript ask you first.
@MainActor
final class BuddyTools {
    let store: BrainStore
    /// Asks the user to approve a risky action; returns true if allowed.
    var confirm: (String) async -> Bool = { _ in false }
    /// Status line shown under the blob while a tool runs ("Opening Spotify…").
    var onStatus: (String) -> Void = { _ in }
    /// Says something out loud (used when a timer goes off).
    var announce: (String) -> Void = { _ in }
    /// Self-update hooks. Only the instant voice commands (your own words) call these —
    /// they're deliberately NOT in `definitions`, so Blob's AI brains can't trigger an update.
    var requestUpdate: (String) async -> String = { _ in "" }
    var undoUpdate: () async -> String = { "" }
    /// The app that was in front when Blob was summoned — keyboard tools type into it.
    var targetApp: NSRunningApplication?

    private var timers: [Timer] = []
    /// On-device app control through Accessibility.
    let screen = ScreenControl()

    init(store: BrainStore) {
        self.store = store
        screen.targetApp = { [weak self] in self?.targetApp }
    }

    // MARK: - Tool schemas sent to Claude

    static var definitions: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ props: [String: Any] = [:], _ required: [String] = []) -> [String: Any] {
            ["name": name, "description": description,
             "input_schema": ["type": "object", "properties": props, "required": required] as [String: Any]]
        }
        let str: (String) -> [String: Any] = { ["type": "string", "description": $0] }
        let int: (String) -> [String: Any] = { ["type": "integer", "description": $0] }
        let bool: (String) -> [String: Any] = { ["type": "boolean", "description": $0] }

        return [
            tool("open_app", "Open (or bring to front) a Mac app by name, e.g. Safari, Spotify, Notes.", ["name": str("App name")], ["name"]),
            tool("quit_app", "Quit a running app by name.", ["name": str("App name")], ["name"]),
            tool("open_url", "Open a web page or app link (https, mailto, spotify:, zoommtg: …) in the default handler.", ["url": str("Full URL")], ["url"]),
            tool("play_youtube", "Find a video on YouTube and start playing the top result in the browser.", ["query": str("What to watch")], ["query"]),
            tool("search_web", "Search in the user's browser.", ["query": str("Search words"),
                 "site": ["type": "string", "enum": ["google", "youtube", "amazon", "wikipedia", "reddit", "maps", "images"]] as [String: Any]], ["query"]),
            tool("play_music", "Play a song, artist or album: Apple Music library first, then Spotify, then YouTube.",
                 ["query": str("Song, artist or album"), "app": ["type": "string", "enum": ["music", "spotify", "youtube"]] as [String: Any]], ["query"]),
            tool("list_ui_elements", "List the buttons, links, fields and menus in the front app's window (numbered), optionally filtered by text. Use before click_ui_element.",
                 ["filter": str("Optional text to look for")]),
            tool("click_ui_element", "Click a button/link/item in the front app by its number from list_ui_elements, or by its label. Text fields get focused so you can type_text.",
                 ["target": str("Number like 3, or label text")], ["target"]),
            tool("choose_menu_item", "Choose a menu-bar item in the front app, e.g. 'File > New Window' or 'View > Enter Full Screen'.", ["path": str("Menu path with >")], ["path"]),
            tool("set_volume", "Set the Mac's output volume, or mute/unmute.",
                 ["level": int("0-100. Omit when only muting."), "muted": bool("true to mute, false to unmute")]),
            tool("media_control", "Control music playback in Spotify or Apple Music.",
                 ["action": ["type": "string", "enum": ["play", "pause", "play_pause", "next", "previous", "now_playing"]] as [String: Any],
                  "app": str("Spotify or Music. Omit to use whichever is running.")], ["action"]),
            tool("system_status", "Battery level, volume, frontmost app, running apps, and free disk space."),
            tool("look_at_screen", "Take a screenshot of the main display so you can see what the user is looking at. Use when they ask about something on screen."),
            tool("search_files", "Search the Mac (Spotlight) for files by name or contents. Returns paths, newest first.",
                 ["query": str("Words to search for"), "in_folder": str("Optional folder to limit to, e.g. ~/Documents"),
                  "names_only": bool("Match file names only (faster, fewer results)")], ["query"]),
            tool("read_file", "Read a file's text: plain text/code, PDF, Word/RTF/Pages-exported docs, or images (via on-device text recognition).",
                 ["path": str("Absolute path or ~/…")], ["path"]),
            tool("list_folder", "List what's in a folder (names, sizes, modified dates).", ["path": str("Folder path, e.g. ~/Downloads")], ["path"]),
            tool("read_screen_text", "Read all visible text on the main display using on-device text recognition (no image)."),
            tool("read_clipboard", "Read the text currently on the clipboard."),
            tool("current_browser_tab", "Get the URL and title of the front tab in Safari, Chrome, Arc, Brave or Edge."),
            tool("type_text", "Type text into the app the user was using (as if typed on the keyboard).", ["text": str("Text to type")], ["text"]),
            tool("press_keys", "Press a keyboard shortcut in the app the user was using, e.g. 'cmd+t', 'cmd+shift+4', 'return', 'cmd+space'.",
                 ["keys": str("Keys joined with +")], ["keys"]),
            tool("run_applescript", "Run AppleScript to control apps (Finder, Mail, Messages, Safari tabs, System Events, etc.). The user approves it first unless they've trusted AppleScript. Explain the purpose in 'reason'.",
                 ["script": str("AppleScript source"), "reason": str("Short plain-English description shown to the user")], ["script", "reason"]),
            tool("run_shell", "Run a zsh command on the Mac. ALWAYS shown to the user for approval first. Prefer other tools when possible. Never use for destructive actions unless the user explicitly asked.",
                 ["command": str("Shell command"), "reason": str("Short plain-English description shown to the user")], ["command", "reason"]),
            tool("get_schedule", "Read the user's calendar events, assignments due, and today's check-in plan from Blob's Brain.",
                 ["date": str("YYYY-MM-DD, default today"), "days": int("How many days, 1-14 (default 1)")]),
            tool("list_assignments", "List open to-dos and school assignments with due dates and time estimates.",
                 ["include_completed": bool("Also include recently completed ones")]),
            tool("add_event", "Add an event to the user's calendar in Blob's Brain.",
                 ["title": str("Event title"), "start": str("Local start, YYYY-MM-DDTHH:MM (or YYYY-MM-DD for all-day)"),
                  "end": str("Local end, same format. Default 1 hour after start"), "location": str("Optional"),
                  "repeat": ["type": "string", "enum": ["none", "daily", "weekdays", "weekly", "monthly"]] as [String: Any]],
                 ["title", "start"]),
            tool("add_task", "Add a to-do or assignment to Blob's Brain.",
                 ["title": str("What to do"), "due": str("Local due time YYYY-MM-DDTHH:MM, optional"),
                  "course": str("Class name, optional"), "estimate_minutes": int("How long it takes, optional"),
                  "long_term": bool("A big assignment worked on over days or weeks (project, essay, studying for a test) — Blob splits it into dated steps")], ["title"]),
            tool("complete_task", "Mark a to-do/assignment as done.", ["title": str("Title (or close match) of the task")], ["title"]),
            tool("log_progress", "Log progress on an assignment from a plain sentence, e.g. 'worked 45 min on the history essay', 'finished the outline for my english essay', 'got 92/100 on the chem lab', 'history project is 60% done', 'break the science project into steps'. Pass the user's words.",
                 ["sentence": str("What the user said they did")], ["sentence"]),
            tool("assignment_status", "How the user's long-term assignments are going (progress, on pace or behind, next step, time per day needed). Give a title for one assignment, or leave empty for all.",
                 ["title": str("Assignment (optional)")]),
            tool("check_in", "Check the user in: builds their timeline of what to work on from now until bedtime and returns it."),
            tool("set_timer", "Start a timer; Blob speaks and notifies when it finishes.",
                 ["minutes": ["type": "number", "description": "Length in minutes (can be fractional)"] as [String: Any], "label": str("What it's for")], ["minutes"]),
        ]
    }

    // MARK: - Dispatch

    func run(_ name: String, _ input: [String: Any]) async -> ToolOutput {
        func s(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "open_app": return openApp(s("name") ?? "")
        case "quit_app": return quitApp(s("name") ?? "")
        case "open_url": return openURL(s("url") ?? "")
        case "play_youtube": return await WebMedia.playYouTube(s("query") ?? "")
        case "search_web": return WebMedia.searchWeb(s("query") ?? "", site: s("site"))
        case "play_music":
            if s("app") == "youtube" { return await WebMedia.playYouTube((s("query") ?? "") + " audio") }
            return await WebMedia.playMusic(s("query") ?? "", app: s("app"), screen: screen)
        case "list_ui_elements": return screen.listElements(filter: s("filter"))
        case "click_ui_element": return screen.click(s("target") ?? "")
        case "choose_menu_item": return screen.chooseMenu(s("path") ?? "")
        case "set_volume": return setVolume(level: (input["level"] as? NSNumber)?.intValue, muted: input["muted"] as? Bool)
        case "media_control": return await media(action: s("action") ?? "play_pause", app: s("app"))
        case "system_status": return systemStatus()
        case "look_at_screen": return await lookAtScreen()
        case "search_files": return await searchFiles(s("query") ?? "", folder: s("in_folder"), namesOnly: input["names_only"] as? Bool ?? false)
        case "read_file": return await readFile(s("path") ?? "")
        case "list_folder": return listFolder(s("path") ?? "~")
        case "read_screen_text": return await readScreenText()
        case "read_clipboard": return ToolOutput(text: NSPasteboard.general.string(forType: .string).map { "Clipboard:\n" + String($0.prefix(8000)) } ?? "The clipboard has no text.")
        case "current_browser_tab": return browserTab()
        case "type_text": return await typeText(s("text") ?? "")
        case "press_keys": return await pressKeys(s("keys") ?? "")
        case "run_applescript": return await runAppleScript(s("script") ?? "", reason: s("reason") ?? "Run a script")
        case "run_shell": return await runShell(s("command") ?? "", reason: s("reason") ?? "Run a command")
        case "get_schedule": return schedule(date: s("date"), days: (input["days"] as? NSNumber)?.intValue ?? 1)
        case "list_assignments": return assignments(includeDone: input["include_completed"] as? Bool ?? false)
        case "add_event": return addEvent(input)
        case "add_task": return addTask(input)
        case "complete_task": return completeTask(s("title") ?? "")
        case "log_progress": return logProgress(s("sentence") ?? "")
        case "assignment_status": return assignmentStatus(s("title"))
        case "check_in": return checkIn()
        case "set_timer": return setTimer(minutes: (input["minutes"] as? NSNumber)?.doubleValue ?? 0, label: s("label"))
        default: return .error("Unknown tool \(name)")
        }
    }

    // MARK: - Apps & web

    func openApp(_ name: String) -> ToolOutput {
        guard let url = findApp(name) else { return .error("Couldn't find an app called \(name).") }
        onStatus("Opening \(url.deletingPathExtension().lastPathComponent)…")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return ToolOutput(text: "Opened \(url.deletingPathExtension().lastPathComponent).")
    }

    func findApp(_ rawName: String) -> URL? {
        let name = rawName.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let aliases = ["chrome": "google chrome", "vscode": "visual studio code", "vs code": "visual studio code",
                       "word": "microsoft word", "excel": "microsoft excel", "powerpoint": "microsoft powerpoint",
                       "settings": "system settings", "system preferences": "system settings", "itunes": "music",
                       "teams": "microsoft teams", "outlook": "microsoft outlook"]
        let wanted = aliases[name] ?? name
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                    NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications"]
        var candidates: [URL] = []
        for dir in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            candidates += items.filter { $0.pathExtension == "app" }
        }
        func key(_ u: URL) -> String { u.deletingPathExtension().lastPathComponent.lowercased() }
        return candidates.first { key($0) == wanted }
            ?? candidates.first { key($0).hasPrefix(wanted) }
            ?? candidates.first { key($0).contains(wanted) }
    }

    func quitApp(_ name: String) -> ToolOutput {
        let n = name.lowercased()
        let matches = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && ($0.localizedName?.lowercased().contains(n) ?? false) && $0 != NSRunningApplication.current
        }
        guard !matches.isEmpty else { return .error("\(name) isn't running.") }
        matches.forEach { $0.terminate() }
        return ToolOutput(text: "Quit \(matches.compactMap(\.localizedName).joined(separator: ", ")).")
    }

    func openURL(_ raw: String) -> ToolOutput {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme != "file" else {
            return .error("That isn't a link I can open.")
        }
        onStatus("Opening \(url.host ?? scheme)…")
        return NSWorkspace.shared.open(url) ? ToolOutput(text: "Opened \(raw).") : .error("Nothing on this Mac can open \(raw).")
    }

    // MARK: - Sound & media

    func setVolume(level: Int?, muted: Bool?) -> ToolOutput {
        var parts: [String] = []
        if let level { parts.append("set volume output volume \(max(0, min(100, level)))") }
        if let muted { parts.append("set volume output muted \(muted)") }
        guard !parts.isEmpty else { return .error("Give a level or mute.") }
        if level != nil && muted == nil { parts.append("set volume output muted false") }
        _ = Self.appleScript(parts.joined(separator: "\n"))
        return ToolOutput(text: "Volume \(level.map { "set to \($0)%" } ?? "")\(muted == true ? " muted" : muted == false ? " unmuted" : "").")
    }

    func media(action: String, app: String?) async -> ToolOutput {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        let target = app ?? (running.contains("Spotify") ? "Spotify" : "Music")
        let verb: String
        switch action {
        case "play": verb = "play"
        case "pause": verb = "pause"
        case "next": verb = "next track"
        case "previous": verb = "previous track"
        case "now_playing":
            let script = target == "Spotify"
                ? #"tell application "Spotify" to if player state is playing then return (name of current track) & " by " & (artist of current track)"#
                : #"tell application "Music" to if player state is playing then return (name of current track) & " by " & (artist of current track)"#
            let r = Self.appleScript(script)
            return ToolOutput(text: r.output.isEmpty ? "Nothing is playing in \(target)." : "Now playing: \(r.output)", isError: r.error != nil)
        default: verb = "playpause"
        }
        let r = Self.appleScript("tell application \"\(target)\" to \(verb)")
        if let e = r.error { return .error("\(target): \(e)") }
        return ToolOutput(text: "\(target): \(action.replacingOccurrences(of: "_", with: "/")).")
    }

    // MARK: - Status

    func systemStatus() -> ToolOutput {
        var lines: [String] = []
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                   let cap = d[kIOPSCurrentCapacityKey] as? Int {
                    let charging = (d[kIOPSIsChargingKey] as? Bool) == true ? ", charging" : ""
                    lines.append("Battery: \(cap)%\(charging)")
                }
            }
        }
        let vol = Self.appleScript("output volume of (get volume settings) & \" \" & output muted of (get volume settings)").output
        if !vol.isEmpty { lines.append("Volume / muted: \(vol)") }
        if let front = targetApp?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName { lines.append("Frontmost app: \(front)") }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        lines.append("Running apps: \(apps.joined(separator: ", "))")
        if let attrs = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = attrs.volumeAvailableCapacityForImportantUsage {
            lines.append("Free disk: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
        }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }

    // MARK: - Screen

    func lookAtScreen() async -> ToolOutput {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return .error("I need Screen Recording permission. Turn on Blob in System Settings → Privacy & Security → Screen & System Audio Recording, then ask again.")
        }
        onStatus("Looking at your screen…")
        do {
            guard let image = try await captureScreen(maxWidth: 1568) else { return .error("No display found.") }
            guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
                return .error("Couldn't encode the screenshot.")
            }
            let front = targetApp?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            return ToolOutput(text: "Screenshot of the main display (front app: \(front)):", imageJPEGBase64: jpeg.base64EncodedString())
        } catch {
            return .error("Screenshot failed: \(error.localizedDescription)")
        }
    }

    /// Raw screenshot (main display, excluding Blob) as a CGImage.
    private func captureScreen(maxWidth: Double) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else { return nil }
        let mine = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let config = SCStreamConfiguration()
        let scale = min(2.0, maxWidth / Double(display.width))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: mine), configuration: config)
    }

    func readScreenText() async -> ToolOutput {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return .error("I need Screen Recording permission. Turn on Blob in System Settings → Privacy & Security → Screen & System Audio Recording, then ask again.")
        }
        onStatus("Reading your screen…")
        do {
            guard let image = try await captureScreen(maxWidth: 2880) else { return .error("No display found.") }
            let text = await Self.recognizeText(in: image)
            let front = targetApp?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            return ToolOutput(text: "Front app: \(front)\nVisible text (top to bottom):\n" + (text.isEmpty ? "(none found)" : String(text.prefix(12000))))
        } catch {
            return .error("Couldn't read the screen: \(error.localizedDescription)")
        }
    }

    /// On-device OCR with Apple's Vision framework.
    nonisolated static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: image).perform([request])
                let lines = (request.results ?? [])
                    .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                    .compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Files

    private func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath)
    }

    func searchFiles(_ query: String, folder: String?, namesOnly: Bool) async -> ToolOutput {
        guard !query.isEmpty else { return .error("What should I search for?") }
        onStatus("Searching for \(query)…")
        var args = ["-onlyin", folder.map { expand($0).path } ?? NSHomeDirectory()]
        if namesOnly { args += ["-name", query] } else { args.append(query) }
        let out = await Self.runProcess("/usr/bin/mdfind", args, timeout: 15)
        let paths = out.split(separator: "\n").map(String.init)
            .filter { !$0.contains("/Library/") && !$0.contains("/.") }
        guard !paths.isEmpty else { return ToolOutput(text: "No files found for \"\(query)\".") }
        let fm = FileManager.default
        let dated: [(String, Date)] = paths.prefix(300).map { p in
            (p, (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast)
        }
        let top = dated.sorted { $0.1 > $1.1 }.prefix(25)
        return ToolOutput(text: "\(paths.count) matches; newest 25:\n" + top.map { "\($0.0)  (modified \($0.1.dueText()))" }.joined(separator: "\n"))
    }

    func listFolder(_ path: String) -> ToolOutput {
        let url = expand(path)
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return .error("Can't open \(url.path). It may not exist, or macOS may need Files & Folders permission for it.")
        }
        let rows = items.map { u -> (String, Date) in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            let size = v?.isDirectory == true ? "folder" : ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file)
            return ("\(u.lastPathComponent)  (\(size))", v?.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        return ToolOutput(text: "\(url.path) — \(rows.count) items, newest first:\n" + rows.prefix(80).map { "\($0.0) · \($0.1.dueText())" }.joined(separator: "\n"))
    }

    func readFile(_ path: String) async -> ToolOutput {
        let url = expand(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return .error("No file at \(url.path).") }
        onStatus("Reading \(url.lastPathComponent)…")
        let ext = url.pathExtension.lowercased()
        var text: String?
        if ext == "pdf" {
            text = PDFDocument(url: url)?.string
        } else if ["png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp", "webp"].contains(ext) {
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                let t = await Self.recognizeText(in: img)
                text = "Text recognized in image:\n" + (t.isEmpty ? "(no text)" : t)
            }
        } else if ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive"].contains(ext) {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        } else {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }
        guard var t = text, !t.isEmpty else { return .error("I can't read text from \(url.lastPathComponent).") }
        let total = t.count
        if total > 30000 { t = String(t.prefix(30000)) + "\n…(showing first 30,000 of \(total) characters)" }
        return ToolOutput(text: "\(url.path):\n\(t)")
    }

    func browserTab() -> ToolOutput {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        let browsers: [(String, String)] = [
            ("Safari", #"tell application "Safari" to return (URL of front document) & linefeed & (name of front document)"#),
            ("Google Chrome", #"tell application "Google Chrome" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)"#),
            ("Arc", #"tell application "Arc" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)"#),
            ("Brave Browser", #"tell application "Brave Browser" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)"#),
            ("Microsoft Edge", #"tell application "Microsoft Edge" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)"#),
        ]
        let front = targetApp?.localizedName
        let ordered = browsers.filter { $0.0 == front } + browsers.filter { $0.0 != front }
        for (name, script) in ordered where running.contains(name) {
            let r = Self.appleScript(script)
            if r.error == nil, !r.output.isEmpty { return ToolOutput(text: "\(name) front tab:\n\(r.output)") }
        }
        return .error("No supported browser has a tab open (or macOS asked for permission to control it — allow it and try again).")
    }

    nonisolated static func runProcess(_ exe: String, _ args: [String], timeout: Double) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: ""); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    // MARK: - Keyboard

    private func ensureAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private func focusTarget() async {
        if let app = targetApp, !app.isActive {
            app.activate()
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    func typeText(_ text: String) async -> ToolOutput {
        guard ensureAccessibility() else {
            return .error("I need Accessibility permission to type. Turn on Blob in System Settings → Privacy & Security → Accessibility.")
        }
        await focusTarget()
        let utf16 = Array(text.utf16)
        var i = 0
        while i < utf16.count {
            let chunk = Array(utf16[i..<min(i + 16, utf16.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.post(tap: .cghidEventTap)
            }
            i += 16
            try? await Task.sleep(for: .milliseconds(12))
        }
        return ToolOutput(text: "Typed \(text.count) characters into \(targetApp?.localizedName ?? "the front app").")
    }

    static let keyCodes: [String: Int] = {
        var m: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "escape": kVK_Escape, "esc": kVK_Escape,
            "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "`": kVK_ANSI_Grave,
        ]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, k) in fkeys.enumerated() { m["f\(i + 1)"] = k }
        return m
    }()

    func pressKeys(_ combo: String) async -> ToolOutput {
        guard ensureAccessibility() else {
            return .error("I need Accessibility permission for shortcuts. Turn on Blob in System Settings → Privacy & Security → Accessibility.")
        }
        var flags: CGEventFlags = []
        var key: Int?
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: key = Self.keyCodes[part]
            }
        }
        guard let key else { return .error("I don't know the key in \(combo).") }
        await focusTarget()
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        return ToolOutput(text: "Pressed \(combo).")
    }

    // MARK: - Scripts (approval required)

    func runAppleScript(_ script: String, reason: String) async -> ToolOutput {
        let trusted = UserDefaults.standard.bool(forKey: "buddyTrustAppleScript")
        if !trusted {
            guard await confirm("\(reason)\n\nAppleScript:\n\(script)") else { return .error("The user said no.") }
        }
        onStatus(reason + "…")
        let r = Self.appleScript(script)
        if let e = r.error { return .error("AppleScript error: \(e)") }
        return ToolOutput(text: r.output.isEmpty ? "Done." : String(r.output.prefix(4000)))
    }

    func runShell(_ command: String, reason: String) async -> ToolOutput {
        guard await confirm("\(reason)\n\n$ \(command)") else { return .error("The user said no.") }
        onStatus(reason + "…")
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", command]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: .error("Couldn't start: \(error.localizedDescription)"))
                    return
                }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                var out = String(data: data, encoding: .utf8) ?? ""
                if out.count > 6000 { out = String(out.prefix(6000)) + "\n…(truncated)" }
                cont.resume(returning: ToolOutput(text: "exit \(p.terminationStatus)\n\(out)", isError: p.terminationStatus != 0))
            }
        }
    }

    static func appleScript(_ source: String) -> (output: String, error: String?) {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { return ("", (err[NSAppleScript.errorMessage] as? String) ?? "failed") }
        return (result?.stringValue ?? "", nil)
    }

    // MARK: - Blob's Brain data

    private static let isoLocal: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parseDate(_ s: String?) -> (date: Date, allDay: Bool)? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let d = isoLocal.date(from: String(s.prefix(16))) { return (d, false) }
        if let d = dayOnly.date(from: String(s.prefix(10))) { return (d, true) }
        return nil
    }

    func schedule(date: String?, days: Int) -> ToolOutput {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Self.parseDate(date)?.date ?? Date())
        var lines: [String] = []
        for offset in 0..<max(1, min(14, days)) {
            let day = cal.date(byAdding: .day, value: offset, to: start)!
            lines.append("## " + day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            let occ = store.occurrences(on: day)
            let due = store.tasksDue(on: day)
            if occ.isEmpty && due.isEmpty { lines.append("(nothing)") }
            for o in occ {
                let when = o.isAllDay ? "all day" : "\(o.start.shortTime)–\(o.end.shortTime)"
                lines.append("- \(when): \(o.title)" + (o.location.map { " @ \($0)" } ?? ""))
            }
            for t in due {
                lines.append("- DUE \(t.due!.shortTime): \(t.title)" + (t.course.map { " (\($0))" } ?? "") + (t.isCompleted ? " ✓ done" : " · ~\(t.estimatedMinutes) min"))
            }
            if cal.isDateInToday(day), let plan = store.todayPlan {
                lines.append("Today's check-in plan (\(plan.summary)):")
                for b in plan.blocks where b.kind == .task {
                    lines.append("  \(b.start.shortTime) \(b.title)\(store.isBlockDone(b) ? " ✓" : "")")
                }
            }
        }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }

    func assignments(includeDone: Bool) -> ToolOutput {
        var list = store.pendingTasks.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        if includeDone {
            list += store.tasks.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }.prefix(10)
        }
        guard !list.isEmpty else { return ToolOutput(text: "No open to-dos or assignments.") }
        return ToolOutput(text: list.map { t in
            "- \(t.title)" + (t.course.map { " [\($0)]" } ?? "") + (t.due.map { " due \($0.dueText())" } ?? " (no due date)")
                + " · ~\(t.remainingMinutes) min left" + (t.isCompleted ? " ✓ done" : "")
                + (t.isLongTerm && !t.isCompleted ? " · long-term \(Int(t.progress * 100))% \(t.pace().label)" + (t.nextMilestone.map { ", next: \($0.title)" } ?? "") : "")
                + (t.percentGrade.map { " · grade \(Int($0.rounded()))%" } ?? "")
        }.joined(separator: "\n"))
    }

    func addEvent(_ input: [String: Any]) -> ToolOutput {
        guard let title = input["title"] as? String, let (start, allDay) = Self.parseDate(input["start"] as? String) else {
            return .error("Need a title and a start like 2026-10-20T15:00.")
        }
        let end = Self.parseDate(input["end"] as? String)?.date
            ?? (allDay ? Calendar.current.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(3600))
        let freq = RecurrenceRule.Frequency(rawValue: input["repeat"] as? String ?? "none") ?? .none
        store.upsert(BrainEvent(title: title, start: start, end: end, isAllDay: allDay, location: input["location"] as? String,
                                recurrence: RecurrenceRule(frequency: freq)))
        return ToolOutput(text: "Added \(title) on \(start.dueText(includeTime: !allDay)).")
    }

    func addTask(_ input: [String: Any]) -> ToolOutput {
        guard let title = input["title"] as? String, !title.isEmpty else { return .error("Need a title.") }
        let due = Self.parseDate(input["due"] as? String).map { $0.allDay ? Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: $0.date)! : $0.date }
        let est = (input["estimate_minutes"] as? NSNumber)?.intValue
        let t = BrainTask(title: title, course: input["course"] as? String, due: due, estimatedMinutes: est ?? 30,
                          estimateIsUserSet: est != nil)
        store.upsert(t)
        store.setUpLongTermIfNeeded(t.id, explicit: input["long_term"] as? Bool ?? false)
        if let saved = store.task(t.id), !saved.milestones.isEmpty {
            return ToolOutput(text: "Added \(title)" + (due.map { ", due \($0.dueText())" } ?? "") + ", tracked long-term in steps: "
                + saved.milestones.map { "\($0.title)" + ($0.due.map { " by \($0.dueText(includeTime: false))" } ?? "") }.joined(separator: "; ") + ".")
        }
        return ToolOutput(text: "Added to-do \(title)" + (due.map { ", due \($0.dueText())" } ?? "") + ".")
    }

    func completeTask(_ query: String) -> ToolOutput {
        guard var t = TaskMatcher.best(query, in: store.pendingTasks) else {
            return .error("No open task matches \"\(query)\". Open tasks: " + store.pendingTasks.prefix(15).map(\.title).joined(separator: "; "))
        }
        store.markDone(&t)
        store.upsert(t)
        return ToolOutput(text: "Marked \(t.title) done.")
    }

    func logProgress(_ sentence: String) -> ToolOutput {
        guard ProgressLogParser().parse(sentence) != nil else {
            return .error("Couldn't read that as progress. Phrase it like 'worked 30 min on X', 'finished the outline for X', 'got 18/20 on X', 'X is 50% done'.")
        }
        let msg = store.applyLog(sentence) ?? ""
        return msg.hasPrefix("I couldn't") ? .error(msg + " Open assignments: " + store.pendingTasks.prefix(15).map(\.title).joined(separator: "; ")) : ToolOutput(text: msg)
    }

    func assignmentStatus(_ title: String?) -> ToolOutput {
        guard let title, !title.isEmpty else { return ToolOutput(text: store.trackerSummary()) }
        guard let t = TaskMatcher.best(title, in: store.tasks) else { return .error("No assignment matches \"\(title)\".") }
        var lines = ["\(t.title)" + (t.course.map { " [\($0)]" } ?? "") + ": \(Int(t.progress * 100))% done, \(t.pace().label)."]
        if let d = t.due { lines.append("Due \(d.dueText()).") }
        lines.append("Logged \(Scheduler.durationText(t.loggedMinutes)), about \(Scheduler.durationText(t.remainingMinutes)) left.")
        if let need = t.minutesPerDayNeeded() { lines.append("Needs about \(Scheduler.durationText(need)) a day.") }
        for m in t.milestones { lines.append("- \(m.isDone ? "✓" : "○") \(m.title)" + (m.due.map { " by \($0.dueText(includeTime: false))" } ?? "")) }
        if let g = t.percentGrade { lines.append("Grade: \(Int(g.rounded()))%.") }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }

    func checkIn() -> ToolOutput {
        store.checkIn()
        guard let plan = store.todayPlan else { return .error("Couldn't build a plan.") }
        var lines = [plan.summary, plan.strategy]
        for b in plan.blocks {
            switch b.kind {
            case .task: lines.append("\(b.start.shortTime) \(b.title) (\(b.minutes) min) — \(b.reason ?? "")")
            case .event: lines.append("\(b.start.shortTime) [event] \(b.title)")
            case .breakTime: lines.append("\(b.start.shortTime) break")
            }
        }
        let overflow = plan.overflowTaskIDs.compactMap { store.task($0)?.title }
        if !overflow.isEmpty { lines.append("Didn't fit: " + overflow.joined(separator: ", ")) }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }

    func setTimer(minutes: Double, label: String?) -> ToolOutput {
        guard minutes > 0 else { return .error("Timer needs a length.") }
        let name = label ?? "Timer"
        let content = UNMutableNotificationContent()
        content.title = "⏰ \(name)"
        content.body = "Your \(Scheduler.durationText(Int(minutes.rounded()))) timer is done."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "buddy-timer-\(UUID())", content: content,
                                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: minutes * 60, repeats: false)))
        let t = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.announce("Hey! Your \(name.lowercased() == "timer" ? "" : name + " ")timer is done.") }
        }
        timers.append(t)
        let end = Date().addingTimeInterval(minutes * 60)
        return ToolOutput(text: "Timer set for \(minutes) minutes, ends at \(end.shortTime).")
    }
}
