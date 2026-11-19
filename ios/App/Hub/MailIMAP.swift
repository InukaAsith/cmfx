import Foundation
import HubKit
import Network

// Mail from any IMAP + SMTP account with an app password (Gmail, iCloud, Yahoo, Zoho, Fastmail, …). No packages:
// Network.framework for TLS from the start (IMAP 993, SMTP 465); STARTTLS (SMTP 587, IMAP 143) goes over
// URLSessionStreamTask, which can turn TLS on mid-connection (an NWConnection cannot). Rows are single emails, the
// newest 11 in INBOX by UID. HubKit's Imap, Smtp and Mime do the parsing. The password lives in the Keychain only
// and is never logged or shown.

/// The account's settings (Keychain, "imap-account"); its password is apart ("imap-password").
struct ImapAccount: Codable, Equatable {
    var email = "", imapHost = "", imapPort = 993, smtpHost = "", smtpPort = 465

    /// Servers for a known address's domain.
    static func preset(_ email: String) -> (imap: String, imapPort: Int, smtp: String, smtpPort: Int)? {
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        switch domain {
        case "gmail.com", "googlemail.com": return ("imap.gmail.com", 993, "smtp.gmail.com", 465)
        case "icloud.com", "me.com", "mac.com": return ("imap.mail.me.com", 993, "smtp.mail.me.com", 587)
        case "yahoo.com", "ymail.com", "rocketmail.com": return ("imap.mail.yahoo.com", 993, "smtp.mail.yahoo.com", 465)
        case "zoho.com", "zohomail.com": return ("imap.zoho.com", 993, "smtp.zoho.com", 465)
        case "fastmail.com", "fastmail.fm": return ("imap.fastmail.com", 993, "smtp.fastmail.com", 465)
        default: return nil
        }
    }

    /// Outlook, Hotmail and Live no longer take a password over IMAP (Microsoft turned basic auth off).
    static func unsupported(_ email: String) -> Bool {
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        return ["outlook.com", "hotmail.com", "live.com", "msn.com"].contains { domain == $0 || domain.hasPrefix($0.dropLast(4) + ".") }
    }

    var complete: Bool { email.contains("@") && !imapHost.isEmpty && !smtpHost.isEmpty }
    /// Gmail keeps a copy of what its SMTP sends; other servers need it put in Sent.
    var gmail: Bool { imapHost.lowercased().hasSuffix("gmail.com") || imapHost.lowercased().hasSuffix("googlemail.com") }

    static var saved: ImapAccount? {
        get { Keychain.get("imap-account").flatMap { try? JSONDecoder().decode(ImapAccount.self, from: Data($0.utf8)) } }
        set { Keychain.set("imap-account", newValue.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }) }
    }
    static var password: String? {
        get { Keychain.get("imap-password").flatMap { $0.isEmpty ? nil : $0 } }
        set { Keychain.set("imap-password", newValue.flatMap { $0.isEmpty ? nil : $0 }) }
    }
}

enum MailNetError: LocalizedError {
    case timeout(String), closed(String), server(String), refused(String)
    var errorDescription: String? {
        switch self {
        case .timeout(let h): "\(h) did not answer in time."
        case .closed(let h): "\(h) closed the connection."
        case .server(let s): s
        case .refused(let s): s
        }
    }
}

// MARK: - socket

/// A continuation resumed once, whichever comes first (a reply or its timer).
final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var k: CheckedContinuation<T, Error>?
    init(_ k: CheckedContinuation<T, Error>) { self.k = k }

    @discardableResult
    func resume(_ r: Result<T, Error>) -> Bool {
        lock.lock()
        let c = k
        k = nil
        lock.unlock()
        c?.resume(with: r)
        return c != nil
    }
}

/// A byte stream to a mail server over TLS: TLS from the start, or plain until `startTLS()`.
final class MailSocket: @unchecked Sendable {
    enum Security { case tls, startTLS }

    let host: String, port: Int, security: Security
    var timeout: TimeInterval = 20

    private let queue = DispatchQueue(label: "cmfx.mail.socket")
    private var conn: NWConnection?
    private var stream: URLSessionStreamTask?

    init(host: String, port: Int, security: Security) {
        self.host = host; self.port = port; self.security = security
    }

