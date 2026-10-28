import SwiftUI
import EventKit
import BrainCore

struct SettingsScreen: View {
    @EnvironmentObject var store: BrainStore
    @ObservedObject var school: GoogleAccount
    @ObservedObject var personal: GoogleAccount
    @ObservedObject var systemCalendar: SystemCalendarBridge
    @AppStorage("googleClientID") private var clientID = ""
    @State private var showSetupHelp = false

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $store.displayName)
                AccentPicker()
            } header: { Text("You") } footer: {
                Text("The accent colors the main buttons, the + button, the focus timer and highlights.")
            }

            TickTickSection()

            GoogleSection(school: school, personal: personal, systemCalendar: systemCalendar, showSetupHelp: $showSetupHelp)

            Section {
                LabeledContent("Syncing through") {
                    Text(store.syncAccount?.email ?? (store.syncAccount != nil ? "Google Drive" : "Not set up"))
                        .foregroundStyle(.secondary)
                }
                accountRow(personal, label: "Separate sync account (optional)", scopes: [GoogleAccount.driveScope])
                Button {
                    Task { await store.syncDevices() }
                } label: {
                    HStack {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath.icloud")
                        Spacer()
                        if store.isSyncing { ProgressView().controlSize(.small) }
                        else if let d = store.lastSync { Text(d.formatted(.relative(presentation: .named))).foregroundStyle(.secondary) }
                    }
                }
                .disabled(store.syncAccount == nil)
                if let err = store.syncError { Text(err).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Mac ↔ iPhone sync")
            } footer: {
                Text("Your calendar, to-dos and timelines are stored in a hidden app folder in Google Drive and merged automatically. Sign in with the same account on both devices. If your school blocks Drive, add a personal Gmail here.")
            }

            Section("Check-in planner") {
                DatePicker("Done working by", selection: bedtime, displayedComponents: .hourAndMinute)
                Stepper("Focus blocks: \(store.settings.focusBlockMinutes) min", value: setting(\.focusBlockMinutes), in: 15...120, step: 5)
                Stepper("Breaks: \(store.settings.breakMinutes) min", value: setting(\.breakMinutes), in: 0...30, step: 5)
                Stepper("Daily work goal: \(Scheduler.durationText(store.settings.dailyWorkTargetMinutes))",
                        value: setting(\.dailyWorkTargetMinutes), in: 30...480, step: 15)
                Stepper("Late-night session: \(store.settings.lateSessionMinutes) min", value: setting(\.lateSessionMinutes), in: 15...180, step: 15)
            }

            AppleCalendarSection(systemCalendar: systemCalendar)

            Section {
                Toggle("Homework & task reminders", isOn: Binding(
                    get: { store.remindersOn },
                    set: { on in
                        store.remindersOn = on
                        Task { _ = await Reminders.requestAuthorization(); store.rescheduleReminders() }
                    }))
                if store.remindersOn {
                    Picker("“Due tonight” reminder", selection: Binding(get: { store.dueTodayHour }, set: { store.dueTodayHour = $0; store.rescheduleReminders() })) {
                        ForEach([12, 14, 15, 16, 17, 18, 19, 20], id: \.self) { h in Text(hourText(h)).tag(h) }
                    }
                    Picker("“Due tomorrow” reminder", selection: Binding(get: { store.dueTomorrowHour }, set: { store.dueTomorrowHour = $0; store.rescheduleReminders() })) {
                        ForEach([17, 18, 19, 20, 21], id: \.self) { h in Text(hourText(h)).tag(h) }
                    }
                }
                Toggle("Morning summary (7 AM)", isOn: Binding(get: { store.morningDigestOn }, set: { store.morningDigestOn = $0; store.rescheduleReminders() }))
                Toggle("Also alert me before events", isOn: Binding(get: { store.eventAlertsOn }, set: { store.eventAlertsOn = $0; store.rescheduleReminders() }))
                if store.eventAlertsOn {
                    Stepper("\(store.reminderLead) min before", value: $store.reminderLead, in: 0...120, step: 5)
                    Text("Your calendar app already alerts you for events — turning this on as well means two notifications per event.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Notifications")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
        .sheet(isPresented: $showSetupHelp) { SetupHelp() }
    }

    private var bedtime: Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(store.settings.bedtimeMinutes) * 60) },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                store.updateSettings { $0.bedtimeMinutes = (c.hour ?? 22) * 60 + (c.minute ?? 0) }
            })
    }

    private func setting(_ key: WritableKeyPath<PlannerSettings, Int>) -> Binding<Int> {
        Binding(get: { store.settings[keyPath: key] }, set: { v in store.updateSettings { $0[keyPath: key] = v } })
    }

    @ViewBuilder
    private func accountRow(_ account: GoogleAccount, label: String, scopes: [String]) -> some View {
        AccountRow(account: account, label: label, scopes: scopes, disabled: !GoogleAccount.isConfigured) {
            Task { await store.syncEverything() }
        }
    }
}

