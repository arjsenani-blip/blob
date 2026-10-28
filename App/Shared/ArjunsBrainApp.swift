import SwiftUI
import BrainCore

@main
struct ArjunsBrainApp: App {
    @StateObject private var store = BrainStore.shared
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("accent") private var accent = AccentChoice.violet.rawValue

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
    @State private var tab: XTab = .today
    @State private var showSettings = false
    @State private var showSearch = false

    var body: some View {
        ZStack(alignment: .bottom) {
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            XTabBar(tab: $tab) { store.showQuickAdd = true }
                .padding(.horizontal, 12)
                .padding(.bottom, bottomInset)
        }
        .background(X.page.ignoresSafeArea())
        .sheet(isPresented: $store.showQuickAdd) { QuickAddSheet().environmentObject(store) }
        .sheet(isPresented: $store.showLogSheet) { LogSheet(taskID: nil).environmentObject(store) }
        .sheet(item: $store.logSheetTask) { LogSheet(taskID: $0.id).environmentObject(store) }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsScreen(school: store.school, personal: store.personal, systemCalendar: store.systemCalendar)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            }
            .environmentObject(store)
            .sheetSize(minWidth: 620, minHeight: 700)
        }
        .sheet(isPresented: $showSearch) { SearchSheet().environmentObject(store) }
        .overlay(alignment: .top) {
            if let t = store.toast { ToastView(text: t).padding(.top, 8) }
        }
        .animation(.spring(duration: 0.35), value: store.toast)
        #if os(macOS)
        .task { await WindowSnapshot.runIfRequested(store: store) { tab = $0 } }
        #endif
    }

    private var bottomInset: CGFloat {
        #if os(iOS)
        6
        #else
        22
        #endif
    }

    @ViewBuilder
    private var screen: some View {
        switch tab {
        case .today: TodayX(tab: $tab, openSettings: { showSettings = true }, openSearch: { showSearch = true })
        case .calendar: CalendarX(openSettings: { showSettings = true }, openSearch: { showSearch = true })
        case .routines: RoutinesScreen(openSettings: { showSettings = true }, openSearch: { showSearch = true })
        case .focus: FocusScreen()
        case .tasks:
            NavigationStack {
                TasksScreen(school: store.school)
                    .scrollContentBackground(.hidden)
                    .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 90) }
                    #if os(iOS)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { NavigationLink("Activity") { ActivityScreen().safeAreaInset(edge: .bottom) { Color.clear.frame(height: 90) } } } }
                    #endif
            }
        case .activity:
            NavigationStack {
                ActivityScreen().scrollContentBackground(.hidden)
                    .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 90) }
            }
        }
    }
}

/// Search assignments and events.
struct SearchSheet: View {
    @EnvironmentObject var store: BrainStore
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @State private var openTask: IDBox?

