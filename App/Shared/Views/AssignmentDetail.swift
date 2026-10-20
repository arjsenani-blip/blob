import SwiftUI
import BrainCore

extension Pace {
    var color: Color {
        switch self {
        case .done: return .green
        case .ahead: return .teal
        case .onTrack: return .blue
        case .behind: return .orange
        case .atRisk, .overdue: return .red
        case .notStarted: return .secondary
        }
    }
    var icon: String {
        switch self {
        case .done: return "checkmark.seal.fill"
        case .ahead: return "hare.fill"
        case .onTrack: return "checkmark.circle"
        case .behind: return "tortoise.fill"
        case .atRisk: return "exclamationmark.triangle.fill"
        case .overdue: return "exclamationmark.octagon.fill"
        case .notStarted: return "circle.dashed"
        }
    }
}

struct ProgressRing: View {
    var progress: Double
    var color: Color
    var size: CGFloat = 54
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: size * 0.12)
            Circle().trim(from: 0, to: max(0.001, progress))
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))%").font(.system(size: size * 0.26, weight: .bold, design: .rounded))
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.4), value: progress)
    }
}

struct ProgressBar: View {
    var progress: Double
    var color: Color
    /// Where you'd be if the work were spread evenly (a small tick).
    var expected: Double?
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule().fill(color).frame(width: max(6, g.size.width * progress))
                if let e = expected, e > 0.02, e < 0.99 {
                    Rectangle().fill(.primary.opacity(0.45)).frame(width: 2, height: g.size.height + 4).offset(x: g.size.width * e - 1)
                }
            }
        }
        .frame(height: 7)
        .animation(.spring(duration: 0.4), value: progress)
    }
}

/// Everything about one assignment over time: steps, time logged, pace, grade.
struct AssignmentDetail: View {
    @EnvironmentObject var store: BrainStore
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    @State private var logText = ""
    @State private var editing: BrainTask?
    @State private var newStep = ""
    @State private var earned = ""
    @State private var possible = ""

    private var task: BrainTask? { store.task(taskID) }

