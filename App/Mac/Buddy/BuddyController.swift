import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine
import IOKit.ps

/// Blob's state machine: resting in the corner → listening → thinking → speaking → back to resting.
@MainActor
final class BuddyController: ObservableObject {
    static let shared = BuddyController()

    enum Phase: Equatable { case resting, awake, listening, thinking, speaking, confirming }

    @Published private(set) var phase: Phase = .resting
    @Published private(set) var heard = ""
    @Published private(set) var reply = ""
    @Published private(set) var status = ""
    @Published private(set) var confirmPrompt: String?
    @Published private(set) var showBubble = false
    @Published private(set) var isError = false
    @Published var hovering = false
    /// Idle for a while → Blob dozes off (eyes closed), a clear sign it isn't listening.
    @Published private(set) var sleeping = false
    /// Brief happy face after finishing something.
    @Published private(set) var celebrating = false
    private var lastActive = Date()
    private var sleepTimer: Timer?
    @Published var typed = ""
    /// True when the bubble's text box is asking for a change to Blob itself.
    @Published var updateMode = false
    /// Where the mouse is relative to Blob's eyes (-1…1), so it can look at your cursor.
    @Published var look = CGPoint.zero
    /// Bubble frame in panel coordinates (top-left origin), for click-through hit testing.
    var bubbleFrame: CGRect = .zero

    let speechIn = SpeechInput()
    private let fnKey = FnKeyMonitor()
    /// False while Blob's panel is covered or the display is asleep — the animation pauses then.
    @Published private(set) var panelVisible = true
    private var onBattery = PowerSource.onBattery
    let speechOut = SpeechOutput()
    private(set) var tools: BuddyTools?
    private var brain: BuddyBrain?
    private var panel: BuddyPanel?
    private var hotKey: HotKey?
    private var work: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var confirmation: CheckedContinuation<Bool, Never>?
    private var mouseMonitors: [Any] = []
    private var permissionsChecked = false
    private var bag = Set<AnyCancellable>()

    static let panelSize = CGSize(width: 420, height: 520)
    static let blobArea = CGSize(width: 170, height: 170)

    var brainDescription: String { brain?.activeDescription ?? "—" }

    // MARK: Setup

