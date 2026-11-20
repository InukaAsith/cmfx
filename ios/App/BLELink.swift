import CoreBluetooth
import WireKit

// WireKit's Link over CoreBluetooth, on the link the phone already holds for Nothing X (cmf-watch-sdk
// docs/abi-1.4.md, "Writing a host", steps 1–2). Everything runs on the main queue; one step waits at a time.
// Background: `bluetooth-central` keeps the link and wakes the app on a notify (WakeProbe checks that it does).
// The watch is shared with Nothing X (the system holds its link; this is CMFX's use of it), so:
// - a drop (the watch walked away, restarted) asks for the watch again at once: a pending connect iOS keeps while
//   the app is suspended, no timer; the notifies are subscribed again when it is back, then `onReconnect`.
// - writes without response wait for room (`canSendWriteWithoutResponse`), in order, instead of being dropped.
// - the RPC listener's link (`restore`) uses state restoration: iOS relaunches CMFX for a watch notify after it
//   ended it for memory, and the restored link is taken up again.

enum BLEError: LocalizedError {
    case off, unauthorized, noWatch, missing, failed(String)
    var errorDescription: String? {
        switch self {
        case .off: String(localized: "Bluetooth is off.")
        case .unauthorized: String(localized: "CMFX may not use Bluetooth. Allow it in Settings.")
        case .noWatch: String(localized: "No watch connected. Open Nothing X and make sure the watch is connected.")
        case .missing: String(localized: "This watch does not offer the expected services.")
        case .failed(let m): m
        }
    }
}

final class BLELink: NSObject, Link, @unchecked Sendable {
    static let service = CBUUID(string: "FFF0")
    private static let required = [Uuid.cmdWrite, Uuid.cmdNotify, Uuid.shellWrite, Uuid.shellNotify]
    /// The stock upload pair (watchface install) and the firmware update's: only those need them.
    private static let known = (required + [DataUuid.write, DataUuid.notify, OtaUuid.write, OtaUuid.notify])
        .map { (CBUUID(string: $0), $0) }
    private static let notifies = [Uuid.cmdNotify, Uuid.shellNotify, DataUuid.notify, OtaUuid.notify]

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [String: CBCharacteristic] = [:]
    /// Every session on the link gets every notification and keeps its own.
    private var handlers: [@Sendable (String, Data) -> Void] = []
    private let lock = NSLock()
    private var step: CheckedContinuation<Void, Error>?
    /// Bumped with each step: a timeout ends only the step it was set for.
    private var stepGen = 0
    private var pendingServices = 0
    /// Writes without response waiting for room in iOS's buffer, oldest first.
    private var queued: [(Data, CBCharacteristic, CheckedContinuation<Void, Error>)] = []
    /// false after disconnect(): no reconnecting.
    private var wanted = true
    /// Back after a drop or a restoration: `onReconnect` once the notifies are on again.
    private var reconnecting = false
    /// The link went down (DEBUG wake probe logs it). Its sessions are over: their handlers go with it.
    var onDisconnect: (() -> Void)?
    /// The link is back (reconnected after a drop, or restored): open a session on it again.
    var onReconnect: (() -> Void)?

    /// The connected watch's identifier: keys the cached pairing secret.
    var watchID: UUID? { peripheral?.identifier }
    /// The advertised name ("CMF Watch Pro 2-1A2B"): the only model id there is.
    var watchName: String? { peripheral?.name }

    /// `restore`: a state restoration identifier (one link at a time may use it).
    init(restore: String? = nil) {
        super.init()
        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
        if let restore { options[CBCentralManagerOptionRestoreIdentifierKey] = restore }
        central = CBCentralManager(delegate: self, queue: .main, options: options)
    }

    /// Connected, every characteristic found and every notify on.
    private var ready: Bool {
        guard let p = peripheral, p.state == .connected, Self.required.allSatisfy({ chars[$0] != nil }) else { return false }
        return Self.notifies.compactMap { chars[$0] }.allSatisfy(\.isNotifying)
    }

    /// `scan`: with no link up (Nothing X closed, the system dropped it) look for the watch's advertisement, as
    /// Bluefy's picker does, for up to 10 s.
    @MainActor func connect(scan: Bool = false) async throws {
        wanted = true
        if central.state != .poweredOn { try await wait() }
        // restored, or back after a drop
        if ready { return }
        var found = peripheral ?? central.retrieveConnectedPeripherals(withServices: [Self.service]).first
        if found == nil, scan {
            central.scanForPeripherals(withServices: nil)
            let timeout = Task { @MainActor in
                try await Task.sleep(for: .seconds(10))
                finish(BLEError.noWatch)
            }
            defer { central.stopScan(); timeout.cancel() }
            try await wait()
            found = peripheral
        }
        guard let p = found else { throw BLEError.noWatch }
        peripheral = p
        p.delegate = self
        if p.state == .connected { p.discoverServices(nil) } else { central.connect(p) }
        try await wait() // connected, services and characteristics found, both notifies on
    }

    /// On purpose: no reconnecting.
    @MainActor func disconnect() {
        wanted = false
        reconnecting = false
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        failQueued(BLEError.failed(String(localized: "The watch disconnected.")))
        finish(BLEError.failed(String(localized: "The watch disconnected."))) // a connect waiting on a pending reconnect
    }

    /// Ends whatever waits (a step, queued writes) and keeps the link: its loop starts again on it.
    @MainActor func unstick() {
        failQueued(BLEError.failed(String(localized: "The watch did not answer.")))
        finish(BLEError.failed(String(localized: "The watch did not answer.")))
    }

    /// Ends a step that never finished (the watch went quiet).
    @MainActor func abort() {
        finish(BLEError.failed(String(localized: "The watch did not answer.")))
        disconnect()
    }