    var body: some View {
        NavigationStack {
            if let t = task {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(t)
                        quickLog(t)
                        steps(t)
                        grade(t)
                        history(t)
                    }
                    .padding(20)
                }
                .background(Brand.canvas)
                .navigationTitle(t.course ?? "Assignment")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = t } }
                }
                .sheet(item: $editing) { TaskEditor(task: $0) }
                .onAppear {
                    earned = t.pointsEarned.map(BrainStore.fmt) ?? ""
                    possible = t.maxPoints.map(BrainStore.fmt) ?? ""
                }
            } else {
                Text("This assignment was deleted.").foregroundStyle(.secondary).padding()
            }
        }
        .frame(minWidth: 520, minHeight: 640)
    }

    // MARK: Sections

    private func header(_ t: BrainTask) -> some View {
        let pace = t.pace()
        return HStack(alignment: .top, spacing: 16) {
            ProgressRing(progress: t.progress, color: pace.color, size: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(t.title).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Chip(text: pace.label, icon: pace.icon, color: pace.color)
                    if let d = t.due { Chip(text: "Due " + d.dueText(), icon: "flag.fill", color: .orange) }
                    if t.isLate { Chip(text: "Late", icon: "clock.badge.exclamationmark", color: .red) }
                }
                HStack(spacing: 14) {
                    stat("Logged", Scheduler.durationText(t.loggedMinutes))
                    stat("Left", t.isCompleted ? "—" : "~" + Scheduler.durationText(t.remainingMinutes))
                    if let need = t.minutesPerDayNeeded(), !t.isCompleted { stat("Per day", Scheduler.durationText(need)) }
                }
                if let link = t.link, let url = URL(string: link) {
                    Button { Platform.open(url) } label: { Label("Open in Classroom", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.borderless).font(.subheadline)
                }
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func quickLog(_ t: BrainTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Log work").font(.headline)
            HStack(spacing: 8) {
                ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                    Button("+" + Scheduler.durationText(m)) { log(minutes: m, t) }
                        .buttonStyle(.bordered).tint(Brand.violet)
                }
                Spacer()
                if !t.isCompleted {
                    Button { var c = t; store.markDone(&c); store.upsert(c) } label: { Label("Done", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent).tint(.green)
                }
            }
            HStack {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                TextField("Or say it: “worked 40 min, wrote the intro” · “finished the outline” · “60% done”", text: $logText)
                    .textFieldStyle(.plain)
                    .onSubmit { submitLog(t) }
            }
            .padding(10)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
        .card()
    }

    private func steps(_ t: BrainTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Steps").font(.headline)
                Spacer()
                Button(t.milestones.isEmpty ? "Suggest steps" : "Re-plan steps") {
                    var c = t
                    store.planSteps(&c)
                    store.upsert(c)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            if t.milestones.isEmpty {
                Text("Break it into steps with their own dates so it moves forward a bit at a time. The check-in planner then works on one step at a time.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(t.milestones) { m in
                StepRow(task: t, step: m)
                if m.id != t.milestones.last?.id { Divider().padding(.leading, 34) }
            }
            HStack {
                Image(systemName: "plus.circle").foregroundStyle(Brand.violet)
                TextField("Add a step", text: $newStep).textFieldStyle(.plain)
                    .onSubmit {
                        guard !newStep.trimmingCharacters(in: .whitespaces).isEmpty, var c = task else { return }
                        let last = c.milestones.last?.due ?? Date()
                        c.milestones.append(Milestone(title: newStep, due: min(c.due ?? .distantFuture, last.addingTimeInterval(86_400)), estimatedMinutes: 30))
                        store.upsert(c)
                        newStep = ""
                    }
            }
        }
        .card()
    }

    private func grade(_ t: BrainTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Grade").font(.headline)
                Spacer()
                if let p = t.percentGrade { Chip(text: "\(Int(p.rounded()))%", icon: "rosette", color: p >= 90 ? .green : p >= 80 ? .blue : p >= 70 ? .orange : .red) }
            }
            HStack(spacing: 8) {
                TextField("Points", text: $earned).frame(width: 70)
                Text("/")
                TextField("Out of", text: $possible).frame(width: 70)
                Button("Save") {
                    guard var c = task, let e = Double(earned) else { return }
                    c.pointsEarned = e
                    c.maxPoints = Double(possible) ?? c.maxPoints ?? 100
                    store.upsert(c)
                    store.show("Grade saved")
                }
                .buttonStyle(.bordered)
                if t.source == .classroom { Text("Classroom fills this in when it's returned.").font(.caption).foregroundStyle(.secondary) }
            }
            .textFieldStyle(.roundedBorder)
        }
        .card()
    }

    private func history(_ t: BrainTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Work log").font(.headline)
            if t.sessions.isEmpty {
                Text("Nothing logged yet. Time from the check-in timeline lands here automatically.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(t.sessions.sorted { $0.date > $1.date }) { s in
                HStack(alignment: .firstTextBaseline) {
                    Text(s.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).font(.subheadline.monospacedDigit()).frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        if s.minutes > 0 { Text(Scheduler.durationText(s.minutes)).font(.subheadline.weight(.semibold)) }
                        if let step = s.milestoneID.flatMap({ id in t.milestones.first { $0.id == id } }) {
                            Text(step.title).font(.caption).foregroundStyle(.secondary)
                        }
                        if let n = s.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button { var c = t; c.sessions.removeAll { $0.id == s.id }; c.actualMinutes = c.sessions.reduce(0) { $0 + $1.minutes }; store.upsert(c) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
            }
        }
        .card()
    }

    // MARK: Actions

    private func log(minutes: Int, _ t: BrainTask) {
        var c = t
        store.logWork(&c, minutes: minutes, note: nil, milestoneID: c.nextMilestone?.id)
        store.upsert(c)
        store.show("Logged \(Scheduler.durationText(minutes)) · \(Int(c.progress * 100))% done")
    }

    /// Free text about this assignment: understood like everywhere else, but always applied to this one.
    private func submitLog(_ t: BrainTask) {
        let text = logText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        var c = t
        let parser = ProgressLogParser()
        let intent = parser.parse(text) ?? parser.parse("worked " + text) ?? parser.parse("finished " + text)
        switch intent {
        case .worked(let m, _, let note)?:
            store.logWork(&c, minutes: m, note: note, milestoneID: c.nextMilestone?.id)
        case .finishedStep(let step, _)?:
            if let m = TaskMatcher.step(step, in: c) { store.finishStep(&c, m.id) } else { store.logWork(&c, minutes: 0, note: "Finished \(step)", milestoneID: nil) }
        case .completed(let what)?:
            // "finished the outline" here means that step, when there is one by that name.
            if !c.milestones.isEmpty, let m = TaskMatcher.step(what, in: c), TaskMatcher.overlap(TaskMatcher.words(what), m.title) > 0 {
                store.finishStep(&c, m.id)
            } else {
                store.markDone(&c)
            }
        case .progress(let p, _)?: store.setProgress(&c, percent: p)
        case .grade(let e, let p, _)?: c.pointsEarned = e; c.maxPoints = p
        case .started?: c.startDate = c.startDate ?? Date()
        case .planSteps?: store.planSteps(&c)
        default:
            store.logWork(&c, minutes: 0, note: text, milestoneID: nil)
        }
        store.upsert(c)
        logText = ""
    }
}

private struct StepRow: View {
    @EnvironmentObject var store: BrainStore
    var task: BrainTask
    var step: Milestone
    @State private var title = ""

    private var late: Bool { !step.isDone && (step.due ?? .distantFuture) < Date() }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                var c = task
                if step.isDone {
                    if let i = c.milestones.firstIndex(where: { $0.id == step.id }) { c.milestones[i].isDone = false; c.milestones[i].doneAt = nil }
                    c.isCompleted = false; c.completedAt = nil
                } else {
                    store.finishStep(&c, step.id)
                }
                withAnimation { store.upsert(c) }
            } label: {
                Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(step.isDone ? Color.green : (late ? .red : Brand.violet))
            }
            .buttonStyle(.plain)
            TextField("Step", text: $title)
                .textFieldStyle(.plain)
                .strikethrough(step.isDone)
                .foregroundStyle(step.isDone ? .secondary : .primary)
                .onSubmit { update { $0.title = title } }
            Spacer()
            Text(Scheduler.durationText(step.estimatedMinutes)).font(.caption).foregroundStyle(.secondary)
            DatePicker("", selection: Binding(get: { step.due ?? Date() }, set: { d in update { $0.due = d } }), displayedComponents: .date)
                .labelsHidden()
                .foregroundStyle(late ? .red : .primary)
            Button { var c = task; c.milestones.removeAll { $0.id == step.id }; store.upsert(c) } label: {
                Image(systemName: "trash").foregroundStyle(.tertiary)
            }.buttonStyle(.plain)
        }
        .onAppear { title = step.title }
    }

    private func update(_ change: (inout Milestone) -> Void) {
        var c = task
        guard let i = c.milestones.firstIndex(where: { $0.id == step.id }) else { return }
        change(&c.milestones[i])
        store.upsert(c)
    }
}
