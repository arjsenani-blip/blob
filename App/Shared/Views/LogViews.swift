import SwiftUI
import Charts
import BrainCore

// MARK: - Focus timer pill

/// The running timer: which assignment, how long, and Stop & log. Shows wherever you are.
struct FocusPill: View {
    @EnvironmentObject var store: BrainStore
    @State private var confirmDiscard = false

    var body: some View {
        if let f = store.focus, let t = store.task(f.taskID) {
            HStack(spacing: 10) {
                Circle().fill(Brand.accent).frame(width: 9, height: 9)
                    .shadow(color: Brand.accent, radius: 5)
                    .phaseAnimator([1.0, 0.45]) { c, o in c.opacity(o) } animation: { _ in .easeInOut(duration: 1) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(Brand.ink)
                    Text(f.start, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(Brand.accentText)
                }
                Spacer(minLength: 6)
                Button { _ = store.stopFocus(log: true) } label: { Label("Log", systemImage: "stop.fill") }
                    .buttonStyle(TintButtonStyle(compact: true))
                    .help("Stop the timer and log the time")
                Menu {
                    Button("Stop & mark next step done") { _ = store.stopFocus(log: true, finishedStep: true) }
                        .disabled(t.nextMilestone == nil)
                    Button("Discard timer", role: .destructive) { _ = store.stopFocus(log: false) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.accent.opacity(0.55), lineWidth: 1.2))
            .shadow(color: Brand.accent.opacity(0.35), radius: 14, y: 6)
        }
    }
}

// MARK: - Log composer

/// The fast way to log: pick the assignment, tap the time, optionally a note or "step done", Log.
struct LogComposer: View {
    @EnvironmentObject var store: BrainStore
    var compact = false
    /// Fixes the assignment (the log sheet opened from one assignment).
    var fixedTaskID: UUID?
    var onLogged: (() -> Void)?

    @State private var taskID: UUID?
    @State private var minutes = 30
    @State private var note = ""
    @State private var stepDone = false
    @State private var allDone = false
    @State private var when = Date()
    @State private var showWhen = false

    private static let presets = [15, 30, 45, 60, 90, 120]

    private var selected: BrainTask? { store.task(fixedTaskID ?? taskID ?? store.logSuggestions.first?.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            if !compact {
                HStack(spacing: 10) {
                    Glyph(icon: "square.and.pencil")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Log work").font(.headline).foregroundStyle(Brand.inkStrong)
                        Text("Time you spent, what you did, what's done.").font(.caption).foregroundStyle(Brand.muted)
                    }
                    Spacer()
                }
            }

            if fixedTaskID == nil { picker }

            if let t = selected {
                // Time
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Self.presets, id: \.self) { m in
                            ToggleChip(text: Scheduler.durationText(m), isOn: minutes == m) { minutes = m }
                        }
                        Stepper(value: $minutes, in: 0...600, step: 5) {
                            Text(Self.presets.contains(minutes) ? "Other" : Scheduler.durationText(minutes))
                                .font(.subheadline.weight(.medium)).foregroundStyle(Brand.muted)
                        }
                        .fixedSize()
                    }
                    .padding(.vertical, 2)
                }

                if !compact {
                    TextField("What did you do? (optional) — “wrote the intro”, “problems 1–12”", text: $note, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .padding(10)
                        .background(Brand.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.hairline))
                }

                // Outcome
                HStack(spacing: 6) {
                    if let step = t.nextMilestone {
                        ToggleChip(text: compact ? "Step done" : "Done: \(step.title)", icon: "checkmark.circle", isOn: stepDone && !allDone, color: Brand.ok) {
                            stepDone.toggle(); if stepDone { allDone = false }
                        }
                    }
                    ToggleChip(text: "Finished it", icon: "checkmark.seal", isOn: allDone, color: Brand.ok) {
                        allDone.toggle(); if allDone { stepDone = false }
                    }
                    if !compact {
                        ToggleChip(text: showWhen ? when.dueText() : "Earlier…", icon: "clock", isOn: showWhen) { showWhen.toggle(); if !showWhen { when = Date() } }
                    }
                    Spacer(minLength: 0)
                }
                if showWhen && !compact {
                    DatePicker("Finished at", selection: $when, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        .font(.subheadline)
                }

                HStack(spacing: 8) {
                    Button(action: commit) {
                        Label(minutes > 0 ? "Log \(Scheduler.durationText(minutes))" : "Save", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TintButtonStyle(fullWidth: true, compact: compact))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(minutes == 0 && note.isEmpty && !stepDone && !allDone)

                    if store.focus?.taskID != t.id {
                        Button { store.startFocus(t) } label: { Label("Timer", systemImage: "play.fill") }
                            .buttonStyle(TintButtonStyle(kind: .glass, compact: compact))
                            .help("Start a timer on \(t.title); stop it to log the time")
                    }
                }
            } else {
                EmptyHint(icon: "tray", text: "Add an assignment first — then log time against it here.")
            }
        }
        .modifier(OptionalCard(on: !compact))
    }