    func open() async throws {
        switch security {
        case .startTLS:
            let s = URLSession.shared.streamTask(withHostName: host, port: port)
            stream = s
            s.resume()
        case .tls:
            guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw MailNetError.refused("Bad port \(port)") }
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = Int(timeout)
            let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp))
            conn = c
            let host = host, timeout = timeout, queue = queue
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                let once = Once(k)
                c.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.resume(.success(()))
                    case .failed(let e), .waiting(let e): if once.resume(.failure(e)) { c.cancel() }
                    case .cancelled: once.resume(.failure(MailNetError.closed(host)))
                    default: break
                    }
                }
                c.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    if once.resume(.failure(MailNetError.timeout(host))) { c.cancel() }
                }
            }
            c.stateUpdateHandler = nil
        }
    }

    func write(_ d: Data) async throws {
        if let stream { return try await stream.write(d, timeout: timeout) }
        guard let conn else { throw MailNetError.closed(host) }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            conn.send(content: d, completion: .contentProcessed { e in
                if let e { k.resume(throwing: e) } else { k.resume() }
            })
        }
    }

    /// Some bytes; throws at the end of the stream or after `timeout` with nothing.
    func read() async throws -> Data {
        if let stream {
            let (d, eof) = try await stream.readData(ofMinLength: 1, maxLength: 65536, timeout: timeout)
            if let d, !d.isEmpty { return d }
            throw eof ? MailNetError.closed(host) : MailNetError.timeout(host)
        }
        guard let conn else { throw MailNetError.closed(host) }
        let host = host, timeout = timeout, queue = queue
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
            let once = Once(k)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.resume(.failure(MailNetError.timeout(host))) { conn.cancel() }
            }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let data, !data.isEmpty { once.resume(.success(data)) }
                else { once.resume(.failure(error ?? MailNetError.closed(host))) }
            }
        }
    }

    /// STARTTLS: TLS from here on (after the server said go ahead).
    func startTLS() throws {
        guard let stream else { throw MailNetError.refused("STARTTLS needs a plain connection") }
        stream.startSecureConnection()
    }

    func close() {
        conn?.cancel()
        conn = nil
        stream?.cancel()
        stream = nil
    }

    deinit { close() }
}

// MARK: - IMAP

/// One IMAP connection, reused; it reconnects when the link broke. Calls must not overlap (MailService runs one
/// job at a time).
@MainActor final class ImapClient {
    let account: ImapAccount
    private let password: String
    private var sock: MailSocket?
    private var reader = Imap.Reader()
    private var tagN = 0
    private(set) var caps: Set<String> = []
    /// INBOX's UIDVALIDITY while it is selected.
    private(set) var validity: String?
    private var exists = 0
    private var archiveBox: String?
    private var sentBox: String??

    init(account: ImapAccount, password: String) {
        self.account = account
        self.password = password
    }

    enum Arg {
        case raw(String), string(String), literal(Data)
    }

    // MARK: connection

