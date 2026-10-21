import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Training mode: Blob watches you do something once, then does it for you on request.
//
// Recording is on only while training mode is on (Blob shows a red "Watching" bubble the whole time).
// What's kept: the apps you switch to, the web pages you go to, which button/link/field you clicked (by its
// name, not just where it was), what you typed, keyboard shortcuts and scrolling. Typing into password
// fields is never recorded — the routine pauses there and asks you to type it yourself.
// Routines are saved only on this Mac (~/Library/Application Support/ArjunsBrain/routines.json).

/// One thing you did.
struct RoutineStep: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case openApp, openURL, click, type, key, scroll, waitForUser }

    var id = UUID()
    var kind: Kind
    /// Seconds after the previous step (as you did it).
    var delay: Double = 0
    var appBundleID: String?
    var appName: String?
    var url: String?
    var text: String?
    /// Typed text that should be swapped for what you say next time ("search youtube for jazz").
    var isInput: Bool?
    /// Key combo like "cmd+t" or "return".
    var keys: String?
    var target: ClickTarget?
    var scrollY: Double?
    var scrollX: Double?

    var summary: String {
        switch kind {
        case .openApp: return "Open \(appName ?? "app")"
        case .openURL: return "Go to \(URL(string: url ?? "")?.host() ?? url ?? "page")"
        case .click:
            guard let t = target else { return "Click" }
            let what = t.label.isEmpty ? (t.roleName.isEmpty ? "spot" : t.roleName) : "“\(t.label)”"
            return (t.clickCount > 1 ? "Double-click " : t.rightClick ? "Right-click " : "Click ") + what + (t.appName.map { " in \($0)" } ?? "")
        case .type: return isInput == true ? "Type what you ask for (last time: “\(text ?? "")”)" : "Type “\(text ?? "")”"
        case .key: return "Press \(keys ?? "")"
        case .scroll: return (scrollY ?? 0) < 0 ? "Scroll down" : "Scroll up"
        case .waitForUser: return text ?? "Wait for you"
        }
    }
}

/// What was clicked, described so it can be found again even if the window moved.
struct ClickTarget: Codable, Hashable {
    var appBundleID: String?
    var appName: String?
    var role: String
    var label: String
    var identifier: String?
    var windowTitle: String?
    /// Click point as a fraction of the window (0…1), for when the element can't be found by name.
    var relX: Double?
    var relY: Double?
    /// Screen point (top-left origin) — last resort.
    var x: Double
    var y: Double
    var clickCount: Int = 1
    var rightClick: Bool = false
    var flags: UInt64 = 0

    var roleName: String { role.replacingOccurrences(of: "AX", with: "").lowercased() }
}

