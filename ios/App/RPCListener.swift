import UIKit
import UserNotifications
import WireKit

// Answers the running watch app's service requests (docs/miniapp-rpc.md) for as long as the app lives, foreground
// or woken by BLE in the background. Its own BLELink and K session, next to WatchModel.check's: every K host sees
// every K reply, so INFO and MSG from both go one at a time through KLock. A watchface install stops it (the stock
// session binds the watch) and starts it again after.
// Its link stays: after a drop it waits on BLELink's pending reconnect (no timer), and CoreBluetooth state
// restoration brings it back when iOS relaunches CMFX for the watch after ending it. A watch never seen: tried
// again every 30 s while the app runs (10 min on stock firmware).
// ponytail: what woke a restored launch arrives before the session is open and is lost; the watch app's next
// message gets through.

/// One K exchange at a time across sessions: a reply carries no request id.
actor KLock {
    static let shared = KLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }

    func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }
}

@MainActor final class RPCListener {
    static let shared = RPCListener()
    private var task: Task<Void, Never>?
    private var link: BLELink?
    /// slot → package name, from INFO
    private var apps: [Int: String] = [:]
    /// When `apps` was read: an app installed by another tool (fmc.tools, wp2apps) into a slot that held another
    /// would otherwise ask and be granted under the old app's name, so a request reads it again once it is old.
    private var appsAt: Date = .distantPast
    /// The stub's release, from the same read: PUSH needs 7.
    private var stub: UInt32 = 1
    /// The open session, and when the listening loop last went round: `wake()` tells a stuck loop from a quiet one.
    private var session: KSession?
    private var beat = Date.now
    /// Bumped at each `wake()`: a stuck check from an earlier opening does nothing.
    private var wakes = 0

    /// CoreBluetooth state restoration: the listener's link only.
    static let restoreID = "app.cmfx.watch"

    private enum Ended { case stock, dropped, failed }

