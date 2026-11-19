import AuthenticationServices
import CryptoKit
import Foundation
import HubKit
import UIKit

// Mail from Gmail's REST API with the user's own Google Cloud iOS OAuth client (PKCE, no secret; redirect is the
// reversed client id). Rows are threads: From of the latest email not ours, Subject of the first.

@MainActor @Observable final class GmailBackend: NSObject, MailBackend {
    static let scope = "https://www.googleapis.com/auth/gmail.modify"

    let label = "Gmail"
    private(set) var email: String? = Keychain.get("google-email")
    var status: String?
    var signedIn: Bool { Keychain.get("google-refresh") != nil }
    var configured: Bool { signedIn }
    var address: String? { email }

    private var token: String? { Keychain.get("google-access") }
    private var expires: Date {
        Date(timeIntervalSince1970: Double(Keychain.get("google-expires") ?? "0") ?? 0)
    }

    /// Threads as last fetched: one whose history did not change keeps what was fetched.
    private var cache: [String: MailEntry] = [:]

    func reset() { cache = [:] }

    // MARK: MailBackend

    func inbox(_ n: Int) async throws -> [MailEntry] {
        if email == nil { try await profile() }
        let r = try await call("GET", "/threads", query: ["labelIds": "INBOX", "maxResults": "\(n)"]) as? [String: Any]
        var out: [MailEntry] = []
        for t in r?["threads"] as? [[String: Any]] ?? [] {
            let id = t.str("id"), history = t.str("historyId")
            if let o = cache[id], o.version == history { out.append(o); continue }
            let full = try await call("GET", "/threads/\(id)", query: ["format": "metadata", "metadataHeaders": "From,Subject"])
                as? [String: Any] ?? [:]
            let msgs = full["messages"] as? [[String: Any]] ?? []
            let hs = msgs.map { headers(($0["payload"] as? [String: Any]) ?? [:]) }
            let mine = email?.lowercased()
            let from = hs.last(where: { MailText.address($0["from"] ?? "").lowercased() != mine })?["from"] ?? hs.last?["from"] ?? ""
            out.append(MailEntry(id: id, version: history, from: from, subject: hs.first?["subject"] ?? "",
                                 unread: msgs.contains { labels($0).contains("UNREAD") }))
        }
        cache = Dictionary(out.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return out
    }

    func message(_ thread: String) async throws -> MailMessage {
        let t = try await call("GET", "/threads/\(thread)", query: ["format": "full"]) as? [String: Any] ?? [:]
        let msgs = (t["messages"] as? [[String: Any]] ?? []).filter { !labels($0).contains("DRAFT") }
        guard let last = msgs.last else { throw HubError.failed("Empty thread") }
        let payload = last["payload"] as? [String: Any] ?? [:]
        let h = headers(payload)
        let first = headers((msgs.first?["payload"] as? [String: Any]) ?? [:])
        let text = Self.text(payload) ?? (last["snippet"] as? String).map(MailText.strip(html:)) ?? ""
        return MailMessage(from: h["from"] ?? "", to: h["to"] ?? "", replyTo: h["reply-to"],
                           subject: first["subject"] ?? h["subject"] ?? "", messageID: h["message-id"] ?? "",
                           references: h["references"] ?? "", text: text)
    }

    func setRead(_ thread: String, _ read: Bool) async throws {
        try await modify(thread, add: read ? [] : ["UNREAD"], remove: read ? ["UNREAD"] : [])
    }

    func archive(_ thread: String) async throws { try await modify(thread, remove: ["INBOX"]) }

    func reply(_ thread: String, to: String, subject: String, messageID: String, references: String, text: String) async throws {
        let raw = MailText.reply(to: to, subject: subject, messageID: messageID, references: references, text: text)
        try await call("POST", "/messages/send", body: ["raw": raw.base64url, "threadId": thread])
    }

    // MARK: Gmail

    private func labels(_ m: [String: Any]) -> [String] { m["labelIds"] as? [String] ?? [] }

    /// A message part's headers, names lowercased.
    private func headers(_ payload: [String: Any]) -> [String: String] {
        var h: [String: String] = [:]
        for x in payload["headers"] as? [[String: Any]] ?? [] { h[x.str("name").lowercased()] = x.str("value") }
        return h
    }

    /// text/plain if there is one, else text/html as text.
    static func text(_ payload: [String: Any]) -> String? {
        func find(_ p: [String: Any], _ mime: String) -> String? {
            if p.str("mimeType").lowercased() == mime, let d = (p["body"] as? [String: Any])?["data"] as? String,
               let data = Data(base64url: d) {
                return String(decoding: data, as: UTF8.self)
            }
            for part in p["parts"] as? [[String: Any]] ?? [] {
                if let t = find(part, mime) { return t }
            }
            return nil
        }
        return find(payload, "text/plain") ?? find(payload, "text/html").map(MailText.strip(html:))
    }

    private func modify(_ thread: String, add: [String] = [], remove: [String] = []) async throws {
        try await call("POST", "/threads/\(thread)/modify", body: ["addLabelIds": add, "removeLabelIds": remove])
    }

    private func profile() async throws {
        let p = try await call("GET", "/profile") as? [String: Any] ?? [:]
        email = p["emailAddress"] as? String
        Keychain.set("google-email", email)
    }

    @discardableResult
    private func call(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> Any? {
        let token = try await fresh()
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me" + path)!
        if !query.isEmpty {
            // metadataHeaders repeats
            c.queryItems = query.flatMap { k, v in
                k == "metadataHeaders" ? v.split(separator: ",").map { URLQueryItem(name: k, value: String($0)) } : [URLQueryItem(name: k, value: v)]
            }
        }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { Keychain.set("google-expires", "0") }
        guard (200..<300).contains(code) else { throw HubError.failed("Gmail \(code)") }
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
    }

    /// The access token, refreshed when it is near its end.
    private func fresh() async throws -> String {
        if let token, expires.timeIntervalSinceNow > 60 { return token }
        guard let refresh = Keychain.get("google-refresh") else { throw HubError.notSignedIn }
        try await tokens(["grant_type": "refresh_token", "refresh_token": refresh])
        guard let token else { throw HubError.notSignedIn }
        return token
    }

    private func tokens(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var f = form
        f["client_id"] = Secrets.googleClient
        req.httpBody = f.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], let access = j["access_token"] as? String
        else { throw HubError.failed("Google sign-in failed") }
        Keychain.set("google-access", access)
        Keychain.set("google-expires", "\(Date.now.timeIntervalSince1970 + Double(j["expires_in"] as? Int ?? 3600))")
        if let r = j["refresh_token"] as? String { Keychain.set("google-refresh", r) }
    }

    // MARK: sign-in (PKCE)

    /// The iOS client's redirect scheme: its id reversed (com.googleusercontent.apps.<prefix>).
    static var scheme: String {
        let id = Secrets.googleClient.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps." + id
    }
    static var redirect: String { scheme + ":/oauth2redirect" }

    private var authSession: ASWebAuthenticationSession?

    func signIn() async {
        status = nil
        guard !Secrets.googleClient.isEmpty else { status = "Enter your Google OAuth client ID first."; return }
        let verifier = Data((0..<48).map { _ in UInt8.random(in: 0...255) }).base64url
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64url
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: Secrets.googleClient), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
        ]
        do {
            let url: URL = try await withCheckedThrowingContinuation { k in
                let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: Self.scheme) { url, err in
                    if let url { k.resume(returning: url) } else { k.resume(throwing: err ?? HubError.notSignedIn) }
                }
                s.presentationContextProvider = self
                authSession = s
                s.start()
            }
            guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "code" })?.value else { throw HubError.notSignedIn }
            try await tokens(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                              "code_verifier": verifier])
            try await profile()
            Hub.shared.mail.restart()
        } catch {
            status = error.localizedDescription
        }
    }

    func signOut() {
        if let r = Keychain.get("google-refresh") {
            var c = URLComponents(string: "https://oauth2.googleapis.com/revoke")!
            c.queryItems = [.init(name: "token", value: r)]
            var req = URLRequest(url: c.url!)
            req.httpMethod = "POST"
            Task { _ = try? await URLSession.shared.data(for: req) }
        }
        for k in ["google-access", "google-refresh", "google-expires", "google-email"] { Keychain.set(k, nil) }
        email = nil
        Hub.shared.mail.restart()
    }
}

extension GmailBackend: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

extension Data {
    init?(base64url s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        self.init(base64Encoded: b)
    }
}
