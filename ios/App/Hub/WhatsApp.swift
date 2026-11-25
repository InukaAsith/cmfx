import BackgroundTasks
import Foundation
import HubKit
import UIKit
import ImageIO
import WABridge

// The watch's WhatsApp app (the chats app; cmf-watch-sdk hosts/wahost.py is the reference). CMFX is a WhatsApp
// linked device, like WhatsApp Web: whatsmeow (Go, MPL-2.0) built with gomobile as WABridge (ios/WABridge), its
// session and a small chat store in Application Support/WhatsApp.
// Battery: strictly on demand. It goes online only when the watch app talks (R, o, s; the BLE notify wakes CMFX),
// and offline 60 s after the watch's last message once CMFX is in the background, when the background time runs
// out, or at once when another watch app talks (the watch runs one at a time). No timers or polling while idle.
// Keep chats up to date (a toggle, off by default): short catch-ups so the watch opens on fresh chats instead of
// waiting for a long gap's offline messages. Only when CMFX is awake anyway (a watch BLE wake, another watch app)
// or iOS grants a background refresh (BGAppRefreshTask: iOS picks the time from battery and use), at most every
// 15 minutes, never in Low Power Mode; online until WhatsApp says the offline messages are in (25 s at most), then
// offline again.

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

    func onReceipt(_ jid: String?) {
        guard let jid else { return }
        Task { @MainActor in Hub.shared.whatsapp.receipts(jid) }
    }

    func onPresence(_ jid: String?, online: Bool) {
        guard let jid else { return }
        Task { @MainActor in Hub.shared.whatsapp.presence(jid, online) }
    }
}

