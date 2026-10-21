import SwiftUI

/// Settings → Training: start training mode, and review, fix, run or delete what Blob has learned.
struct TrainingSettingsSection: View {
    @ObservedObject private var library = RoutineLibrary.shared
    @ObservedObject private var buddy = BuddyController.shared
    @State private var newName = ""

    var body: some View {
        Section {
            HStack {
                TextField("What will you show Blob? (e.g. upload my essay to Classroom)", text: $newName)
                Button(buddy.training ? "Stop watching" : "Start training") {
                    if buddy.training { buddy.stopTraining() }
                    else {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        newName = ""
                        // Give you a moment to switch to the app you'll use.
                        NSApp.hide(nil)
                        buddy.say(buddy.startTraining(name: name.isEmpty ? nil : name))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(buddy.training ? .red : BuddyColors.deep)
            }
            if library.routines.isEmpty {
                Text("Nothing learned yet.").foregroundStyle(.secondary)
            }
            ForEach(library.routines) { r in RoutineRow(routine: r) }
        } header: {
            Text("Training mode")
        } footer: {
            Text("Say “training mode” (or “watch me upload my essay”), do the task once, then tap \(BuddyShortcut.current.label). Next time just say its name. Blob remembers which buttons and links you clicked by name, what you typed, shortcuts, apps and web pages. It never records passwords — it pauses there so you can type them. Routines that click things like Send, Submit, Turn in, Delete or Buy always ask first. Saved only on this Mac.")
        }
    }
}

private struct RoutineRow: View {
    @ObservedObject private var library = RoutineLibrary.shared
    @State var routine: Routine
    @State private var phrases = ""

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $routine.name).onSubmit(save)
                TextField("Other ways to ask (comma separated)", text: $phrases)
                    .onSubmit {
                        routine.phrases = phrases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        save()
                    }
                ForEach(Array(routine.steps.enumerated()), id: \.element.id) { i, step in
                    HStack(spacing: 8) {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                        Image(systemName: icon(step.kind)).foregroundStyle(BuddyColors.deep).frame(width: 18)
                        Text(step.summary).lineLimit(2)
                        Spacer()
                        if step.kind == .type {
                            Toggle("Ask each time", isOn: Binding(
                                get: { routine.steps[i].isInput == true },
                                set: { routine.steps[i].isInput = $0 ? true : nil; save() }))
                                .toggleStyle(.checkbox).font(.caption)
                                .help("Next time, type what you say after the routine's name instead of this")
                        }
                        Button { routine.steps.remove(at: i); save() } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove this step")
                    }
                    .font(.callout)
                }
                HStack {
                    Button("Run now") {
                        let r = routine
                        Task { BuddyController.shared.say(await BuddyController.shared.runRoutine(r, input: nil)) }
                    }
                    Button("Re-teach") {
                        library.delete(routine.id)
                        NSApp.hide(nil)
                        BuddyController.shared.say(BuddyController.shared.startTraining(name: routine.name))
                    }
                    Spacer()
                    Button("Delete", role: .destructive) { library.delete(routine.id) }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text(routine.name).fontWeight(.semibold)
                Spacer()
                Text("\(routine.steps.count) steps" + (routine.runs > 0 ? " · ran \(routine.runs)×" : "")).foregroundStyle(.secondary).font(.caption)
            }
        }
        .onAppear { phrases = routine.phrases.joined(separator: ", ") }
        .onChange(of: library.routines) { if let fresh = library.routines.first(where: { $0.id == routine.id }) { routine = fresh } }
    }

    private func save() { library.save(routine) }

    private func icon(_ k: RoutineStep.Kind) -> String {
        switch k {
        case .openApp: return "app"
        case .openURL: return "safari"
        case .click: return "cursorarrow.click"
        case .type: return "keyboard"
        case .key: return "command"
        case .scroll: return "scroll"
        case .waitForUser: return "hand.raised"
        }
    }
}