    func start() {
        guard task == nil else { return }
        // now, not in the task: a relaunch for a restored link needs its central in didFinishLaunching
        if link == nil { link = Self.makeLink() }
        task = Task {
            while !Task.isCancelled {
                switch await listen() {
                case .stock: try? await Task.sleep(for: .seconds(600))
                case .dropped: continue // connect() waits for the reconnect iOS keeps pending
                case .failed: try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    private static func makeLink() -> BLELink {
        let link = BLELink(restore: restoreID)
        link.onReconnect = { DevLog.shared.log("link back") }
        return link
    }

    /// CMFX came to the front: costs nothing in the background (no timer). The listener registers with the watch
    /// again (one PING), which is what relaunching Nothing X used to do for it. Stuck: a loop that has not gone round
    /// in 40 s on screen (it goes round every 5 s, a request at most 30 s) starts again on the same link. Time
    /// suspended does not count: the loop sleeps with the app. Nothing while stopped on purpose (a watch face install).
    func wake() {
        guard task != nil else { return }
        wakes += 1
        let (gen, woke) = (wakes, Date.now)
        Task {
            try? await Task.sleep(for: .seconds(40))
            guard gen == wakes, task != nil, UIApplication.shared.applicationState == .active, beat < woke else { return }
            DevLog.shared.log("listener stuck: starting again")
            restart()
        }
        guard let session else { return }
        Task {
            do {
                _ = try await withDeadline(.seconds(8)) { try await KLock.shared.run { try await session.ping() } }
            } catch {
                // busy (a transfer) or away: not a reason to cut the link
                DevLog.shared.log("register on open: \(error)")
            }
        }
    }

    /// A new loop on the same link: a second central with the restore id would stop iOS waking CMFX for the watch
    /// (only a relaunch fixed that). The old loop's waiting step ends with an error and the loop with its task.
    private func restart() {
        task?.cancel()
        task = nil
        link?.unstick()
        start()
    }

    func stop() {
        task?.cancel()
        task = nil
        link?.disconnect()
        link = nil
    }

    /// What WatchModel.check read: the apps by slot, and a loader on a watch that had none.
    func update(_ state: LoaderState?) {
        guard let state else { return }
        apps = state.apps.mapValues(\.name)
        appsAt = .now
        stub = state.stub.version
        Hub.shared.setApps(apps)
        if task == nil { start() }
    }

    private func listen() async -> Ended {
        let link = self.link ?? Self.makeLink()
        self.link = link
        var up = true
        link.onDisconnect = { up = false }
        do {
            try await link.connect()
            let (session, state) = try await KLock.shared.run { try await WatchModel.open(link) }
            guard let state else {
                DevLog.shared.log("stock firmware: not listening")
                link.disconnect()
                if self.link === link { self.link = nil }
                return .stock
            }
            apps = state.apps.mapValues(\.name)
            appsAt = .now
            stub = state.stub.version
            // the watch is back (a restart, a reconnect): the Watch tab and Firmware page read it again
            WatchModel.shared.linkCameBack()
            _ = try await KLock.shared.run { try await session.ping() } // registers: the stub sends us EVENTs
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            // a restart's old loop ends late: it must not detach the new session
            self.session = session
            Hub.shared.attach(session, apps: apps)
            defer {
                if self.session === session {
                    self.session = nil
                    Hub.shared.attach(nil, apps: apps)
                }
            }
            DevLog.shared.log("listening")
            while up, !Task.isCancelled {
                beat = .now
                await runDueJobs(session)
                // Nothing X talked (its bind changes the watch's session): register again, or the watch apps
                // wait for the phone until CMFX is relaunched. Costs nothing while Nothing X is quiet.
                if await session.takeForeign() {
                    do {
                        _ = try await withDeadline(.seconds(8)) { try await KLock.shared.run { try await session.ping() } }
                        DevLog.shared.log("Nothing X talked: registered again")
                    } catch {
                        DevLog.shared.log("register after Nothing X: \(error)")
                    }
                }
                guard let m = try? await session.recvFrom(timeout: .seconds(2)) else { continue }
                beat = .now
                // one request that hangs (a server, a service) must not stop the watch's next ones being heard
                let data = m.data, slot = Int(m.slot)
                do {
                    try await withDeadline(.seconds(30)) { @MainActor in await self.handle(data, slot: slot, session) }
                } catch {
                    DevLog.shared.log("slot \(slot): no answer in 30 s, listening on")
                }
            }
            DevLog.shared.log("link dropped")
            return up ? .failed : .dropped
        } catch {
            DevLog.shared.log("link: \(error.localizedDescription)")
        }
        return .failed
    }

    /// The watch apps' background jobs that are due, while the link is up: in the foreground and in the ~10 s a BLE
    /// wake gives. ponytail: no BGAppRefreshTask; it wakes without the link, and delivering needs it.
    private func runDueJobs(_ session: KSession) async {
        let now = Date.now
        for (package, jobs) in Jobs.shared.all {
            for j in jobs where j.due(now) {
                Jobs.shared.ran(package, j.id, at: now) // first: a failing job waits its interval
                do {
                    let records = try await withDeadline(.seconds(8)) { @MainActor in
                        try await runJob(j, package: package, host: PhoneServices.shared)
                    }
                    await deliver(package, j, records, session, now)
                } catch {
                    DevLog.shared.log("\(package) job \(j.id): \(error)")
                }
            }
        }
    }

    /// Writes a job's records to the app's widget card or start blob (PUSH, stub 8, cmf-watch-sdk docs/widget-push.md).
    private func deliver(_ package: String, _ job: RefreshJob, _ records: [Data], _ session: KSession, _ now: Date) async {
        let line = "\(package) job \(job.id)"
        guard let data = job.pushData(records) else { return DevLog.shared.log("\(line): nothing to push (\(records.count) records)") }
        guard canPush(stub: stub) else { return DevLog.shared.log("\(line): stub \(stub) takes no PUSH (8+)") }
        guard let slot = apps.first(where: { $0.value == package })?.key else { return DevLog.shared.log("\(line): not on the watch") }
        do {
            switch try await KLock.shared.run({ try await push(session, slot: slot, kind: job.target, data: data) }) {
            case .ok: DevLog.shared.log("\(line): pushed to slot \(slot)")
            case .later(let ms):
                // due again once the watch takes a write for this slot
                Jobs.shared.ran(package, job.id, at: now + Double(ms) / 1000 - Double(job.minutes * 60))
            case .refused(let s): DevLog.shared.log("\(line): push refused (\(s))")
            }
        } catch {
            DevLog.shared.log("\(line): push failed: \(error)")
        }
    }

    private func handle(_ message: Data, slot: Int, _ session: KSession) async {
        // CMFX: the hub's watch apps (Spotify, Gemini, maps, navigation, photos) talk their own protocols
        guard message.starts(with: rpcPrefix) else {
            if apps[slot] == nil, let state = try? await KLock.shared.run({ try await readLoader(session) }) {
                apps = state.apps.mapValues(\.name)
                Hub.shared.setApps(apps)
            }
            return Hub.shared.receive(message, slot: slot)
        }
        // the ~10 s a BLE wake gives, kept until the reply is out
        let bg = UIApplication.shared.beginBackgroundTask(withName: "rpc")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        if apps[slot] == nil || -appsAt.timeIntervalSinceNow > 60,
           let state = try? await KLock.shared.run({ try await readLoader(session) }) {
            apps = state.apps.mapValues(\.name)
            appsAt = .now
            Hub.shared.setApps(apps)
        }
        // empty: a part of http.request before its last
        guard let out = await answer(message, package: apps[slot], host: PhoneServices.shared), !out.isEmpty else { return }
        // "R1Q id method …" in, "R1A id status index total" out
        let method = message.count > 4 ? DevLog.methods[message[message.startIndex + 4]] ?? "?" : "?"
        let status = out.first.flatMap { $0.count > 4 ? Int($0[$0.startIndex + 4]) : nil }
            .map { $0 < DevLog.statuses.count ? DevLog.statuses[$0] : "\($0)" } ?? "?"
        do {
            try await KLock.shared.run {
                for m in out { try await session.send(m) }
            }
            DevLog.shared.log("\(apps[slot] ?? "slot \(slot)") \(method) → \(status), \(out.count) msg")
        } catch {
            DevLog.shared.log("\(apps[slot] ?? "slot \(slot)") \(method) → \(status), send failed: \(error)")
        }
    }
}

/// Starts the listener at launch (a background launch has no scene) and opens the asking app's page from the ask notification.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        RPCListener.shared.start()
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                               queue: .main) { _ in
            Task { @MainActor in
                RPCListener.shared.wake()
                await PhoneServices.shared.refresh(within: .seconds(10))
            }
        }
        return true
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        let package = r.notification.request.content.userInfo["package"] as? String
        await MainActor.run { Permissions.shared.open = package }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound] // a watch app's notify with its sound, also while the companion is open
    }
}