    func start(store: BrainStore) {
        guard tools == nil else { return }
        let tools = BuddyTools(store: store)
        tools.confirm = { [weak self] prompt in await self?.askPermission(prompt) ?? false }
        tools.onStatus = { [weak self] s in self?.status = s }
        tools.announce = { [weak self] s in self?.say(s) }
        tools.requestUpdate = { [weak self] r in await self?.requestSelfUpdate(r) ?? "" }
        tools.undoUpdate = { [weak self] in await self?.undoLastUpdate() ?? "" }
        self.tools = tools
        brain = BuddyBrain(tools: tools)

        speechIn.onFinished = { [weak self] text in self?.heardFinished(text) }
        speechOut.onFinished = { [weak self] in self?.doneSpeaking() }
        // Forward voice levels so the blob view redraws.
        speechIn.objectWillChange.merge(with: speechOut.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BuddyController.shared.panel?.moveToCorner() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BuddyController.shared.applySettings() }
        }
        fnKey.onTap = { [weak self] in self?.activate() }
        ChatterboxServer.shared.startIfNeeded()   // warms up the natural voice (only when plugged in)
        applySettings()
        if let note = UserDefaults.standard.string(forKey: "blobUpdateNote") {
            UserDefaults.standard.removeObject(forKey: "blobUpdateNote")
            Task {
                try? await Task.sleep(for: .seconds(2))
                say(note)
            }
        }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let b = BuddyController.shared
                if b.phase == .resting, !b.hovering, !b.sleeping, Date().timeIntervalSince(b.lastActive) > 90 {
                    b.sleeping = true
                }
                // Plugged in ↔ battery: load or unload the heavy natural voice.
                let battery = PowerSource.onBattery
                if battery != b.onBattery {
                    b.onBattery = battery
                    if VoiceEngine.effective == .chatterbox { ChatterboxServer.shared.startIfNeeded() } else { ChatterboxServer.shared.stop() }
                }
            }
        }
    }

    private func wakeUp() {
        lastActive = Date()
        if sleeping { sleeping = false }
    }

    private func celebrate() {
        celebrating = true
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            celebrating = false
        }
    }

    var isEnabled: Bool { UserDefaults.standard.object(forKey: "buddyEnabled") as? Bool ?? true }

    private var appliedShortcut: String?
    private func applySettings() {
        if isEnabled {
            if panel == nil { makePanel() }
            let shortcut = BuddyShortcut.current
            if appliedShortcut != shortcut.rawValue {
                hotKey = nil
                if shortcut == .fnKey {
                    fnKey.start()
                } else {
                    fnKey.stop()
                    hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers) { [weak self] in self?.activate() }
                }
                appliedShortcut = shortcut.rawValue
            }
        } else {
            fnKey.stop()
            cancel()
            panel?.orderOut(nil)
            panel = nil
            hotKey = nil
            appliedShortcut = nil
            mouseMonitors.forEach(NSEvent.removeMonitor)
            mouseMonitors = []
        }
    }

    private func makePanel() {
        let p = BuddyPanel(size: Self.panelSize)
        let host = NSHostingView(rootView: BuddyOverlay().environmentObject(self))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        p.contentView = host
        p.moveToCorner()
        p.orderFrontRegardless()
        panel = p
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated {
                let visible = BuddyController.shared.panel?.occlusionState.contains(.visible) ?? false
                if BuddyController.shared.panelVisible != visible { BuddyController.shared.panelVisible = visible }
            }
        }

        let handler: (NSEvent) -> Void = { _ in MainActor.assumeIsolated { BuddyController.shared.mouseMoved() } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in handler(e); return e }) { mouseMonitors.append(l) }
        mouseMoved()
    }

    /// Hover detection, eye tracking, and click-through for everything that isn't Blob or its bubble.
    private func mouseMoved() {
        guard let panel else { return }
        let m = NSEvent.mouseLocation
        let local = CGPoint(x: m.x - panel.frame.minX, y: panel.frame.maxY - m.y)
        let blobCenter = CGPoint(x: Self.panelSize.width - Self.blobArea.width / 2 + (phase == .resting ? 52 : 0),
                                 y: Self.panelSize.height - Self.blobArea.height / 2 + (phase == .resting ? 50 : 0))
        let dx = local.x - blobCenter.x, dy = local.y - blobCenter.y
        let dist = hypot(dx, dy)
        let overBlob = dist < 62
        let overBubble = showBubble && bubbleFrame.insetBy(dx: -6, dy: -6).contains(local)
        panel.ignoresMouseEvents = !(overBlob || overBubble)
        if hovering != overBlob { withAnimation(.spring(duration: 0.35)) { hovering = overBlob } }
        if overBlob { wakeUp() }
        // Eyes only follow the cursor while Blob is out of its corner — and only redraw for visible changes.
        guard phase != .resting || hovering else { return }
        let reach = max(dist, 1)
        let next = CGPoint(x: dx / reach * min(1, dist / 300), y: dy / reach * min(1, dist / 300))
        if abs(next.x - look.x) > 0.04 || abs(next.y - look.y) > 0.04 { look = next }
    }

    // MARK: Interaction

    /// Keyboard shortcut or tap on the blob.
    func activate() {
        wakeUp()
        switch phase {
        case .listening:
            speechIn.stop(deliver: true)
        case .confirming:
            break
        case .thinking, .speaking:
            work?.cancel()
            speechOut.stop()
            listen()
        case .resting, .awake:
            rememberTargetApp()
            listen()
        }
    }

    private func rememberTargetApp() {
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            tools?.targetApp = front
        }
    }

    private func listen() {
        hideTask?.cancel()
        isError = false
        status = ""
        Task {
            if !permissionsChecked {
                if let problem = await SpeechInput.requestPermissions() {
                    show(reply: problem, error: true)
                    return
                }
                permissionsChecked = true
            }
            do {
                heard = ""
                reply = ""
                withAnimation(.spring(duration: 0.4)) { phase = .listening; showBubble = true }
                NSSound(named: "Tink")?.play()
                try speechIn.start()
            } catch {
                show(reply: error.localizedDescription, error: true)
            }
        }
    }

    private func heardFinished(_ text: String) {
        guard phase == .listening else { return }
        if text.isEmpty {
            show(reply: "I'm sorry, sir, I didn't catch that. Tap \(BuddyShortcut.current.label) to try again.", error: false, speak: false)
            return
        }
        submit(text)
    }

    func submitTyped() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        typed = ""
        if updateMode {
            updateMode = false
            Task { say(await requestSelfUpdate(t)) }
            return
        }
        if tools?.targetApp == nil { rememberTargetApp() }
        submit(t)
    }

    func submit(_ text: String) {
        guard let brain else { return }
        wakeUp()
        speechIn.stop(deliver: false)
        speechOut.stop()
        hideTask?.cancel()
        heard = text
        reply = ""
        status = ""
        isError = false
        if panel?.isKeyWindow == true {
            panel?.resignKeyIfNeeded()
            tools?.targetApp?.activate()
        }
        withAnimation(.spring(duration: 0.4)) { phase = .thinking; showBubble = true }
        work?.cancel()
        work = Task {
            let answer = await brain.respond(to: text)
            guard !Task.isCancelled else { return }
            self.say(answer)
        }
    }

    /// Show and (optionally) speak a reply.
    func say(_ text: String) {
        show(reply: text, error: false, speak: true)
    }

    private func show(reply text: String, error: Bool, speak: Bool = true) {
        reply = text
        status = ""
        isError = error
        let speakOn = UserDefaults.standard.object(forKey: "buddySpeak") as? Bool ?? true
        withAnimation(.spring(duration: 0.4)) { showBubble = true }
        if speak && speakOn && !text.isEmpty {
            phase = .speaking
            speechOut.speak(text)
        } else {
            phase = .awake
            if !error { celebrate() }
            scheduleHide()
        }
    }

    private func doneSpeaking() {
        if phase == .speaking {
            phase = .awake
            if !isError { celebrate() }
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(12))
            // Stay open while an update is running so its live progress stays visible.
            if case .working = BlobUpdater.shared.state { return }
            guard !Task.isCancelled, phase == .awake, typed.isEmpty, !updateMode else { return }
            dismiss()
        }
    }

    func dismiss() {
        withAnimation(.spring(duration: 0.45)) {
            showBubble = false
            phase = .resting
        }
        lastActive = Date()
        panel?.resignKeyIfNeeded()
    }

    func cancel() {
        work?.cancel()
        speechIn.stop(deliver: false)
        speechOut.stop()
        confirmation?.resume(returning: false)
        confirmation = nil
        confirmPrompt = nil
        dismiss()
    }

    func newConversation() {
        brain?.reset()
        heard = ""
        reply = "Fresh start, sir. How can I help?"
        withAnimation { showBubble = true; phase = .awake }
        scheduleHide()
    }

    /// Opens the bubble ready for "describe a change to Blob".
    func startUpdateRequest() {
        updateMode = true
        startTyping()
    }

    func startTyping() {
        rememberTargetApp()
        hideTask?.cancel()
        withAnimation(.spring(duration: 0.4)) { showBubble = true; if phase == .resting { phase = .awake } }
        panel?.makeKey()
    }

    // MARK: Snapshot support (used by the -snapshot launch flag)

    var snapshotView: NSView? { panel?.contentView }

    func stage(_ p: Phase, heard: String = "", reply: String = "", status: String = "", hover: Bool = false,
               sleeping: Bool = false, happy: Bool = false, error: Bool = false, ask: String? = nil) {
        self.sleeping = sleeping
        celebrating = happy
        isError = error
        confirmPrompt = ask
        phase = p
        self.heard = heard
        self.reply = reply
        self.status = status
        hovering = hover
        showBubble = !(heard.isEmpty && reply.isEmpty && ask == nil && p != .listening)
    }

    // MARK: Approvals

    private func askPermission(_ prompt: String) async -> Bool {
        confirmation?.resume(returning: false)
        let previous = phase
        withAnimation(.spring(duration: 0.4)) {
            confirmPrompt = prompt
            phase = .confirming
            showBubble = true
        }
        if UserDefaults.standard.object(forKey: "buddySpeak") as? Bool ?? true {
            speechOut.speak("Is it okay if I " + (prompt.components(separatedBy: "\n").first ?? "do that").lowercasedFirst + "?")
        }
        let ok = await withCheckedContinuation { cont in confirmation = cont }
        confirmPrompt = nil
        phase = previous == .confirming ? .awake : previous
        status = ok ? "Working on it…" : ""
        return ok
    }

    // MARK: Self-update (started only by you: Settings or your own words)

    /// Step 2: you approve the request. Step 3 runs in the background. Step 4: you review before install.
    func requestSelfUpdate(_ request: String) async -> String {
        let updater = BlobUpdater.shared
        if case .working = updater.state { return "I'm already working on an update, sir." }
        if case .review = updater.state { Task { await reviewUpdate() }; return "There's an update waiting for your review, sir." }
        if phase == .resting { withAnimation { phase = .awake } }
        guard await askPermission("Update myself: \(request)\n\nClaude Code (on your Pro plan, no extra charge) will edit my code in the project folder and rebuild me. It can only edit files there and run build commands. Nothing gets installed until you've reviewed the changes.") else {
            return "Very good, sir. I'll stay as I am."
        }
        Task {
            let result = await updater.run(request)
            switch result {
            case .review: await reviewUpdate()
            case .failed(let message): say("The update didn't work out, sir. \(message)")
            default: break
            }
        }
        return "On it, sir. Claude Code is working on that now. I'll show you exactly what changed before installing anything."
    }

    /// Step 4: show the summary and changed files; install only if you click Allow.
    func reviewUpdate() async {
        guard case .review(let summary, let changes) = BlobUpdater.shared.state else { return }
        wakeUp()
        withAnimation(.spring(duration: 0.4)) { if phase == .resting { phase = .awake }; showBubble = true }
        let list = changes.prefix(40).joined(separator: "\n") + (changes.count > 40 ? "\n…and \(changes.count - 40) more" : "")
        let ok = await askPermission("Install the update I just built\n\n\(summary)\n\nChanged files:\n\(list)")
        if ok {
            do {
                try BlobUpdater.shared.installReviewedUpdate()
                say("Installing now, sir. Back in a moment.")
            } catch {
                say("I couldn't install it, sir: \(error.localizedDescription)")
            }
        } else {
            BlobUpdater.shared.discardReviewedUpdate()
            say("Understood, sir. I've discarded those changes and put my code back as it was.")
        }
    }

    func undoLastUpdate() async -> String {
        guard !BlobUpdater.shared.backups.isEmpty else { return "There's no earlier version to go back to, sir." }
        guard await askPermission("Undo the last update\n\nI'll restore the previous version of the app and its code, then restart.") else {
            return "As you wish, sir."
        }
        do {
            try BlobUpdater.shared.undoLastUpdate()
            return "Restoring the previous version, sir. Back in a moment."
        } catch {
            return "I couldn't undo it, sir: \(error.localizedDescription)"
        }
    }

    func answerPermission(_ ok: Bool) {
        speechOut.stop()
        confirmation?.resume(returning: ok)
        confirmation = nil
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - Panel

final class BuddyPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Sit flush in the bottom-right corner of the screen (above the Dock).
    func moveToCorner() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        setFrameOrigin(NSPoint(x: v.maxX - frame.width, y: v.minY))
    }

    func resignKeyIfNeeded() {
        if isKeyWindow { resignKey() }
    }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { BuddyController.shared.cancel() }
    }
}