struct Routine: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Extra ways to ask for it.
    var phrases: [String] = []
    var steps: [RoutineStep]
    var createdAt = Date()
    var lastRun: Date?
    var runs = 0

    /// Clicking these asks you first when the routine runs.
    static let riskyWords = #"\b(send|submit|turn in|hand in|post|publish|delete|remove|trash|buy|purchase|pay|order|checkout|confirm|unsubscribe|transfer)\b"#
    var riskyClicks: [String] {
        steps.compactMap { $0.kind == .click ? $0.target?.label : nil }
            .filter { $0.range(of: Self.riskyWords, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}

// MARK: - Saved routines

@MainActor
final class RoutineLibrary: ObservableObject {
    static let shared = RoutineLibrary()
    @Published private(set) var routines: [Routine] = []
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ArjunsBrain")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("routines.json")
        if let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode([Routine].self, from: d) { routines = r }
    }

    func save(_ r: Routine) {
        if let i = routines.firstIndex(where: { $0.id == r.id }) { routines[i] = r } else { routines.append(r) }
        persist()
    }

    func delete(_ id: UUID) {
        routines.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(routines) { try? d.write(to: url, options: .atomic) }
        // Only readable by you.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func words(_ s: String) -> [String] {
        let stop: Set<String> = ["the", "a", "an", "my", "please", "for", "me", "to", "do", "run", "blob", "can", "you", "could", "hey", "routine"]
        return s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !stop.contains($0) }
    }

    /// "do my homework upload", "post to classroom", "search youtube for jazz" → the routine and anything extra you said.
    func match(_ request: String) -> (routine: Routine, input: String?)? {
        var text = request.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        text = text.replacingOccurrences(of: #"^(?:hey blob|blob|ok blob)[, ]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^(?:can you |could you |please |go ahead and )+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^(?:do|run|play|start|repeat) (?:the |my )?(?:routine )?"#, with: "", options: .regularExpression)
        var best: (Routine, String?, Double)?
        for r in routines {
            for phrase in [r.name] + r.phrases {
                let p = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                guard !p.isEmpty else { continue }
                // Said exactly, or said with something extra after it: "search youtube for lofi beats".
                if text == p { return (r, nil) }
                if text.hasPrefix(p + " ") {
                    var rest = String(text.dropFirst(p.count + 1))
                    rest = rest.replacingOccurrences(of: #"^(?:for|with|to|about|called|named|:)\s+"#, with: "", options: .regularExpression)
                    if best == nil || best!.2 < 1 { best = (r, rest.isEmpty ? nil : rest, 1) }
                    continue
                }
                // Same words, different order or filler.
                let pw = Set(Self.words(p)), tw = Set(Self.words(text))
                guard !pw.isEmpty, tw.count <= pw.count + 1 else { continue }
                let score = Double(pw.intersection(tw).count) / Double(pw.count)
                if score >= 0.8, score > (best?.2 ?? 0) { best = (r, nil, score) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }
}

// MARK: - Watching

@MainActor
final class TrainingRecorder {
    private(set) var isRecording = false
    private(set) var steps: [RoutineStep] = []
    var onChange: (Int) -> Void = { _ in }
    private var monitors: [Any] = []
    private var lastEventAt = Date()
    private var urlTimer: Timer?
    private var lastURL: String?
    /// Address-bar typing turns into "go to this page" once the new page shows up.
    private var pendingAddressStep: Int?

    static let browsers: [String: String] = [
        "com.apple.Safari": #"tell application id "com.apple.Safari" to return URL of front document"#,
        "com.google.Chrome": #"tell application id "com.google.Chrome" to return URL of active tab of front window"#,
        "company.thebrowser.Browser": #"tell application id "company.thebrowser.Browser" to return URL of active tab of front window"#,
        "com.brave.Browser": #"tell application id "com.brave.Browser" to return URL of active tab of front window"#,
        "com.microsoft.edgemac": #"tell application id "com.microsoft.edgemac" to return URL of active tab of front window"#,
    ]

    func start() {
        guard !isRecording else { return }
        steps = []
        isRecording = true
        lastEventAt = Date()
        lastURL = nil
        pendingAddressStep = nil
        // Starting point: the app (and page) that's in front right now.
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            append(RoutineStep(kind: .openApp, appBundleID: front.bundleIdentifier, appName: front.localizedName))
            if let id = front.bundleIdentifier, let u = Self.currentURL(id) {
                lastURL = u
                append(RoutineStep(kind: .openURL, appBundleID: id, appName: front.localizedName, url: u))
            }
        }
        let handler: (NSEvent) -> Void = { e in Task { @MainActor in self.handle(e) } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel], handler: handler) {
            monitors.append(m)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        urlTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { _ in Task { @MainActor in self.checkURL() } }
    }

    /// Stops watching and returns the cleaned-up steps.
    func stop() -> [RoutineStep] {
        guard isRecording else { return [] }
        isRecording = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        urlTimer?.invalidate()
        urlTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        return Self.cleanUp(steps)
    }

    private func append(_ s: RoutineStep) {
        var s = s
        s.delay = min(Date().timeIntervalSince(lastEventAt), 30)
        lastEventAt = Date()
        steps.append(s)
        onChange(steps.count)
    }

    @objc private func appActivated(_ n: Notification) {
        guard isRecording, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app != NSRunningApplication.current else { return }
        if let last = steps.last(where: { $0.kind == .openApp }), last.appBundleID == app.bundleIdentifier,
           steps.last?.kind == .openApp { return }
        append(RoutineStep(kind: .openApp, appBundleID: app.bundleIdentifier, appName: app.localizedName))
    }

    private func checkURL() {
        guard isRecording, let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier,
              Self.browsers[id] != nil, let u = Self.currentURL(id), u != lastURL else { return }
        lastURL = u
        // You typed an address (or a search) in the address bar → next time just go straight to the page.
        if let i = pendingAddressStep, i < steps.count {
            steps.removeSubrange(i...)
            pendingAddressStep = nil
            append(RoutineStep(kind: .openURL, appBundleID: id, appName: front.localizedName, url: u))
        }
    }

    static func currentURL(_ bundleID: String) -> String? {
        guard let script = browsers[bundleID] else { return nil }
        let r = BuddyTools.appleScript(script)
        return r.error == nil && r.output.hasPrefix("http") ? r.output : nil
    }

    // MARK: Events

    private func handle(_ e: NSEvent) {
        guard isRecording else { return }
        switch e.type {
        case .leftMouseDown, .rightMouseDown: recordClick(e)
        case .keyDown: recordKey(e)
        case .scrollWheel: recordScroll(e)
        default: break
        }
    }

    private func recordClick(_ e: NSEvent) {
        // NSEvent uses bottom-left screen coordinates; Accessibility uses top-left.
        let loc = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let p = CGPoint(x: loc.x, y: primaryHeight - loc.y)

        var role = "", label = "", identifier: String?, windowTitle: String?, relX: Double?, relY: Double?
        var appID: String?, appName: String?
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success, let el = hit {
            // Use the nearest thing with a name (a click on a button's icon should count as the button).
            var current: AXUIElement? = el
            // Containers (windows, pages, scroll areas) aren't what you clicked — a click there is remembered by position.
            let containers: Set<String> = ["AXWindow", "AXScrollArea", "AXWebArea", "AXApplication", "AXSplitGroup", "AXLayoutArea", "AXSheet"]
            for _ in 0..<4 {
                guard let c = current else { break }
                let r = ScreenControl.string(c, kAXRoleAttribute) ?? ""
                if containers.contains(r) { if role.isEmpty { role = r }; break }
                let l = ScreenControl.label(c)
                if role.isEmpty { role = r }
                if !l.isEmpty { role = r; label = l; identifier = ScreenControl.string(c, "AXIdentifier"); break }
                var parent: CFTypeRef?
                AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &parent)
                current = parent.map { $0 as! AXUIElement }
            }
            if role == "AXSecureTextField" { label = "password field" }
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            if let app = NSRunningApplication(processIdentifier: pid) { appID = app.bundleIdentifier; appName = app.localizedName }
            var win: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &win) == .success, let w = win {
                let window = w as! AXUIElement
                windowTitle = ScreenControl.string(window, kAXTitleAttribute)
                if let f = ScreenControl.frame(window), f.width > 0, f.height > 0 {
                    relX = (p.x - f.minX) / f.width
                    relY = (p.y - f.minY) / f.height
                }
            }
        }
        // Long text in a label is page content, not a button name.
        if label.count > 60 { label = String(label.prefix(60)) }
        let target = ClickTarget(appBundleID: appID, appName: appName, role: role, label: label, identifier: identifier,
                                 windowTitle: windowTitle, relX: relX, relY: relY, x: p.x, y: p.y,
                                 clickCount: e.clickCount, rightClick: e.type == .rightMouseDown,
                                 flags: UInt64(e.modifierFlags.intersection([.command, .shift, .option, .control]).rawValue))
        // A double-click arrives as two clicks: keep one.
        if e.clickCount > 1, var last = steps.last, last.kind == .click, last.target?.x == target.x, last.target?.y == target.y {
            last.target?.clickCount = e.clickCount
            steps[steps.count - 1] = last
            return
        }
        append(RoutineStep(kind: .click, target: target))
    }

    private func recordKey(_ e: NSEvent) {
        // Password fields: macOS hides those keys from other apps anyway; never keep them.
        if IsSecureEventInputEnabled() || focusedRole() == "AXSecureTextField" {
            if steps.last?.kind != .waitForUser {
                append(RoutineStep(kind: .waitForUser, text: "Type your password, then tap fn"))
            }
            return
        }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        let name = Self.keyName(Int(e.keyCode))
        if !mods.isEmpty || Self.specialKeys.contains(name ?? "") {
            // Backspace while typing just edits what was typed.
            if name == "delete", mods.isEmpty, let i = steps.indices.last, steps[i].kind == .type {
                var t = steps[i].text ?? ""
                if !t.isEmpty { t.removeLast() }
                if t.isEmpty { steps.removeLast(); onChange(steps.count) } else { steps[i].text = t }
                return
            }
            guard let name else { return }
            var combo: [String] = []
            if e.modifierFlags.contains(.command) { combo.append("cmd") }
            if e.modifierFlags.contains(.control) { combo.append("ctrl") }
            if e.modifierFlags.contains(.option) { combo.append("alt") }
            if e.modifierFlags.contains(.shift) { combo.append("shift") }
            combo.append(name)
            // Return right after typing in an address bar → wait for the page to replace both.
            if name == "return", mods.isEmpty, let last = steps.last, last.kind == .type, focusedIsAddressBar() {
                pendingAddressStep = steps.count - 1
            }
            append(RoutineStep(kind: .key, keys: combo.joined(separator: "+")))
            return
        }
        guard let chars = e.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
        if var last = steps.last, last.kind == .type, Date().timeIntervalSince(lastEventAt) < 8 {
            last.text = (last.text ?? "") + chars
            steps[steps.count - 1] = last
            lastEventAt = Date()
        } else {
            let role = focusedRole() ?? ""
            let isSearch = role == "AXSearchField" || (focusedLabel()?.lowercased().contains("search") ?? false)
            append(RoutineStep(kind: .type, text: chars, isInput: isSearch ? true : nil))
        }
    }

    private func recordScroll(_ e: NSEvent) {
        let dy = Double(e.scrollingDeltaY), dx = Double(e.scrollingDeltaX)
        guard abs(dy) + abs(dx) > 0.5 else { return }
        if var last = steps.last, last.kind == .scroll, Date().timeIntervalSince(lastEventAt) < 1.5 {
            last.scrollY = (last.scrollY ?? 0) + dy
            last.scrollX = (last.scrollX ?? 0) + dx
            steps[steps.count - 1] = last
            lastEventAt = Date()
            return
        }
        let loc = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        var s = RoutineStep(kind: .scroll, scrollY: dy, scrollX: dx)
        s.target = ClickTarget(role: "", label: "", x: loc.x, y: h - loc.y)
        append(s)
    }

    private func focused() -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &v) == .success, let v else { return nil }
        return (v as! AXUIElement)
    }
    private func focusedRole() -> String? { focused().flatMap { ScreenControl.string($0, kAXRoleAttribute) } }
    private func focusedLabel() -> String? { focused().map { ScreenControl.label($0) } }
    private func focusedIsAddressBar() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.browsers[front] != nil else { return false }
        let label = (focusedLabel() ?? "").lowercased()
        let desc = focused().flatMap { ScreenControl.string($0, kAXDescriptionAttribute) }?.lowercased() ?? ""
        return [label, desc].contains { $0.contains("address") || $0.contains("smart search") || $0.contains("url") || $0.contains("search or enter") }
    }

    // MARK: Tidy up

    static let specialKeys: Set<String> = ["return", "tab", "esc", "delete", "forwarddelete", "up", "down", "left", "right", "pageup", "pagedown", "home", "end", "space"]

    static func keyName(_ code: Int) -> String? {
        let names = BuddyTools.keyCodes.filter { $0.value == code }.map(\.key)
        // "return" not "enter", "esc" not "escape", "delete" not "backspace".
        return names.first { specialKeys.contains($0) } ?? names.sorted { ($0.count, $0) < ($1.count, $1) }.first
    }

    static func cleanUp(_ raw: [RoutineStep]) -> [RoutineStep] {
        var out: [RoutineStep] = []
        for s in raw {
            // Repeated "open the same app" in a row.
            if s.kind == .openApp, let last = out.last, last.kind == .openApp {
                out[out.count - 1] = s
                continue
            }
            // Switching to an app and straight back.
            if s.kind == .type, (s.text ?? "").isEmpty { continue }
            out.append(s)
        }
        // A trailing app switch is just you coming back to Blob.
        while let last = out.last, last.kind == .openApp, out.count > 1 { out.removeLast() }
        return out
    }
}

