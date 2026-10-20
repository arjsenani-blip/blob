import AppKit
import ApplicationServices
import ScreenCaptureKit

// MARK: - On-device screen control (Accessibility) — free, offline, no AI vision needed

/// Reads and operates the buttons, links, fields and menus of whatever app is in front,
/// through macOS Accessibility. Works with Safari, Chrome, Finder, Music, Spotify, etc.
@MainActor
final class ScreenControl {
    private var lastElements: [AXUIElement] = []
    var targetApp: () -> NSRunningApplication? = { nil }

    private static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox", "AXTab", "AXCell", "AXRow", "AXDisclosureTriangle", "AXSlider",
    ]

    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func requestPermission() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    private func frontApp() -> NSRunningApplication? {
        if let t = targetApp(), !t.isTerminated { return t }
        return NSWorkspace.shared.frontmostApplication
    }

    /// Numbered list of what can be clicked or typed into in the front window.
    func listElements(filter: String?) -> ToolOutput {
        guard Self.requestPermission() else { return .error(Self.permissionMessage) }
        guard let app = frontApp() else { return .error("No app is in front.") }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium-based browsers only expose web content when asked.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        var root: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &root)
        let start = (root as! AXUIElement?) ?? axApp

        var found: [(AXUIElement, String)] = []
        var visited = 0
        let needle = filter?.lowercased()
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 40, visited < 6000, found.count < 150 else { return }
            visited += 1
            let role = Self.string(el, kAXRoleAttribute) ?? ""
            if Self.actionableRoles.contains(role) {
                let label = Self.label(el)
                if !label.isEmpty || role.contains("Text") || role.contains("Search") {
                    let line = "\(Self.roleName(role)) \"\(label.isEmpty ? "(empty)" : label)\""
                    if needle == nil || line.lowercased().contains(needle!) { found.append((el, line)) }
                }
            }
            for child in Self.children(el) { walk(child, depth: depth + 1) }
        }
        walk(start, depth: 0)
        lastElements = found.map(\.0)
        guard !found.isEmpty else {
            return ToolOutput(text: "No clickable items found in \(app.localizedName ?? "the front app")\(filter.map { " matching \"\($0)\"" } ?? "").")
        }
        let window = Self.string(start, kAXTitleAttribute) ?? ""
        return ToolOutput(text: "\(app.localizedName ?? "App") — \(window)\n" +
                          found.enumerated().map { "[\($0.offset + 1)] \($0.element.1)" }.joined(separator: "\n"))
    }

    /// Press an element by its number from the last list, or by (part of) its label.
    func click(_ target: String) -> ToolOutput {
        guard Self.requestPermission() else { return .error(Self.permissionMessage) }
        var element: AXUIElement?
        if let n = Int(target.trimmingCharacters(in: CharacterSet(charactersIn: "[]# "))), n >= 1, n <= lastElements.count {
            element = lastElements[n - 1]
        } else {
            _ = listElements(filter: target)
            let t = target.lowercased()
            element = lastElements.first { Self.label($0).lowercased() == t } ?? lastElements.first
        }
        guard let el = element else { return .error("Couldn't find \"\(target)\" on screen. Try list_ui_elements first.") }
        frontApp()?.activate()
        let label = Self.label(el)
        let role = Self.string(el, kAXRoleAttribute) ?? ""
        if role.contains("Text") || role.contains("Search") || role == "AXComboBox" {
            AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return ToolOutput(text: "Focused the \(label.isEmpty ? "text field" : label) field — now use type_text.")
        }
        if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
            return ToolOutput(text: "Clicked \"\(label)\".")
        }
        // Fall back to a real mouse click at the element's center.
        if let frame = Self.frame(el) {
            Mouse.click(at: CGPoint(x: frame.midX, y: frame.midY))
            return ToolOutput(text: "Clicked \"\(label)\".")
        }
        return .error("\"\(label)\" can't be clicked.")
    }

    /// e.g. "File > New Window", "History > Show All History".
    func chooseMenu(_ path: String) -> ToolOutput {
        guard Self.requestPermission() else { return .error(Self.permissionMessage) }
        guard let app = frontApp() else { return .error("No app is in front.") }
        let parts = path.split(whereSeparator: { $0 == ">" || $0 == "→" }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !parts.isEmpty else { return .error("Give a menu path like File > New Tab.") }
        var menuBar: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute as CFString, &menuBar)
        guard var current = menuBar as! AXUIElement? else { return .error("That app has no menu bar.") }
        for (i, name) in parts.enumerated() {
            var items = Self.children(current)
            if let menu = items.first, Self.string(menu, kAXRoleAttribute) == "AXMenu" { items = Self.children(menu) }
            guard let match = items.first(where: { Self.label($0).lowercased() == name })
                    ?? items.first(where: { Self.label($0).lowercased().hasPrefix(name) }) else {
                let options = items.map(Self.label).filter { !$0.isEmpty }.prefix(30).joined(separator: ", ")
                return .error("No menu item \"\(name)\". Options: \(options)")
            }
            if i == parts.count - 1 {
                app.activate()
                AXUIElementPerformAction(match, kAXPressAction as CFString)
                return ToolOutput(text: "Chose \(path).")
            }
            current = match
        }
        return .error("Menu path not found.")
    }

    static let permissionMessage = "I need Accessibility permission to control apps, sir. Turn on Blob in System Settings → Privacy & Security → Accessibility."

    // MARK: AX helpers

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    static func label(_ el: AXUIElement) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, "AXPlaceholderValue"] {
            if let s = string(el, attr)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return String(s.prefix(80)) }
        }
        // Many web links keep their text in a child.
        for child in children(el).prefix(3) {
            if let s = string(child, kAXValueAttribute) ?? string(child, kAXTitleAttribute), !s.isEmpty { return String(s.prefix(80)) }
        }
        return ""
    }

    static func roleName(_ role: String) -> String {
        role.replacingOccurrences(of: "AX", with: "").lowercased()
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var posV: CFTypeRef?, sizeV: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV)
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV)
        guard let posV, let sizeV else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
}