// MARK: - Global shortcut

enum BuddyShortcut: String, CaseIterable, Identifiable {
    case fnKey, commandShiftB, f10, optionSpace, controlOptionSpace, commandShiftSpace, optionB
    var id: String { rawValue }

    static var current: BuddyShortcut {
        BuddyShortcut(rawValue: UserDefaults.standard.string(forKey: "buddyShortcut") ?? "") ?? .fnKey
    }

    var label: String {
        switch self {
        case .fnKey: return "fn (🌐)"
        case .commandShiftB: return "⇧⌘B"
        case .f10: return "F10"
        case .optionSpace: return "⌥ Space"
        case .controlOptionSpace: return "⌃⌥ Space"
        case .commandShiftSpace: return "⇧⌘ Space"
        case .optionB: return "⌥ B"
        }
    }
    var keyCode: UInt32 {
        switch self {
        case .f10: return UInt32(kVK_F10)
        case .optionB, .commandShiftB: return UInt32(kVK_ANSI_B)
        case .fnKey: return 0
        default: return UInt32(kVK_Space)
        }
    }
    var carbonModifiers: UInt32 {
        switch self {
        case .f10, .fnKey: return 0
        case .commandShiftB: return UInt32(cmdKey | shiftKey)
        case .optionSpace, .optionB: return UInt32(optionKey)
        case .controlOptionSpace: return UInt32(optionKey | controlKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        }
    }
}

/// System-wide hotkey via Carbon (works in any app, no Accessibility permission needed).
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = handler
        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4255_4459), id: id) // 'BUDY'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Tap the fn (🌐) key on its own to talk to Blob. Holding fn with another key (fn+arrows, fn+F-keys) is ignored.
