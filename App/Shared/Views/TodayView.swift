import SwiftUI
import BrainCore

struct TodayView: View {
    @EnvironmentObject var store: BrainStore
    @State private var editingTask: BrainTask?
    @State private var editingEvent: BrainEvent?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                LogComposer()
                dueSoon
                if let plan = store.todayPlan {
                    PlanTimeline(plan: plan, onTapTask: { editingTask = $0 })
                } else {
                    checkInCard
                }
                agenda
                loggedToday
                longTerm
            }
            .padding(24)
            .page()
        }
        .navigationTitle("Today")
        .sheet(item: $editingTask) { AssignmentDetail(taskID: $0.id) }
        .sheet(item: $editingEvent) { EventEditor(event: $0) }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 4..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Late night"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Overline(text: Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
            Text("\(greeting), \(store.displayName)").screenTitle()
            HStack(spacing: 8) {
                let dueToday = store.pendingTasks.filter { $0.due.map { $0 < Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400) } ?? false }.count
                Chip(text: "\(Scheduler.durationText(store.minutesToday)) logged today", icon: "square.and.pencil", color: Brand.accent)
                if store.streak > 1 { Chip(text: "\(store.streak)-day streak", icon: "flame.fill", color: .orange) }
                Chip(text: dueToday == 0 ? "Nothing due today" : "\(dueToday) due today", icon: "flag.fill", color: dueToday > 0 ? .orange : Brand.ok)
                Chip(text: "\(store.pendingTasks.count) open", icon: "checklist", color: .blue)
            }
        }
    }

    /// What's due in the next three days, with one-tap timer and log.
    @ViewBuilder
    private var dueSoon: some View {
        let limit = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3 * 86_400)
        let items = store.pendingTasks.filter { ($0.due ?? .distantFuture) < limit }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Due soon", trailing: Scheduler.durationText(items.reduce(0) { $0 + $1.remainingMinutes }) + " of work")
                VStack(spacing: 0) {
                    ForEach(items) { t in
                        TaskRow(task: t, showActions: true).contentShape(Rectangle()).onTapGesture { editingTask = t }
                        if t.id != items.last?.id { Divider().padding(.leading, 40) }
                    }
                }
                .card(padding: 12)
            }
        }
    }

    @ViewBuilder
    private var loggedToday: some View {
        let work = store.recentWork(since: Calendar.current.startOfDay(for: Date()))
        if !work.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Logged today", trailing: Scheduler.durationText(store.minutesToday))
                VStack(spacing: 0) {
                    ForEach(work) { w in
                        LoggedRow(work: w).contentShape(Rectangle()).onTapGesture { editingTask = w.task }
                            .contextMenu { Button("Delete entry", role: .destructive) { store.deleteSession(w) } }
                        if w.id != work.last?.id { Divider().padding(.leading, 44) }
                    }
                }
                .card(padding: 12, bloom: false)
            }
        }
    }

    /// The big assignments, so they're never out of sight.
    @ViewBuilder
    private var longTerm: some View {
        let items = store.pendingTasks.filter(\.isLongTerm).sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(3)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Long-term", trailing: "\(items.count) in progress")
                VStack(spacing: 0) {
                    ForEach(Array(items)) { t in
                        LongTermRow(task: t).contentShape(Rectangle()).onTapGesture { editingTask = t }
                        if t.id != items.last?.id { Divider() }
                    }
                }
                .card(padding: 12, bloom: false)
            }
        }
    }

    private var checkInCard: some View {
        HStack(spacing: 14) {
            Glyph(icon: "list.bullet.below.rectangle", size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Plan the rest of today").font(.headline).foregroundStyle(Brand.inkStrong)
                Text("Lines up your assignments around your events, with breaks, done by bedtime.")
                    .font(.subheadline).foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(.spring) { store.checkIn() }
            } label: {
                Label("Check in", systemImage: "play.fill")
            }
            .buttonStyle(TintButtonStyle())
            .keyboardShortcut("i", modifiers: .command)
        }
        .card(padding: 18, bloom: false)
    }

    private var agenda: some View {
        let occ = store.occurrences(on: Date())
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "On the calendar")
            VStack(alignment: .leading, spacing: 0) {
                if occ.isEmpty {
                    EmptyHint(icon: "sun.max", text: "Nothing scheduled today.")
                }
                ForEach(occ) { o in
                    OccurrenceRow(occurrence: o)
                        .contentShape(Rectangle())
                        .onTapGesture { editingEvent = store.event(o.eventID) }
                    if o.id != occ.last?.id { Divider().padding(.leading, 70) }
                }
            }
            .card(padding: 12, bloom: false)
        }
    }
}

