import SwiftUI
import BrainCore

@main
struct ArjunsBrainApp: App {
    @StateObject private var store = BrainStore.shared
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    private var mainWindow: some Scene {
        WindowGroup("Blob's Brain") {
            RootView()
                .environmentObject(store)
                .tint(Brand.violet)
                .fontDesign(.rounded)
                .task { await store.onLaunch() }
                .onChange(of: scenePhase) { if scenePhase == .active { store.becameActive() } }
        }
    }

    var body: some Scene {
        #if os(macOS)
        mainWindow
            .defaultSize(width: 1120, height: 780)
            .commands {
                CommandGroup(after: .newItem) {
                    Button("Quick Add…") { store.showQuickAdd = true }.keyboardShortcut("k")
                    Button("Check In") { store.checkIn() }.keyboardShortcut("i")
                    Button("Sync Now") { Task { await store.syncEverything() } }.keyboardShortcut("r")
                }
            }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
                .tint(Brand.violet)
                .fontDesign(.rounded)
        } label: {
            Image(nsImage: BlobMenuIcon.image)
        }
        .menuBarExtraStyle(.window)
        #else
        mainWindow
        #endif
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case today, calendar, tasks, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .calendar: return "Calendar"
        case .tasks: return "Assignments"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .today: return "sun.max.fill"
        case .calendar: return "calendar"
        case .tasks: return "checklist"
        case .settings: return "gearshape.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: BrainStore
    @State private var tab: AppTab? = .today
    #if os(iOS)
    @StateObject private var phoneBlob = PhoneBlob(store: BrainStore.shared)
    #endif

    var body: some View {
        container
            .sheet(isPresented: $store.showQuickAdd) { QuickAddSheet().environmentObject(store) }
            .overlay(alignment: .top) {
                if let t = store.toast { ToastView(text: t).padding(.top, 8) }
            }
            .animation(.spring(duration: 0.35), value: store.toast)
            #if os(macOS)
            .task { await WindowSnapshot.runIfRequested(store: store) { tab = $0 } }
            #endif
    }

    @ViewBuilder
    private func screen(_ t: AppTab) -> some View {
        switch t {
        case .today: TodayView()
        case .calendar: CalendarScreen()
        case .tasks: TasksScreen(school: store.school)
        case .settings: SettingsScreen(school: store.school, personal: store.personal, systemCalendar: store.systemCalendar)
        }
    }

    @ViewBuilder
    private var container: some View {
        #if os(macOS)
        NavigationSplitView {
            List(AppTab.allCases, selection: $tab) { t in
                Label(t.title, systemImage: t.icon).tag(t)
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    BlobCharacter(mood: .idle, level: 0, look: .zero, fixedTime: 1.0)
                        .frame(width: 30, height: 30)
                    Text("Blob's Brain").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom) { SyncBadge().padding(12) }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            NavigationStack { screen(tab ?? .today) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.showQuickAdd = true } label: { Label("Quick Add", systemImage: "plus") }
                    .help("Quick add (⌘K)")
            }
        }
        #else
        TabView(selection: Binding(get: { tab ?? .today }, set: { tab = $0 })) {
            ForEach(AppTab.allCases) { t in
                NavigationStack { screen(t) }
                    .tabItem { Label(t.title, systemImage: t.icon) }
                    .tag(t)
            }
        }
        .overlay(alignment: .bottomTrailing) { PhoneBlobOverlay(blob: phoneBlob) }
        #endif
    }
}