    var body: some View {
        NavigationStack {
            List {
                let query = q.trimmingCharacters(in: .whitespaces).lowercased()
                if !query.isEmpty {
                    let ts = store.tasks.filter { ($0.title + " " + ($0.course ?? "")).lowercased().contains(query) }.prefix(30)
                    if !ts.isEmpty {
                        Section("Assignments & to-dos") {
                            ForEach(Array(ts)) { t in
                                Button { openTask = IDBox(id: t.id) } label: {
                                    HStack {
                                        Text(DayFeed.emoji(task: t))
                                        VStack(alignment: .leading) {
                                            Text(t.title).foregroundStyle(X.ink).strikethrough(t.isCompleted)
                                            Text([t.course, t.due.map { "due " + $0.dueText() }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(X.muted)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    let now = Date()
                    let evs = store.occurrences(in: DateInterval(start: now.addingTimeInterval(-60 * 86_400), duration: 180 * 86_400))
                        .filter { $0.title.lowercased().contains(query) }.prefix(40)
                    if !evs.isEmpty {
                        Section("Events") {
                            ForEach(Array(evs)) { o in
                                HStack {
                                    Text(DayFeed.emoji(event: o.title, category: DayFeed.category(for: o)))
                                    VStack(alignment: .leading) {
                                        Text(o.title).foregroundStyle(X.ink)
                                        Text(o.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + (o.isAllDay ? "" : " · " + o.start.formatted(date: .omitted, time: .shortened)) + " · " + DayFeed.category(for: o))
                                            .font(.caption).foregroundStyle(X.muted)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $q, prompt: "Search assignments and events")
            .navigationTitle("Search")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .sheetSize(minWidth: 520, minHeight: 560)
        .sheet(item: $openTask) { AssignmentDetail(taskID: $0.id).environmentObject(store) }
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
    static func runIfRequested(store: BrainStore, select: (XTab) -> Void) async {
        guard let prefix = UserDefaults.standard.string(forKey: "snapshot") else { return }
        if UserDefaults.standard.bool(forKey: "snapshotCheckIn") { store.checkIn() }
        let w = UserDefaults.standard.double(forKey: "snapshotWidth"), h = UserDefaults.standard.double(forKey: "snapshotHeight")
        if w > 0, let win = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            win.setContentSize(NSSize(width: w, height: h > 0 ? h : 820))
        }
        func shoot(_ name: String) {
            guard let view = NSApplication.shared.windows.first(where: { $0.canBecomeMain })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
        for t in XTab.allCases {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `-calendarAudit <file>`: write every event for the next 90 days (repeats expanded) to a TSV, then quit. Read-only.
        if let path = UserDefaults.standard.string(forKey: "calendarAudit") {
            CalendarAudit.write(to: path)
            NSApplication.shared.terminate(nil)
        }
        // `-calendarBackup <file.json>`: every event in your editable calendars (2 years back and ahead) as JSON. Read-only.
        if let path = UserDefaults.standard.string(forKey: "calendarBackup") {
            CalendarAudit.backup(to: path)
            NSApplication.shared.terminate(nil)
        }
        // `-calendarOps <ops.json> -calendarOpsLog <file>`: apply a reviewed list of moves/deletes, logging each result.
        if let path = UserDefaults.standard.string(forKey: "calendarOps") {
            CalendarAudit.apply(opsFile: path, log: UserDefaults.standard.string(forKey: "calendarOpsLog") ?? path + ".log")
            NSApplication.shared.terminate(nil)
        }
    }
}

import EventKit

private extension Int { var nonZero: Int? { self == 0 ? nil : self } }

extension CalendarAudit {
    static func backup(to path: String) {
        let ek = EKEventStore()
        let now = Date()
        let cals = ek.calendars(for: .event).filter(\.allowsContentModifications)
        var seen = Set<String>()
        var out: [[String: Any]] = []
        let iso = ISO8601DateFormatter()
        // EventKit only searches 4 years at a time; go in 1-year windows.
        for y in -2..<2 {
            let s = Calendar.current.date(byAdding: .year, value: y, to: now)!, e = Calendar.current.date(byAdding: .year, value: y + 1, to: now)!
            for ev in ek.events(matching: ek.predicateForEvents(withStart: s, end: e, calendars: cals)) {
                let key = ev.hasRecurrenceRules ? ev.calendarItemIdentifier : ev.calendarItemIdentifier + "@" + iso.string(from: ev.startDate)
                guard seen.insert(key).inserted else { continue }
                out.append([
                    "calendar": ev.calendar.title, "calendarID": ev.calendar.calendarIdentifier, "source": ev.calendar.source.title,
                    "title": ev.title ?? "", "start": iso.string(from: ev.startDate), "end": iso.string(from: ev.endDate),
                    "allDay": ev.isAllDay, "location": ev.location ?? "", "notes": ev.notes ?? "", "url": ev.url?.absoluteString ?? "",
                    "recurrence": (ev.recurrenceRules ?? []).map { $0.description }, "alarms": (ev.alarms ?? []).map { $0.relativeOffset },
                    "id": ev.calendarItemIdentifier, "externalID": ev.calendarItemExternalIdentifier ?? "", "detached": ev.isDetached,
                ])
            }
        }
        if let d = try? JSONSerialization.data(withJSONObject: ["savedAt": iso.string(from: now), "events": out], options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: path))
        }
    }

    /// ops: [{"op":"move","id":<calendarItemIdentifier>,"to":<calendarID>}, {"op":"delete","id":…},
    ///       {"op":"deleteCalendar","calendar":<id>}, {"op":"renameCalendar","calendar":<id>,"title":…}]
    static func apply(opsFile: String, log: String) {
        let ek = EKEventStore()
        var lines: [String] = []
        defer { try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8) }
        guard let data = FileManager.default.contents(atPath: opsFile),
              let ops = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { lines.append("ERROR bad ops file"); return }
        for op in ops {
            let kind = op["op"] ?? ""
            do {
                switch kind {
                case "move", "delete":
                    guard let id = op["id"], let ev = ek.calendarItem(withIdentifier: id) as? EKEvent else { lines.append("MISS \(kind) \(op["id"] ?? "")"); continue }
                    let title = ev.title ?? ""
                    if kind == "delete" {
                        try ek.remove(ev, span: .futureEvents, commit: true)
                        lines.append("OK delete \(title)")
                    } else {
                        guard let to = op["to"].flatMap({ ek.calendar(withIdentifier: $0) }) else { lines.append("MISS target for \(title)"); continue }
                        let from = ev.calendar.title
                        ev.calendar = to
                        try ek.save(ev, span: .futureEvents, commit: true)
                        lines.append("OK move \(title): \(from) → \(to.title)")
                    }
                case "deleteCalendar":
                    guard let c = op["calendar"].flatMap({ ek.calendar(withIdentifier: $0) }) else { lines.append("MISS calendar \(op["calendar"] ?? "")"); continue }
                    let t = c.title
                    try ek.removeCalendar(c, commit: true)
                    lines.append("OK deleteCalendar \(t)")
                case "renameCalendar":
                    guard let c = op["calendar"].flatMap({ ek.calendar(withIdentifier: $0) }), let t = op["title"] else { lines.append("MISS rename"); continue }
                    let old = c.title
                    c.title = t
                    try ek.saveCalendar(c, commit: true)
                    lines.append("OK rename \(old) → \(t)")
                default: lines.append("SKIP unknown op \(kind)")
                }
            } catch {
                lines.append("FAIL \(kind) \(op["id"] ?? op["calendar"] ?? ""): \(error.localizedDescription)")
            }
        }
    }
}

/// Read-only listing of calendar events, used to find duplicates.
enum CalendarAudit {
    static func write(to path: String) {
        let ek = EKEventStore()
        let days = Double(UserDefaults.standard.integer(forKey: "auditDays").nonZero ?? 90)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-days * 86_400)
        let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(days * 86_400)
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var lines = ["auth\t\(EKEventStore.authorizationStatus(for: .event).rawValue)"]
        for c in ek.calendars(for: .event) {
            lines.append(["CAL", c.title, c.source.title, "\(c.source.sourceType.rawValue)", c.calendarIdentifier, "\(c.type.rawValue)",
                          c.allowsContentModifications ? "editable" : "readonly", c.isSubscribed ? "subscribed" : "",
                          c.isImmutable ? "immutable" : ""].joined(separator: "\t"))
        }
        for c in ek.calendars(for: .reminder) {
            lines.append(["REMLIST", c.title, c.source.title, "\(c.source.sourceType.rawValue)", c.calendarIdentifier].joined(separator: "\t"))
        }
        for e in ek.events(matching: ek.predicateForEvents(withStart: start, end: end, calendars: nil)) {
            let fields: [String] = [
                e.calendar.title, e.calendar.source.title, e.calendar.calendarIdentifier,
                (e.title ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " "),
                iso.string(from: e.startDate), iso.string(from: e.endDate), e.isAllDay ? "allday" : "",
                e.calendarItemIdentifier, e.calendarItemExternalIdentifier ?? "", e.hasRecurrenceRules ? "repeats" : "",
                e.url?.absoluteString ?? "", "\(e.alarms?.count ?? 0)", e.calendar.allowsContentModifications ? "editable" : "readonly",
                e.organizer?.name ?? "", e.isDetached ? "detached" : "",
            ]
            lines.append(fields.joined(separator: "\t"))
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

#endif