private struct AccountRow: View {
    @ObservedObject var account: GoogleAccount
    var label: String
    var scopes: [String]
    var disabled: Bool
    var onSignedIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    Text(account.isSignedIn ? (account.email ?? "Signed in") : "Not signed in")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if account.isWorking {
                    ProgressView().controlSize(.small)
                } else if account.isSignedIn {
                    Button("Sign out", role: .destructive) { account.signOut() }.buttonStyle(TintButtonStyle(kind: .quiet, compact: true))
                } else {
                    Button("Sign in with Google") {
                        Task {
                            await account.signIn(scopes: scopes)
                            if account.isSignedIn { onSignedIn() }
                        }
                    }
                    .buttonStyle(TintButtonStyle(compact: true))
                    .disabled(disabled)
                }
            }
            if disabled && !account.isSignedIn {
                Label("Paste your OAuth client ID under Google setup first — then this button works.", systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(Brand.caution)
            }
            if let err = account.lastError { Text(err).font(.caption).foregroundStyle(.red) }
        }
    }
}

private struct SetupHelp: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Google gives each app its own ID. This takes about 5 minutes, once:").foregroundStyle(.secondary)
                    step(1, "Go to console.cloud.google.com and create a project called “Blob” (free — no billing needed).")
                    step(2, "APIs & Services → Library: enable **Google Classroom API**, **Google Drive API** and **Google Tasks API**.")
                    step(3, "OAuth consent screen (Google Auth Platform): choose **External**, name it Blob, add your email. Under **Audience**, click **Publish app** so you aren't signed out every week.")
                    step(4, "Clients → Create client → type **iOS**, bundle ID **com.arjunsenani.brain**.")
                    step(5, "Copy the client ID (ends in .apps.googleusercontent.com) and give it to Claude to build into Blob — or paste it under Settings → Google → Advanced on each device.")
                    Text("When you sign in, Google may say it hasn't verified the app — that's normal for your own app. Click Advanced → Go to Blob. Your Google calendars don't need any of this; they already work through this device's Google account.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                        .buttonStyle(TintButtonStyle())
                }
                .padding(20)
            }
            .navigationTitle("Google setup")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheetSize(minWidth: 480, minHeight: 520)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).foregroundStyle(Brand.accentText).frame(width: 28, height: 28)
                .background(Brand.accent.opacity(0.2), in: Circle()).overlay(Circle().strokeBorder(Brand.accent.opacity(0.6)))
            Text(text)
        }
    }
}

private struct GoogleCalendarRows: View {
    @EnvironmentObject var store: BrainStore
    @ObservedObject var school: GoogleAccount
    @ObservedObject var personal: GoogleAccount
    var clientMissing: Bool

