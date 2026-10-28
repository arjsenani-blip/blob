import SwiftUI
import BrainCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Step pictures

/// A step's minimalist picture: its symbol, deep-toned, on a soft pastel circle.
struct RoutineBadge: View {
    var symbol: String
    var tint: Int
    var size: CGFloat = 44

    static let fills: [(Color, Color)] = [
        (Color(adaptive: (0.93, 0.89, 1.0), dark: (0.24, 0.18, 0.38)), Color(adaptive: (0.36, 0.20, 0.80), dark: (0.80, 0.70, 1.0))),
        (Color(adaptive: (0.87, 0.96, 0.83), dark: (0.13, 0.27, 0.12)), Color(adaptive: (0.16, 0.45, 0.10), dark: (0.62, 0.90, 0.55))),
        (Color(adaptive: (1.0, 0.94, 0.76), dark: (0.32, 0.25, 0.08)), Color(adaptive: (0.55, 0.38, 0.0), dark: (1.0, 0.85, 0.50))),
        (Color(adaptive: (0.90, 0.94, 1.0), dark: (0.12, 0.20, 0.34)), Color(adaptive: (0.12, 0.33, 0.70), dark: (0.62, 0.76, 1.0))),
        (Color(adaptive: (1.0, 0.93, 0.89), dark: (0.34, 0.19, 0.12)), Color(adaptive: (0.70, 0.30, 0.10), dark: (1.0, 0.70, 0.55))),
        (Color(adaptive: (1.0, 0.91, 0.94), dark: (0.36, 0.13, 0.22)), Color(adaptive: (0.72, 0.16, 0.42), dark: (1.0, 0.62, 0.78))),
        (Color(adaptive: (0.88, 0.97, 0.96), dark: (0.08, 0.28, 0.27)), Color(adaptive: (0.05, 0.45, 0.42), dark: (0.50, 0.92, 0.88))),
        (Color(adaptive: (0.94, 0.94, 0.96), dark: (0.20, 0.20, 0.24)), Color(adaptive: (0.30, 0.30, 0.36), dark: (0.85, 0.85, 0.90))),
    ]

    /// Falls back to a generic shape if this OS doesn't have the symbol.
    static func available(_ name: String) -> String {
        #if os(macOS)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "circle.hexagongrid.fill"
        #else
        return UIImage(systemName: name) != nil ? name : "circle.hexagongrid.fill"
        #endif
    }

    var body: some View {
        let pair = Self.fills[abs(tint) % Self.fills.count]
        Image(systemName: Self.available(symbol))
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(pair.1)
            .frame(width: size, height: size)
            .background(pair.0, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - The Routines tab

struct RoutinesScreen: View {
    @EnvironmentObject var store: BrainStore
    var openSettings: () -> Void
    var openSearch: () -> Void
    @StateObject private var dictation = Dictation()
    @State private var text = ""
    @State private var draft: DailyRoutine?
    @State private var running: DailyRoutine?

    private let examples = [
        "Bedtime routine: shower 15 min, brush teeth, skincare, read 20 minutes, lights out at 10:30",
        "Morning routine starting at 6:45: wake up, make bed, shower, get dressed, breakfast 15 min, pack bag",
        "After school routine: snack, walk the dog, homework 1 hour, practice piano 30 min",
    ]

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 760
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Routines").font(.system(size: wide ? 40 : 32, weight: .heavy)).tracking(-1).foregroundStyle(X.ink)
                        Spacer()
                        XToolbarPill(onSearch: openSearch, onSettings: openSettings)
                    }
                    composer
                    if store.routines.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            XLabel(text: "Try one", tone: .due)
                            ForEach(examples, id: \.self) { ex in
                                Button { text = ex } label: {
                                    Text("“\(ex)”").font(.system(size: 15)).foregroundStyle(X.body).multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(14)
                                        .background(X.soft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        let cols = wide ? [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)] : [GridItem(.flexible())]
                        LazyVGrid(columns: cols, alignment: .leading, spacing: 16) {
                            ForEach(store.routines) { r in
                                RoutineCard(routine: r, onStart: { running = r }, onEdit: { draft = r })
                            }
                        }
                    }
                }
                .padding(.horizontal, wide ? 36 : 20).padding(.top, wide ? 26 : 16).padding(.bottom, 130)
                .frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
        }
        .background(X.page.ignoresSafeArea())
        .sheet(item: $draft) { RoutineEditor(routine: $0).environmentObject(store) }
        #if os(iOS)
        .fullScreenCover(item: $running) { RoutineRunner(routine: $0).environmentObject(store) }
        #else
        .sheet(item: $running) { RoutineRunner(routine: $0).environmentObject(store).frame(minWidth: 520, minHeight: 700) }
        #endif
        .onChange(of: dictation.transcript) { if dictation.isListening { text = dictation.transcript } }
    }

