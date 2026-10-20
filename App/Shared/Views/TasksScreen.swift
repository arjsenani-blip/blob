import SwiftUI
import BrainCore

struct TasksScreen: View {
    @EnvironmentObject var store: BrainStore
    @ObservedObject var school: GoogleAccount
    @State private var showDone = false
    @State private var editing: BrainTask?

    private struct Group: Identifiable { let id: String; let tasks: [BrainTask] }

    private var groups: [Group] {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let dayAfter = cal.date(byAdding: .day, value: 2, to: today)!
        let week = cal.date(byAdding: .day, value: 7, to: today)!
        if showDone {
            let done = store.tasks.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            return [Group(id: "Completed", tasks: done)]
        }
        let open = store.pendingTasks.sorted { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
        let buckets: [(String, (BrainTask) -> Bool)] = [
            ("Overdue", { $0.due.map { $0 < now } ?? false }),
            ("Today", { $0.due.map { $0 >= now && $0 < tomorrow } ?? false }),
            ("Tomorrow", { $0.due.map { $0 >= tomorrow && $0 < dayAfter } ?? false }),
            ("This week", { $0.due.map { $0 >= dayAfter && $0 < week } ?? false }),
            ("Later", { $0.due.map { $0 >= week } ?? false }),
            ("No due date", { $0.due == nil }),
        ]
        return buckets.map { name, test in Group(id: name, tasks: open.filter(test)) }.filter { !$0.tasks.isEmpty }
    }

    var body: some View {
        List {
            Section {
                QuickAddBar()
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                classroomStatus
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if groups.isEmpty {
                EmptyHint(icon: "checkmark.seal.fill", text: showDone ? "Nothing completed yet." : "All caught up!")
                    .listRowBackground(Color.clear)
            }
            ForEach(groups) { g in
                Section {
                    ForEach(g.tasks) { t in
                        TaskRow(task: t)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = t }
                            .contextMenu {
                                Button("Edit") { editing = t }
                                if let link = t.link, let url = URL(string: link) {
                                    Button("Open in Classroom") { Platform.open(url) }
                                }
                                Button("Delete", role: .destructive) { store.delete(t) }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { store.delete(t) }
                            }
                    }
                } header: {
                    HStack {
                        Text(g.id)
                        Spacer()
                        Text(Scheduler.durationText(g.tasks.reduce(0) { $0 + $1.estimatedMinutes }))
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(g.id == "Overdue" ? .red : .secondary)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(Brand.canvas)
        .navigationTitle("Assignments")
        .sheet(item: $editing) { TaskEditor(task: $0) }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $showDone) {
                    Text("Upcoming").tag(false)
                    Text("Done").tag(true)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button {
                    editing = BrainTask(title: "")
                } label: { Label("New to-do", systemImage: "plus") }
            }
        }
        .refreshable { await store.syncClassroom(); await store.syncDevices() }
    }

    @ViewBuilder
    private var classroomStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: "graduationcap.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                if school.isSignedIn {
                    Text("Google Classroom").font(.subheadline.weight(.semibold))
                    Text(store.classroomError ?? (store.lastClassroomSync.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet"))
                        .font(.caption)
                        .foregroundStyle(store.classroomError == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                } else {
                    Text("Connect Google Classroom in Settings to pull in assignments.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if school.isSignedIn {
                if store.isSyncingClassroom { ProgressView().controlSize(.small) }
                else {
                    Button("Sync") { Task { await store.syncClassroom() } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .card(padding: 12)
    }
}
