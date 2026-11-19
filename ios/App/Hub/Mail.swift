import AuthenticationServices
import CryptoKit
import Foundation
import HubKit
import UIKit

// The watch's Mail app (the chats app in mail mode, cmf-watch-sdk sdk/examples/mail; hosts/inboxhost.py is the
// reference). Gmail with the user's own Google Cloud iOS OAuth client (PKCE, no secret; redirect is the reversed
// client id). Threads are rows (sender, subject); a thread opens as its latest email's text; quick replies that
// start with "• " are actions. While Mail is open on the watch the inbox is checked every minute.

@MainActor @Observable final class MailService: NSObject, WatchService {
    static let app = "Mail"
    static let scope = "https://www.googleapis.com/auth/gmail.modify"
    static let quick = ["• Archive", "• Mark unread", "Thanks!", "Got it, will reply soon", "Sounds good", "On it"]
    static let threads = 11
    static let poll: Duration = .seconds(60)

    private(set) var email: String? = Keychain.get("google-email")
    var status: String?
    var signedIn: Bool { Keychain.get("google-refresh") != nil }

    private var token: String? { Keychain.get("google-access") }
    private var expires: Date {
        Date(timeIntervalSince1970: Double(Keychain.get("google-expires") ?? "0") ?? 0)
    }

    struct Entry {
        let id: String, history: String, from: String, subject: String
        var unread: Bool
    }

    /// The thread open on the watch: what it shows and what a reply needs.
    struct Opened {
        let id: UInt8, thread: String, title: String
        var msgs: [(me: Bool, kind: UInt8, text: String)]
        let to: String, subject: String, messageID: String, references: String
    }

    private var ids = ChatsProto.Ids()
    private var listed: [Entry] = []
    private var opened: Opened?
    private var chain: Task<Void, Never>?
    private var poller: Task<Void, Never>?

    // MARK: watch

    func receive(_ m: Data) {
        guard let ask = ChatsProto.parse(m) else { return }
        enqueue { await self.handle(ask) }
    }