    /// Describe it — typed or spoken.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe a routine").font(.system(size: 17, weight: .bold)).foregroundStyle(X.ink)
            Text("Say or type the steps in order. Add times (“shower 15 min”) and when it starts or when you want to be done (“lights out at 10:30”) — Blob fills in the rest.")
                .font(.system(size: 14)).foregroundStyle(X.muted)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("e.g. bedtime routine: shower, brush teeth, read 20 min, lights out at 10:30")
                        .font(.system(size: 16)).foregroundStyle(X.muted.opacity(0.8)).padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 84)
            }
            .padding(10)
            .background(X.soft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack(spacing: 10) {
                Button { dictation.toggle(startingWith: text) } label: {
                    Label(dictation.isListening ? "Stop" : "Speak", systemImage: dictation.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(dictation.isListening ? .white : X.ink)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(dictation.isListening ? AnyShapeStyle(X.now) : AnyShapeStyle(X.raised), in: Capsule())
                        .overlay(Capsule().strokeBorder(X.line, lineWidth: dictation.isListening ? 0 : 1))
                }
                .buttonStyle(.plain)
                if dictation.isListening {
                    Text("Listening…").font(.system(size: 13, weight: .semibold)).foregroundStyle(X.now)
                }
                Spacer()
                Button {
                    dictation.stop()
                    let r = RoutineParser.parse(text)
                    if !r.steps.isEmpty { draft = r; text = "" }
                } label: {
                    Label("Make timeline", systemImage: "sparkles")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(X.purple, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            if let p = dictation.problem { Text(p).font(.caption).foregroundStyle(X.now) }
        }
        .xCard()
    }
}

func clock(_ minuteOfDay: Int) -> String {
    let m = ((minuteOfDay % 1440) + 1440) % 1440
    let d = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date())!
    return d.formatted(date: .omitted, time: .shortened)
}

struct RoutineCard: View {
    @EnvironmentObject var store: BrainStore
    var routine: DailyRoutine
    var onStart: () -> Void
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(routine.name).font(.system(size: 19, weight: .bold)).foregroundStyle(X.ink)
                    Text("\(clock(routine.startMinute)) – \(clock(routine.endMinute)) · \(routine.steps.count) steps · \(Scheduler.durationText(routine.totalMinutes))")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(X.muted)
                    Text(dayText(routine.weekdays)).font(.system(size: 12, weight: .semibold)).foregroundStyle(X.purple)
                }
                Spacer()
                Menu {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                    Button("Delete", systemImage: "trash", role: .destructive) { store.delete(routine) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold)).foregroundStyle(X.muted).frame(width: 30, height: 30) }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .accessibilityLabel("More")
            }
            // The steps as a little timeline.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(routine.timeline(on: Date()).enumerated()), id: \.element.step.id) { i, item in
                    HStack(spacing: 12) {
                        VStack(spacing: 0) {
                            RoutineBadge(symbol: item.step.symbol, tint: item.step.tint, size: 34)
                            if i < routine.steps.count - 1 { Rectangle().fill(X.line).frame(width: 2, height: 10) }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.step.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(X.ink).lineLimit(1)
                            Text(item.start.formatted(date: .omitted, time: .shortened) + " · \(item.step.minutes) min")
                                .font(.system(size: 12)).foregroundStyle(X.muted)
                        }
                        .padding(.bottom, i < routine.steps.count - 1 ? 10 : 0)
                        Spacer(minLength: 0)
                    }
                }
            }
            Button(action: onStart) {
                Label("Start \(routine.name.lowercased())", systemImage: "play.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(X.purple, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .xCard()
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
    }
}

