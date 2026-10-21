import Foundation
import BrainCore

// Blob's Calendar & Reminders helper (Mac). Blob runs it for each Apple sync: assignments and events come in as JSON on
// stdin, the changes made in Calendar/Reminders go back out as JSON on stdout. Running EventKit's Reminders code inside
// Blob's own process crashed it, so this keeps it in a separate, short-lived process. It uses Blob's Calendar and
// Reminders permissions.

struct Input: Decodable {
    var tasks: [BrainTask]
    var events: [BrainEvent]
    var options: AppleSync.Options
}

struct Output: Encodable {
    var result: AppleSync.Result?
    var error: String?
}

let encoder = JSONEncoder()
let done = DispatchSemaphore(value: 0)
var output = Output()
Task {
    do {
        let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
        output.result = try await AppleSync().sync(tasks: input.tasks, events: input.events, options: input.options)
    } catch {
        output.error = String(describing: error)
    }
    done.signal()
}
// Keep the main run loop going (EventKit delivers some callbacks on it) until the sync finishes.
while done.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
FileHandle.standardOutput.write((try? encoder.encode(output)) ?? Data("{\"error\":\"encode\"}".utf8))
exit(output.error == nil ? 0 : 1)
