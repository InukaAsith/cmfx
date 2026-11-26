import Foundation
import HubKit

// The watch's Mail app (the chats app in mail mode, cmf-watch-sdk sdk/examples/mail; hosts/inboxhost.py is the
// reference). Mail comes from one of two backends, picked on the Mail page: Gmail (REST, the user's own OAuth
// client; MailGmail.swift) or any IMAP + SMTP account with an app password (MailIMAP.swift). Rows are the newest
// inbox threads (Gmail) or emails (IMAP): sender, subject, unread; one opens as its latest email's text; quick
// replies that start with "• " are actions. While Mail is open on the watch the inbox is checked every minute.

/// One row of the inbox. `version` changes when the row has new mail (Gmail's history id; an IMAP UID never does).
struct MailEntry {
    let id: String, version: String, from: String, subject: String
    var unread: Bool
}

/// An email opened: its headers (decoded) and its text (text/plain, else HTML as text; not yet cut down).
struct MailMessage {
    let from: String, to: String, replyTo: String?, subject: String, messageID: String, references: String, text: String
}

/// Where mail comes from. Ids are the backend's own (a Gmail thread, an IMAP UID).
@MainActor protocol MailBackend: AnyObject {
    /// "Gmail", "Mail": in errors on the watch.
    var label: String { get }
    var configured: Bool { get }
    /// The account's own address (to tell our emails from theirs).
    var address: String? { get }
    /// The newest `n` inbox rows, newest first.
    func inbox(_ n: Int) async throws -> [MailEntry]
    /// The row's latest email (not marked read).
    func message(_ id: String) async throws -> MailMessage
    func setRead(_ id: String, _ read: Bool) async throws
    /// Out of the inbox.
    func archive(_ id: String) async throws
    /// A reply in the row's thread, to `to` (an empty id and messageID: a new email).
    func reply(_ id: String, to: String, subject: String, messageID: String, references: String, text: String) async throws
    /// Forget what is cached or connected (an account changed).
    func reset()
}

enum MailKind: String, CaseIterable, Identifiable {
    case gmail, imap
    var id: String { rawValue }
    var title: String { self == .gmail ? "Gmail sign-in" : "IMAP account" }
}

@MainActor @Observable final class MailService: WatchService {
    static let app = "Mail"
    static let quick = ["• Archive", "• Mark unread", "Thanks!", "Got it, will reply soon", "Sounds good", "On it"]
    static let threads = 11
    static let poll: Duration = .seconds(60)

    let gmail = GmailBackend()
    let imap = ImapBackend()

    /// Which backend the watch gets (Settings: Hub › Mail).
    var kind: MailKind = MailKind(rawValue: UserDefaults.standard.string(forKey: "mail-backend") ?? "") ?? .gmail {
        didSet {
            guard kind != oldValue else { return }
            UserDefaults.standard.set(kind.rawValue, forKey: "mail-backend")
            restart()
        }
    }
    var status: String?

    var backend: MailBackend { kind == .gmail ? gmail : imap }
    var configured: Bool { backend.configured }

    /// The row open on the watch: what it shows and what a reply needs.
    struct Opened {
        let id: UInt8, key: String, title: String
        var msgs: [(me: Bool, kind: UInt8, text: String)]
        let to: String, subject: String, messageID: String, references: String
    }

    /// The new-mail row: the watch's + button; its picker's rows are keyed "to:<address>".
    static let newMail: UInt8 = 1
    private var ids = ChatsProto.Ids(first: 2)
    private var listed: [MailEntry] = []
    private var opened: Opened?
    private var chain: Task<Void, Never>?
    private var poller: Task<Void, Never>?