func dayText(_ days: [Int]) -> String {
    let set = Set(days)
    if set.isEmpty || set.count == 7 { return "Every day" }
    if set == [2, 3, 4, 5, 6] { return "Weekdays" }
    if set == [1, 7] { return "Weekends" }
    let syms = Calendar.current.shortWeekdaySymbols
    return days.sorted().map { syms[$0 - 1] }.joined(separator: ", ")
}

// MARK: - Edit / review a routine

struct RoutineEditor: View {
    @EnvironmentObject var store: BrainStore
    @Environment(\.dismiss) private var dismiss
    @State var routine: DailyRoutine
    @State private var newStep = ""

    private var timeBinding: Binding<Date> {
        Binding(get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(routine.time) * 60) },
                set: { d in let c = Calendar.current.dateComponents([.hour, .minute], from: d); routine.time = (c.hour ?? 0) * 60 + (c.minute ?? 0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $routine.name).font(.title3.weight(.bold))
                    Picker("Timing", selection: $routine.anchor) {
                        Text("Starts at").tag(DailyRoutine.Anchor.start)
                        Text("Done by").tag(DailyRoutine.Anchor.end)
                    }
                    .pickerStyle(.segmented)
                    DatePicker(routine.anchor == .start ? "Starts at" : "Done by", selection: timeBinding, displayedComponents: .hourAndMinute)
                    LabeledContent("Timeline", value: "\(clock(routine.startMinute)) – \(clock(routine.endMinute)) · \(Scheduler.durationText(routine.totalMinutes))")
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { d in
                            let on = routine.weekdays.isEmpty || routine.weekdays.contains(d)
                            Button {
                                var set = Set(routine.weekdays.isEmpty ? Array(1...7) : routine.weekdays)
                                if set.contains(d) { set.remove(d) } else { set.insert(d) }
                                routine.weekdays = set.count == 7 ? [] : set.sorted()
                            } label: {
                                Text(String(Calendar.current.shortWeekdaySymbols[d - 1].prefix(2)))
                                    .font(.caption.weight(.bold)).frame(width: 34, height: 34)
                                    .background(on ? X.ink : X.soft, in: Circle())
                                    .foregroundStyle(on ? X.page : X.ink)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Toggle("Remind me when it's time to start", isOn: $routine.remind)
                }
                Section("Steps") {
                    ForEach($routine.steps) { $step in
                        HStack(spacing: 12) {
                            Menu {
                                ForEach(RoutineIcons.table.map(\.symbol), id: \.self) { sym in
                                    Button { step.symbol = sym } label: { Label(sym, systemImage: RoutineBadge.available(sym)) }
                                }
                                Divider()
                                ForEach(0..<RoutineIcons.tintCount, id: \.self) { t in Button("Color \(t + 1)") { step.tint = t } }
                            } label: { RoutineBadge(symbol: step.symbol, tint: step.tint, size: 38) }
                            .menuStyle(.button).buttonStyle(.plain).fixedSize()
                            .accessibilityLabel("Change picture")
                            TextField("Step", text: $step.title)
                                .onSubmit { let p = RoutineIcons.pick(for: step.title); step.symbol = p.symbol; step.tint = p.tint }
                            Stepper("\(step.minutes)m", value: $step.minutes, in: 1...240)
                                .fixedSize()
                        }
                    }
                    .onDelete { routine.steps.remove(atOffsets: $0) }
                    .onMove { routine.steps.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(X.purple)
                        TextField("Add a step (e.g. “stretch 10 min”)", text: $newStep)
                            .onSubmit {
                                let parsed = RoutineParser.parse(newStep).steps
                                routine.steps += parsed.isEmpty ? [RoutineStep(title: newStep, minutes: 10)] : parsed
                                newStep = ""
                            }
                    }
                }
                if store.routine(routine.id) != nil {
                    Section { Button("Delete routine", role: .destructive) { store.delete(routine); dismiss() } }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(store.routine(routine.id) == nil ? "New routine" : "Edit routine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.upsert(routine); store.show("Saved \(routine.name)"); dismiss() }
                        .disabled(routine.steps.isEmpty)
                }
            }
        }
        .sheetSize(minWidth: 560, minHeight: 680)
    }
}

