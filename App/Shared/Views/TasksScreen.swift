import SwiftUI
import Charts
import BrainCore

struct TasksScreen: View {
    @EnvironmentObject var store: BrainStore
    @ObservedObject var school: GoogleAccount
    enum Mode: String, CaseIterable, Identifiable { case upcoming = "Upcoming", longTerm = "Long-term", classes = "Classes", done = "Done"; var id: String { rawValue } }
    @AppStorage("assignmentsMode") private var mode: Mode = .upcoming
    @State private var editing: BrainTask?
    @State private var detail: UUID?
    private var showDone: Bool { mode == .done }

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
            if mode == .longTerm {
                LongTermSection(open: { detail = $0 })
            } else if mode == .classes {
                ClassesSection(open: { detail = $0 })
            } else {
            if groups.isEmpty {
                EmptyHint(icon: "checkmark.seal.fill", text: showDone ? "Nothing completed yet." : "All caught up!")
                    .listRowBackground(Color.clear)
            }
            ForEach(groups) { g in
                Section {
                    ForEach(g.tasks) { t in
                        TaskRow(task: t)
                            .contentShape(Rectangle())
                            .onTapGesture { detail = t.id }
                            .contextMenu {
                                Button("Open") { detail = t.id }
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
        .sheet(item: Binding(get: { detail.map(IDBox.init) }, set: { detail = $0?.id })) { AssignmentDetail(taskID: $0.id) }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
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

struct IDBox: Identifiable { let id: UUID }

// MARK: - Long-term tracker

/// Big assignments over weeks: how far along each is, whether you're on pace, what's next, and the workload ahead.
struct LongTermSection: View {
    @EnvironmentObject var store: BrainStore
    var open: (UUID) -> Void

    private var items: [BrainTask] {
        store.pendingTasks.filter(\.isLongTerm).sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    var body: some View {
        Section {
            WorkloadChart(tasks: store.pendingTasks)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        Section {
            if items.isEmpty {
                EmptyHint(icon: "chart.line.uptrend.xyaxis",
                          text: "No long-term assignments. Add one like “history project due nov 20 long-term” — it gets steps with dates automatically.")
                    .listRowBackground(Color.clear)
            }
            ForEach(items) { t in
                LongTermRow(task: t)
                    .contentShape(Rectangle())
                    .onTapGesture { open(t.id) }
                    .contextMenu {
                        Button("Open") { open(t.id) }
                        Button("Stop tracking long-term") { var c = t; c.milestones = []; c.estimatedMinutes = min(c.estimatedMinutes, 90); store.upsert(c) }
                    }
            }
        } header: {
            HStack {
                Text("In progress")
                Spacer()
                Text(Scheduler.durationText(items.reduce(0) { $0 + $1.remainingMinutes }) + " left")
            }
            .font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
        }
    }
}

struct LongTermRow: View {
    var task: BrainTask

    var body: some View {
        let pace = task.pace()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title).font(.body.weight(.semibold)).lineLimit(2)
                Spacer()
                Chip(text: pace.label, icon: pace.icon, color: pace.color)
            }
            ProgressBar(progress: task.progress, color: pace.color, expected: task.expectedProgress())
            HStack(spacing: 6) {
                if let c = task.course { Chip(text: c, color: Brand.color(for: c)) }
                if let d = task.due { Chip(text: "Due " + d.dueText(includeTime: false), icon: "flag", color: .orange) }
                Text("\(Int(task.progress * 100))%").font(.caption.weight(.bold).monospacedDigit())
                if let need = task.minutesPerDayNeeded() { Text("· \(Scheduler.durationText(need))/day").font(.caption).foregroundStyle(.secondary) }
            }
            if let m = task.nextMilestone {
                let late = (m.due ?? .distantFuture) < Date()
                Label {
                    Text("Next: \(m.title)") + Text(m.due.map { " · by " + $0.dueText(includeTime: false) } ?? "").foregroundColor(late ? .red : .secondary)
                } icon: { Image(systemName: "arrow.turn.down.right") }
                .font(.caption)
            }
            if !task.milestones.isEmpty {
                HStack(spacing: 3) {
                    ForEach(task.milestones) { m in
                        Capsule().fill(m.isDone ? pace.color : Color.secondary.opacity(0.2)).frame(height: 4)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Minutes of work per day for the next two weeks, if everything is spread out evenly.
struct WorkloadChart: View {
    @EnvironmentObject var store: BrainStore
    var tasks: [BrainTask]

    var body: some View {
        let days = Workload.perDay(tasks, days: 14)
        let target = store.settings.dailyWorkTargetMinutes
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Next 2 weeks").font(.headline)
                Spacer()
                let heavy = days.filter { $0.minutes > target }.count
                Text(heavy == 0 ? "Fits your daily goal" : "\(heavy) heavy day\(heavy == 1 ? "" : "s") — start early")
                    .font(.caption.weight(.semibold)).foregroundStyle(heavy == 0 ? .green : .orange)
            }
            Chart {
                ForEach(days, id: \.day) { d in
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Minutes", d.minutes))
                        .foregroundStyle(d.minutes > target ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Brand.gradient))
                        .cornerRadius(4)
                }
                RuleMark(y: .value("Goal", target))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
            .chartYAxis {
                AxisMarks { v in
                    AxisGridLine()
                    AxisValueLabel { if let m = v.as(Int.self) { Text(Scheduler.durationText(m)) } }
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow).day()) } }
            .frame(height: 140)
        }
        .card(padding: 14)
    }
}

// MARK: - Per class

struct ClassesSection: View {
    @EnvironmentObject var store: BrainStore
    var open: (UUID) -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        let summaries = CourseSummary.build(store.tasks)
        if summaries.isEmpty {
            EmptyHint(icon: "graduationcap", text: "Classes show up here once you have assignments.").listRowBackground(Color.clear)
        }
        ForEach(summaries) { c in
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(Brand.color(for: c.name)).frame(width: 10, height: 10)
                        Text(c.name).font(.headline)
                        Spacer()
                        if let g = c.averageGrade {
                            Text("\(Int(g.rounded()))%").font(.title3.weight(.bold).monospacedDigit())
                                .foregroundStyle(g >= 90 ? .green : g >= 80 ? .blue : g >= 70 ? .orange : .red)
                        }
                    }
                    HStack(spacing: 6) {
                        Chip(text: "\(c.openCount) open", icon: "tray", color: .blue)
                        if c.overdueCount > 0 { Chip(text: "\(c.overdueCount) overdue", icon: "exclamationmark.triangle.fill", color: .red) }
                        if c.longTermCount > 0 { Chip(text: "\(c.longTermCount) long-term", icon: "chart.line.uptrend.xyaxis", color: .teal) }
                        Chip(text: "\(c.completedCount) done", icon: "checkmark", color: .green)
                    }
                    HStack(spacing: 16) {
                        if c.remainingMinutes > 0 { Text("~\(Scheduler.durationText(c.remainingMinutes)) of work left") }
                        if c.loggedMinutes > 0 { Text("\(Scheduler.durationText(c.loggedMinutes)) logged") }
                        if let d = c.nextDue { Text("next due \(d.dueText(includeTime: false))") }
                        if c.gradedCount > 0 { Text("\(c.gradedCount) graded") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { if expanded.contains(c.name) { expanded.remove(c.name) } else { expanded.insert(c.name) } }

                if expanded.contains(c.name) {
                    let ts = store.tasks.filter { ($0.course ?? "Other") == c.name || (c.name == "Other" && ($0.course ?? "").isEmpty) }
                        .sorted { ($0.isCompleted ? 1 : 0, $0.due ?? .distantFuture) < ($1.isCompleted ? 1 : 0, $1.due ?? .distantFuture) }
                    ForEach(ts) { t in
                        HStack {
                            Image(systemName: t.isCompleted ? "checkmark.circle.fill" : "circle").foregroundStyle(t.isCompleted ? .green : .secondary)
                            Text(t.title).lineLimit(1)
                            Spacer()
                            if let p = t.percentGrade { Text("\(BrainStore.fmt(t.pointsEarned ?? 0))/\(BrainStore.fmt(t.maxPoints ?? 0)) · \(Int(p.rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            else if let d = t.due { Text(d.dueText(includeTime: false)).font(.caption).foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { open(t.id) }
                    }
                }
            }
        }
    }
}