    func onNotify(_ handler: @escaping @Sendable (String, Data) -> Void) {
        lock.withLock { handlers.append(handler) }
    }

    func write(_ uuid: String, _ data: Data) async throws {
        try await send(uuid, data)
    }

    /// Writes and, with response, waits for the ack: the step is set in the same main-actor turn as the write,
    /// so the callback cannot come first.
    @MainActor private func send(_ uuid: String, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            guard let p = peripheral, let ch = chars[uuid] else { return c.resume(throwing: BLEError.missing) }
            guard p.state == .connected else { return c.resume(throwing: BLEError.failed(String(localized: "The watch disconnected."))) }
            // a frame over MTU-3 goes as one write with response (abi-1.4.md, step 4)
            let big = data.count > p.maximumWriteValueLength(for: .withoutResponse)
            if big || !ch.properties.contains(.writeWithoutResponse) {
                // never two waiting: an older one (it should not happen) fails rather than waits for ever
                finish(BLEError.failed(String(localized: "The watch did not answer.")))
                step = c
                stepGen += 1
                let g = stepGen
                p.writeValue(data, for: ch, type: .withResponse)
                // no ack in 5 s: this write failed, the lane goes on
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    if self.stepGen == g { self.finish(BLEError.failed(String(localized: "The watch did not answer."))) }
                }
            } else if queued.isEmpty, p.canSendWriteWithoutResponse {
                p.writeValue(data, for: ch, type: .withoutResponse)
                c.resume()
            } else {
                // iOS's buffer is full: written from peripheralIsReady, in order. iOS does not always say it is
                // ready (another app on the same link): after 1.5 s the queue is written anyway, nothing waits for ever
                queued.append((data, ch, c))
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1500))
                    self.flushStale(p)
                }
            }
        }
    }

    private func drainQueued(_ p: CBPeripheral) {
        while let w = queued.first, p.canSendWriteWithoutResponse {
            queued.removeFirst()
            p.writeValue(w.0, for: w.1, type: .withoutResponse)
            w.2.resume()
        }
    }

    /// Writes still queued after their wait: written now (a dropped one is resent by its sender).
    private func flushStale(_ p: CBPeripheral) {
        guard p.state == .connected else { return failQueued(BLEError.failed(String(localized: "The watch disconnected."))) }
        let q = queued
        queued.removeAll()
        for w in q {
            p.writeValue(w.0, for: w.1, type: .withoutResponse)
            w.2.resume()
        }
    }

    private func failQueued(_ error: Error) {
        let q = queued
        queued.removeAll()
        q.forEach { $0.2.resume(throwing: error) }
    }

    @MainActor private func wait() async throws {
        try await withCheckedThrowingContinuation { step = $0 }
    }

    private func finish(_ error: Error? = nil) {
        let s = step
        step = nil
        if let error { s?.resume(throwing: error) } else { s?.resume() }
    }
}

extension BLELink: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            // restored with nobody waiting yet: take the watch up again (the listener's connect() finds it ready)
            if step == nil, wanted, let p = peripheral {
                reconnecting = true
                if p.state == .connected { p.discoverServices(nil) } else { c.connect(p) }
            }
            finish()
        case .poweredOff: finish(BLEError.off)
        case .unauthorized, .unsupported: finish(BLEError.unauthorized)
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any],
                        rssi: NSNumber) {
        guard peripheral == nil, (p.name ?? "").hasPrefix("CMF Watch") else { return }
        peripheral = p
        finish()
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        guard let p = restored.first(where: { ($0.name ?? "").hasPrefix("CMF Watch") }) ?? restored.first else { return }
        peripheral = p
        p.delegate = self
        // its characteristics, if iOS kept them; the notifies are checked again once powered on
        for s in p.services ?? [] {
            for ch in s.characteristics ?? [] {
                if let name = Self.known.first(where: { $0.0 == ch.uuid })?.1 { chars[name] = ch }
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        finish(error ?? BLEError.noWatch)
        again(p)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        finish(BLEError.failed(String(localized: "The watch disconnected.")))
        failQueued(BLEError.failed(String(localized: "The watch disconnected.")))
        // the sessions on it are over (a new one registers its own handler)
        lock.withLock { handlers.removeAll() }
        onDisconnect?()
        again(p)
    }

    /// Not dropped on purpose: ask for the watch again. iOS keeps the request (no timeout) while the app is
    /// suspended and connects when the watch is back.
    private func again(_ p: CBPeripheral) {
        guard wanted, p === peripheral, central.state == .poweredOn else { return }
        reconnecting = true
        central.connect(p)
    }

    /// Notifies on: whoever waits goes on; after a drop or a restoration, `onReconnect`.
    private func linkReady() {
        finish()
        if reconnecting {
            reconnecting = false
            onReconnect?()
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        guard error == nil, !services.isEmpty else { return finish(error ?? BLEError.missing) }
        pendingServices = services.count
        services.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if let name = Self.known.first(where: { $0.0 == c.uuid })?.1 { chars[name] = c }
        }
        pendingServices -= 1
        guard pendingServices == 0 else { return }
        guard Self.required.allSatisfy({ chars[$0] != nil }) else { return finish(BLEError.missing) }
        let off = Self.notifies.compactMap { chars[$0] }.filter { !$0.isNotifying }
        // restored with its subscriptions: nothing to turn on
        if off.isEmpty { return linkReady() }
        off.forEach { p.setNotifyValue(true, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error { return finish(error) }
        if Self.notifies.compactMap({ chars[$0] }).allSatisfy(\.isNotifying) { linkReady() }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        drainQueued(p)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let value = c.value, let name = Self.known.first(where: { $0.0 == c.uuid })?.1 else { return }
        lock.withLock { handlers }.forEach { $0(name, value) }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        finish(error)
    }
}
