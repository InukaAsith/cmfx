import Foundation
import HubKit
import UIKit
import WABridge

// The watch's WhatsApp app (the chats app; cmf-watch-sdk hosts/wahost.py is the reference). CMFX is a WhatsApp
// linked device, like WhatsApp Web: whatsmeow (Go, MPL-2.0) built with gomobile as WABridge (ios/WABridge), its
// session and a small chat store in Application Support/WhatsApp.
// Battery: strictly on demand. It goes online only when the watch app talks (R, o, s; the BLE notify wakes CMFX),
// and offline 60 s after the watch's last message once CMFX is in the background, when the background time runs
// out, or at once when another watch app talks (the watch runs one at a time). No timers or polling while idle.

/// Go → Swift, on a Go thread.
private final class WAEvents: NSObject, WabridgeListenerProtocol {
    func onMessage(_ jid: String?) {
        guard let jid else { return }
        Task { @MainActor in Hub.shared.whatsapp.incoming(jid) }
    }

    func onState(_ s: String?) {
        guard let s else { return }
        Task { @MainActor in Hub.shared.whatsapp.changed(s) }
    }
}

private struct WAChat: Decodable { let jid: String, name: String, unread: Int, preview: String }
private struct WAMsg: Decodable { let fromMe: Bool, kind: Int, text: String, who: String? }

@MainActor @Observable final class WhatsAppService: WatchService {
    static let app = "WhatsApp"
    static let quick = ["OK", "On my way", "Call you later", "Yes", "No", "Thanks!"]
    /// Online this long after the watch's last message (in the background).
    static let idle: Duration = .seconds(60)
    /// The row shown while not linked.
    static let info: UInt8 = 1

    /// Linked, as last seen (kept so the Hub row needs no bridge).
    private(set) var linked = UserDefaults.standard.bool(forKey: "wa.linked")
    /// "+<number> <push name>" of the linked account.
    private(set) var me = ""
    /// "unlinked", "disconnected", "connected" or "synced".
    private(set) var connection = "disconnected"
    /// The pairing code to type on the phone, while linking.
    private(set) var code: String?
    private(set) var pairing = false
    var status: String?

    private var opened = false
    private let events = WAEvents()
    private var ids = ChatsProto.Ids(first: 2)
    private var names: [String: String] = [:]
    /// The chat open on the watch.
    private var open: UInt8?
    /// The watch app is open: it talked, and the last message to it went through.
    private var live = false
    private var chain: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var bg: UIBackgroundTaskIdentifier = .invalid
    private var syncWaiters: [CheckedContinuation<Void, Never>] = []
    /// The link page is on screen (online there while CMFX is in front).
    private var pageShown = false

