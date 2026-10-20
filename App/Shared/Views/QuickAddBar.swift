import SwiftUI
import BrainCore

/// Type anything — "soccer every tue 5-7pm at Field 3", "chem lab due thu ~90m" — and see how it'll be saved before you hit return.
struct QuickAddBar: View {
    @EnvironmentObject var store: BrainStore
    var autofocus = false
    var onAdded: (() -> Void)?

    @State private var text = ""
    @State private var override: ParsedEntry.Kind?
    @FocusState private var focused: Bool

    private static let examples = [
        "Dentist tomorrow at 3pm",
        "Soccer every tue & thu 5-7pm @ Lincoln Field",
        "Essay due friday ~90m #English",
        "Study group sat 11-1pm",
        "Call grandma in 2 hours",
        "History project due nov 20 long-term",
        "Worked 45 min on the history essay",
        "Finished the outline for my english essay",
        "Got 92/100 on the chem lab",
    ]
    @State private var exampleIndex = Int.random(in: 0..<9)

    /// "worked 45 min on …", "finished the outline …", "got 92/100 on …" — logging progress instead of adding.
    private var log: (intent: LogIntent, task: BrainTask?)? {
        text.trimmingCharacters(in: .whitespaces).isEmpty || override != nil ? nil : store.logPreview(text)
    }

    private var parsed: ParsedEntry? {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : store.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Brand.gradient)
                TextField("Try “\(Self.examples[exampleIndex])”", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .focused($focused)
                    .onSubmit(commit)
                    .submitLabel(.done)
                    #if os(iOS)
                    .textInputAutocapitalization(.sentences)
                    #endif
                if parsed != nil {
                    Button(action: commit) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(Brand.gradient)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            if let l = log {
                logPreview(l)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let p = parsed {
                preview(p)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .card(padding: 14)
        .animation(.easeOut(duration: 0.15), value: parsed == nil)
        .onAppear { if autofocus { focused = true } }
        .onChange(of: text) { if text.isEmpty { override = nil } }
    }

    @ViewBuilder
    private func preview(_ p: ParsedEntry) -> some View {
        let kind = override ?? p.kind
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Menu {
                    Button("Event", systemImage: "calendar") { override = .event }
                    Button("To-do / assignment", systemImage: "checklist") { override = .task }
                } label: {
                    Chip(text: kind == .event ? "Event" : "To-do", icon: kind == .event ? "calendar" : "checklist",
                         color: kind == .event ? Brand.violet : Brand.pink)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()

                Chip(text: p.title.isEmpty ? "Untitled" : p.title, icon: "textformat", color: .primary)
                if let s = p.start {
                    if kind == .task {
                        Chip(text: "Due " + s.dueText(includeTime: p.hasExplicitTime), icon: "flag.fill", color: .orange)
                    } else if p.isAllDay {
                        Chip(text: s.dueText(includeTime: false) + " · all day", icon: "calendar", color: .blue)
                    } else {
                        Chip(text: s.dueText(includeTime: false), icon: "calendar", color: .blue)
                        Chip(text: s.shortTime + (p.end.map { " – " + $0.shortTime } ?? ""), icon: "clock", color: .blue)
                    }
                }
                if p.recurrence.isRepeating { Chip(text: p.recurrence.describe(), icon: "repeat", color: .teal) }
                if let l = p.location { Chip(text: l, icon: "mappin", color: .green) }
                if let c = p.course, kind == .task { Chip(text: c, icon: "graduationcap", color: Brand.color(for: c)) }
                if let t = p.tag { Chip(text: t, icon: "number", color: Brand.color(for: t)) }
                if kind == .task, let m = p.durationMinutes { Chip(text: Scheduler.durationText(m), icon: "timer", color: .purple) }
                if p.priority == .high { Chip(text: "High", icon: "exclamationmark", color: .red) }
            }
        }
    }

    @ViewBuilder
    private func logPreview(_ l: (intent: LogIntent, task: BrainTask?)) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Menu {
                    Button("Log progress", systemImage: "chart.line.uptrend.xyaxis") {}
                    Button("Add as to-do instead", systemImage: "checklist") { override = .task }
                    Button("Add as event instead", systemImage: "calendar") { override = .event }
                } label: {
                    Chip(text: "Log", icon: "chart.line.uptrend.xyaxis", color: .teal)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                switch l.intent {
                case .worked(let m, _, _): Chip(text: "+" + Scheduler.durationText(m), icon: "timer", color: .purple)
                case .finishedStep(let step, _): Chip(text: "Step done: \(step)", icon: "checkmark.circle", color: .green)
                case .completed: Chip(text: "Mark done", icon: "checkmark.seal.fill", color: .green)
                case .started: Chip(text: "Started", icon: "play.fill", color: .blue)
                case .progress(let p, _): Chip(text: "\(p)% done", icon: "chart.pie.fill", color: .blue)
                case .grade(let e, let p, _): Chip(text: "\(BrainStore.fmt(e))/\(BrainStore.fmt(p))", icon: "rosette", color: .orange)
                case .planSteps: Chip(text: "Split into steps", icon: "list.number", color: Brand.violet)
                }
                if let t = l.task {
                    Chip(text: t.title, icon: "doc.text", color: .primary)
                    if let c = t.course { Chip(text: c, icon: "graduationcap", color: Brand.color(for: c)) }
                } else {
                    Chip(text: "Which assignment?", icon: "questionmark", color: .red)
                }
            }
        }
    }

    private func commit() {
        if log != nil {
            withAnimation { _ = store.applyLog(text) }
            text = ""
            onAdded?()
            return
        }
        guard let p = parsed else { return }
        withAnimation { store.add(p, as: override) }
        text = ""
        override = nil
        exampleIndex = (exampleIndex + 1) % Self.examples.count
        onAdded?()
    }
}

struct QuickAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Quick add").font(.title2.weight(.bold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            QuickAddBar(autofocus: true) { dismiss() }
            Text("Dates, times, ranges, “every tue”, “in 2 hours”, “@ place”, “#tag”, “due fri”, “~45m”, “!!”, “long-term”.\nLog progress too: “worked 30 min on …”, “finished the outline for …”, “got 18/20 on …”")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 520)
        .background(Brand.canvas)
    }
}
