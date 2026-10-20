import SwiftUI
import AVFoundation
import ServiceManagement
import ApplicationServices

struct BuddySettingsSection: View {
    @AppStorage("buddyEnabled") private var enabled = true
    @AppStorage("buddyShortcut") private var shortcut = BuddyShortcut.fnKey.rawValue
    @AppStorage("blobChatterboxOnBattery") private var chatterboxOnBattery = false
    @AppStorage("buddyBrain") private var brainMode = BuddyBrainMode.onDevice.rawValue
    @AppStorage("buddySpeak") private var speak = true
    @AppStorage("buddyVoice") private var voiceID = ""
    @AppStorage("blobVoiceEngine") private var voiceEngine = VoiceEngine.current.rawValue
    @AppStorage("blobKokoroVoice") private var kokoroVoice = 24
    @AppStorage("buddyTrustAppleScript") private var trustAppleScript = false
    @State private var apiKey = BuddyBrain.apiKey
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var refresh = 0
    @State private var preview = SpeechOutput()
    @ObservedObject private var updater = BlobUpdater.shared
    @AppStorage("blobSourceRoot") private var sourceOverride = ""
    @State private var changeRequest = ""
    @State private var claudePath: String?

    var body: some View {
        Section {
            Toggle("Show Blob in the corner", isOn: $enabled)
            Picker("Shortcut to talk", selection: $shortcut) {
                ForEach(BuddyShortcut.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Toggle("Open at login (so Blob is always there)", isOn: Binding(
                get: { launchAtLogin },
                set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {}
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
        } header: {
            Text("Blob")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tap \(BuddyShortcut(rawValue: shortcut)?.label ?? "fn") or click Blob to talk. Blob doesn't listen in the background — the mic only turns on when you call it.")
                if shortcut == BuddyShortcut.fnKey.rawValue {
                    Text("Tap fn on its own (not held with another key). Set System Settings → Keyboard → \"Press 🌐 key to\" → Do Nothing, so macOS doesn't also open the emoji picker. Needs Accessibility permission.")
                    Button("Open Keyboard settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                }
                if shortcut == BuddyShortcut.commandShiftB.rawValue {
                    Text("⇧⌘B works everywhere, so it overrides that shortcut inside apps (for example Safari's Favorites Bar).")
                }
                if shortcut == BuddyShortcut.f10.rawValue {
                    Text("On most Macs F10 is the mute key: press fn + F10, or turn on System Settings → Keyboard → Keyboard Shortcuts → Function Keys → \"Use F1, F2, etc. keys as standard function keys\".")
                }
            }
        }

        Section {
            Picker("Brain", selection: $brainMode) {
                ForEach(BuddyBrainMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            LabeledContent("Apple Intelligence") {
                if let reason = OnDeviceBrain.unavailableReason {
                    Text(reason).foregroundStyle(.orange)
                } else {
                    Label("Ready on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            if brainMode == BuddyBrainMode.claudeAPI.rawValue {
                SecureField("Claude API key", text: $apiKey, prompt: Text("sk-ant-…"))
                    .onChange(of: apiKey) { BuddyBrain.apiKey = apiKey }
                Text("⚠️ The Claude API is billed per use, separately from your Claude Pro plan. Only needed for screenshot-based screen control.")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Blob's brain")
        } footer: {
            Text("Free by default. On-device runs on Apple Intelligence: private, offline, no cost. Opening apps and sites, YouTube, music, search, volume, timers, your schedule and controlling app buttons all work on-device. Say \"ask Claude…\" to send one question to Claude on your Pro plan (needs internet, no extra charge).")
        }

        Section {
            Toggle("Speak replies out loud", isOn: $speak)
            Picker("Voice engine", selection: $voiceEngine) {
                ForEach(VoiceEngine.allCases) { e in
                    Text(e.label).tag(e.rawValue)
                        .disabled((e == .chatterbox && !ChatterboxServer.isInstalled) || (e == .kokoro && !NaturalVoice.isInstalled))
                }
            }
            .onChange(of: voiceEngine) {
                if VoiceEngine.effective == .chatterbox { ChatterboxServer.shared.startIfNeeded() } else { ChatterboxServer.shared.stop() }
            }
            if voiceEngine == VoiceEngine.chatterbox.rawValue {
                Toggle("Use the natural voice on battery too (uses more battery)", isOn: $chatterboxOnBattery)
                    .onChange(of: chatterboxOnBattery) {
                        if VoiceEngine.effective == .chatterbox { ChatterboxServer.shared.startIfNeeded() } else { ChatterboxServer.shared.stop() }
                    }
            }
            if voiceEngine != VoiceEngine.apple.rawValue && NaturalVoice.isInstalled {
                Picker(voiceEngine == VoiceEngine.chatterbox.rawValue ? "Kokoro fallback voice" : "Kokoro voice", selection: $kokoroVoice) {
                    ForEach(NaturalVoice.voices, id: \.speaker) { v in Text("\(v.name) — \(v.note)").tag(v.speaker) }
                }
            }
            Picker(voiceEngine == VoiceEngine.apple.rawValue ? "Apple voice" : "Apple fallback voice", selection: $voiceID) {
                Text("Automatic (best British voice)").tag("")
                ForEach(SpeechOutput.englishVoices, id: \.identifier) { v in
                    Text("\(v.name) — \(v.language)\(v.quality == .premium ? " · Premium" : v.quality == .enhanced ? " · Enhanced" : "")").tag(v.identifier)
                }
            }
            HStack {
                Text("Using: " + (voiceEngine == VoiceEngine.chatterbox.rawValue ? (ChatterboxServer.shared.isReady ? "Chatterbox Daniel" : "Chatterbox Daniel (warming up — Kokoro meanwhile)") : NaturalVoice.isEnabled ? "\(NaturalVoice.voices.first { $0.speaker == NaturalVoice.speakerID }?.name ?? "Daniel") (Kokoro)" : SpeechOutput.voice.map { "\($0.name) (\($0.language))" } ?? "system voice"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Preview") { preview.speak("Good evening, sir. All systems are running smoothly.") }
            }
            if SpeechOutput.needsBetterVoice && !NaturalVoice.isEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Get the natural British voice (free, works offline)", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("Open Spoken Content → System Voice → Manage Voices… → English (United Kingdom), and download **Jamie (Premium)** or **Daniel (Enhanced)**. Blob switches to it automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Spoken Content settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Voice")
        }

        Section {
            LabeledContent("Source folder") {
                HStack {
                    Text(updater.sourceRoot?.path ?? "Not found")
                        .foregroundStyle(updater.sourceRoot == nil ? .orange : .secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseSourceFolder() }
                }
            }
            LabeledContent("Claude Code") {
                Text(claudePath == nil ? "Not found" : "Ready (Pro plan)")
                    .foregroundStyle(claudePath == nil ? .orange : .green)
            }
            HStack {
                TextField("Describe a change, e.g. \"add a Pomodoro timer to Blob\"", text: $changeRequest)
                Button("Ask Claude Code") {
                    let r = changeRequest
                    changeRequest = ""
                    Task { BuddyController.shared.say(await BuddyController.shared.requestSelfUpdate(r)) }
                }
                .disabled(changeRequest.trimmingCharacters(in: .whitespaces).isEmpty || updater.sourceRoot == nil || claudePath == nil)
            }
            HStack {
                Text(updater.statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if case .review = updater.state {
                    Button("Review update") { Task { await BuddyController.shared.reviewUpdate() } }
                }
                Button("Undo last update") {
                    Task { BuddyController.shared.say(await BuddyController.shared.undoLastUpdate()) }
                }
                .disabled(updater.backups.isEmpty)
            }
        } header: {
            Text("Blob updates")
        } footer: {
            Text("You can also tap fn and say \"Update yourself to…\". You approve the request, Claude Code edits and rebuilds the project (file edits and build commands only, on your Pro plan), then you review the summary and changed files and approve again before it installs. The previous version is always backed up — say \"undo the last update\" to go back. Blob's AI can never start an update on its own.")
        }
        .task { claudePath = await ClaudeCodeBrain.findClaude() }

        Section {
            permissionRow("Microphone & Speech", granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                          pane: "Privacy_Microphone")
            permissionRow("Accessibility (control apps, type, click)", granted: AXIsProcessTrusted(), pane: "Privacy_Accessibility")
            permissionRow("Screen Recording (read your screen)", granted: CGPreflightScreenCaptureAccess(), pane: "Privacy_ScreenCapture")
            permissionRow("Full Disk Access (read any file)", granted: nil, pane: "Privacy_AllFiles")
            Toggle("Run AppleScript without asking", isOn: $trustAppleScript)
        } header: {
            Text("What Blob can do")
        } footer: {
            Text("Blob asks before running any shell command. It never deletes, sends or buys anything unless you ask for exactly that.")
        }
        .id(refresh)
        .onAppear { refresh += 1 }
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the ArjunsBrain folder (the one containing project.yml)"
        if panel.runModal() == .OK, let url = panel.url {
            sourceOverride = url.path
            updater.objectWillChange.send()
        }
    }

    private func permissionRow(_ title: String, granted: Bool?, pane: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if granted == true {
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(granted == nil ? "Open settings" : "Turn on") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
    }
}