// MARK: - Mouse & keyboard primitives (global screen points, top-left origin)

enum Mouse {
    static func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton = .left, clicks: Int = 1, flags: CGEventFlags = []) {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }

    static func move(to p: CGPoint) { post(.mouseMoved, at: p) }

    static func click(at p: CGPoint, button: CGMouseButton = .left, count: Int = 1, flags: CGEventFlags = []) {
        let (down, up): (CGEventType, CGEventType) = switch button {
        case .right: (.rightMouseDown, .rightMouseUp)
        case .center: (.otherMouseDown, .otherMouseUp)
        default: (.leftMouseDown, .leftMouseUp)
        }
        move(to: p)
        usleep(20_000)
        for i in 1...max(1, count) {
            post(down, at: p, button: button, clicks: i, flags: flags)
            usleep(15_000)
            post(up, at: p, button: button, clicks: i, flags: flags)
            usleep(40_000)
        }
    }

    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }
}

enum Keys {
    static func flags(_ names: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for n in names {
            switch n.lowercased() {
            case "cmd", "command", "super", "meta", "win", "⌘": f.insert(.maskCommand)
            case "ctrl", "control", "⌃": f.insert(.maskControl)
            case "alt", "option", "opt", "⌥": f.insert(.maskAlternate)
            case "shift", "⇧": f.insert(.maskShift)
            case "fn": f.insert(.maskSecondaryFn)
            default: break
            }
        }
        return f
    }

    static let modifierNames: Set<String> = ["cmd", "command", "super", "meta", "win", "ctrl", "control", "alt", "option", "opt", "shift", "fn", "⌘", "⌃", "⌥", "⇧"]

