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
                QuickAddBar()
                if let plan = store.todayPlan {
                    PlanTimeline(plan: plan, onTapTask: { editingTask = $0 })
                } else {
                    checkInCard
                }
                agenda
            }
            .padding(20)
            .page()
        }
        .background(Brand.canvas)
        .navigationTitle("Today")
        .sheet(item: $editingTask) { TaskEditor(task: $0) }
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
        VStack(alignment: .leading, spacing: 6) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text("\(greeting), \(store.displayName)")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            HStack(spacing: 8) {
                let dueToday = store.pendingTasks.filter { $0.due.map { $0 < Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400) } ?? false }.count
                let eventsLeft = store.occurrences(on: Date()).filter { !$0.isAllDay && $0.end > Date() }.count
                Chip(text: "\(dueToday) due today", icon: "flag.fill", color: dueToday > 0 ? .orange : .green)
                Chip(text: "\(eventsLeft) events left", icon: "calendar", color: .blue)
                Chip(text: "\(store.pendingTasks.count) open to-dos", icon: "checklist", color: Brand.pink)
            }
        }
    }

    private var checkInCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Brand.gradient)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to get to work?").font(.title3.weight(.bold))
                    Text("Check in and I'll line up your assignments in the best order for right now — around your events, with breaks, done by bedtime.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                withAnimation(.spring) { store.checkIn() }
            } label: {
                Label("Check in now · \(Date().shortTime)", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GradientButtonStyle())
            .keyboardShortcut("i", modifiers: .command)
        }
        .card(padding: 20)
    }

    private var agenda: some View {
        let occ = store.occurrences(on: Date())
        let due = store.tasksDue(on: Date())
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "On the calendar")
            VStack(alignment: .leading, spacing: 0) {
                if occ.isEmpty && due.isEmpty {
                    EmptyHint(icon: "sun.max.fill", text: "Nothing scheduled today.")
                }
                ForEach(occ) { o in
                    OccurrenceRow(occurrence: o)
                        .contentShape(Rectangle())
                        .onTapGesture { editingEvent = store.event(o.eventID) }
                    if o.id != occ.last?.id || !due.isEmpty { Divider().padding(.leading, 70) }
                }
                ForEach(due) { t in
                    TaskRow(task: t).contentShape(Rectangle()).onTapGesture { editingTask = t }
                    if t.id != due.last?.id { Divider().padding(.leading, 40) }
                }
            }
            .card(padding: 12)
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
                    Text("Your timeline").font(.title3.weight(.bold))
                    Text(plan.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.spring) { store.checkIn() }
                } label: {
                    Label("Re-check in", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .tint(Brand.violet)
            }
            Label(plan.strategy, systemImage: "lightbulb.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            TimelineView(.everyMinute) { ctx in
                VStack(spacing: 0) {
                    if plan.blocks.isEmpty {
                        EmptyHint(icon: "party.popper.fill", text: "Nothing to do. Seriously — go have fun.")
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
                        .foregroundStyle(.orange)
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
                    .fill(done ? Color.green : color)
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
                            Chip(text: "\(block.minutes) min", icon: "timer", color: .secondary)
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
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        } else {
            HStack(spacing: 6) {
                if block.startedAt == nil {
                    Button { store.startBlock(block) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.bordered)
                        .help("Start the timer — helps learn your real times")
                } else {
                    Text(block.startedAt!, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Brand.violet)
                }
                Button { withAnimation { store.completeBlock(block) } } label: { Image(systemName: "checkmark") }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.violet)
                    .help("Mark done")
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
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary).help("From Apple Calendar (read-only)")
            }
        }
        .padding(.vertical, 8)
    }
}

struct TaskRow: View {
    @EnvironmentObject var store: BrainStore
    var task: BrainTask

    private var overdue: Bool { !task.isCompleted && (task.due.map { $0 < Date() } ?? false) }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(duration: 0.3)) { store.toggle(task) }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.isCompleted ? AnyShapeStyle(Color.green) : AnyShapeStyle(Brand.color(for: task.course)))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let c = task.course { Chip(text: c, color: Brand.color(for: c)) }
                    if let d = task.due {
                        Chip(text: d.dueText(), icon: overdue ? "exclamationmark.triangle.fill" : "flag", color: overdue ? .red : .orange)
                    }
                    Chip(text: Scheduler.durationText(task.estimatedMinutes), icon: "timer", color: .secondary)
                    if task.priority == .high { Image(systemName: "exclamationmark.2").foregroundStyle(.red).font(.caption.bold()) }
                }
            }
            Spacer(minLength: 4)
            if task.source == .classroom {
                Image(systemName: "graduationcap.fill").foregroundStyle(.green).font(.caption).help("From Google Classroom")
            }
        }
        .padding(.vertical, 6)
    }
}