    func connect() async throws {
        close()
        let s = MailSocket(host: account.imapHost, port: account.imapPort, security: account.imapPort == 143 ? .startTLS : .tls)
        sock = s
        reader = Imap.Reader()
        try await s.open()
        let hello = try await response()
        if String(decoding: hello.prefix(6), as: UTF8.self).uppercased().hasPrefix("* BYE") {
            throw MailNetError.server("IMAP: " + String(decoding: hello, as: UTF8.self).dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if s.security == .startTLS {
            try await run([.raw("STARTTLS")])
            try s.startTLS()
            reader = Imap.Reader()
        }
        let preauth = String(decoding: hello.prefix(10), as: UTF8.self).uppercased().hasPrefix("* PREAUTH")
        if !preauth {
            do {
                try await run([.raw("LOGIN "), .string(account.email), .raw(" "), .string(password)])
            } catch MailNetError.server(let t) {
                throw MailNetError.refused(t)
            }
        }
        for r in try await run([.raw("CAPABILITY")]) {
            if let c = Imap.capabilities(r) { caps = Set(c) }
        }
    }

    func close() {
        sock?.close()
        sock = nil
        validity = nil
    }

    func logout() async {
        _ = try? await run([.raw("LOGOUT")])
        close()
    }

    /// `op` on a live connection: connects first if there is none, and once more if the link broke (not when the
    /// server said no).
    private func live<T>(_ op: () async throws -> T) async throws -> T {
        if sock == nil { try await connect() }
        do {
            return try await op()
        } catch let e as MailNetError {
            if case .server = e { throw e }
            if case .refused = e { throw e }
            try await connect()
            return try await op()
        } catch {
            try await connect()
            return try await op()
        }
    }

    // MARK: commands

    /// The next whole response from the server.
    private func response() async throws -> Data {
        guard let sock else { throw MailNetError.closed(account.imapHost) }
        while true {
            if let r = reader.next() { return r }
            reader.feed(try await sock.read())
        }
    }

    /// One command; → its untagged responses. A string that cannot be quoted goes as a literal (after the
    /// server's "+", or at once with LITERAL+). A NO or BAD throws the server's words.
    @discardableResult
    func run(_ args: [Arg]) async throws -> [Data] {
        guard let sock else { throw MailNetError.closed(account.imapHost) }
        tagN += 1
        let tag = "C\(tagN)"
        let plus = caps.contains("LITERAL+")
        // pieces: each after the first waits for a continuation (unless LITERAL+)
        var pieces: [Data] = [Data((tag + " ").utf8)]
        func lit(_ d: Data) {
            pieces[pieces.count - 1].append(Data("{\(d.count)\(plus ? "+" : "")}\r\n".utf8))
            pieces.append(d)
        }
        for a in args {
            switch a {
            case .raw(let s): pieces[pieces.count - 1].append(Data(s.utf8))
            case .string(let s):
                if let q = Imap.quote(s) { pieces[pieces.count - 1].append(Data(q.utf8)) } else { lit(Data(s.utf8)) }
            case .literal(let d): lit(d)
            }
        }
        pieces[pieces.count - 1].append(Data("\r\n".utf8))
        var untagged: [Data] = []
        for (i, p) in pieces.enumerated() {
            if i > 0, !plus {
                // wait for "+ go ahead"
                while true {
                    let r = try await response()
                    if r.first == UInt8(ascii: "+") { break }
                    if let st = Imap.status(r, tag: tag) { throw MailNetError.server("IMAP: " + st.text) }
                    untagged.append(r)
                }
            }
            try await sock.write(p)
        }
        while true {
            let r = try await response()
            if let st = Imap.status(r, tag: tag) {
                guard st.ok else { throw MailNetError.server("IMAP: " + (st.text.isEmpty ? st.kind : st.text)) }
                return untagged
            }
            if r.first == UInt8(ascii: "+") { continue }
            untagged.append(r)
        }
    }

    private func select() async throws {
        var v: String?
        exists = 0
        for r in try await run([.raw("SELECT INBOX")]) {
            if let n = Imap.exists(r) { exists = n }
            if let u = Imap.code(r, "UIDVALIDITY") { v = u }
        }
        validity = v ?? "0"
    }

    // MARK: mail

    /// The newest `n` in INBOX by UID (the last sequence numbers), newest first. Selects INBOX afresh each time,
    /// which gives its count now.
    func inbox(_ n: Int) async throws -> [(key: String, summary: Imap.Summary)] {
        try await live {
            try await select()
            guard exists > 0 else { return [] }
            let lo = max(1, exists - n + 1)
            let rs = try await run([.raw("FETCH \(lo):\(exists) (UID FLAGS ENVELOPE)")])
            let v = validity ?? "0"
            return rs.compactMap { Imap.fetch($0).flatMap { Imap.summary($0.items) } }
                .sorted { $0.uid > $1.uid }.prefix(n).map { ("\(v).\($0.uid)", $0) }
        }
    }

    /// `validity.uid` → the UID, if INBOX is still the same.
    private func uid(_ key: String) throws -> UInt32 {
        let p = key.split(separator: ".")
        guard p.count == 2, let u = UInt32(p[1]) else { throw MailNetError.server("Unknown email") }
        if let validity, validity != p[0] { throw MailNetError.server("The inbox changed; open Mail again.") }
        return u
    }

    private func selected() async throws {
        if validity == nil { try await select() }
    }

    /// The email's first 64 KB (enough for its text), not marking it read.
    func body(_ key: String) async throws -> Data {
        try await live {
            try await selected()
            let u = try uid(key)
            for r in try await run([.raw("UID FETCH \(u) (UID BODY.PEEK[]<0.65536>)")]) {
                guard let f = Imap.fetch(r) else { continue }
                if let d = f.items.first(where: { $0.key.hasPrefix("BODY[") })?.value.data { return d }
            }
            throw MailNetError.server("That email is no longer in the inbox.")
        }
    }

    func flag(_ key: String, seen: Bool) async throws {
        try await live {
            try await selected()
            try await run([.raw("UID STORE \(try uid(key)) \(seen ? "+" : "-")FLAGS.SILENT (\\Seen)")])
        }
    }

    /// Out of INBOX into the archive (MOVE, else COPY + \Deleted + expunge).
    func archive(_ key: String) async throws {
        try await live {
            try await selected()
            let u = try uid(key)
            let box = try await archiveMailbox()
            if caps.contains("MOVE") {
                try await run([.raw("UID MOVE \(u) "), .string(box)])
            } else {
                try await run([.raw("UID COPY \(u) "), .string(box)])
                try await run([.raw("UID STORE \(u) +FLAGS.SILENT (\\Deleted)")])
                try await run([.raw(caps.contains("UIDPLUS") ? "UID EXPUNGE \(u)" : "EXPUNGE")])
            }
        }
    }

    /// A sent reply into Sent (not on Gmail, which keeps its own).
    func saveSent(_ message: Data) async throws {
        try await live {
            guard let box = try await sentMailbox() else { return }
            try await run([.raw("APPEND "), .string(box), .raw(" (\\Seen) "), .literal(message)])
        }
    }

    private func mailboxes() async throws -> [(flags: [String], name: String)] {
        try await run([.raw("LIST \"\" \"*\"")]).compactMap(Imap.list)
    }

    /// The \Archive mailbox; else Gmail's All Mail (\All); else one named Archive; else a new "Archive".
    private func archiveMailbox() async throws -> String {
        if let archiveBox { return archiveBox }
        let all = try await mailboxes()
        let found = all.first { $0.flags.contains("\\archive") }?.name
            ?? all.first { $0.flags.contains("\\all") || $0.name == "[Gmail]/All Mail" || $0.name == "[Google Mail]/All Mail" }?.name
            ?? all.first { $0.name.lowercased() == "archive" || $0.name.lowercased().hasSuffix(".archive") || $0.name.lowercased().hasSuffix("/archive") }?.name
        if let found { archiveBox = found; return found }
        do {
            try await run([.raw("CREATE "), .string("Archive")])
            archiveBox = "Archive"
        } catch MailNetError.server {
            // servers that keep everything under INBOX (INBOX.Archive)
            try await run([.raw("CREATE "), .string("INBOX.Archive")])
            archiveBox = "INBOX.Archive"
        }
        return archiveBox!
    }

    private func sentMailbox() async throws -> String? {
        if let sentBox { return sentBox }
        let all = try await mailboxes()
        let names = ["sent", "sent messages", "sent items", "sent mail", "inbox.sent"]
        let found = all.first { $0.flags.contains("\\sent") }?.name ?? all.first { names.contains($0.name.lowercased()) }?.name
        sentBox = .some(found)
        return found
    }
}

// MARK: - SMTP

/// One SMTP session per send: connect, EHLO, (STARTTLS, EHLO), AUTH, then the mail.
enum SmtpClient {
    @MainActor
    static func send(_ account: ImapAccount, password: String, to: [String], message: Data) async throws {
        try await session(account, password: password) { say in
            try await say("MAIL FROM:<\(account.email)>", [250], nil)
            for r in to { try await say("RCPT TO:<\(r)>", [250, 251], nil) }
            try await say("DATA", [354], nil)
            try await say(nil, [250], Smtp.data(message))
        }
    }

    /// Connects and signs in, then QUIT.
    @MainActor
    static func test(_ account: ImapAccount, password: String) async throws {
        try await session(account, password: password) { _ in }
    }

    @MainActor
    private static func session(_ account: ImapAccount, password: String,
                                _ body: (_ say: (String?, [Int], Data?) async throws -> Void) async throws -> Void) async throws {
        let implicit = account.smtpPort == 465
        let s = MailSocket(host: account.smtpHost, port: account.smtpPort, security: implicit ? .tls : .startTLS)
        defer { s.close() }
        try await s.open()
        var reader = Imap.Reader()
        func reply() async throws -> (code: Int, text: String) {
            var lines: [String] = []
            while true {
                while let l = reader.line() {
                    lines.append(l)
                    if let r = Smtp.reply(lines) { return r }
                }
                reader.feed(try await s.read())
            }
        }
        func say(_ line: String?, _ want: [Int], _ raw: Data? = nil) async throws {
            if let line { try await s.write(Data((line + "\r\n").utf8)) }
            if let raw { try await s.write(raw) }
            let r = try await reply()
            guard want.contains(r.code) else {
                throw MailNetError.server("SMTP: \(r.code) \(r.text.replacingOccurrences(of: "\n", with: " "))")
            }
        }
        func ehlo() async throws -> String {
            try await s.write(Data("EHLO [127.0.0.1]\r\n".utf8))
            let r = try await reply()
            guard r.code == 250 else { throw MailNetError.server("SMTP: \(r.code) \(r.text)") }
            return r.text.uppercased()
        }
        let hello = try await reply()
        guard hello.code == 220 else { throw MailNetError.server("SMTP: \(hello.code) \(hello.text)") }
        var ext = try await ehlo()
        if !implicit {
            guard ext.contains("STARTTLS") else { throw MailNetError.refused("SMTP: \(account.smtpHost) does not offer STARTTLS.") }
            try await say("STARTTLS", [220])
            try s.startTLS()
            reader = Imap.Reader()
            ext = try await ehlo()
        }
        let auth = ext.split(separator: "\n").first { $0.hasPrefix("AUTH") }.map(String.init) ?? ""
        do {
            if auth.contains("PLAIN") || !auth.contains("LOGIN") {
                try await say("AUTH PLAIN " + Smtp.plain(user: account.email, password: password), [235])
            } else {
                try await say("AUTH LOGIN", [334])
                try await say(Data(account.email.utf8).base64EncodedString(), [334])
                try await say(Data(password.utf8).base64EncodedString(), [235])
            }
        } catch MailNetError.server(let t) {
            throw MailNetError.refused(t)
        }
        try await body { line, want, raw in try await say(line, want, raw) }
        _ = try? await say("QUIT", [221])
    }
}

// MARK: - backend

@MainActor @Observable final class ImapBackend: MailBackend {
    let label = "Mail"
    private(set) var account: ImapAccount? = ImapAccount.saved
    private var client: ImapClient?

    var configured: Bool { account?.complete == true && ImapAccount.password != nil }
    var address: String? { account?.email }

    /// Saves the account (and the password, when one is given) and drops the connection.
    func save(_ a: ImapAccount, password: String?) {
        ImapAccount.saved = a
        if let password { ImapAccount.password = password }
        account = a
        Hub.shared.mail.restart()
    }

    func remove() {
        ImapAccount.saved = nil
        ImapAccount.password = nil
        account = nil
        Hub.shared.mail.restart()
    }

    func reset() {
        let c = client
        client = nil
        if let c { Task { await c.logout() } }
    }

    private func live() throws -> ImapClient {
        guard let account, account.complete, let pw = ImapAccount.password else { throw HubError.notSignedIn }
        if let client, client.account == account { return client }
        let c = ImapClient(account: account, password: pw)
        client = c
        return c
    }

    func inbox(_ n: Int) async throws -> [MailEntry] {
        try await live().inbox(n).map {
            MailEntry(id: $0.key, version: $0.key, from: $0.summary.from, subject: $0.summary.subject, unread: !$0.summary.seen)
        }
    }

    func message(_ id: String) async throws -> MailMessage {
        let raw = try await live().body(id)
        let p = Mime.parse(raw)
        return MailMessage(from: p.header("from") ?? "", to: p.header("to") ?? "", replyTo: p.header("reply-to"),
                           subject: p.header("subject") ?? "", messageID: p.raw("message-id") ?? "",
                           references: p.raw("references") ?? "", text: Mime.text(p) ?? "")
    }

    func setRead(_ id: String, _ read: Bool) async throws { try await live().flag(id, seen: read) }

    func archive(_ id: String) async throws { try await live().archive(id) }

    func reply(_ id: String, to: String, subject: String, messageID: String, references: String, text: String) async throws {
        let c = try live()
        guard let pw = ImapAccount.password else { throw HubError.notSignedIn }
        let a = c.account
        let raw = MailText.reply(to: to, subject: subject, messageID: messageID, references: references, text: text,
                                 from: a.email, date: .now, id: MailText.newID(a.email))
        try await SmtpClient.send(a, password: pw, to: [MailText.address(to)], message: raw)
        // sent: a copy in Sent is a nicety, its failure is not the reply's
        if !a.gmail && !c.caps.contains("X-GM-EXT-1") { try? await c.saveSent(raw) }
    }

    /// Signs in to both servers with these settings: nil when both work, else what went wrong.
    static func test(_ a: ImapAccount, password: String) async -> String? {
        let c = ImapClient(account: a, password: password)
        do {
            try await c.connect()
            try await c.run([.raw("SELECT INBOX")])
            await c.logout()
        } catch {
            c.close()
            return "IMAP (\(a.imapHost)): \(error.localizedDescription)"
        }
        do {
            try await SmtpClient.test(a, password: password)
        } catch {
            return "SMTP (\(a.smtpHost)): \(error.localizedDescription)"
        }
        return nil
    }
}