/// Needs Accessibility permission (macOS only shares modifier-key presses with trusted apps).
@MainActor
final class FnKeyMonitor {
    var onTap: () -> Void = {}
    private var monitors: [Any] = []
    private var downAt: Date?
    private var otherKey = false

    func start() {
        guard monitors.isEmpty else { return }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        let flags: (NSEvent) -> Void = { e in MainActor.assumeIsolated { FnKeyMonitor.shared?.flagsChanged(e) } }
        let keys: (NSEvent) -> Void = { _ in MainActor.assumeIsolated { FnKeyMonitor.shared?.otherKey = true } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) { monitors.append(m) }
        FnKeyMonitor.shared = self
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        downAt = nil
    }

    private static weak var shared: FnKeyMonitor?

    private func flagsChanged(_ e: NSEvent) {
        guard e.keyCode == UInt16(kVK_Function) else {
            if downAt != nil { otherKey = true }        // another modifier joined in
            return
        }
        if e.modifierFlags.contains(.function) {
            downAt = Date()
            otherKey = false
        } else if let start = downAt {
            downAt = nil
            if !otherKey, Date().timeIntervalSince(start) < 0.6 { onTap() }
        }
    }
}

/// Plugged in or on battery (polled every few seconds by Blob; cheap).
enum PowerSource {
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }
}
