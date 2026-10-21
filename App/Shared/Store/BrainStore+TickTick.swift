#if os(macOS)
import Foundation
import BrainCore

/// TickTick: homework (by context) ↔ a project in TickTick. Runs on the Mac.
extension BrainStore {
    var tickTickOn: Bool {
        get { UserDefaults.standard.bool(forKey: "tickTickOn") }
        set { UserDefaults.standard.set(newValue, forKey: "tickTickOn"); objectWillChange.send() }
    }
    var tickTickProject: String {
        get { UserDefaults.standard.string(forKey: "tickTickProject") ?? "Homework" }
        set { UserDefaults.standard.set(newValue, forKey: "tickTickProject"); objectWillChange.send() }
    }
    var tickTickImport: Bool {
        get { UserDefaults.standard.object(forKey: "tickTickImport") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tickTickImport"); objectWillChange.send() }
    }

    func syncTickTick() async {
        let account = TickTickAccount.shared
        guard tickTickOn, account.isSignedIn, !isTestData, !tickTickRunning else { return }
        tickTickRunning = true
        defer { tickTickRunning = false }
        do {
            let sync = TickTickSync(account: account)
            let name = tickTickProject.trimmingCharacters(in: .whitespaces).isEmpty ? "Homework" : tickTickProject
            let projectID = try await sync.project(named: name)
            var known = UserDefaults.standard.dictionary(forKey: "tickTickKnown") as? [String: String] ?? [:]
            if UserDefaults.standard.string(forKey: "tickTickProjectID") != projectID { known = [:] }
            let homework = doc.tasks.filter { $0.looksLikeSchoolwork || ($0.externalID?.hasPrefix("reminder:") ?? false) || ($0.externalID?.hasPrefix("ticktick:") ?? false) }
            let r = try await sync.sync(tasks: homework, projectID: projectID, importNew: tickTickImport, known: &known)
            UserDefaults.standard.set(known, forKey: "tickTickKnown")
            UserDefaults.standard.set(projectID, forKey: "tickTickProjectID")
            for id in r.completed { if var t = task(id), !t.isCompleted { markDone(&t); upsert(t) } }
            for s in r.stepsDone { if var t = task(s.task) { finishStep(&t, s.step); upsert(t) } }
            for item in r.imported where task(item.id) == nil {
                let parsed = parse(item.title)
                upsert(BrainTask(id: item.id, title: item.title, course: parsed.course, notes: item.notes,
                                 due: item.due ?? (parsed.kind == .task ? parsed.start : nil), estimatedMinutes: parsed.durationMinutes ?? 30,
                                 externalID: "ticktick:\(item.id.uuidString)"))
            }
            if !r.completed.isEmpty { show("Marked done from TickTick ✓") }
            if !r.imported.isEmpty { show("\(r.imported.count) new from TickTick") }
            tickTickError = nil
            SyncLog.write("ticktick: ok, done \(r.completed.count), steps \(r.stepsDone.count), imported \(r.imported.count), tracking \(known.count)")
        } catch {
            tickTickError = error.localizedDescription
            SyncLog.write("ticktick: error \(error)")
        }
    }
}
#endif