// MARK: - Do it, step by step

struct RoutineRunner: View {
    @EnvironmentObject var store: BrainStore
    @Environment(\.dismiss) private var dismiss
    var routine: DailyRoutine
    @State private var index = 0
    @State private var stepEnds = Date()
    @State private var paused: TimeInterval?
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var step: RoutineStep? { routine.steps.indices.contains(index) ? routine.steps[index] : nil }
    private var left: TimeInterval { paused ?? max(0, stepEnds.timeIntervalSince(now)) }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Button("Close") { dismiss() }.buttonStyle(.plain).font(.system(size: 16, weight: .semibold)).foregroundStyle(X.muted)
                Spacer()
                Text(routine.name).font(.system(size: 16, weight: .bold)).foregroundStyle(X.ink)
                Spacer()
                Text("\(min(index + 1, routine.steps.count))/\(routine.steps.count)").font(.system(size: 15, weight: .semibold)).foregroundStyle(X.muted)
            }
            Spacer(minLength: 0)
            if let s = step {
                ZStack {
                    PomodoroRing(progress: 1 - left / Double(s.minutes * 60), color: X.purple, size: 250, line: 14)
                    VStack(spacing: 10) {
                        RoutineBadge(symbol: s.symbol, tint: s.tint, size: 92)
                        Text(String(format: "%d:%02d", Int(left) / 60, Int(left) % 60))
                            .font(.system(size: 40, weight: .heavy).monospacedDigit()).foregroundStyle(X.ink)
                    }
                }
                Text(s.title).font(.system(size: 30, weight: .heavy)).foregroundStyle(X.ink).multilineTextAlignment(.center)
                if let next = routine.steps.indices.contains(index + 1) ? routine.steps[index + 1] : nil {
                    HStack(spacing: 8) {
                        Text("Next").font(.system(size: 14, weight: .semibold)).foregroundStyle(X.muted)
                        RoutineBadge(symbol: next.symbol, tint: next.tint, size: 26)
                        Text(next.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(X.ink)
                    }
                }
                HStack(spacing: 12) {
                    Button { go(index - 1) } label: { Image(systemName: "backward.end.fill").frame(width: 52, height: 52).background(X.raised, in: Circle()).overlay(Circle().strokeBorder(X.line)) }
                        .disabled(index == 0).accessibilityLabel("Previous step")
                    Button {
                        if let p = paused { stepEnds = Date().addingTimeInterval(p); paused = nil } else { paused = left }
                    } label: {
                        Text(paused == nil ? "Pause" : "Resume").font(.system(size: 17, weight: .heavy)).foregroundStyle(X.ink)
                            .frame(width: 110, height: 52).background(X.raised, in: Capsule()).overlay(Capsule().strokeBorder(X.line))
                    }
                    Button { go(index + 1) } label: {
                        Text(index == routine.steps.count - 1 ? "Finish" : "Done ✓").font(.system(size: 17, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 130, height: 52).background(X.purple, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(X.ink)
            } else {
                Text("🎉").font(.system(size: 72))
                Text("\(routine.name) done").font(.system(size: 30, weight: .heavy)).foregroundStyle(X.ink)
                Button("Close") { dismiss() }
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 40).padding(.vertical, 14).background(X.purple, in: Capsule()).buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background(LinearGradient(colors: [X.page, X.purpleSoft.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .onAppear { go(0) }
        .onReceive(tick) { t in
            now = t
            if paused == nil, step != nil, left <= 0 { go(index + 1) }
        }
    }

    private func go(_ i: Int) {
        index = max(0, i)
        paused = nil
        if let s = step { stepEnds = Date().addingTimeInterval(Double(s.minutes * 60)) }
        now = Date()
        if index >= routine.steps.count { store.show("Nice — \(routine.name) done ✓") }
    }
}
