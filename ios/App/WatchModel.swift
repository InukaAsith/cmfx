import Foundation
import Observation
import WireKit

// Is the App Loader on the watch? Read only: K from the shell, then INFO (fmc_frontend ble.ts readWp2).
// Features that need the loader show only when `loader` is set.

@MainActor @Observable final class WatchModel {
    /// One per app: the RPC listener reads the watch again through it when the link comes back.
    static let shared = WatchModel()
    enum Phase: Equatable {
        case idle, checking
        /// Connected; nil = stock firmware (or a stub from before 2026-11-13, which has no K).
        case checked(LoaderState?)
        case failed(String)
    }

    var phase = Phase.idle

    var loader: LoaderState? {
        if case .checked(let s) = phase { s } else { nil }
    }

    /// The last read while a new one runs: lists keep their rows through a refresh.
    private(set) var lastLoader: LoaderState?
    var listedLoader: LoaderState? {
        if case .checking = phase { lastLoader } else { loader }
    }
    var isChecking: Bool {
        switch phase { case .idle, .checking: true; default: false }
    }

    /// When the last read began.
    private(set) var lastCheck: Date?
    /// A firmware was sent: the watch installs it and restarts, and is read every 20 s till it answers with it.
    private(set) var installing = false

    func check() async {
        lastCheck = .now
        phase = .checking
        do {
            let state = try await read()
            phase = .checked(state)
            Analytics.track("watch_connected", ["firmware": state == nil ? "stock" : "patched"])
            lastLoader = state
            RPCListener.shared.update(state)
            // an order the watch refused with Busy goes now
            if AppOrder.shared.unsent { Task { await AppOrder.shared.send(self) } }
        } catch {
            phase = .failed(error.localizedDescription)
            lastLoader = nil
        }
    }

    /// The RPC listener has the watch again after a drop (a restart, out of range): read it, so stub, loader and
    /// apps aren't the old ones. Not before the user's first read, not twice within 30 s, not during a restart wait;
    /// installs and flashes stop the listener, so none of them is running. Its own K session shares the link
    /// (KLock keeps the requests apart).
    func linkCameBack() {
        guard recheckDue(idle: phase == .idle, busy: phase == .checking || installing, last: lastCheck, now: .now) else { return }
        DevLog.shared.log("link back: reading the watch again")
        Task { await check() }
    }

    /// After a firmware is sent: every 20 s for up to 10 min, until the watch answers with `stub` or later.
    /// true when it did.
    func awaitRestart(stub target: UInt32) async -> Bool {
        installing = true
        defer { installing = false }
        return await retry(every: .seconds(20), for: .seconds(600)) {
            await check()
            return (loader?.stub.version ?? 0) >= target
        }
    }

    private func read() async throws -> LoaderState? {
        let link = BLELink()
        defer { link.disconnect() }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(30))
            link.abort()
        }
        defer { watchdog.cancel() }
        try await link.connect()
        AppOrder.shared.watch = link.watchID?.uuidString
        return try await KLock.shared.run { try await Self.open(link) }.1
    }

    /// A K session on `link` and the loader it reads: the cached K first, read again once when it gets no answer
    /// (K changes with a factory reset). Hold KLock: the RPC listener talks K on its own link.
    static func open(_ link: BLELink) async throws -> (KSession, LoaderState?) {
        let account = "k-\(link.watchID?.uuidString ?? "")"
        let cached = Keychain.get(account)
        let (session, secret) = try await KSession.open(link: link, secretHex: cached, register: false)
        Keychain.set(account, secret)
        if let state = try await readLoader(session) { return (session, state) }
        guard cached != nil else { return (session, nil) }
        let (fresh, newSecret) = try await KSession.open(link: link, register: false)
        Keychain.set(account, newSecret)
        return (fresh, try await readLoader(fresh))
    }
}