private struct WAChat: Decodable { let jid: String, name: String, unread: Int, preview: String }
private struct WAMsg: Decodable {
    let id: String?, fromMe: Bool, state: Int?, kind: Int, text: String, who: String?
}

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

    /// Keep chats up to date between watch openings (off by default).
    var keepSynced = UserDefaults.standard.bool(forKey: "wa.keepSynced") {
        didSet {
            UserDefaults.standard.set(keepSynced, forKey: "wa.keepSynced")
            if keepSynced { Self.scheduleRefresh() } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
            }
        }
    }
    /// The last catch-up that got WhatsApp's offline messages in.
    private(set) var lastSync = UserDefaults.standard.object(forKey: "wa.lastSync") as? Date
    static let refreshID = "app.cmfx.ios.whatsapp-sync"
    static let syncEvery: TimeInterval = 15 * 60
    private var catchingUp = false
    /// The last catch-up tried (done or not): the 15 minutes count from it, so a bad connection never retries
    /// at every wake (no burst of logins WhatsApp could find odd).
    private var lastTry: Date?

    private var opened = false
    private let events = WAEvents()
    private var ids = ChatsProto.Ids(first: 2)
    private var names: [String: String] = [:]
    /// The chat open on the watch.
    private var open: UInt8?
    /// The watch app is open: it talked, and the last message to it went through.
    private(set) var live = false
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
                        await self.out(self.opened(id, jid))
                        await Self.go { WabridgeMarkRead(jid) }
                        Task.detached { WabridgeWatch(jid) }
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
            Task.detached {
                WabridgeUnwatch()
                WabridgeDisconnect()
            }
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

    // MARK: keeping chats up to date

    /// Asks iOS for a background refresh, not before `syncEvery` (iOS decides when, or not at all).
    static func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: refreshID)
        r.earliestBeginDate = .now.addingTimeInterval(syncEvery)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// Registered at launch: iOS's refresh runs one catch-up and asks for the next.
    static func registerRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: .main) { task in
            MainActor.assumeIsolated {
                let w = Hub.shared.whatsapp
                guard w.keepSynced else { return task.setTaskCompleted(success: true) }
                scheduleRefresh()
                let job = Task { @MainActor in
                    let ok = await w.catchUp()
                    task.setTaskCompleted(success: ok)
                }
                task.expirationHandler = {
                    job.cancel()
                    Task { @MainActor in if !w.live { w.goOffline() } }
                }
            }
        }
    }

    /// One short catch-up when it's on and due: online until the offline messages are in (25 s at most), then
    /// offline unless the watch app opened meanwhile. Free to call often: it does nothing until due.
    @discardableResult
    func catchUp() async -> Bool {
        guard keepSynced, linked, !live, !pairing, !catchingUp, idleTask == nil,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              lastSync.map({ Date.now.timeIntervalSince($0) >= Self.syncEvery }) ?? true,
              lastTry.map({ Date.now.timeIntervalSince($0) >= Self.syncEvery }) ?? true else { return false }
        catchingUp = true
        lastTry = .now
        defer { catchingUp = false }
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "whatsapp-sync") { }
        defer { UIApplication.shared.endBackgroundTask(bgTask) }
        guard openBridge() else { return false }
        if WabridgeState() != "synced" {
            startConnect()
            let deadline = ContinuousClock.now + .seconds(25)
            while WabridgeState() != "synced", ContinuousClock.now < deadline, !Task.isCancelled {
                await withCheckedContinuation { c in
                    syncWaiters.append(c)
                    Task { try? await Task.sleep(for: .seconds(2)); self.wakeWaiters() }
                }
            }
        }
        let ok = WabridgeState() == "synced"
        if ok {
            lastSync = .now
            UserDefaults.standard.set(lastSync, forKey: "wa.lastSync")
        }
        // nobody uses it: offline at once
        if !live, idleTask == nil, !pairing, !(pageShown && UIApplication.shared.applicationState == .active) {
            goOffline()
        }
        refresh()
        return ok
    }

    private func wakeWaiters() {
        let w = syncWaiters
        syncWaiters.removeAll()
        w.forEach { $0.resume() }
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
        case .tap(let idx):
            // beside the queue: a download can take a while, messages go on meanwhile
            Task { await self.picture(idx) }
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
                var row = ChatsProto.Row(id: Self.info, name: "Syncing...", preview: "Saved chats below")
                row.status = true
                rows.append(row)
            }
            for c in chats() {
                names[c.jid] = c.name
                rows.append(.init(id: ids.id(c.jid), unreadCount: c.unread, name: c.name, preview: c.preview))
            }
            if rows.isEmpty || rows.allSatisfy({ $0.id == Self.info }) {
                let syncing = WabridgeState() != "synced" && connecting != nil
                var row = ChatsProto.Row(id: Self.info, name: syncing ? "Syncing..." : "WhatsApp",
                                         preview: syncing ? "Getting your chats" : connection == "disconnected" ? "Offline" : "No chats yet")
                row.status = syncing
                rows = [row]
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

    /// The open chat's messages as the watch has them (its idx is the place in here).
    private var shown: [WAMsg] = []

    /// `H` and the last messages, with our messages' states; `shown` follows.
    private func opened(_ id: UInt8, _ jid: String) -> [Data] {
        shown = Array(messages(jid).suffix(ChatsProto.maxMsgs))
        return [ChatsProto.open(id, title: names[jid] ?? "Chat")] + shown.enumerated().map { i, m in
            let b = bubble(m)
            return ChatsProto.message(i, me: b.me, state: m.state ?? 0, kind: b.kind, b.text)
        }
    }

    private func show(_ id: UInt8) async {
        open = id
        shown = []
        guard id != Self.info, let jid = ids.key(id) else {
            let text = linked ? "Your chats show here once WhatsApp is reachable." :
                "Open CMFX on the iPhone › Hub › WhatsApp, and link it with a pairing code."
            return await out([ChatsProto.open(id, title: "WhatsApp"), ChatsProto.message(0, text)])
        }
        await out(opened(id, jid))
        // online: a green dot on the watch while this chat is open (see WabridgeWatch)
        if WabridgeState() != "disconnected" { Task.detached { WabridgeWatch(jid) } }
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
        } else if open == id {
            // the watch added its own bubble at the end; it is in the store now, with its id for receipts
            shown = Array(messages(jid).suffix(ChatsProto.maxMsgs))
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
                self.shown = Array((self.shown + [last]).suffix(ChatsProto.maxMsgs))
                await self.out([ChatsProto.append(me: b.me, state: last.state ?? 0, kind: b.kind, b.text)])
            }
        }
    }

    /// From Go: our messages in jid were delivered or read: the open chat's dots.
    fileprivate func receipts(_ jid: String) {
        guard live, let id = open, ids.key(id) == jid else { return }
        enqueue {
            guard self.open == id else { return }
            let now = self.messages(jid)
            var msgs: [Data] = []
            for (i, m) in self.shown.enumerated() where m.fromMe {
                guard let new = now.first(where: { $0.id != nil && $0.id == m.id }), (new.state ?? 0) > (m.state ?? 0)
                else { continue }
                self.shown[i] = new
                msgs.append(ChatsProto.state(i, new.state ?? 0))
            }
            if !msgs.isEmpty { await self.out(msgs) }
        }
    }

    /// From Go: the open chat's contact came online or went offline.
    fileprivate func presence(_ jid: String, _ on: Bool) {
        guard live, let id = open, ids.key(id) == jid else { return }
        enqueue { await self.out([ChatsProto.online(on)]) }
    }

    /// A tap on a sticker or photo: its picture, downloaded from WhatsApp, into the bubble.
    private func picture(_ idx: Int) async {
        guard let id = open, let jid = ids.key(id), idx < shown.count, [1, 2].contains(shown[idx].kind) else { return }
        // `e` alone: the watch says "No picture"
        let none = [Data([UInt8(ascii: "e"), UInt8(idx & 0xFF)])]
        guard let mid = shown[idx].id else { return await out(none) }
        let sticker = shown[idx].kind == 1
        // no going offline during the download (the sender's phone may be asked to upload it again)
        idleTask?.cancel()
        defer { if live { touch() } }
        guard await online() else { return await out(none) }
        let data = await Self.go { () -> Data? in
            var e: NSError?
            let d = WabridgeMedia(jid, mid, &e)
            return e == nil ? d : nil
        }
        guard open == id else { return }
        guard let data, let img = Self.firstFrame(data) else { return await out(none) }
        // a sticker 120 px as it is, a photo 96 px drawn doubled
        let side = sticker ? 120 : 96
        let rgb = await Task.detached { Self.fitted(img, side: side) }.value
        await out(ChatsProto.picture(idx, rgb: rgb, width: side, height: side, scale: sticker ? 1 : 2))
    }

    /// The first frame (an animated sticker's too), at most 512 px: an HD photo is not decoded whole.
    private nonisolated static func firstFrame(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 512]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return UIImage(cgImage: cg) }
        return UIImage(data: data)
    }

    /// The picture inside side×side on black (a sticker's see-through parts black too), RGB.
    private nonisolated static func fitted(_ img: UIImage, side: Int) -> [UInt8] {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        let s = CGFloat(side)
        let r = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: f).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            let k = min(s / max(img.size.width, 1), s / max(img.size.height, 1))
            let (w, h) = (img.size.width * k, img.size.height * k)
            img.draw(in: CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
        }
        guard let cg = r.cgImage else { return [UInt8](repeating: 0, count: side * side * 3) }
        return Pixels.bytes(cg, side: side)
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