    var body: some View {
        if let acct = store.calendarAccount {
            LabeledContent("Connected", value: acct.email ?? "Google account")
            Toggle("Show my Google Calendar events", isOn: Binding(
                get: { store.googleCalendarOn }, set: { store.googleCalendarOn = $0; Task { await store.syncGoogle(force: true) } }))
            Toggle("Add my Blob events to Google Calendar", isOn: Binding(
                get: { store.googleEventsPushOn }, set: { store.googleEventsPushOn = $0; Task { await store.syncGoogle() } }))
            Toggle("Assignments as Google Tasks", isOn: Binding(
                get: { store.googleTasksOn }, set: { store.googleTasksOn = $0; Task { await store.syncGoogle() } }))
            Toggle("Put assignment due dates on my Google Calendar", isOn: Binding(
                get: { store.googleDueEventsOn }, set: { store.googleDueEventsOn = $0; Task { await store.syncGoogle() } }))
            Toggle("Put logged work on Google Calendar", isOn: Binding(
                get: { store.googleLogEventsOn }, set: { store.googleLogEventsOn = $0; Task { await store.syncGoogle() } }))
            if store.googleLogEventsOn && !store.googleCanMakeLogCalendar {
                HStack {
                    Text("Logged work goes on your main calendar. Allow Blob to make its own “Blob work log” calendar instead?")
                        .font(.caption).foregroundStyle(Brand.muted)
                    Spacer()
                    Button("Allow") { if let a = store.calendarAccount { Task { await store.connectGoogleCalendar(on: a) } } }
                        .buttonStyle(TintButtonStyle(kind: .glass, compact: true))
                }
            }
            Button {
                Task { await store.syncGoogle(force: true) }
            } label: {
                HStack {
                    Label("Sync Google Calendar now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if store.isSyncingGoogle { ProgressView().controlSize(.small) }
                }
            }
        } else {
            Text(school.isSignedIn || personal.isSignedIn ? "Connect the account whose calendar you use." : "First sign in with Google under Google setup and Google Classroom below.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        ForEach([personal, school].filter { $0.isSignedIn && !$0.hasScope(GoogleAccount.calendarScopes[0]) }, id: \.role) { acct in
            Button {
                Task { await store.connectGoogleCalendar(on: acct) }
            } label: {
                Label("Connect Google Calendar on \(acct.email ?? acct.role.rawValue)", systemImage: "calendar.badge.plus")
            }
            .disabled(clientMissing || acct.isWorking)
            if let e = acct.lastError { Text(e).font(.caption).foregroundStyle(.red) }
        }
        if let err = store.googleCalendarError { Text(err).font(.caption).foregroundStyle(.red) }
    }
}

/// Apple Calendar & Reminders — and through them any calendar account on this device (iCloud, Google, Outlook/Exchange, Yahoo…).
private struct AppleCalendarSection: View {
    @EnvironmentObject var store: BrainStore
    @ObservedObject var systemCalendar: SystemCalendarBridge

    private func calendars(_ type: EKEntityType) -> [EKCalendar] {
        _ = systemCalendar.changeToken
        return AppleSync.writableCalendars(systemCalendar.store, type)
    }

    private func sync() { Task { await store.syncApple() } }

    var body: some View {
        Section {
            Toggle("Show my calendar events in Blob", isOn: Binding(
                get: { store.useAppleCalendar },
                set: { on in store.useAppleCalendar = on; if on { Task { await systemCalendar.requestAccess() } } }))

            // Homework ↔ Reminders (+ due dates on your calendar)
            Toggle("Homework in Reminders & my calendar", isOn: Binding(
                get: { store.appleTasksOn },
                set: { on in
                    store.appleTasksOn = on
                    guard on else { return }
                    Task {
                        await systemCalendar.requestRemindersAccess()
                        await systemCalendar.requestAccess()
                        // Due dates go on your main calendar unless you pick another below.
                        if store.appleDueCalendar.isEmpty, let main = systemCalendar.store.defaultCalendarForNewEvents, main.allowsContentModifications {
                            store.appleDueCalendar = main.calendarIdentifier
                        }
                        await store.syncApple()
                    }
                }))
            if store.appleTasksOn {
                if systemCalendar.remindersAuthorized {
                    Picker("Homework list", selection: Binding(get: { store.appleReminderList }, set: { store.appleReminderList = $0; sync() })) {
                        Text("Homework (made by Blob)").tag("")
                        ForEach(calendars(.reminder).filter { $0.title != AppleSync.homeworkListName }, id: \.calendarIdentifier) { c in
                            Text("\(c.title) · \(c.source.title)").tag(c.calendarIdentifier)
                        }
                    }
                    Picker("Other to-dos (not school)", selection: Binding(get: { store.appleOtherList }, set: { store.appleOtherList = $0; sync() })) {
                        Text("Keep in Blob only").tag("")
                        ForEach(calendars(.reminder).filter { $0.title != AppleSync.homeworkListName && $0.calendarIdentifier != store.appleReminderList }, id: \.calendarIdentifier) { c in
                            Text("\(c.title) · \(c.source.title)").tag(c.calendarIdentifier)
                        }
                    }
                    Toggle("Reminders I add to the Homework list become assignments", isOn: Binding(
                        get: { store.appleImportReminders }, set: { store.appleImportReminders = $0; sync() }))
                    Toggle("Include the steps of long-term assignments", isOn: Binding(
                        get: { store.appleStepsOn }, set: { store.appleStepsOn = $0; sync() }))
                } else {
                    Text("Allow Reminders access in System Settings → Privacy & Security → Reminders.").font(.caption).foregroundStyle(.orange)
                }
            }

            // Due dates → any calendar
            if systemCalendar.authorized {
                Picker("Show due dates on calendar", selection: Binding(get: { store.appleDueCalendar }, set: { store.appleDueCalendar = $0; sync() })) {
                    Text("Off").tag("")
                    ForEach(calendars(.event), id: \.calendarIdentifier) { c in
                        Text("\(c.title) · \(c.source.title)").tag(c.calendarIdentifier)
                    }
                }
            } else {
                Button("Allow calendar access to put due dates on your calendar") { Task { await systemCalendar.requestAccess() } }
            }

            // Blob's events → a calendar
            Toggle("Add Blob's events to my calendar", isOn: Binding(
                get: { store.appleEventsOn },
                set: { on in store.appleEventsOn = on; if on { Task { await systemCalendar.requestAccess(); await store.syncApple() } } }))
            if store.appleEventsOn && systemCalendar.authorized {
                Picker("Put them in", selection: Binding(get: { store.appleEventCalendar }, set: { store.appleEventCalendar = $0; sync() })) {
                    Text("Blob (its own calendar)").tag("")
                    ForEach(calendars(.event).filter { $0.title != AppleSync.calendarName }, id: \.calendarIdentifier) { c in
                        Text("\(c.title) · \(c.source.title)").tag(c.calendarIdentifier)
                    }
                }
            }
            if (store.useAppleCalendar || store.appleEventsOn) && !systemCalendar.authorized {
                Text("Allow calendar access in System Settings → Privacy & Security → Calendars.").font(.caption).foregroundStyle(.orange)
            }
            if let err = store.appleSyncError { Text(err).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Calendars & Reminders")
        } footer: {
            Text("Blob uses context to spot homework — Classroom work, anything with a class, and school words like essay, worksheet, lab, chapter, study for, quiz — and puts it in a “Homework” list in Reminders, with due dates on your calendar. Everyday to-dos (groceries, calls) stay out unless you pick a list for them. Works with every calendar and reminders account on this \(deviceName): iCloud, Google, Outlook/Exchange, Yahoo and more — add accounts in \(accountsPlace). Tick something off in Reminders or Calendar and it's done in Blob. Drag a due date to another day in Calendar to change it. Turn on the same options on your Mac and iPhone — they update the same items, not copies.")
        }
        .onAppear { if store.appleTasksOn || store.appleEventsOn || !store.appleDueCalendar.isEmpty { sync() } }
    }

    private var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }
    private var accountsPlace: String {
        #if os(macOS)
        "System Settings → Internet Accounts"
        #else
        "Settings → Apps → Calendar → Calendar Accounts"
        #endif
    }
}

/// TickTick: homework ↔ a TickTick project (two-way), on the Mac and the iPhone.
private struct TickTickSection: View {
    @EnvironmentObject var store: BrainStore
    @ObservedObject private var account = TickTickAccount.shared
    @AppStorage("tickTickClientID") private var clientID = ""
    @AppStorage("tickTickClientSecret") private var clientSecret = ""
    @State private var project = ""
    @State private var showHelp = false
    @State private var apiToken = ""
    @State private var copied = false

    var body: some View {
        Section {
            if account.isSignedIn {
                HStack(spacing: 10) {
                    Glyph(icon: "checkmark.circle", color: .blue, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("TickTick connected").font(.body.weight(.semibold))
                        Text(store.tickTickRunning ? "Syncing…" : store.lastTickTickSync.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet")
                            .font(.caption).foregroundStyle(Brand.muted)
                    }
                    Spacer()
                    Button("Sync now") { Task { await store.syncTickTick() } }
                        .buttonStyle(TintButtonStyle(kind: .glass, compact: true))
                        .disabled(!store.tickTickOn || store.tickTickRunning)
                }
                Toggle("Sync homework with TickTick", isOn: Binding(
                    get: { store.tickTickOn }, set: { store.tickTickOn = $0; if $0 { Task { await store.syncTickTick() } } }))
                if store.tickTickOn {
                    TextField("TickTick list", text: $project, prompt: Text("Homework"))
                        .onSubmit { store.tickTickProject = project; Task { await store.syncTickTick() } }
                    Toggle("Tag tasks with their class", isOn: Binding(
                        get: { store.tickTickTags }, set: { store.tickTickTags = $0; Task { await store.syncTickTick() } }))
                    Toggle("Tasks I add to that list become assignments", isOn: Binding(
                        get: { store.tickTickImport }, set: { store.tickTickImport = $0 }))
                }
                #if os(macOS)
                Button(copied ? "Copied — paste it into Blob on your iPhone" : "Copy TickTick sign-in for my iPhone") {
                    if let t = account.tokenForOtherDevice {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(t, forType: .string)
                        copied = true
                    }
                }
                #endif
                Button("Disconnect TickTick", role: .destructive) { account.signOut(); store.tickTickOn = false }
            } else {
                HStack {
                    SecureField("TickTick access token", text: $apiToken)
                    Button("Connect") {
                        Task {
                            await account.useToken(apiToken)
                            apiToken = ""
                            if account.isSignedIn { store.tickTickOn = true; await store.syncTickTick() }
                        }
                    }
                    .buttonStyle(TintButtonStyle(compact: true))
                    .disabled(apiToken.isEmpty || account.isWorking)
                }
                #if os(macOS)
                Text("Paste a TickTick API token if your account has one, or connect through a free developer app below.")
                    .font(.caption).foregroundStyle(Brand.muted)
                DisclosureGroup("Connect with a developer app") {
                    TextField("Client ID", text: $clientID)
                    SecureField("Client secret", text: $clientSecret)
                    HStack {
                        Button("How do I get these?") { showHelp = true }
                        Spacer()
                        if account.isWorking { ProgressView().controlSize(.small) }
                        Button("Connect TickTick") {
                            Task {
                                await account.signIn()
                                if account.isSignedIn { store.tickTickOn = true; await store.syncTickTick() }
                            }
                        }
                        .buttonStyle(TintButtonStyle(compact: true))
                        .disabled(clientID.isEmpty || clientSecret.isEmpty || account.isWorking)
                    }
                }
                #else
                Text("Easiest: connect TickTick on your Mac, then Settings → TickTick → **Copy TickTick sign-in for my iPhone**, and paste it here. Or paste a TickTick API token.")
                    .font(.caption).foregroundStyle(Brand.muted)
                #endif
            }
            if let e = account.lastError ?? store.tickTickError { Text(e).font(.caption).foregroundStyle(Brand.stop) }
        } header: {
            Text("TickTick")
        } footer: {
            Text("Homework goes into a TickTick list, tagged with its class, with long-term steps as checklist items and time you've logged in the notes. Complete a task, check a step or move a due date in TickTick and Blob does the same. Tasks you add to the list come into Blob.")
        }
        .onAppear { project = store.tickTickProject == "Homework" ? "" : store.tickTickProject }
        #if os(macOS)
        .sheet(isPresented: $showHelp) { TickTickHelp() }
        #endif
    }
}

#if os(macOS)
private struct TickTickHelp: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect TickTick (2 minutes, once)").font(.title2.bold())
            Text("1. Go to developer.ticktick.com and sign in with your TickTick account.")
            Text("2. Click **Manage Apps** → **+App Name**, call it “Blob”.")
            Text("3. Edit the app and set **OAuth redirect URL** to:")
            HStack {
                Text(TickTickAccount.redirectURI).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(TickTickAccount.redirectURI, forType: .string) }
            }
            Text("4. Copy the **Client ID** and **Client Secret** into Blob, then click **Connect TickTick**.")
            HStack {
                Link("Open developer.ticktick.com", destination: URL(string: "https://developer.ticktick.com/manage")!)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
#endif

/// Pick the one accent that tints the app.
private struct AccentPicker: View {
    @AppStorage("accent") private var accent = AccentChoice.violet.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accent color")
            HStack(spacing: 8) {
                ForEach(AccentChoice.allCases) { c in
                    let on = accent == c.rawValue
                    Button { accent = c.rawValue } label: {
                        Circle().fill(c.color)
                            .frame(width: 26, height: 26)
                            .overlay { if on { Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(.white) } }
                            .padding(3)
                            .overlay(Circle().strokeBorder(on ? Brand.inkStrong : .clear, lineWidth: 2))
                            .frame(maxWidth: .infinity)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.name + (on ? ", selected" : ""))
                    .help(c.name)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Google, the easy way:
/// - Calendar needs no sign-in: Blob uses the Google account already on this Mac/iPhone (System Settings → Internet Accounts).
/// - One "Sign in with Google" button covers Classroom, Google Tasks and Mac ↔ iPhone sync.
/// - The manual client-ID setup and the direct Google Calendar connection live under Advanced.
private struct GoogleSection: View {
    @EnvironmentObject var store: BrainStore
    @ObservedObject var school: GoogleAccount
    @ObservedObject var personal: GoogleAccount
    @ObservedObject var systemCalendar: SystemCalendarBridge
    @Binding var showSetupHelp: Bool
    @AppStorage("googleClientID") private var clientID = ""
    @State private var advanced = false

    /// Google calendars this device already has through its Google account.
    private var googleCalendars: [EKCalendar] {
        _ = systemCalendar.changeToken
        guard systemCalendar.authorized else { return [] }
        return systemCalendar.store.calendars(for: .event).filter {
            $0.source.title.localizedCaseInsensitiveContains("google") || $0.source.title.localizedCaseInsensitiveContains("gmail")
        }
    }

    var body: some View {
        Section {
            // 1. Calendar through the system account.
            let cals = googleCalendars
            if !systemCalendar.authorized {
                Button { Task { await systemCalendar.requestAccess(); store.useAppleCalendar = true } } label: {
                    Label("Allow Blob to see your calendars", systemImage: "calendar.badge.checkmark")
                }
            } else if cals.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No Google account on this \(device) yet.")
                    Text(addAccountHint).font(.caption).foregroundStyle(.secondary)
                    #if os(macOS)
                    Button("Add a Google account…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                    }
                    .buttonStyle(TintButtonStyle(kind: .primary, compact: true))
                    #endif
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Google Calendar is connected")
                        Text("Through this \(device)'s Google account · " + cals.map(\.title).sorted().joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Show these calendars in Blob", isOn: Binding(get: { store.useAppleCalendar }, set: { store.useAppleCalendar = $0 }))
            }

            // 2. One sign-in for the rest.
            if school.isSignedIn {
                HStack {
                    Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(school.email ?? "Signed in with Google")
                        Text("Classroom, Google Tasks and Mac ↔ iPhone sync").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign out", role: .destructive) { school.signOut() }.buttonStyle(TintButtonStyle(kind: .glass, compact: true))
                }
                Toggle("Assignments as Google Tasks", isOn: Binding(get: { store.googleTasksOn }, set: { store.googleTasksOn = $0; Task { await store.syncGoogle() } }))
            } else if GoogleAccount.isConfigured {
                Button {
                    Task {
                        await school.signIn(scopes: GoogleAccount.classroomScopes + [GoogleAccount.driveScope, GoogleAccount.tasksScope])
                        if school.isSignedIn { await store.syncEverything() }
                    }
                } label: {
                    HStack(spacing: 10) {
                        GoogleG()
                        Text("Sign in with Google").fontWeight(.semibold)
                        Spacer()
                        if school.isWorking { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                if let e = school.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in with Google needs a one-time setup").fontWeight(.semibold)
                    Text("Only for Classroom, Google Tasks and Mac ↔ iPhone sync — your Google calendars already work above.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show me how (5 minutes)") { showSetupHelp = true }
                        .buttonStyle(TintButtonStyle(kind: .glass, compact: true))
                }
            }

            DisclosureGroup("Advanced", isExpanded: $advanced) {
                TextField("Google OAuth client ID", text: $clientID, prompt: Text(GoogleAccount.hasBuiltInClientID ? "Using Blob's built-in ID" : "1234-abc.apps.googleusercontent.com"))
                    .font(.system(.footnote, design: .monospaced))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Text("Google Calendar can also be connected directly (instead of through this \(device)'s account) — only needed for a Google calendar that isn't on this device.")
                    .font(.caption).foregroundStyle(.secondary)
                GoogleCalendarRows(school: school, personal: personal, clientMissing: !GoogleAccount.isConfigured)
            }
        } header: {
            Text("Google")
        } footer: {
            Text("Free. Calendar uses the Google account already on this \(device). Sign in once for Classroom, Google Tasks and syncing your Mac and iPhone.")
        }
    }

    private var device: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }
    private var addAccountHint: String {
        #if os(macOS)
        "Add it in System Settings → Internet Accounts → Google, with Calendars turned on. Blob picks it up right away."
        #else
        "Add it in Settings → Apps → Calendar → Calendar Accounts → Add Account → Google. Blob picks it up right away."
        #endif
    }
}

/// The Google "G", drawn (no image asset needed).
private struct GoogleG: View {
    var body: some View {
        Text("G").font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(LinearGradient(colors: [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.92, green: 0.26, blue: 0.21),
                                                     Color(red: 0.98, green: 0.74, blue: 0.02), Color(red: 0.20, green: 0.66, blue: 0.33)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 28, height: 28)
            .background(Brand.card, in: Circle())
            .overlay(Circle().strokeBorder(Brand.hairline))
    }
}
