import SwiftUI
import BrainCore

@main
struct ArjunsBrainApp: App {
    @StateObject private var store = BrainStore.shared
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("accent") private var accent = AccentChoice.cyan.rawValue

    private var mainWindow: some Scene {
        WindowGroup("Blob") {
            RootView()
                .environmentObject(store)
                .tint(Brand.accent)
                .id(accent)   // re-tint everything when you pick a new accent
                .task { await store.onLaunch() }
                .onChange(of: scenePhase) { if scenePhase == .active { store.becameActive() } }
        }
    }

    var body: some Scene {
        #if os(macOS)
        mainWindow
            .defaultSize(width: 1160, height: 800)
            .commands {
                CommandGroup(after: .newItem) {
                    Button("Log Work…") { store.showLogSheet = true }.keyboardShortcut("l")
                    Button("Quick Add…") { store.showQuickAdd = true }.keyboardShortcut("k")
                    Button("Check In") { store.checkIn() }.keyboardShortcut("i")
                    Button("Sync Now") { Task { await store.syncEverything() } }.keyboardShortcut("r")
                }
            }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
                .tint(Brand.accent)
                .id(accent)
        } label: {
            MenuBarLabel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)
        #else
        mainWindow
        #endif
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case today, tasks, activity, calendar, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .tasks: return "Assignments"
        case .activity: return "Activity"
        case .calendar: return "Calendar"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .tasks: return "checklist"
        case .activity: return "chart.bar.xaxis"
        case .calendar: return "calendar"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: BrainStore
    @State private var tab: AppTab? = .today

    var body: some View {
        container
            .background(FrameBackground())
            .sheet(isPresented: $store.showQuickAdd) { QuickAddSheet().environmentObject(store) }
            .sheet(isPresented: $store.showLogSheet) { LogSheet(taskID: nil).environmentObject(store) }
            .sheet(item: $store.logSheetTask) { LogSheet(taskID: $0.id).environmentObject(store) }
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
        case .tasks: TasksScreen(school: store.school)
        case .activity: ActivityScreen()
        case .calendar: CalendarScreen()
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
                HStack(spacing: 10) {
                    AppMark(size: 28)
                    Text("Blob").font(.headline.weight(.bold)).tracking(-0.3)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    if store.focus != nil { FocusPill() }
                    SyncBadge()
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            NavigationStack {
                screen(tab ?? .today)
                    .scrollContentBackground(.hidden)
                    .background(FrameBackground())
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.showLogSheet = true } label: { Label("Log work", systemImage: "square.and.pencil") }
                    .help("Log work (⌘L)")
                Button { store.showQuickAdd = true } label: { Label("Quick Add", systemImage: "plus") }
                    .help("Quick add (⌘K)")
            }
        }
        #else
        TabView(selection: Binding(get: { tab ?? .today }, set: { tab = $0 })) {
            ForEach(AppTab.allCases) { t in
                NavigationStack {
                    screen(t)
                        .scrollContentBackground(.hidden)
                        .background(FrameBackground())
                }
                .tabItem { Label(t.title, systemImage: t.icon) }
                .tag(t)
            }
        }
        .overlay(alignment: .bottom) {
            // The running timer floats just above the tab bar.
            if store.focus != nil { FocusPill().padding(.horizontal, 16).padding(.bottom, 64) }
        }
        #endif
    }
}

struct SyncBadge: View {
    @EnvironmentObject var store: BrainStore
    var body: some View {
        HStack(spacing: 6) {
            if store.isSyncing || store.isSyncingGoogle || store.tickTickRunning {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            } else if store.syncError != nil || store.googleCalendarError != nil || store.tickTickError != nil {
                Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(Brand.caution)
                Text("Sync problem — see Settings")
            } else if let d = [store.lastSync, store.lastTickTickSync, store.lastGoogleRead].compactMap({ $0 }).max() {
                Image(systemName: "checkmark.icloud.fill").foregroundStyle(Brand.ok)
                Text("Synced \(d.formatted(.relative(presentation: .named)))")
            } else {
                Image(systemName: "icloud.slash").foregroundStyle(Brand.faint)
                Text("Sync off")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(Brand.muted)
    }
}

#if os(macOS)
/// Menu bar icon: the check mark, or the running timer.
struct MenuBarLabel: View {
    @EnvironmentObject var store: BrainStore
    var body: some View {
        if let f = store.focus {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("◉ \(Scheduler.durationText(f.minutes))")
            }
        } else {
            Image(systemName: "checklist")
        }
    }
}

/// Menu bar panel: log work, run the timer, add anything, see what's next — without opening the window.
struct MenuBarPanel: View {
    @EnvironmentObject var store: BrainStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppMark(size: 24)
                Text("Blob").font(.headline.weight(.bold))
                Spacer()
                SyncBadge().fixedSize()
            }
            if store.focus != nil { FocusPill() }
            LogComposer(compact: true)
            QuickAddBar()
            Overline(text: "Up next")
            let next = upNext
            if next.isEmpty { EmptyHint(icon: "sun.max", text: "Nothing coming up.") }
            ForEach(next, id: \.0) { item in
                HStack {
                    Circle().fill(item.3).frame(width: 8, height: 8)
                    Text(item.1).lineLimit(1)
                    Spacer()
                    Text(item.2).font(.caption).foregroundStyle(Brand.muted)
                }
            }
            Divider()
            HStack {
                Button("Check in") { store.checkIn(); activate() }.buttonStyle(TintButtonStyle(compact: true))
                Spacer()
                Button("Open Blob") { activate() }.buttonStyle(TintButtonStyle(kind: .quiet, compact: true))
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(TintButtonStyle(kind: .quiet, compact: true))
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(FrameBackground())
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

/// `ArjunsBrain -snapshot /path/prefix` saves a PNG of each tab, then quits. Used to check the UI from scripts.
enum WindowSnapshot {
    @MainActor
    static func runIfRequested(store: BrainStore, select: (AppTab) -> Void) async {
        guard let prefix = UserDefaults.standard.string(forKey: "snapshot") else { return }
        if UserDefaults.standard.bool(forKey: "snapshotCheckIn") { store.checkIn() }
        func shoot(_ name: String) {
            guard let view = NSApplication.shared.windows.first(where: { $0.canBecomeMain })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
        for t in AppTab.allCases {
            select(t)
            try? await Task.sleep(for: .seconds(1.5))
            shoot(t.rawValue)
        }
        select(.tasks)
        for mode in ["Long-term", "Classes"] {
            UserDefaults.standard.set(mode, forKey: "assignmentsMode")
            try? await Task.sleep(for: .seconds(1.5))
            shoot("tasks-\(mode)")
        }
        UserDefaults.standard.set("Upcoming", forKey: "assignmentsMode")
        if let t = store.pendingTasks.filter({ !$0.milestones.isEmpty }).min(by: { ($0.due ?? .distantFuture) > ($1.due ?? .distantFuture) }) {
            let host = NSHostingView(rootView: AssignmentDetail(taskID: t.id).environmentObject(store))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host
            win.orderFront(nil)
            try? await Task.sleep(for: .seconds(1.5))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-detail.png"))
            }
            win.close()
        }
        NSApplication.shared.terminate(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window keeps the menu bar panel (and a running timer) going.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

#endif