// MARK: - Timeline

struct PlanTimeline: View {
    @EnvironmentObject var store: BrainStore
    var plan: DayPlan
    var onTapTask: (BrainTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today's plan").font(.title3.weight(.bold)).tracking(-0.3).foregroundStyle(Brand.inkStrong)
                    Text(plan.summary).font(.subheadline).foregroundStyle(Brand.muted)
                }
                Spacer()
                Button {
                    withAnimation(.spring) { store.checkIn() }
                } label: {
                    Label("Re-plan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(TintButtonStyle(kind: .glass, compact: true))
            }
            Label(plan.strategy, systemImage: "lightbulb.fill")
                .font(.footnote)
                .foregroundStyle(Brand.muted)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            TimelineView(.everyMinute) { ctx in
                VStack(spacing: 0) {
                    if plan.blocks.isEmpty {
                        EmptyHint(icon: "party.popper", text: "Nothing to do. Go have fun.")
                    }
                    ForEach(plan.blocks) { block in
                        BlockRow(block: block, now: ctx.date, isLast: block.id == plan.blocks.last?.id, onTapTask: onTapTask)
                    }
                }
            }
            .card(padding: 14)

            let overflow = plan.overflowTaskIDs.compactMap { store.task($0) }.filter { !$0.isCompleted }
            if !overflow.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Didn't fit before bedtime", systemImage: "moon.zzz.fill")
                        .font(.headline)
                        .foregroundStyle(Brand.caution)
                    ForEach(overflow) { t in
                        TaskRow(task: t).contentShape(Rectangle()).onTapGesture { onTapTask(t) }
                    }
                    Text("Tip: start these first thing tomorrow, or ask for an extension.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .card()
            }
        }
    }
}

struct BlockRow: View {
    @EnvironmentObject var store: BrainStore
    var block: PlanBlock
    var now: Date
    var isLast: Bool
    var onTapTask: (BrainTask) -> Void

