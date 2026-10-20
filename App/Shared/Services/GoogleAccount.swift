import Foundation
import AuthenticationServices
import CryptoKit
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum GoogleError: LocalizedError {
    case notConfigured, notSignedIn, cancelled, badResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Google OAuth client ID in Settings first."
        case .notSignedIn: return "Sign in with Google first."
        case .cancelled: return "Sign-in was cancelled."
        case .badResponse: return "Google sent back something unexpected."
        case .http(let code, let msg):
            if code == 403, msg.contains("admin") || msg.contains("policy") || msg.contains("access_denied") {
                return "Your school's Google admin is blocking this app (403). Ask IT to allow it, or use a personal account for sync."
            }
            return "Google error \(code): \(msg)"
        }
    }
}

/// One signed-in Google account. Uses the standard OAuth "installed app" flow with PKCE,
/// so there's no client secret in the app. Tokens live in the Keychain on each device.
@MainActor
final class GoogleAccount: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    enum Role: String { case school, personal }

    static let classroomScopes = [
        "https://www.googleapis.com/auth/classroom.courses.readonly",
        "https://www.googleapis.com/auth/classroom.coursework.me.readonly",
    ]
    static let driveScope = "https://www.googleapis.com/auth/drive.appdata"
    /// Read your calendars and add/update Blob's own events.
    static let calendarScopes = [
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    ]
    /// Assignments as Google Tasks, which Google Calendar shows as tasks on their due dates.
    static let tasksScope = "https://www.googleapis.com/auth/tasks"

    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiry: Date
        var email: String?
        var scopes: String
    }

    let role: Role
    @Published private(set) var email: String?
    @Published private(set) var isWorking = false
    @Published var lastError: String?
    private var tokens: Tokens?
    private var session: ASWebAuthenticationSession?

    var isSignedIn: Bool { tokens != nil }
    func hasScope(_ scope: String) -> Bool { tokens?.scopes.split(separator: " ").contains { $0 == scope } ?? false }
    var grantedScopes: [String] {
        (tokens?.scopes ?? "").split(separator: " ").map(String.init).filter { $0.hasPrefix("https://") }
    }

    /// Ask for more access while keeping what was already granted (e.g. adding Google Calendar to the school account).
    func addScopes(_ scopes: [String]) async {
        await signIn(scopes: Array(Set(grantedScopes + scopes)).sorted())
    }

    init(role: Role) {
        self.role = role
        super.init()
        if let data = Keychain.get(account: keychainKey), let t = try? JSONDecoder().decode(Tokens.self, from: data) {
            tokens = t
            email = t.email
        }
    }

    private var keychainKey: String { "google.\(role.rawValue)" }

    static var clientID: String {
        (UserDefaults.standard.string(forKey: "googleClientID") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Google's iOS-type client IDs use the reversed client ID as the redirect scheme.
    static var redirectScheme: String {
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(prefix)"
    }
    static var redirectURI: String { redirectScheme + ":/oauthredirect" }

    // MARK: Sign in / out

    func signIn(scopes: [String]) async {
        lastError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await performSignIn(scopes: scopes)
        } catch GoogleError.cancelled {
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func performSignIn(scopes: [String]) async throws {
        let clientID = Self.clientID
        guard !clientID.isEmpty else { throw GoogleError.notConfigured }

        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let allScopes = (["openid", "email"] + scopes).joined(separator: " ")

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: allScopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "include_granted_scopes", value: "true"),
            .init(name: "prompt", value: "consent select_account"),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: Self.redirectScheme) { url, error in
                if let url { cont.resume(returning: url) }
                else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: GoogleError.cancelled) }
                else { cont.resume(throwing: error ?? GoogleError.badResponse) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            s.start()
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value { throw GoogleError.http(403, err) }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw GoogleError.badResponse }

        let json = try await tokenRequest([
            "code": code,
            "client_id": clientID,
            "redirect_uri": Self.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw GoogleError.badResponse
        }
        let expires = (json["expires_in"] as? Double) ?? 3600
        let mail = (json["id_token"] as? String).flatMap(Self.emailFromIDToken)
        let t = Tokens(accessToken: access, refreshToken: refresh, expiry: Date().addingTimeInterval(expires - 60),
                       email: mail, scopes: (json["scope"] as? String) ?? allScopes)
        save(t)
    }

    func signOut() {
        if let t = tokens {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(t.refreshToken)")!)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req).resume()
        }
        tokens = nil
        email = nil
        Keychain.delete(account: keychainKey)
    }

    // MARK: Tokens

    func accessToken() async throws -> String {
        guard var t = tokens else { throw GoogleError.notSignedIn }
        if t.expiry > Date() { return t.accessToken }
        let json = try await tokenRequest([
            "client_id": Self.clientID,
            "refresh_token": t.refreshToken,
            "grant_type": "refresh_token",
        ])
        guard let access = json["access_token"] as? String else { throw GoogleError.badResponse }
        t.accessToken = access
        t.expiry = Date().addingTimeInterval(((json["expires_in"] as? Double) ?? 3600) - 60)
        save(t)
        return access
    }

    /// Authorized request with one automatic retry on an expired token.
    func send(_ request: URLRequest) async throws -> Data {
        var req = request
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, var t = tokens {
            t.expiry = .distantPast
            tokens = t
            req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            let (d2, r2) = try await URLSession.shared.data(for: req)
            let c2 = (r2 as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(c2) else { throw GoogleError.http(c2, Self.message(d2)) }
            return d2
        }
        guard (200..<300).contains(code) else { throw GoogleError.http(code, Self.message(data)) }
        return data
    }

    private func tokenRequest(_ params: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if code == 400 || code == 401, params["grant_type"] == "refresh_token" {
                // Refresh token revoked or expired (testing-mode tokens last 7 days) — sign in again.
                tokens = nil
                email = nil
                Keychain.delete(account: keychainKey)
                throw GoogleError.notSignedIn
            }
            throw GoogleError.http(code, Self.message(data))
        }
        return json
    }

    private func save(_ t: Tokens) {
        tokens = t
        email = t.email
        if let data = try? JSONEncoder().encode(t) { Keychain.set(data, account: keychainKey) }
    }

    // MARK: ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first.map { UIWindow(windowScene: $0) } ?? ASPresentationAnchor()
            #endif
        }
    }

    // MARK: Helpers

    static func message(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = json["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let e = json["error_description"] as? String { return e }
            if let e = json["error"] as? String { return e }
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "unknown"
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &rng)! })
    }

    private static func emailFromIDToken(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

enum Keychain {
    private static let service = "com.arjunsenani.brain"

    static func set(_ data: Data, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