    /// Likely assignments as chips, plus every open one in a menu.
    private var picker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                let sel = selected?.id
                ForEach(store.logSuggestions) { t in
                    ToggleChip(text: t.title, icon: t.course == nil ? "doc.text" : "graduationcap",
                               isOn: sel == t.id, color: Brand.color(for: t.course)) { taskID = t.id; stepDone = false; allDone = false }
                }
                let more = store.pendingTasks.filter { t in !store.logSuggestions.contains { $0.id == t.id } }
                if !more.isEmpty {
                    Menu {
                        ForEach(more.sorted { $0.title < $1.title }) { t in
                            Button(t.course.map { "\(t.title) · \($0)" } ?? t.title) { taskID = t.id }
                        }
                    } label: {
                        Label("More", systemImage: "chevron.down").font(.subheadline.weight(.medium))
                    }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    .padding(.horizontal, 10)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private func commit() {
        guard let t = selected else { return }
        withAnimation(.spring(duration: 0.35)) {
            store.log(taskID: t.id, minutes: minutes, note: compact ? nil : note, finishStep: stepDone, markDone: allDone,
                      on: showWhen ? when : Date())
        }
        note = ""; stepDone = false; allDone = false; showWhen = false; when = Date()
        onLogged?()
    }
}

private struct OptionalCard: ViewModifier {
    var on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.card(padding: 18) } else { content }
    }
}

/// ⌘L, or "Log" on an assignment.
struct LogSheet: View {
    @EnvironmentObject var store: BrainStore
    @Environment(\.dismiss) private var dismiss
    var taskID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let id = taskID, let t = store.task(id) {
                        HStack(spacing: 8) {
                            Text(t.title).font(.title3.weight(.bold)).tracking(-0.3)
                            if let c = t.course { Chip(text: c, color: Brand.color(for: c)) }
                        }
                    }
                    LogComposer(fixedTaskID: taskID) { dismiss() }
                    Text("Or type it anywhere in quick add (⌘K): “worked 40 min on the lab report”, “finished the outline for my essay”, “history project is 60% done”, “got 18/20 on the quiz”.")
                        .font(.caption).foregroundStyle(Brand.muted)
                }
                .padding(20)
            }
            .background(FrameBackground())
            .navigationTitle("Log work")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .frame(minWidth: 560, minHeight: 460)
    }
}

// MARK: - Activity