    private var done: Bool { store.isBlockDone(block) }
    private var isNow: Bool { block.start <= now && now < block.end && !done }
    private var color: Color {
        switch block.kind {
        case .task: return Brand.color(for: block.subtitle ?? block.title)
        case .event: return .gray
        case .breakTime: return .teal
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(block.start.shortTime)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(isNow ? Brand.violet : .secondary)
                .frame(width: 62, alignment: .trailing)
                .padding(.top, 2)

            VStack(spacing: 0) {
                Circle()
                    .fill(done ? Brand.ok : color)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Brand.card, lineWidth: 2))
                    .overlay {
                        if isNow { Circle().stroke(Brand.violet.opacity(0.4), lineWidth: 6) }
                    }
                    .padding(.top, 3)
                if !isLast {
                    Rectangle().fill(.quaternary).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 14)

            content
                .padding(.bottom, isLast ? 0 : 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(done ? 0.55 : 1)
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .breakTime:
            HStack(spacing: 6) {
                Image(systemName: "cup.and.saucer.fill")
                Text("Break · \(block.minutes) min")
            }
            .font(.subheadline)
            .foregroundStyle(.teal)
        case .event:
            VStack(alignment: .leading, spacing: 2) {
                Label(block.title, systemImage: "calendar").font(.subheadline.weight(.semibold))
                Text("\(block.start.shortTime) – \(block.end.shortTime)" + (block.subtitle.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .task:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(block.title + (block.part.map { " (\($0)/\(block.partsTotal ?? $0))" } ?? ""))
                            .font(.body.weight(.semibold))
                            .strikethrough(done)
                        HStack(spacing: 6) {
                            if let course = block.subtitle { Chip(text: course, color: color) }
                            Chip(text: "\(block.minutes) min", icon: "timer", color: .gray)
                            if isNow { Chip(text: "Now", icon: "bolt.fill", color: Brand.violet) }
                        }
                    }
                    Spacer(minLength: 8)
                    actions
                }
                if let reason = block.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(color.opacity(isNow ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { if let t = store.task(block.taskID) { onTapTask(t) } }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if done {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Brand.ok)
        } else {
            HStack(spacing: 6) {
                if block.startedAt == nil {
                    Button { store.startBlock(block) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(TintButtonStyle(kind: .glass, compact: true))
                        .help("Start the timer — helps learn your real times")
                } else {
                    Text(block.startedAt!, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Brand.violet)
                }
                Button { withAnimation { store.completeBlock(block) } } label: { Image(systemName: "checkmark") }
                    .buttonStyle(TintButtonStyle(compact: true))
                    .help("Mark done and log the time")
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Shared rows

struct OccurrenceRow: View {
    var occurrence: EventOccurrence
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                if occurrence.isAllDay {
                    Text("all day").font(.caption.weight(.semibold))
                } else {
                    Text(occurrence.start.shortTime).font(.caption.weight(.semibold).monospacedDigit())
                    Text(occurrence.end.shortTime).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 58, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(Brand.color(for: occurrence)).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(occurrence.title).font(.body.weight(.medium)).lineLimit(1)
                let detail = [occurrence.location, occurrence.externalCalendar].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if occurrence.externalCalendar != nil {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Brand.faint).help("From \(occurrence.externalCalendar ?? "another calendar") (read-only)")
            }
        }
        .padding(.vertical, 8)
    }
}

struct TaskRow: View {
    @EnvironmentObject var store: BrainStore
    var task: BrainTask
    /// Timer and log buttons on the right.
    var showActions = false

    private var overdue: Bool { !task.isCompleted && (task.due.map { $0 < Date() } ?? false) }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(duration: 0.3)) { store.toggle(task) }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.isCompleted ? AnyShapeStyle(Brand.ok) : AnyShapeStyle(Brand.color(for: task.course)))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? Brand.muted : Brand.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let c = task.course { Chip(text: c, color: Brand.color(for: c)) }
                    if let d = task.due {
                        Chip(text: d.dueText(), icon: overdue ? "exclamationmark.triangle.fill" : "flag", color: overdue ? .red : .orange)
                    }
                    if task.isLongTerm && !task.isCompleted {
                        let pace = task.pace()
                        Chip(text: "\(Int(task.progress * 100))% · \(pace.label)", icon: pace.icon, color: pace.color)
                    } else if let g = task.percentGrade {
                        Chip(text: "\(Int(g.rounded()))%", icon: "rosette", color: g >= 90 ? .green : g >= 80 ? .blue : .orange)
                    } else {
                        Chip(text: task.loggedMinutes > 0 ? "\(Scheduler.durationText(task.loggedMinutes)) of ~\(Scheduler.durationText(task.estimatedMinutes))" : "~" + Scheduler.durationText(task.estimatedMinutes), icon: "timer", color: .gray)
                    }
                    if task.priority == .high { Image(systemName: "exclamationmark.2").foregroundStyle(.red).font(.caption.bold()) }
                }
            }
            Spacer(minLength: 4)
            if task.source == .classroom {
                Image(systemName: "graduationcap.fill").foregroundStyle(Brand.ok).font(.caption).help("From Google Classroom")
            }
            if showActions && !task.isCompleted {
                if store.focus?.taskID == task.id {
                    Image(systemName: "timer").foregroundStyle(Brand.accentText).help("Timer running")
                } else {
                    Button { store.startFocus(task) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(TintButtonStyle(kind: .glass, compact: true)).help("Start a timer")
                }
                Button { store.logSheetTask = IDBox(id: task.id) } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(TintButtonStyle(kind: .glass, compact: true)).help("Log work")
            }
        }
        .padding(.vertical, 6)
    }
}