    /// Parses "cmd+shift+t", "Return", "ctrl+s", "alt+Tab", "Page_Down".
    static func parse(_ combo: String) -> (key: Int, flags: CGEventFlags)? {
        let parts = combo.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        let mods = parts.filter { modifierNames.contains($0.lowercased()) }
        guard let keyName = parts.last(where: { !modifierNames.contains($0.lowercased()) }) else { return nil }
        let normalized = keyName.lowercased().replacingOccurrences(of: "_", with: "")
        let aliases = ["kpenter": "return", "escape": "esc", "bs": "backspace", "del": "forwarddelete", "pgup": "pageup", "pgdn": "pagedown",
                       "arrowup": "up", "arrowdown": "down", "arrowleft": "left", "arrowright": "right", "spacebar": "space", "plus": "=", "minus": "-"]
        guard let code = BuddyTools.keyCodes[aliases[normalized] ?? normalized] else { return nil }
        return (code, flags(mods))
    }

    static func press(_ key: Int, flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    static func type(_ text: String) async {
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
    }
}

// MARK: - Web & media shortcuts (free; need internet only for the site itself)

enum WebMedia {
    /// Finds the top YouTube result and opens it playing. No API key or account needed.
    static func playYouTube(_ query: String) async -> ToolOutput {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let results = URL(string: "https://www.youtube.com/results?search_query=\(q)")!
        var req = URLRequest(url: results, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let (data, _) = try? await URLSession.shared.data(for: req), let html = String(data: data, encoding: .utf8),
           let r = html.range(of: #""videoId":"([A-Za-z0-9_-]{11})""#, options: .regularExpression) {
            let id = html[r].dropFirst(11).prefix(11)
            var title = ""
            if let tr = html.range(of: #""title":\{"runs":\[\{"text":"([^"]{1,120})""#, options: .regularExpression, range: r.lowerBound..<html.endIndex) {
                title = String(html[tr]).components(separatedBy: "\"text\":\"").last?.replacingOccurrences(of: "\"", with: "") ?? ""
            }
            NSWorkspace.shared.open(URL(string: "https://www.youtube.com/watch?v=\(id)")!)
            return ToolOutput(text: "Playing on YouTube: \(title.isEmpty ? query : title)")
        }
        NSWorkspace.shared.open(results)
        return ToolOutput(text: "Opened YouTube results for \(query).")
    }

    static func searchWeb(_ query: String, site: String?) -> ToolOutput {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let s = (site ?? "google").lowercased()
        let url: String
        switch s {
        case "youtube": url = "https://www.youtube.com/results?search_query=\(q)"
        case "amazon": url = "https://www.amazon.com/s?k=\(q)"
        case "wikipedia": url = "https://en.wikipedia.org/wiki/Special:Search?search=\(q)"
        case "maps", "google maps", "apple maps": url = "https://maps.apple.com/?q=\(q)"
        case "images": url = "https://www.google.com/search?tbm=isch&q=\(q)"
        case "reddit": url = "https://www.reddit.com/search/?q=\(q)"
        default: url = "https://www.google.com/search?q=\(q)"
        }
        NSWorkspace.shared.open(URL(string: url)!)
        return ToolOutput(text: "Searched \(s == "google" ? "the web" : s) for \(query).")
    }

    static let sites: [String: String] = [
        "youtube": "https://www.youtube.com", "gmail": "https://mail.google.com", "google classroom": "https://classroom.google.com",
        "classroom": "https://classroom.google.com", "google docs": "https://docs.google.com", "google drive": "https://drive.google.com",
        "netflix": "https://www.netflix.com", "twitter": "https://x.com", "x": "https://x.com", "instagram": "https://www.instagram.com",
        "reddit": "https://www.reddit.com", "amazon": "https://www.amazon.com", "chatgpt": "https://chatgpt.com", "claude": "https://claude.ai",
        "github": "https://github.com", "canvas": "https://canvas.instructure.com", "quizlet": "https://quizlet.com", "khan academy": "https://www.khanacademy.org",
        "google": "https://www.google.com", "wikipedia": "https://www.wikipedia.org", "twitch": "https://www.twitch.tv", "espn": "https://www.espn.com",
        "youtube music": "https://music.youtube.com", "google calendar": "https://calendar.google.com", "desmos": "https://www.desmos.com/calculator",
    ]

    /// Plays music: your Apple Music library first (offline), then Spotify, then YouTube.
    @MainActor
    static func playMusic(_ query: String, app: String?, screen: ScreenControl) async -> ToolOutput {
        let q = query.replacingOccurrences(of: "\"", with: "")
        let wanted = app?.lowercased()
        if wanted == nil || wanted == "music" || wanted == "apple music" {
            let script = """
            tell application "Music"
                set results to (every track of library playlist 1 whose name contains "\(q)" or artist contains "\(q)" or album contains "\(q)")
                if (count of results) > 0 then
                    play item 1 of results
                    return (name of current track) & " by " & (artist of current track)
                end if
                return ""
            end tell
            """
            let r = BuddyTools.appleScript(script)
            if r.error == nil, !r.output.isEmpty { return ToolOutput(text: "Playing \(r.output) in Music.") }
            if wanted != nil { return .error("\"\(query)\" isn't in your Music library.") }
        }
        let hasSpotify = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
        if wanted == "spotify" || (wanted == nil && hasSpotify) {
            guard hasSpotify else { return .error("Spotify isn't installed.") }
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q
            NSWorkspace.shared.open(URL(string: "spotify:search:\(encoded)")!)
            try? await Task.sleep(for: .seconds(3))
            if ScreenControl.hasPermission,
               let spotify = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first {
                screen.targetApp = { spotify }
                let list = screen.listElements(filter: "play")
                if !list.isError, list.text.contains("[1]") {
                    _ = screen.click("1")
                    return ToolOutput(text: "Playing \(query) on Spotify.")
                }
            }
            return ToolOutput(text: "Searched Spotify for \(query) — tap play on the top result.")
        }
        return await playYouTube(query + " audio")
    }
}

// MARK: - Claude computer-use toolset (only used with the optional paid Claude API brain)

@MainActor
final class ComputerUse {
    private var scale: CGFloat = 1     // screenshot pixels per screen point
    private var origin: CGPoint = .zero