/// Everything you've logged: totals, a two-week chart by class, and the full feed.
struct ActivityScreen: View {
    @EnvironmentObject var store: BrainStore
    enum Span: String, CaseIterable, Identifiable {
        case week = "7 days", twoWeeks = "14 days", month = "30 days"
        var id: String { rawValue }
        var days: Int { self == .week ? 7 : self == .twoWeeks ? 14 : 30 }
    }
    @AppStorage("activityRange") private var range: Span = .twoWeeks
    @State private var detail: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Overline(text: "Your work log")
                    Text("Activity").screenTitle()
                }
                stats
                chart
                feed
            }
            .padding(24)
            .page()
        }
        .navigationTitle("Activity")
        .sheet(item: Binding(get: { detail.map(IDBox.init) }, set: { detail = $0?.id })) { AssignmentDetail(taskID: $0.id) }
    }

    private var stats: some View {
        HStack(spacing: 12) {
            StatTile(value: Scheduler.durationText(store.minutesToday), label: "Today", icon: "sun.max")
            StatTile(value: Scheduler.durationText(store.minutesThisWeek), label: "This week", icon: "calendar")
            StatTile(value: "\(store.streak)", label: store.streak == 1 ? "Day streak" : "Days in a row", icon: "flame")
            StatTile(value: "\(store.tasks.filter { $0.isCompleted && ($0.completedAt ?? .distantPast) > Date().addingTimeInterval(-7 * 86_400) }.count)",
                     label: "Finished this week", icon: "checkmark.seal")
        }
    }

    private var chart: some View {
        let rows = store.dailyByCourse(days: range.days)
        let courses = Array(Set(rows.map(\.course))).sorted()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Time by class").font(.headline).foregroundStyle(Brand.inkStrong)
                Spacer()
                GlassSegmented(options: Span.allCases, selection: $range) { $0.rawValue }.frame(width: 260)
            }
            if rows.isEmpty {
                EmptyHint(icon: "chart.bar", text: "Nothing logged in the last \(range.days) days yet.")
            } else {
                Chart(rows) { r in
                    BarMark(x: .value("Day", r.day, unit: .day), y: .value("Minutes", r.minutes))
                        .foregroundStyle(by: .value("Class", r.course))
                        .cornerRadius(3)
                }
                .chartForegroundStyleScale(domain: courses, range: courses.map { Brand.color(for: $0 == "Other" ? nil : $0) })
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine().foregroundStyle(Brand.hairline)
                        AxisValueLabel { if let m = v.as(Int.self) { Text(Scheduler.durationText(m)) } }
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 200)
                let perClass: [(String, Int)] = courses.map { c in (c, rows.filter { $0.course == c }.reduce(0) { $0 + $1.minutes }) }
                    .sorted { $0.1 > $1.1 }
                HStack(spacing: 6) {
                    ForEach(Array(perClass.prefix(6).enumerated()), id: \.offset) { item in
                        let c = item.element
                        Chip(text: "\(c.0) · \(Scheduler.durationText(c.1))", color: Brand.color(for: c.0 == "Other" ? nil : c.0))
                    }
                }
            }
        }
        .card(padding: 18)
    }

    private var feed: some View {
        let work = store.recentWork(limit: 300, since: Date().addingTimeInterval(-Double(range.days) * 86_400))
        let days = Array(Set(work.map { Calendar.current.startOfDay(for: $0.session.date) })).sorted(by: >)
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Log", trailing: "\(work.count) entries")
            if work.isEmpty {
                EmptyHint(icon: "square.and.pencil", text: "Log time from Today, the timer, or any assignment — it shows up here.").card()
            }
            ForEach(days, id: \.self) { day in
                let items = work.filter { Calendar.current.isDate($0.session.date, inSameDayAs: day) }
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Overline(text: day.dueText(includeTime: false) + (Calendar.current.isDateInToday(day) || Calendar.current.isDateInYesterday(day) ? "" : " · " + day.formatted(.dateTime.month(.abbreviated).day())))
                        Spacer()
                        Text(Scheduler.durationText(items.reduce(0) { $0 + $1.session.minutes })).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Brand.muted)
                    }
                    .padding(.bottom, 8)
                    ForEach(items) { w in
                        LoggedRow(work: w)
                            .contentShape(Rectangle())
                            .onTapGesture { detail = w.task.id }
                            .contextMenu {
                                Button("Open assignment") { detail = w.task.id }
                                Button("Delete entry", role: .destructive) { store.deleteSession(w) }
                            }
                        if w.id != items.last?.id { Divider().padding(.leading, 44) }
                    }
                }
                .card(padding: 14, bloom: false)
            }
        }
    }
}

struct StatTile: View {
    var value: String
    var label: String
    var icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Glyph(icon: icon, size: 30)
            Text(value).font(.title2.weight(.bold).monospacedDigit()).tracking(-0.5).foregroundStyle(Brand.inkStrong)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(Brand.muted).lineLimit(1)
        }
        .card(padding: 14, bloom: false)
    }
}

struct LoggedRow: View {
    var work: LoggedWork
    var body: some View {
        let color = Brand.color(for: work.task.course)
        HStack(alignment: .top, spacing: 12) {
            Text(work.session.minutes > 0 ? Scheduler.durationText(work.session.minutes) : "note")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color.legible)
                .frame(width: 34, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(work.task.title).font(.body.weight(.medium)).foregroundStyle(Brand.ink).lineLimit(1)
                let detail = [work.stepTitle.map { "Step: \($0)" }, work.session.note].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Brand.muted).lineLimit(2) }
            }
            Spacer()
            if let c = work.task.course { Chip(text: c, color: color) }
            Text(work.session.date.shortTime).font(.caption.monospacedDigit()).foregroundStyle(Brand.faint)
        }
        .padding(.vertical, 7)
    }
}