    init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // nothing from the watch lately: offline now
                guard let self, self.idleTask == nil, !self.pairing else { return }
                self.goOffline()
            }
        }
    }

    // MARK: bridge

    /// Go's calls block (the network): off the main actor.
    private nonisolated static func go<T: Sendable>(_ f: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { f() }.value
    }

    /// Opens the session and chat store (nothing goes online).
    @discardableResult
    func openBridge() -> Bool {
        if opened { return true }
        let dir = URL.applicationSupportDirectory.appending(path: "WhatsApp", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var e: NSError?
        WabridgeOpen(dir.path, &e)
        if let e {
            status = e.localizedDescription
            return false
        }
        WabridgeSetListener(events)
        opened = true
        refresh()
        return true
    }

    private func refresh() {
        linked = WabridgeLinked()
        UserDefaults.standard.set(linked, forKey: "wa.linked")
        me = WabridgeMe()
        connection = WabridgeState()
    }

    /// From Go.
    fileprivate func changed(_ s: String) {
        switch s {
        case "synced":
            let w = syncWaiters
            syncWaiters.removeAll()
            w.forEach { $0.resume() }
            // the watch already shows what the phone had: now the fresh list, and the open chat read
            if live {
                enqueue {
                    await self.sendList()
                    if let id = self.open, id != Self.info, let jid = self.ids.key(id) {
                        await self.out(ChatsProto.chat(id, title: self.names[jid] ?? "Chat", self.messages(jid).map(self.bubble)))
                        await Self.go { WabridgeMarkRead(jid) }
                    }
                }
            }
        case "paired":
            code = nil
            pairing = false
            status = "Linked. Your recent chats are coming in."
            touch() // the first sync, then offline as usual
        case "pair-failed":
            if pairing {
                pairing = false
                code = nil
                status = "Linking did not finish (the code is good for about 2 minutes). Try again."
                goOffline()
            }
        case "logged-out":
            status = "Unlinked from WhatsApp on the phone."
            names.removeAll()
        default: break
        }
        refresh()
    }

    /// The connect under way, if any: nothing waits on it longer than it chooses to.
    private var connecting: Task<Bool, Never>?

    /// Starts connecting (once) without waiting.
    private func startConnect() {
        guard connecting == nil, openBridge(), linked, WabridgeState() != "synced" else { return }
        connecting = Task {
            let ok = await self.connectNow()
            self.connecting = nil
            return ok
        }
    }

    /// Online within `limit`, else false (the connect goes on; "synced" updates the watch when it comes).
    private func online(_ limit: Duration = .seconds(12)) async -> Bool {
        guard openBridge(), linked else { return false }
        if WabridgeState() == "synced" { return true }
        startConnect()
        guard let t = connecting else { return WabridgeState() != "disconnected" }
        let once = FirstWins()
        return await withCheckedContinuation { c in
            Task { @MainActor in let v = await t.value; if once.take() { c.resume(returning: v) } }
            Task { @MainActor in try? await Task.sleep(for: limit); if once.take() { c.resume(returning: false) } }
        }
    }

    /// Connects and waits for the offline messages (8 s at most). false: not linked or no connection.
    private func connectNow() async -> Bool {
        guard openBridge(), linked else { return false }
        if WabridgeState() == "synced" { return true }
        let err = await Self.go { () -> String? in
            var e: NSError?
            WabridgeConnect(&e)
            return e?.localizedDescription
        }
        refresh()
        if let err {
            status = err
            return false
        }
        if WabridgeState() != "synced" {
            await withCheckedContinuation { c in
                syncWaiters.append(c)
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    let w = self.syncWaiters
                    self.syncWaiters.removeAll()
                    w.forEach { $0.resume() }
                }
            }
        }
        return WabridgeState() != "disconnected"
    }

    func goOffline() {
        idleTask?.cancel()
        idleTask = nil
        if opened, connection != "disconnected", connection != "unlinked" {
            Task.detached { WabridgeDisconnect() }
        }
        if opened { connection = linked ? "disconnected" : "unlinked" }
        if bg != .invalid {
            UIApplication.shared.endBackgroundTask(bg)
            bg = .invalid
        }
    }

    /// A watch message: background time from now, and offline `idle` after it.
    private func touch() {
        let old = bg
        bg = UIApplication.shared.beginBackgroundTask(withName: "whatsapp") { [weak self] in
            // out of background time: offline (the next watch message brings it back)
            MainActor.assumeIsolated { self?.goOffline() }
        }
        if old != .invalid { UIApplication.shared.endBackgroundTask(old) }
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: Self.idle)
            guard !Task.isCancelled else { return }
            idleTask = nil
            if pageShown, UIApplication.shared.applicationState == .active { return }
            live = false
            goOffline()
        }
    }

    /// Hub: another watch app talked; this one is closed.
    func otherApp() {
        guard live || idleTask != nil else { return }
        live = false
        if !pairing, !(pageShown && UIApplication.shared.applicationState == .active) { goOffline() }
    }

    // MARK: link page

    func pageAppeared(_ shown: Bool) {
        pageShown = shown
        if shown {
            openBridge()
        } else if idleTask == nil, !pairing {
            goOffline()
        }
    }

    func pair(_ phone: String) async {
        guard openBridge() else { return }
        status = nil
        code = nil
        pairing = true
        let (c, err) = await Self.go { () -> (String, String?) in
            var e: NSError?
            let c = WabridgePairPhone(phone, &e)
            return (c, e?.localizedDescription)
        }
        if let err {
            pairing = false
            status = err
            goOffline()
        } else if c.count == 8 {
            code = String(c.prefix(4)) + "-" + String(c.suffix(4))
        } else {
            code = c
        }
        refresh()
    }

    func cancelPairing() {
        pairing = false
        code = nil
        goOffline()
    }

    func unlink() async {
        guard openBridge() else { return }
        let err = await Self.go { () -> String? in
            var e: NSError?
            WabridgeLogout(&e)
            return e?.localizedDescription
        }
        status = err ?? "Unlinked. The chats on this iPhone are gone."
        names.removeAll()
        ids = ChatsProto.Ids(first: 2)
        refresh()
        goOffline()
    }

    // MARK: watch

    func receive(_ m: Data) {
        guard let ask = ChatsProto.parse(m) else { return }
        live = true
        touch()
        enqueue { await self.handle(ask) }
    }

    /// One job at a time: a chat's H and M messages must not interleave with another's.
    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let prev = chain
        chain = Task { await prev?.value; await job() }
    }

    private func handle(_ ask: ChatsProto.Ask) async {
        switch ask {
        case .ready:
            // at once, from the chats on the phone; fresh ones follow when WhatsApp has synced
            startConnect()
            await sendList(quick: true)
        case .open(let id): await show(id)
        case .send(let id, let text): await send(id, text)
        case .tap: break
        }
    }

    private func chats() -> [WAChat] {
        guard opened else { return [] }
        return (try? JSONDecoder().decode([WAChat].self, from: Data(WabridgeChats().utf8))) ?? []
    }

    private func messages(_ jid: String) -> [WAMsg] {
        (try? JSONDecoder().decode([WAMsg].self, from: Data(WabridgeMessages(jid).utf8))) ?? []
    }

    private func sendList(quick: Bool = false) async {
        var rows: [ChatsProto.Row] = []
        if !linked {
            rows = [.init(id: Self.info, name: "WhatsApp", preview: "Link it in CMFX on the iPhone")]
        } else {
            // the saved chats show at once; while WhatsApp catches up, the top row says so
            if WabridgeState() != "synced", connecting != nil {
                rows.append(.init(id: Self.info, name: "Syncing...", preview: "Saved chats below"))
            }
            for c in chats() {
                names[c.jid] = c.name
                rows.append(.init(id: ids.id(c.jid), unreadCount: c.unread, name: c.name, preview: c.preview))
            }
            if rows.isEmpty || rows.allSatisfy({ $0.id == Self.info }) {
                let syncing = WabridgeState() != "synced" && connecting != nil
                rows = [.init(id: Self.info, name: syncing ? "Syncing..." : "WhatsApp",
                              preview: syncing ? "Getting your chats" : connection == "disconnected" ? "Offline" : "No chats yet")]
            }
        }
        await out(ChatsProto.list(rows) + (quick ? ChatsProto.quick(Self.quick) : []))
    }

    /// The watch shows a group's sender before the text.
    private func bubble(_ m: WAMsg) -> (me: Bool, kind: UInt8, text: String) {
        let who = m.who ?? ""
        let text = m.fromMe || who.isEmpty ? m.text : (m.text.isEmpty ? who : who + ": " + m.text)
        return (m.fromMe, UInt8(clamping: m.kind), text)
    }

    private func show(_ id: UInt8) async {
        open = id
        guard id != Self.info, let jid = ids.key(id) else {
            let text = linked ? "Your chats show here once WhatsApp is reachable." :
                "Open CMFX on the iPhone › Hub › WhatsApp, and link it with a pairing code."
            return await out([ChatsProto.open(id, title: "WhatsApp"), ChatsProto.message(0, text)])
        }
        await out(ChatsProto.chat(id, title: names[jid] ?? "Chat", messages(jid).map(bubble)))
        if WabridgeState() == "synced" {
            await Self.go { WabridgeMarkRead(jid) }
            await sendList()
        } else {
            startConnect() // "synced" sends this chat again and marks it read
        }
    }

    /// The watch shows its own bubble: no echo, only the list (or why it failed).
    private func send(_ id: UInt8, _ text: String) async {
        guard let jid = ids.key(id) else { return }
        guard await online() else {
            return await out([ChatsProto.append("Not sent: \(linked ? "WhatsApp is offline" : "not linked")")])
        }
        let err = await Self.go { () -> String? in
            var e: NSError?
            WabridgeSend(jid, text, &e)
            return e?.localizedDescription
        }
        if let err {
            status = err
            await out([ChatsProto.append("Not sent: \(err)")])
        }
        await sendList()
    }

    /// From Go: a new message from someone while online: buzz, the list, and the bubble when its chat is open.
    fileprivate func incoming(_ jid: String) {
        guard live else { return }
        let id = ids.id(jid)
        enqueue {
            await self.out([ChatsProto.buzz(id)])
            await self.sendList()
            if self.open == id, let last = self.messages(jid).last {
                let b = self.bubble(last)
                await self.out([ChatsProto.append(me: b.me, kind: b.kind, b.text)])
            }
        }
    }

    private func out(_ msgs: [Data]) async {
        guard live else { return }
        do {
            try await Hub.shared.send(Self.app, msgs)
        } catch {
            // the watch app closed, or the watch went away
            live = false
            if !pairing, !(pageShown && UIApplication.shared.applicationState == .active) { goOffline() }
        }
    }
}

/// The first of two racing callers wins.
@MainActor private final class FirstWins {
    private var done = false
    func take() -> Bool { defer { done = true }; return !done }
}