    /// The backend or its account changed: start again from the list.
    func restart() {
        poller?.cancel()
        listed = []
        opened = nil
        ids = ChatsProto.Ids(first: 2)
        status = nil
        gmail.reset()
        imap.reset()
    }

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
        let backend = backend
        do {
            guard backend.configured else { return try await signInFirst(ask) }
            switch ask {
            case .ready:
                try await refresh()
                try await sendList(quick: true)
                watch()
            case .open(let id): try await open(id)
            case .send(let id, let text): try await send(id, text)
            case .tap, .credit, .stop, .filter, .react, .replyTo, .delete: break
            }
        } catch {
            status = error.localizedDescription
            try? await Hub.shared.send(Self.app, ChatsProto.append("\(backend.label) error: \(error.localizedDescription)"))
        }
    }

    private func signInFirst(_ ask: ChatsProto.Ask) async throws {
        let how = kind == .gmail ? "Sign in with Google in CMFX on the iPhone (Hub › Mail)."
            : "Add your mail account in CMFX on the iPhone (Hub › Mail)."
        if case .open = ask {
            try await Hub.shared.send(Self.app, ChatsProto.chat(0, title: "Mail", [(false, 0, how)]))
        } else {
            try await Hub.shared.send(Self.app, ChatsProto.list([.init(id: 0, name: "Sign in", preview: "In CMFX on the iPhone")]))
        }
    }

    private func sendList(quick: Bool = false) async throws {
        var new = ChatsProto.Row(id: Self.newMail, name: "New mail", preview: "Write one")
        new.isNew = true
        let rows = [new] + listed.map { ChatsProto.Row(id: ids.id($0.id), unread: $0.unread, name: MailText.name($0.from),
                                                       preview: $0.subject.isEmpty ? "(no subject)" : $0.subject) }
        // (a picker the watch shows ends with the usual list)
        try await Hub.shared.send(Self.app, [ChatsProto.picker("")] + ChatsProto.list(rows) + (quick ? ChatsProto.quick(Self.quick) : []))
    }

    /// The + button: whom to write to, the people in the inbox (not our own address), as a picker.
    private func sendPicker() async throws {
        var seen = Set<String>()
        var rows: [ChatsProto.Row] = []
        for e in listed {
            let a = MailText.address(e.from).lowercased()
            guard !a.isEmpty, a != backend.address?.lowercased(), seen.insert(a).inserted else { continue }
            rows.append(.init(id: ids.id("to:" + e.from), name: MailText.name(e.from), preview: a))
        }
        guard !rows.isEmpty else {
            return try await Hub.shared.send(Self.app, ChatsProto.chat(Self.newMail, title: "New mail", [(false, 0, "No one to write to yet: the people who email you show here.")]))
        }
        try await Hub.shared.send(Self.app, [ChatsProto.picker("New mail")] + ChatsProto.list(rows))
    }

    private func open(_ id: UInt8) async throws {
        if id == Self.newMail { return try await sendPicker() }
        guard let key = ids.key(id) else { return }
        if key.hasPrefix("to:") {
            // a new email to them: empty till the first words, which are its subject too
            let to = String(key.dropFirst(3))
            let o = Opened(id: id, key: key, title: "To " + MailText.name(to), msgs: [], to: to, subject: "", messageID: "", references: "")
            opened = o
            return try await Hub.shared.send(Self.app, ChatsProto.chat(id, title: o.title, []))
        }
        let o = try await load(id, key)
        opened = o
        try await Hub.shared.send(Self.app, ChatsProto.chat(id, title: o.title, o.msgs))
        if let i = listed.firstIndex(where: { $0.id == key }), listed[i].unread {
            try await backend.setRead(key, true)
            listed[i].unread = false
        }
    }

    /// The row's latest email as text, in pieces the watch shows.
    private func load(_ id: UInt8, _ key: String) async throws -> Opened {
        let m = try await backend.message(key)
        let me = MailText.address(m.from).lowercased() == backend.address?.lowercased()
        var text = MailText.body(m.text)
        if text.isEmpty { text = "(no text)" }
        return Opened(id: id, key: key, title: MailText.name(m.from),
                      msgs: ChatsProto.chunks(text).prefix(ChatsProto.maxMsgs).map { (me: me, kind: ChatsProto.plain, text: $0) },
                      to: me ? m.to : (m.replyTo ?? m.from), subject: m.subject, messageID: m.messageID, references: m.references)
    }

    private func send(_ id: UInt8, _ text: String) async throws {
        guard let key = ids.key(id) else { return }
        if key.hasPrefix("to:") {
            guard ChatsProto.action(text) == nil else { return }
            let to = String(key.dropFirst(3))
            do {
                try await backend.reply("", to: to, subject: Self.subject(text), messageID: "", references: "", text: text)
                try await refresh()
                try await sendList()
            } catch {
                try await Hub.shared.send(Self.app, [ChatsProto.append("Not sent: \(error.localizedDescription)")])
            }
            return
        }
        var o: Opened
        if let x = opened, x.id == id { o = x } else { o = try await load(id, key) }
        if let action = ChatsProto.action(text) {
            var note: String?
            switch action {
            case "Archive":
                try await backend.archive(key)
                note = "Archived"
            case "Mark unread":
                try await backend.setRead(key, false)
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
        do {
            try await backend.reply(key, to: o.to, subject: o.subject, messageID: o.messageID, references: o.references, text: text)
            // the watch already shows it (its own echo, me = 1, kind 0)
            o.msgs.append((true, ChatsProto.plain, text))
            opened = o
        } catch {
            try await Hub.shared.send(Self.app, ChatsProto.chat(id, title: o.title, o.msgs)
                + [ChatsProto.append("Not sent: \(error.localizedDescription)")])
        }
    }

    /// A new email's subject: its first words, at most 40 characters, cut at a word.
    static func subject(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        guard line.count > 40 else { return line }
        let cut = line.prefix(40)
        return String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut) + "..."
    }

    /// Checks the inbox every minute while Mail is the app the watch last talked from (a send that fails, or
    /// another app, ends it): a new unread row buzzes and the list comes again.
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
        let seen = Dictionary(old.map { ($0.id, $0.version) }, uniquingKeysWith: { a, _ in a })
        func sig(_ t: [MailEntry]) -> [String] { t.map { "\($0.id) \($0.version) \($0.unread)" } }
        do {
            try await refresh()
            // unread rows that are new, or have new mail since the last look
            let fresh = listed.filter { $0.unread && seen[$0.id] != $0.version }
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

    private func refresh() async throws {
        listed = try await backend.inbox(Self.threads)
    }
}
