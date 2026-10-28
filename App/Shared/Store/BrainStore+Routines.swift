import Foundation
import BrainCore

extension BrainStore {
    var routines: [DailyRoutine] { doc.routines.filter { !$0.deleted }.sorted { $0.startMinute < $1.startMinute } }

    func routine(_ id: UUID?) -> DailyRoutine? { id.flatMap { id in doc.routines.first { $0.id == id } } }

    func delete(_ r: DailyRoutine) {
        var r = r
        r.deleted = true
        upsert(r)
    }

    /// Routines that run on a day, with their steps' times.
    func routines(on day: Date) -> [DailyRoutine] { routines.filter { $0.runs(on: day) } }
}