struct SyncBadge: View {
    @EnvironmentObject var store: BrainStore
    var body: some View {
        HStack(spacing: 6) {
            if store.isSyncing {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            } else if store.syncError != nil {
                Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.orange)
                Text("Sync problem")
            } else if let d = store.lastSync, store.syncAccount != nil {
                Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green)
                Text("Synced \(d.formatted(.relative(presentation: .named)))")
            } else {
                Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                Text("Sync off")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

#if os(macOS)
/// Menu bar quick panel: add anything and see what's next without opening the window.
struct MenuBarPanel: View {
    @EnvironmentObject var store: BrainStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BlobCharacter(mood: .idle, level: 0, look: .zero, fixedTime: 1.0)
                    .frame(width: 24, height: 24)
                Text("Blob").font(.headline)
                Spacer()
                SyncBadge().fixedSize()
            }
            QuickAddBar(autofocus: true)
            Text("UP NEXT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            let next = upNext
            if next.isEmpty { EmptyHint(icon: "sun.max.fill", text: "Nothing coming up.") }
            ForEach(next, id: \.0) { item in
                HStack {
                    Circle().fill(item.3).frame(width: 8, height: 8)
                    Text(item.1).lineLimit(1)
                    Spacer()
                    Text(item.2).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Button {
                BuddyController.shared.activate()
            } label: {
                Label("Talk to Blob (\(BuddyShortcut.current.label))", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(BuddyColors.cyan)
            HStack {
                Button("Check in") { store.checkIn(); activate() }.buttonStyle(GradientButtonStyle()).controlSize(.small)
                Button("Update Blob…") { BuddyController.shared.startUpdateRequest() }
                Spacer()
                Button("Open app") { activate() }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(Brand.canvas)
    }

    private func activate() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !NSApplication.shared.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }

    private var upNext: [(String, String, String, Color)] {
        let now = Date()
        var items: [(Date, (String, String, String, Color))] = []
        if let plan = store.todayPlan {
            for b in plan.blocks where b.kind == .task && b.end > now && !store.isBlockDone(b) {
                items.append((b.start, (b.id.uuidString, b.title, b.start.shortTime, Brand.color(for: b.subtitle ?? b.title))))
            }
        }
        for o in store.occurrences(in: DateInterval(start: now, duration: 86_400)) where !o.isAllDay && o.end > now {
            items.append((o.start, (o.id, o.title, o.start.dueText(), Brand.color(for: o))))
        }
        return items.sorted { $0.0 < $1.0 }.prefix(5).map(\.1)
    }
}
#endif

#if os(macOS)
/// `ArjunsBrain -snapshot /path/prefix` saves a PNG of each tab, then quits. Used to check the UI from scripts.
enum WindowSnapshot {
    @MainActor
    static func runIfRequested(store: BrainStore, select: (AppTab) -> Void) async {
        guard let prefix = UserDefaults.standard.string(forKey: "snapshot") else { return }
        if UserDefaults.standard.bool(forKey: "snapshotCheckIn") { store.checkIn() }
        for t in AppTab.allCases {
            select(t)
            try? await Task.sleep(for: .seconds(1.5))
            guard let view = NSApplication.shared.windows.first(where: { $0.canBecomeMain })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(t.rawValue).png"))
        }
        let buddy = BuddyController.shared
        let stages: [(String, () -> Void)] = [
            ("buddy-1-sleepy", { buddy.stage(.awake, sleeping: true) }),
            ("buddy-2-idle", { buddy.stage(.awake) }),
            ("buddy-3-curious", { buddy.stage(.awake, hover: true) }),
            ("buddy-4-listening", { buddy.stage(.listening) }),
            ("buddy-5-thinking", { buddy.stage(.thinking) }),
            ("buddy-6-speaking", { buddy.stage(.speaking) }),
            ("buddy-7-happy", { buddy.stage(.awake, happy: true) }),
            ("buddy-8-asking", { buddy.stage(.confirming) }),
            ("buddy-9-error", { buddy.stage(.awake, error: true) }),
        ]
        for (name, apply) in stages {
            apply()
            try? await Task.sleep(for: .seconds(1.2))
            guard let view = buddy.snapshotView,
                  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 3), pixelsHigh: Int(view.bounds.height * 3),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
        NSApplication.shared.terminate(nil)
    }
}
#endif

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            BuddyController.shared.start(store: BrainStore.shared)
            // `-renderIcons <folder>`: draw the app icon from the Blob character, then quit.
            if let folder = UserDefaults.standard.string(forKey: "renderIcons") {
                BlobIconArt.render(to: URL(fileURLWithPath: folder))
                NSApplication.shared.terminate(nil)
            }
            // `-voiceFileTest <path>`: render one line with the natural voice (cleanup included) to a WAV, then quit.
            if let path = UserDefaults.standard.string(forKey: "voiceFileTest") {
                Task {
                    if let url = await NaturalVoice.render("Good evening, sir. I've lined up your assignments for tonight. Your chemistry lab report is first, and if we keep a steady pace, you'll be done by ten.", speaker: NaturalVoice.speakerID) {
                        try? FileManager.default.removeItem(atPath: path)
                        try? FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: path))
                    }
                    NSApplication.shared.terminate(nil)
                }
            }
            // `-speakTest "text"`: say one line with Blob's voice, report which engine spoke, then quit.
            if let line = UserDefaults.standard.string(forKey: "speakTest") {
                let out = SpeechOutput()
                let start = Date()
                FileHandle.standardError.write("voice engine: \(VoiceEngine.current.rawValue)\n".data(using: .utf8)!)
                out.onFinished = {
                    FileHandle.standardError.write(String(format: "finished speaking %.1fs after launch\n", Date().timeIntervalSince(start)).data(using: .utf8)!)
                    NSApplication.shared.terminate(nil)
                }
                Task {
                    // Give the natural voice up to 40 s to load so the test hears it, not the fallback.
                    for _ in 0..<80 where VoiceEngine.current == .chatterbox && !ChatterboxServer.shared.isReady {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    FileHandle.standardError.write("chatterbox ready: \(ChatterboxServer.shared.isReady) after \(Int(Date().timeIntervalSince(start)))s\n".data(using: .utf8)!)
                    out.speak(line)
                }
                objc_setAssociatedObject(NSApplication.shared, "speakTest", out, .OBJC_ASSOCIATION_RETAIN)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { ChatterboxServer.shared.stop() }
    }

    /// Closing the window keeps Blob and the menu bar icon running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
#endif
