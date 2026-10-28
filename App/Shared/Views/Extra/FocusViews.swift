import SwiftUI
import BrainCore

struct PomodoroRing: View {
    var progress: Double
    var color: Color
    var size: CGFloat
    var line: CGFloat
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: line)
            Circle().trim(from: 0, to: max(0.001, progress))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.linear(duration: 0.9), value: progress)
    }
}

struct RoundDots: View {
    @ObservedObject var p: Pomodoro
    var size: CGFloat = 10
    var body: some View {
        HStack(spacing: size * 0.7) {
            ForEach(1...4, id: \.self) { i in
                Circle().fill(i < p.round ? X.purple : i == p.round ? X.purple.opacity(0.45) : X.purple.opacity(0.15))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Round \(p.round) of 4")
    }
}

private extension Pomodoro {
    var ringColor: Color { phase == .focus ? X.purple : Color(red: 0.18, green: 0.62, blue: 0.30) }
}

/// The full Focus tab.
struct FocusScreen: View {
    @EnvironmentObject var store: BrainStore
    @ObservedObject private var p = Pomodoro.shared
    @State private var picking = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack {
                    Text("Focus").font(X.phoneTitleFont).tracking(-0.8).foregroundStyle(X.ink)
                    Spacer()
                    Text("🔥 \(store.streak)-day streak")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(X.raised, in: Capsule()).overlay(Capsule().strokeBorder(X.line))
                }

                // What you're working on
                Button { picking = true } label: {
                    HStack(spacing: 12) {
                        if let t = p.taskID.flatMap({ store.task($0) }) {
                            Text(DayFeed.emoji(task: t)).font(.system(size: 22))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.system(size: 16, weight: .bold)).foregroundStyle(X.ink).lineLimit(1)
                                Text([t.course, t.loggedMinutes > 0 ? "\(Scheduler.durationText(t.loggedMinutes)) of ~\(Scheduler.durationText(t.totalEstimateMinutes)) done" : nil]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 13)).foregroundStyle(X.muted).lineLimit(1)
                            }
                        } else {
                            Text("🎯").font(.system(size: 22))
                            Text("Pick an assignment to focus on").font(.system(size: 16, weight: .semibold)).foregroundStyle(X.ink)
                        }
                        Spacer()
                        Text("Change").font(.system(size: 13, weight: .bold)).foregroundStyle(X.purple)
                    }
                    .padding(14)
                    .background(X.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(X.line))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Length
                HStack(spacing: 2) {
                    ForEach(Pomodoro.Preset.all) { preset in
                        Button { p.choose(preset) } label: {
                            Text(preset.label).font(.system(size: 13, weight: p.preset == preset ? .bold : .semibold))
                                .foregroundStyle(p.preset == preset ? X.ink : X.muted)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(p.preset == preset ? X.raised : .clear, in: Capsule())
                                .shadow(color: .black.opacity(p.preset == preset ? 0.1 : 0), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(X.purpleSoft, in: Capsule())

                // Ring
                ZStack {
                    PomodoroRing(progress: p.progress, color: p.ringColor, size: 272, line: 22)
                    VStack(spacing: 4) {
                        Text(p.phase.label).font(.system(size: 14, weight: .bold)).tracking(0.4).foregroundStyle(p.ringColor)
                        Text(p.clock).font(.system(size: 60, weight: .heavy).monospacedDigit()).tracking(-2).foregroundStyle(X.ink)
                        Text("Round \(p.round) of 4").font(.system(size: 13, weight: .semibold)).foregroundStyle(X.muted)
                    }
                }
                .padding(.top, 4)
                RoundDots(p: p, size: 12)

                // Controls
                HStack(spacing: 12) {
                    circleButton("arrow.counterclockwise", label: "Reset") { p.reset() }
                    Button { p.toggle() } label: {
                        Text(p.isRunning ? "Pause" : (p.isActive ? "Resume" : "Start"))
                            .font(.system(size: 18, weight: .heavy)).foregroundStyle(.white)
                            .frame(minWidth: 168, minHeight: 56)
                            .background(X.purple, in: Capsule())
                            .shadow(color: X.purple.opacity(0.35), radius: 12, y: 8)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    circleButton("forward.end.fill", label: "Skip") { p.skip() }
                }

                Text("Each finished round is logged to the assignment and shows on your calendar. You'll get a notification when a round or break ends.")
                    .font(.system(size: 13)).foregroundStyle(X.muted).multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    stat(Scheduler.durationText(p.focusMinutesToday), "focused today")
                    stat("\(p.roundsToday) 🍅", "rounds today")
                    stat(Scheduler.durationText(store.minutesThisWeek), "logged this week")
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 120)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(LinearGradient(colors: [X.page, X.purpleSoft.opacity(0.6), Color(adaptive: (1, 0.957, 0.933), dark: (0.10, 0.07, 0.06))],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .sheet(isPresented: $picking) { TaskPicker { p.taskID = $0; picking = false }.environmentObject(store) }
    }

    private func circleButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .bold)).foregroundStyle(X.ink)
                .frame(width: 52, height: 52)
                .background(X.raised, in: Circle()).overlay(Circle().strokeBorder(X.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .heavy)).foregroundStyle(X.ink)
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(X.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(X.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(X.line))
    }
}

/// Choose what a Pomodoro is for.
struct TaskPicker: View {
    @EnvironmentObject var store: BrainStore
    @Environment(\.dismiss) private var dismiss
    var onPick: (UUID?) -> Void
    var body: some View {
        NavigationStack {
            List {
                Button { onPick(nil) } label: { Label("Just focus (no assignment)", systemImage: "circle.dashed") }
                Section("Assignments") {
                    ForEach(store.logSuggestions + store.pendingTasks.filter { t in !store.logSuggestions.contains { $0.id == t.id } }) { t in
                        Button { onPick(t.id) } label: {
                            HStack {
                                Text(DayFeed.emoji(task: t))
                                VStack(alignment: .leading) {
                                    Text(t.title).foregroundStyle(X.ink)
                                    if let d = t.due { Text("Due " + d.dueText()).font(.caption).foregroundStyle(X.muted) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Focus on…")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .sheetSize(minWidth: 420, minHeight: 480)
    }
}

/// Compact card for the Mac's Today column.
struct FocusCard: View {
    @EnvironmentObject var store: BrainStore
    @ObservedObject private var p = Pomodoro.shared
    var openFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("🍅 Focus").font(.system(size: 15, weight: .bold))
                Spacer()
                Text("Round \(p.round) of 4").font(.system(size: 13, weight: .semibold)).foregroundStyle(X.muted)
            }
            HStack(spacing: 18) {
                ZStack {
                    PomodoroRing(progress: p.progress, color: p.phase == .focus ? X.purple : .green, size: 104, line: 10)
                    Text(p.clock).font(.system(size: 24, weight: .heavy).monospacedDigit()).tracking(-0.5)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.taskID.flatMap { store.task($0)?.title } ?? "Pick an assignment")
                        .font(.system(size: 16, weight: .bold)).lineLimit(2)
                    Text(p.phase == .focus ? "Then a \(p.round % 4 == 0 ? p.preset.long : p.preset.short)-minute break" : "On a break")
                        .font(.system(size: 13)).foregroundStyle(X.muted)
                    RoundDots(p: p)
                }
            }
            HStack(spacing: 8) {
                Button { if p.taskID == nil { openFocus() } else { p.toggle() } } label: {
                    Text(p.isRunning ? "Pause" : (p.isActive ? "Resume" : "Start")).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 11).background(X.purple, in: Capsule())
                }
                Button(action: openFocus) {
                    Text("Open").font(.system(size: 15, weight: .bold)).foregroundStyle(X.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(X.raised, in: Capsule()).overlay(Capsule().strokeBorder(X.line))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(LinearGradient(colors: [X.purpleSoft, Color(adaptive: (1, 0.953, 0.925), dark: (0.16, 0.10, 0.08))],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// The iPhone's running-timer strip on Today.
struct FocusStrip: View {
    @EnvironmentObject var store: BrainStore
    @ObservedObject private var p = Pomodoro.shared
    var open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ZStack {
                    PomodoroRing(progress: p.progress, color: X.purple, size: 44, line: 5)
                    Text("🍅").font(.system(size: 16))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(p.clock) left" + (p.taskID.flatMap { store.task($0)?.title }.map { " · \($0)" } ?? ""))
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(X.ink).lineLimit(1)
                    Text("Round \(p.round) of 4 · \(p.isRunning ? (p.phase == .focus ? "focusing" : "on a break") : "paused")")
                        .font(.system(size: 13)).foregroundStyle(X.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(X.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(LinearGradient(colors: [X.purpleSoft, Color(adaptive: (1, 0.953, 0.925), dark: (0.16, 0.10, 0.08))],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