    /// One job at a time: a chat's H and M messages must not interleave with another's.
    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let prev = chain
        chain = Task { await prev?.value; await job() }
    }

    private func handle(_ ask: ChatsProto.Ask) async {
        do {
            guard signedIn else { return try await signInFirst(ask) }
            switch ask {
            case .ready:
                try await refresh()
                try await sendList(quick: true)
                watch()
            case .open(let id): try await open(id)
            case .send(let id, let text): try await send(id, text)
            case .tap: break
            }
        } catch {
            status = error.localizedDescription
            try? await Hub.shared.send(Self.app, ChatsProto.append("Gmail error: \(error.localizedDescription)"))
        }
    }

    private func signInFirst(_ ask: ChatsProto.Ask) async throws {
        if case .open = ask {
            try await Hub.shared.send(Self.app, ChatsProto.chat(0, title: "Mail", [(false, 0, "Sign in with Google in CMFX on the iPhone (Hub › Mail).")]))
        } else {
            try await Hub.shared.send(Self.app, ChatsProto.list([.init(id: 0, name: "Sign in", preview: "In CMFX on the iPhone")]))
        }
    }

    private func sendList(quick: Bool = false) async throws {
        let rows = listed.map { ChatsProto.Row(id: ids.id($0.id), unread: $0.unread, name: MailText.name($0.from),
                                               preview: $0.subject.isEmpty ? "(no subject)" : $0.subject) }
        try await Hub.shared.send(Self.app, ChatsProto.list(rows) + (quick ? ChatsProto.quick(Self.quick) : []))
    }

    private func open(_ id: UInt8) async throws {
        guard let thread = ids.key(id) else { return }
        let o = try await load(id, thread)
        opened = o
        try await Hub.shared.send(Self.app, ChatsProto.chat(id, title: o.title, o.msgs))
        if let i = listed.firstIndex(where: { $0.id == thread }), listed[i].unread {
            try await modify(thread, remove: ["UNREAD"])
            listed[i].unread = false
        }
    }

    /// The thread's latest email as text, in pieces the watch shows.
    private func load(_ id: UInt8, _ thread: String) async throws -> Opened {
        let t = try await call("GET", "/threads/\(thread)", query: ["format": "full"]) as? [String: Any] ?? [:]
        let msgs = (t["messages"] as? [[String: Any]] ?? []).filter { !labels($0).contains("DRAFT") }
        guard let last = msgs.last else { throw HubError.failed("Empty thread") }
        let payload = last["payload"] as? [String: Any] ?? [:]
        let h = headers(payload)
        let from = h["from"] ?? ""
        let me = MailText.address(from).lowercased() == email?.lowercased()
        var text = MailText.body(Self.text(payload) ?? (last["snippet"] as? String).map(MailText.strip(html:)) ?? "")
        if text.isEmpty { text = "(no text)" }
        let first = headers((msgs.first?["payload"] as? [String: Any]) ?? [:])
        return Opened(id: id, thread: thread, title: MailText.name(from),
                      msgs: ChatsProto.chunks(text).prefix(ChatsProto.maxMsgs).map { (me: me, kind: ChatsProto.plain, text: $0) },
                      to: me ? (h["to"] ?? "") : (h["reply-to"] ?? from), subject: first["subject"] ?? h["subject"] ?? "",
                      messageID: h["message-id"] ?? "", references: h["references"] ?? "")
    }

    private func send(_ id: UInt8, _ text: String) async throws {
        guard let thread = ids.key(id) else { return }
        var o: Opened
        if let x = opened, x.id == id { o = x } else { o = try await load(id, thread) }
        if let action = ChatsProto.action(text) {
            var note: String?
            switch action {
            case "Archive":
                try await modify(thread, remove: ["INBOX"])
                note = "Archived"
            case "Mark unread":
                try await modify(thread, add: ["UNREAD"])
                note = "Marked unread"
            default: break
            }
            // the watch showed the action as a reply of ours: the chat again, without it
            try await Hub.shared.send(Self.app, ChatsProto.chat(id, title: o.title, o.msgs)
                + (note.map { [ChatsProto.append($0)] } ?? []))
            opened = o
            try await refresh()
            try await sendList()
            return
        }
        let raw = MailText.reply(to: o.to, subject: o.subject, messageID: o.messageID, references: o.references, text: text)
        do {
            try await call("POST", "/messages/send", body: ["raw": raw.base64url, "threadId": thread])
            // the watch already shows it (its own echo, me = 1, kind 0)
            o.msgs.append((true, ChatsProto.plain, text))
            opened = o
        } catch {
            try await Hub.shared.send(Self.app, ChatsProto.chat(id, title: o.title, o.msgs)
                + [ChatsProto.append("Not sent: \(error.localizedDescription)")])
        }
    }

    /// Checks the inbox every minute while Mail is the app the watch last talked from (a send that fails, or
    /// another app, ends it): a new unread thread buzzes and the list comes again.
    private func watch() {
        poller?.cancel()
        poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.poll)
                guard !Task.isCancelled, Hub.shared.lastApp == Self.app else { break }
                enqueue { if await !self.check() { self.poller?.cancel() } }
            }
        }
    }

    /// → false when the watch took nothing (Mail is closed).
    private func check() async -> Bool {
        let old = listed
        let seen = Dictionary(old.map { ($0.id, $0.history) }, uniquingKeysWith: { a, _ in a })
        func sig(_ t: [Entry]) -> [String] { t.map { "\($0.id) \($0.history) \($0.unread)" } }
        do {
            try await refresh()
            // unread threads that are new, or have new mail since the last look
            let fresh = listed.filter { $0.unread && seen[$0.id] != $0.history }
            if let t = fresh.first { try await Hub.shared.send(Self.app, ChatsProto.buzz(ids.id(t.id))) }
            if sig(listed) != sig(old) {
                try await sendList()
            } else {
                // nothing new: a short message that fails when Mail is no longer open
                try await Hub.shared.send(Self.app, Data([UInt8(ascii: "L"), UInt8(min(listed.count, ChatsProto.maxRows))]))
            }
            return true
        } catch {
            return false
        }
    }

    /// The newest inbox threads: From (of the latest email not ours), Subject, unread. A thread whose history did
    /// not change keeps what was fetched.
    private func refresh() async throws {
        if email == nil { try await profile() }
        let r = try await call("GET", "/threads", query: ["labelIds": "INBOX", "maxResults": "\(Self.threads)"]) as? [String: Any]
        let old = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Entry] = []
        for t in r?["threads"] as? [[String: Any]] ?? [] {
            let id = t.str("id"), history = t.str("historyId")
            if let o = old[id], o.history == history { out.append(o); continue }
            let full = try await call("GET", "/threads/\(id)", query: ["format": "metadata", "metadataHeaders": "From,Subject"])
                as? [String: Any] ?? [:]
            let msgs = full["messages"] as? [[String: Any]] ?? []
            let hs = msgs.map { headers(($0["payload"] as? [String: Any]) ?? [:]) }
            let mine = email?.lowercased()
            let from = hs.last(where: { MailText.address($0["from"] ?? "").lowercased() != mine })?["from"] ?? hs.last?["from"] ?? ""
            out.append(Entry(id: id, history: history, from: from, subject: hs.first?["subject"] ?? "",
                              unread: msgs.contains { labels($0).contains("UNREAD") }))
        }
        listed = out
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
        listed = []
        opened = nil
        poller?.cancel()
    }
}

extension MailService: ASWebAuthenticationPresentationContextProviding {
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