// MARK: - Doing it again

@MainActor
final class RoutinePlayer {
    var onStatus: (String) -> Void = { _ in }
    /// Pauses until you tap fn (for passwords and such).
    var waitForUser: (String) async -> Void = { _ in }

    struct Result { var done: Int; var missed: [String] }

    func run(_ routine: Routine, input: String?) async -> Result {
        var missed: [String] = []
        var done = 0
        var currentApp: NSRunningApplication?
        let inputStep = routine.steps.firstIndex { $0.kind == .type && $0.isInput == true }
            ?? (input != nil ? routine.steps.firstIndex { $0.kind == .type } : nil)

        for (i, step) in routine.steps.enumerated() {
            if Task.isCancelled { break }
            // Faster than you did it, but give apps and pages time to react.
            let pause = min(max(step.delay * 0.6, 0.35), 2.5)
            try? await Task.sleep(for: .seconds(pause))
            onStatus("Step \(i + 1) of \(routine.steps.count): \(step.summary)")
            switch step.kind {
            case .openApp:
                if let app = await openApp(step.appBundleID) { currentApp = app; done += 1 } else { missed.append(step.summary) }
            case .openURL:
                guard let s = step.url, let url = URL(string: s) else { continue }
                if let id = step.appBundleID, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    _ = try? await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
                } else {
                    NSWorkspace.shared.open(url)
                }
                try? await Task.sleep(for: .seconds(2.0))       // let the page load
                done += 1
            case .click:
                guard let t = step.target else { continue }
                if await click(t, in: currentApp) { done += 1 } else { missed.append(step.summary) }
            case .type:
                let text = (i == inputStep ? input : nil) ?? step.text ?? ""
                await Keys.type(text)
                done += 1
            case .key:
                if let k = step.keys, let (code, flags) = Keys.parse(k) { Keys.press(code, flags: flags); done += 1 }
            case .scroll:
                let p = CGPoint(x: step.target?.x ?? 400, y: step.target?.y ?? 400)
                Mouse.move(to: p)
                let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                wheel1: Int32((step.scrollY ?? 0) * 8), wheel2: Int32((step.scrollX ?? 0) * 8), wheel3: 0)
                e?.post(tap: .cghidEventTap)
                done += 1
            case .waitForUser:
                await waitForUser(step.text ?? "Your turn — tap fn when you're done")
                done += 1
            }
        }
        return Result(done: done, missed: missed)
    }

    private func openApp(_ bundleID: String?) async -> NSRunningApplication? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<25 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID {
            app?.activate()
            try? await Task.sleep(for: .milliseconds(200))
        }
        return app
    }

    /// Finds the same button/link/field by name (waiting a few seconds for pages to load); falls back to the same spot in the window.
    private func click(_ t: ClickTarget, in current: NSRunningApplication?) async -> Bool {
        let app = t.appBundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first } ?? current
        if let app, NSWorkspace.shared.frontmostApplication != app { app.activate(); try? await Task.sleep(for: .milliseconds(300)) }
        var element: AXUIElement?
        if let app, !t.label.isEmpty || t.identifier != nil {
            for attempt in 0..<8 {
                element = find(t, in: app)
                if element != nil { break }
                try? await Task.sleep(for: .milliseconds(attempt < 3 ? 400 : 700))
            }
        }
        let flags = CGEventFlags(rawValue: t.flags)
        if let el = element, let frame = ScreenControl.frame(el), frame.width > 0 {
            let role = ScreenControl.string(el, kAXRoleAttribute) ?? ""
            if t.clickCount == 1, !t.rightClick, flags.isEmpty,
               !role.contains("Text"), !role.contains("Search"),
               AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
                return true
            }
            Mouse.click(at: CGPoint(x: frame.midX, y: frame.midY), button: t.rightClick ? .right : .left, count: t.clickCount, flags: flags)
            return true
        }
        // Same place in the window as last time.
        if let app, let rx = t.relX, let ry = t.relY, let win = Self.frontWindow(app), let f = ScreenControl.frame(win) {
            Mouse.click(at: CGPoint(x: f.minX + rx * f.width, y: f.minY + ry * f.height), button: t.rightClick ? .right : .left, count: t.clickCount, flags: flags)
            return t.label.isEmpty     // a nameless spot is fine; a named button we couldn't find counts as a miss
        }
        Mouse.click(at: CGPoint(x: t.x, y: t.y), button: t.rightClick ? .right : .left, count: t.clickCount, flags: flags)
        return t.label.isEmpty
    }

    static func frontWindow(_ app: NSRunningApplication) -> AXUIElement? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &v)
        return v.map { $0 as! AXUIElement }
    }

    private func find(_ t: ClickTarget, in app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        guard let window = Self.frontWindow(app) else { return nil }
        let wf = ScreenControl.frame(window)
        let want = t.label.lowercased()
        var best: (AXUIElement, Double)?
        var visited = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 45, visited < 8000 else { return }
            visited += 1
            let role = ScreenControl.string(el, kAXRoleAttribute) ?? ""
            var score = 0.0
            if let id = t.identifier, !id.isEmpty, ScreenControl.string(el, "AXIdentifier") == id { score = 3 }
            else if !want.isEmpty {
                let l = ScreenControl.label(el).lowercased()
                if l == want { score = 2 } else if l.count >= 3, l.hasPrefix(want) || want.hasPrefix(l) { score = 1 }
            }
            if score > 0 {
                if role == t.role { score += 1 }
                // Nearest to where it was last time breaks ties (e.g. several "Open" buttons).
                if let wf, let f = ScreenControl.frame(el), let rx = t.relX, let ry = t.relY, wf.width > 0, wf.height > 0 {
                    let dx = (f.midX - wf.minX) / wf.width - rx, dy = (f.midY - wf.minY) / wf.height - ry
                    score -= min(0.9, (dx * dx + dy * dy).squareRoot())
                }
                if score > (best?.1 ?? 0) { best = (el, score) }
            }
            for c in ScreenControl.children(el) { walk(c, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return best?.0
    }
}

// MARK: - Self-test (launch flag -trainingSelfTest <log>)

@MainActor
enum TrainingSelfTest {
    static func run(log path: String) async {
        var lines: [String] = []
        func note(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        note("accessibility: \(AXIsProcessTrusted())")
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty
        func textEdit(_ script: String) -> String { BuddyTools.appleScript("tell application \"TextEdit\"\n\(script)\nend tell").output }
        _ = textEdit("activate\nmake new document")
        try? await Task.sleep(for: .seconds(1.5))

        // 1. Watch: click in the document, type, press return, type more.
        let recorder = TrainingRecorder()
        recorder.start()
        try? await Task.sleep(for: .milliseconds(400))
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first,
           let win = RoutinePlayer.frontWindow(app), let f = ScreenControl.frame(win) {
            Mouse.click(at: CGPoint(x: f.midX, y: f.midY))
        }
        try? await Task.sleep(for: .milliseconds(400))
        await Keys.type("Blob training test")
        try? await Task.sleep(for: .milliseconds(300))
        if let (k, fl) = Keys.parse("return") { Keys.press(k, flags: fl) }
        try? await Task.sleep(for: .milliseconds(300))
        await Keys.type("second line")
        try? await Task.sleep(for: .milliseconds(600))
        let steps = recorder.stop()
        note("recorded \(steps.count) steps:")
        steps.forEach { note("  - \($0.summary)") }
        let typed1 = textEdit("return text of front document")
        note("typed while watching: \(typed1.debugDescription)")
        _ = textEdit("close front document saving no")

        // 2. Repeat it into a fresh document.
        _ = textEdit("make new document")
        try? await Task.sleep(for: .seconds(1))
        let player = RoutinePlayer()
        let result = await player.run(Routine(name: "self test", steps: steps), input: nil)
        try? await Task.sleep(for: .milliseconds(500))
        let typed2 = textEdit("return text of front document")
        note("replayed: done \(result.done), missed \(result.missed)")
        note("text after replay: \(typed2.debugDescription)")
        _ = textEdit("close front document saving no")
        if !wasRunning { _ = textEdit("quit saving no") }

        note(typed1.lowercased() == typed2.lowercased() && typed2.lowercased().contains("second line") ? "PASS" : "FAIL")
    }
}