    func screenshot() async -> ToolOutput {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return .error("Error: Screen Recording permission is off.")
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
                return .error("Error: no display.")
            }
            let bounds = CGDisplayBounds(display.displayID)
            origin = bounds.origin
            let maxW: CGFloat = 1456
            scale = min(1, maxW / bounds.width)
            let mine = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            let config = SCStreamConfiguration()
            config.width = Int(bounds.width * scale)
            config.height = Int(bounds.height * scale)
            config.showsCursor = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: mine), configuration: config)
            guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
                return .error("Error: couldn't encode screenshot.")
            }
            return ToolOutput(text: "", imageJPEGBase64: jpeg.base64EncodedString())
        } catch {
            return .error("Error: Failed to capture screenshot. \(error.localizedDescription)")
        }
    }

    private func point(_ v: Any?) -> CGPoint? {
        guard let a = v as? [NSNumber], a.count == 2 else { return nil }
        return CGPoint(x: origin.x + CGFloat(a[0].doubleValue) / scale, y: origin.y + CGFloat(a[1].doubleValue) / scale)
    }

    func run(_ name: String, _ input: [String: Any]) async -> ToolOutput {
        if name != "screenshot", name != "zoom", name != "wait", name != "cursor_position", !ScreenControl.hasPermission {
            _ = ScreenControl.requestPermission()
            return .error("Error: Accessibility permission is off, so I can't use the mouse or keyboard.")
        }
        let mods = Keys.flags(((input["text"] as? String) ?? "").split(separator: "+").map(String.init))
        switch name {
        case "screenshot":
            return await screenshot()
        case "zoom":
            guard let r = input["region"] as? [NSNumber], r.count == 4 else { return .error("Error: region needs 4 numbers.") }
            let rect = CGRect(x: CGFloat(r[0].doubleValue) / scale, y: CGFloat(r[1].doubleValue) / scale,
                              width: CGFloat(r[2].doubleValue - r[0].doubleValue) / scale, height: CGFloat(r[3].doubleValue - r[1].doubleValue) / scale)
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { return .error("Error: no display.") }
                let config = SCStreamConfiguration()
                config.sourceRect = rect
                let up = min(4, 1200 / max(rect.width, rect.height))
                config.width = Int(rect.width * up)
                config.height = Int(rect.height * up)
                let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
                let jpeg = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
                return ToolOutput(text: "", imageJPEGBase64: jpeg.base64EncodedString())
            } catch { return .error("Error: zoom failed.") }
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let p = point(input["coordinate"]) ?? Mouse.location
            let button: CGMouseButton = name == "right_click" ? .right : name == "middle_click" ? .center : .left
            let count = name == "double_click" ? 2 : name == "triple_click" ? 3 : 1
            Mouse.click(at: p, button: button, count: count, flags: mods)
            return ToolOutput(text: "OK")
        case "left_click_drag":
            guard let a = point(input["start_coordinate"]), let b = point(input["coordinate"]) else { return .error("Error: need start_coordinate and coordinate.") }
            Mouse.move(to: a)
            Mouse.post(.leftMouseDown, at: a, flags: mods)
            for i in 1...12 {
                let t = CGFloat(i) / 12
                Mouse.post(.leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: mods)
                try? await Task.sleep(for: .milliseconds(15))
            }
            Mouse.post(.leftMouseUp, at: b, flags: mods)
            return ToolOutput(text: "OK")
        case "mouse_move":
            guard let p = point(input["coordinate"]) else { return .error("Error: need coordinate.") }
            Mouse.move(to: p)
            return ToolOutput(text: "OK")
        case "left_mouse_down":
            Mouse.post(.leftMouseDown, at: Mouse.location)
            return ToolOutput(text: "OK")
        case "left_mouse_up":
            Mouse.post(.leftMouseUp, at: Mouse.location)
            return ToolOutput(text: "OK")
        case "cursor_position":
            let l = Mouse.location
            return ToolOutput(text: "X=\(Int((l.x - origin.x) * scale)), Y=\(Int((l.y - origin.y) * scale))")
        case "scroll":
            if let p = point(input["coordinate"]) { Mouse.move(to: p) }
            let amount = Int32((input["scroll_amount"] as? NSNumber)?.intValue ?? 3) * 3
            let dir = input["scroll_direction"] as? String ?? "down"
            let dy: Int32 = dir == "up" ? amount : dir == "down" ? -amount : 0
            let dx: Int32 = dir == "left" ? amount : dir == "right" ? -amount : 0
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
            e?.flags = mods
            e?.post(tap: .cghidEventTap)
            return ToolOutput(text: "OK")
        case "type":
            await Keys.type(input["text"] as? String ?? "")
            return ToolOutput(text: "OK")
        case "key":
            guard let (key, flags) = Keys.parse(input["text"] as? String ?? "") else { return .error("Error: unknown key \(input["text"] ?? "").") }
            for _ in 0..<max(1, min(100, (input["repeat"] as? NSNumber)?.intValue ?? 1)) { Keys.press(key, flags: flags) }
            return ToolOutput(text: "OK")
        case "hold_key":
            guard let (key, flags) = Keys.parse(input["text"] as? String ?? "") else { return .error("Error: unknown key.") }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true)
            down?.flags = flags
            down?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .seconds(min(30, (input["duration"] as? NSNumber)?.doubleValue ?? 1)))
            let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: false)
            up?.post(tap: .cghidEventTap)
            return ToolOutput(text: "OK")
        case "wait":
            try? await Task.sleep(for: .seconds(min(30, (input["duration"] as? NSNumber)?.doubleValue ?? 1)))
            return ToolOutput(text: "OK")
        default:
            return .error("Error: unsupported action \(name).")
        }
    }
}
