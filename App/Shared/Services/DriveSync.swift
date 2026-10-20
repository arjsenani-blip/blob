import Foundation
import BrainCore

/// Keeps Mac and iPhone in sync through one JSON file in your Google Drive's hidden app-data folder
/// (it doesn't show up in Drive and only this app can see it). Each record merges newest-edit-wins.
struct DriveSync {
    let account: GoogleAccount
    private static let fileName = "arjuns-brain.json"

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Downloads the remote copy, merges it with `local`, uploads the result, and returns it.
    func sync(local: BrainDocument) async throws -> BrainDocument {
        let fileID = try await findFile()
        var remote = BrainDocument()
        var remoteData: Data?
        if let fileID {
            let data = try await account.send(URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!))
            remoteData = data
            remote = (try? JSONDecoder().decode(BrainDocument.self, from: data)) ?? BrainDocument()
            if remote.schemaVersion > BrainDocument.currentSchema {
                throw GoogleError.http(409, "Your other device has a newer version of Blob. Update this one.")
            }
        }

        let merged = SyncMerger.merge(local, remote)
        let out = try Self.encoder.encode(merged)
        if out != remoteData {
            if let fileID {
                var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(fileID)?uploadType=media")!)
                req.httpMethod = "PATCH"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = out
                _ = try await account.send(req)
            } else {
                try await create(out)
            }
        }
        return merged
    }

    private func findFile() async throws -> String? {
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            .init(name: "spaces", value: "appDataFolder"),
            .init(name: "q", value: "name = '\(Self.fileName)'"),
            .init(name: "fields", value: "files(id,modifiedTime)"),
            .init(name: "orderBy", value: "modifiedTime desc"),
        ]
        let data = try await account.send(URLRequest(url: comps.url!))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["files"] as? [[String: Any]])?.first?["id"] as? String
    }

    private func create(_ body: Data) async throws {
        let boundary = "brain-\(UUID().uuidString)"
        let meta = #"{"name":"\#(Self.fileName)","parents":["appDataFolder"],"mimeType":"application/json"}"#
        var payload = Data()
        payload.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(meta)\r\n".data(using: .utf8)!)
        payload.append("--\(boundary)\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        payload.append(body)
        payload.append("\r\n--\(boundary)--".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        _ = try await account.send(req)
    }
}
