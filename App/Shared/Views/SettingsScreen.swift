import SwiftUI
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
            } header: { Text("You") }

            #if os(macOS)
            BuddySettingsSection()
            #endif

            Section {
                TextField("OAuth client ID", text: $clientID, prompt: Text("1234-abc.apps.googleusercontent.com"))
                    .font(.system(.body, design: .monospaced))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Button("How do I get this?") { showSetupHelp = true }
            } header: {
                Text("Google setup (one time)")
            } footer: {
                Text("Use the same client ID on your Mac and iPhone so they share the same sync folder.")
            }

            Section {
                accountRow(school, label: "School account",
                           scopes: GoogleAccount.classroomScopes + [GoogleAccount.driveScope])
                if school.isSignedIn {
                    Button {
                        Task { await store.syncClassroom() }
                    } label: {
                        HStack {
                            Label("Sync Classroom now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if store.isSyncingClassroom { ProgressView().controlSize(.small) }
                        }
                    }
                    if let err = store.classroomError { Text(err).font(.caption).foregroundStyle(.red) }
                }
            } header: {
                Text("Google Classroom")
            } footer: {
                Text("Read-only. Pulls assignments from your active classes, their due dates, and whether you've turned them in.")
            }

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

            Section {
                Toggle("Show Apple Calendar events", isOn: Binding(
                    get: { store.useAppleCalendar },
                    set: { on in
                        store.useAppleCalendar = on
                        if on { Task { await systemCalendar.requestAccess() } }
                    }))
                if store.useAppleCalendar && !systemCalendar.authorized {
                    Text("Allow calendar access in System Settings → Privacy & Security → Calendars.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Reminders", isOn: Binding(
                    get: { store.remindersOn },
                    set: { on in
                        store.remindersOn = on
                        if on { Task { _ = await Reminders.requestAuthorization(); store.rescheduleReminders() } }
                        else { Reminders.reschedule(events: [], blocks: [], leadMinutes: 0) }
                    }))
                if store.remindersOn {
                    Stepper("Remind me \(store.reminderLead) min before events", value: $store.reminderLead, in: 0...120, step: 5)
                }
            } header: {
                Text("Calendar & notifications")
            } footer: {
                Text("Apple Calendar includes any Google or iCloud calendars you've added to this device. They're shown read-only and the planner works around them.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Brand.canvas)
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
        AccountRow(account: account, label: label, scopes: scopes, disabled: clientID.isEmpty) {
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
                    Button("Sign out", role: .destructive) { account.signOut() }.buttonStyle(.bordered)
                } else {
                    Button("Sign in with Google") {
                        Task {
                            await account.signIn(scopes: scopes)
                            if account.isSignedIn { onSignedIn() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.violet)
                    .disabled(disabled)
                }
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
                    step(1, "Go to console.cloud.google.com and create a project called “Blob”.")
                    step(2, "APIs & Services → Library: enable **Google Classroom API** and **Google Drive API**.")
                    step(3, "OAuth consent screen: choose **External**, fill in the app name and your email. Under **Test users**, add your school email and your personal Gmail.")
                    step(4, "Credentials → Create credentials → OAuth client ID → type **iOS**. Bundle ID: **com.arjunsenani.brain**.")
                    step(5, "Copy the client ID (ends in .apps.googleusercontent.com) and paste it here on both your Mac and iPhone.")
                    Text("If signing in with your school account says it's blocked, your school's Google admin restricts outside apps. Ask IT to allow it, or use a personal Gmail for sync — Classroom needs the school account.")
                        .font(.footnote).foregroundStyle(.orange)
                    Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                        .buttonStyle(GradientButtonStyle())
                }
                .padding(20)
            }
            .navigationTitle("Google setup")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).foregroundStyle(.white).frame(width: 28, height: 28).background(Brand.gradient, in: Circle())
            Text(text)
        }
    }
}
