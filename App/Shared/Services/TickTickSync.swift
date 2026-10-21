#if os(macOS)
import Foundation
import Network
import AppKit
import BrainCore

// TickTick (Mac): homework goes into a "Homework" project in TickTick, with long-term steps as checklist items.
// Two-way: completing a task or checking a step in TickTick does the same in Blob, and tasks you add to the
// Homework project come into Blob. The Mac does this; the iPhone and Windows get the results through Blob's own sync.
//
// TickTick's API needs your own free developer app (developer.ticktick.com) — its client ID and secret go in Settings.

@MainActor
final class TickTickAccount: ObservableObject {
    static let shared = TickTickAccount()
    static let redirectPort: UInt16 = 8765
    static var redirectURI: String { "http://127.0.0.1:\(redirectPort)/ticktick" }

    @Published private(set) var isSignedIn = false
    @Published private(set) var isWorking = false
    @Published var lastError: String?

    private var token: String? {
        didSet { isSignedIn = token != nil }
    }

    init() {
        token = Keychain.get(account: "ticktick").flatMap { String(data: $0, encoding: .utf8) }
        isSignedIn = token != nil
    }

    var clientID: String { (UserDefaults.standard.string(forKey: "tickTickClientID") ?? "").trimmingCharacters(in: .whitespaces) }
    var clientSecret: String { (UserDefaults.standard.string(forKey: "tickTickClientSecret") ?? "").trimmingCharacters(in: .whitespaces) }

