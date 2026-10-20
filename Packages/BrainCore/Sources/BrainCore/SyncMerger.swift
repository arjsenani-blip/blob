import Foundation

public enum SyncMerger {
    public static func mergeRecords<T: SyncRecord>(_ a: [T], _ b: [T]) -> [T] {
        var byID: [UUID: T] = [:]
        for record in a + b {
            if let existing = byID[record.id], existing.updatedAt >= record.updatedAt { continue }
            byID[record.id] = record
        }
        return Array(byID.values)
    }

    /// Merges two copies of the document. Newest edit of each record wins; old tombstones and old plans are pruned.
    public static func merge(_ local: BrainDocument, _ remote: BrainDocument, now: Date = Date()) -> BrainDocument {
        let tombstoneCutoff = now.addingTimeInterval(-60 * 86_400)
        let planCutoff = now.addingTimeInterval(-14 * 86_400)

        var out = BrainDocument()
        out.events = mergeRecords(local.events, remote.events)
            .filter { !($0.deleted && $0.updatedAt < tombstoneCutoff) }
            .sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
        out.tasks = mergeRecords(local.tasks, remote.tasks)
            .filter { !($0.deleted && $0.updatedAt < tombstoneCutoff) }
            .sorted { ($0.due ?? .distantFuture, $0.id.uuidString) < ($1.due ?? .distantFuture, $1.id.uuidString) }
        out.plans = mergeRecords(local.plans, remote.plans)
            .filter { $0.checkInAt > planCutoff }
            .sorted { $0.checkInAt < $1.checkInAt }
        out.settings = local.settings.updatedAt >= remote.settings.updatedAt ? local.settings : remote.settings
        return out
    }
}