    /// The simple way: a personal API token from TickTick → Settings → Account → API Token.
    func useToken(_ raw: String) async {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "Bearer ", with: "")
        guard !t.isEmpty else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        token = t
        do {
            _ = try await send("GET", "/project")       // check it works
            Keychain.set(Data(t.utf8), account: "ticktick")
        } catch {
            token = nil
            lastError = "That token didn't work — copy it again from TickTick → Settings → Account → API Token."
        }
    }

    func signOut() {
        token = nil
        Keychain.delete(account: "ticktick")
    }

    /// Opens TickTick's sign-in page in your browser and waits for it to come back to Blob on this Mac.
    func signIn() async {
        guard !clientID.isEmpty, !clientSecret.isEmpty else { lastError = "Add your TickTick client ID and secret first."; return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let state = UUID().uuidString
            var comps = URLComponents(string: "https://ticktick.com/oauth/authorize")!
            comps.queryItems = [.init(name: "client_id", value: clientID), .init(name: "scope", value: "tasks:read tasks:write"),
                                .init(name: "state", value: state), .init(name: "redirect_uri", value: Self.redirectURI),
                                .init(name: "response_type", value: "code")]
            let code = try await LoopbackReceiver.waitForCode(port: Self.redirectPort, state: state) {
                NSWorkspace.shared.open(comps.url!)
            }
            var req = URLRequest(url: URL(string: "https://ticktick.com/oauth/token")!)
            req.httpMethod = "POST"
            req.setValue("Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let form = ["code": code, "grant_type": "authorization_code", "scope": "tasks:read tasks:write", "redirect_uri": Self.redirectURI]
            req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
                .joined(separator: "&").data(using: .utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let access = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["access_token"] as? String else {
                throw TickTickError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
            }
            Keychain.set(Data(access.utf8), account: "ticktick")
            token = access
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: API

    func send(_ method: String, _ path: String, body: Any? = nil) async throws -> Data {
        guard let token else { throw TickTickError.notSignedIn }
        var req = URLRequest(url: URL(string: "https://api.ticktick.com/open/v1" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { signOut(); throw TickTickError.notSignedIn }
        guard (200..<300).contains(code) else { throw TickTickError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    func json(_ method: String, _ path: String, body: Any? = nil) async throws -> Any {
        let data = try await send(method, path, body: body)
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
    }
}

enum TickTickError: LocalizedError {
    case notSignedIn, http(Int, String), noCode
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Connect TickTick again in Settings."
        case .http(let c, let m): return "TickTick error \(c)" + (m.isEmpty ? "" : ": \(m.prefix(160))")
        case .noCode: return "TickTick sign-in didn't finish."
        }
    }
}

/// A one-shot web listener on 127.0.0.1 that catches TickTick's redirect with the sign-in code.
enum LoopbackReceiver {
    static func waitForCode(port: UInt16, state: String, open: @escaping () -> Void) async throws -> String {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            let finish: (Result<String, Error>) -> Void = { r in
                guard !finished else { return }
                finished = true
                listener.cancel()
                cont.resume(with: r)
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
                    let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let items = URLComponents(string: "http://x" + path)?.queryItems ?? []
                    let code = items.first { $0.name == "code" }?.value
                    let ok = code != nil && items.first { $0.name == "state" }?.value == state
                    let page = ok ? "You're connected — go back to Blob." : "TickTick sign-in didn't finish. Try again from Blob's Settings."
                    let html = "<html><body style=\"font-family:-apple-system;background:#06121f;color:#bff;display:grid;place-items:center;height:100vh\"><h2>\(page)</h2></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    if path.hasPrefix("/ticktick") { finish(ok ? .success(code!) : .failure(TickTickError.noCode)) }
                }
            }
            listener.stateUpdateHandler = { s in
                switch s {
                case .ready: open()
                case .failed(let e): finish(.failure(e))
                default: break
                }
            }
            listener.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { finish(.failure(TickTickError.noCode)) }
        }
    }
}

// MARK: - Sync

@MainActor
struct TickTickSync {
    let account: TickTickAccount

    struct Result {
        var completed: [UUID] = []
        var stepsDone: [(task: UUID, step: UUID)] = []
        var imported: [(id: UUID, title: String, due: Date?, notes: String?)] = []
    }

    /// Finds (or makes) the project homework goes in.
    func project(named name: String) async throws -> String {
        let list = try await account.json("GET", "/project") as? [[String: Any]] ?? []
        if let p = list.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }), let id = p["id"] as? String { return id }
        let made = try await account.json("POST", "/project", body: ["name": name, "kind": "TASK", "viewMode": "list", "color": "#00C7F2"]) as? [String: Any]
        guard let id = made?["id"] as? String else { throw TickTickError.http(0, "Couldn't create the \(name) project.") }
        return id
    }

    static let df: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"       // TickTick's format: 2019-11-13T03:00:00+0000
        return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = df.date(from: s) { return d }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f.date(from: s)
    }

    /// `known`: Blob task id → TickTick task id from earlier syncs (so completed tasks can be found — TickTick only lists open ones).
    func sync(tasks: [BrainTask], projectID: String, importNew: Bool, known: inout [String: String]) async throws -> Result {
        var result = Result()
        let data = try await account.json("GET", "/project/\(projectID)/data") as? [String: Any]
        let open = data?["tasks"] as? [[String: Any]] ?? []
        var byKey: [String: [String: Any]] = [:]
        let live = Set(tasks.map(\.id))
        for t in open {
            let content = (t["content"] as? String) ?? ""
            if let key = content.components(separatedBy: "\n").last(where: { $0.hasPrefix("blob://task/") }) {
                if byKey[key] != nil, let id = t["id"] as? String { _ = try? await account.send("DELETE", "/project/\(projectID)/task/\(id)"); continue }
                byKey[key] = t
            } else if importNew, let title = t["title"] as? String, let tid = t["id"] as? String {
                // Added by you in TickTick → becomes an assignment; tag it so it's matched from now on.
                let id = UUID.stable(from: "ticktick:\(tid)")
                if !live.contains(id) {
                    result.imported.append((id, title, Self.parse(t["dueDate"] as? String), content.isEmpty ? nil : content))
                }
                var updated = t
                updated["content"] = (content.isEmpty ? "" : content + "\n") + "blob://task/\(id.uuidString)"
                _ = try? await account.json("POST", "/task/\(tid)", body: updated)
                known[id.uuidString] = tid
                byKey["blob://task/\(id.uuidString)"] = updated
            }
        }

        let recentlyDone = Date().addingTimeInterval(-14 * 86_400)
        for t in tasks {
            let key = "blob://task/\(t.id.uuidString)"
            let remote = byKey[key]
            let wanted = !t.deleted && !t.isCompleted
            if let remote, let tid = remote["id"] as? String {
                known[t.id.uuidString] = tid
                if !wanted {
                    // Done or deleted in Blob → done/removed in TickTick.
                    if t.deleted { _ = try? await account.send("DELETE", "/project/\(projectID)/task/\(tid)") }
                    else { _ = try? await account.send("POST", "/project/\(projectID)/task/\(tid)/complete") }
                    continue
                }
                // Steps checked in TickTick → checked in Blob.
                let items = remote["items"] as? [[String: Any]] ?? []
                var checkedThere = false
                for item in items where (item["status"] as? Int ?? 0) != 0 {
                    if let title = item["title"] as? String, let m = t.milestones.first(where: { !$0.isDone && $0.title == title }) {
                        result.stepsDone.append((t.id, m.id))
                        checkedThere = true
                    }
                }
                // Blob takes those in first; next sync sends the rest back.
                if checkedThere { continue }
                let body = payload(t, projectID: projectID, id: tid, existingItems: items)
                if changed(remote, body) { _ = try? await account.json("POST", "/task/\(tid)", body: body) }
            } else if wanted {
                if let tid = known[t.id.uuidString] {
                    // Gone from the open list → finished (or deleted) in TickTick.
                    let task = try? await account.json("GET", "/project/\(projectID)/task/\(tid)") as? [String: Any]
                    if (task?["status"] as? Int ?? 0) == 2 { result.completed.append(t.id); continue }
                    if task != nil { continue }
                    known[t.id.uuidString] = nil
                    if t.updatedAt < Date().addingTimeInterval(-60) { continue }   // you deleted it there; don't bring it back
                }
                let made = try await account.json("POST", "/task", body: payload(t, projectID: projectID, id: nil, existingItems: [])) as? [String: Any]
                if let tid = made?["id"] as? String { known[t.id.uuidString] = tid }
            } else if t.isCompleted, (t.completedAt ?? .distantPast) > recentlyDone, let tid = known[t.id.uuidString] {
                _ = try? await account.send("POST", "/project/\(projectID)/task/\(tid)/complete")
                known[t.id.uuidString] = nil
            }
        }
        return result
    }

    private func payload(_ t: BrainTask, projectID: String, id: String?, existingItems: [[String: Any]]) -> [String: Any] {
        var lines = [t.course, t.isLongTerm && !t.isCompleted ? "\(Int(t.progress * 100))% done · \(t.pace().label)" : nil, t.link].compactMap { $0 }
        lines.append("blob://task/\(t.id.uuidString)")
        var b: [String: Any] = ["title": t.title, "projectId": projectID, "content": lines.joined(separator: "\n"),
                                "priority": t.priority == .high ? 5 : (t.priority == .low ? 1 : 0), "timeZone": TimeZone.current.identifier]
        if let id { b["id"] = id }
        if let due = t.due {
            let allDay = AppleSync.isEndOfDay(due)
            b["isAllDay"] = allDay
            let d = allDay ? Calendar.current.startOfDay(for: due) : due
            b["dueDate"] = Self.df.string(from: d)
            b["startDate"] = Self.df.string(from: d)
        }
        // Steps as a checklist, keeping TickTick's own item ids.
        if !t.milestones.isEmpty {
            b["items"] = t.milestones.map { m -> [String: Any] in
                var item: [String: Any] = ["title": m.title, "status": m.isDone ? 1 : 0]
                if let old = existingItems.first(where: { $0["title"] as? String == m.title }), let iid = old["id"] { item["id"] = iid }
                return item
            }
        }
        return b
    }

    private func changed(_ remote: [String: Any], _ body: [String: Any]) -> Bool {
        func s(_ v: Any?) -> String { v.map { "\($0)" } ?? "" }
        if s(remote["title"]) != s(body["title"]) || s(remote["content"]) != s(body["content"]) || s(remote["priority"]) != s(body["priority"]) { return true }
        if Self.parse(remote["dueDate"] as? String) != (body["dueDate"] as? String).flatMap(Self.parse) { return true }
        let ri = (remote["items"] as? [[String: Any]] ?? []).map { "\(s($0["title"]))=\(s($0["status"]))" }
        let bi = (body["items"] as? [[String: Any]] ?? []).map { "\(s($0["title"]))=\(s($0["status"]))" }
        return ri != bi
    }
}
#endif
