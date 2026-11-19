import CoreBluetooth
import WireKit

// WireKit's Link over CoreBluetooth, on the link the phone already holds for Nothing X (cmf-watch-sdk
// docs/abi-1.4.md, "Writing a host", steps 1–2). Everything runs on the main queue; one step waits at a time.
// Background: `bluetooth-central` keeps the link and wakes the app on a notify (WakeProbe checks that it does).
// ponytail: no state restoration; a kill by the system ends the link until the next launch.

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
    private var pendingServices = 0
    /// The link went down (DEBUG wake probe logs it).
    var onDisconnect: (() -> Void)?

    /// The connected watch's identifier: keys the cached pairing secret.
    var watchID: UUID? { peripheral?.identifier }
    /// The advertised name ("CMF Watch Pro 2-1A2B"): the only model id there is.
    var watchName: String? { peripheral?.name }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// `scan`: with no link up (Nothing X closed, the system dropped it) look for the watch's advertisement, as
    /// Bluefy's picker does, for up to 10 s.
    @MainActor func connect(scan: Bool = false) async throws {
        if central.state != .poweredOn { try await wait() }
        var found = central.retrieveConnectedPeripherals(withServices: [Self.service]).first
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
        central.connect(p)
        try await wait() // connected, services and characteristics found, both notifies on
    }

    @MainActor func disconnect() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
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
            // a frame over MTU-3 goes as one write with response (abi-1.4.md, step 4)
            let big = data.count > p.maximumWriteValueLength(for: .withoutResponse)
            if big || !ch.properties.contains(.writeWithoutResponse) {
                step = c
                p.writeValue(data, for: ch, type: .withResponse)
            } else {
                p.writeValue(data, for: ch, type: .withoutResponse)
                c.resume()
            }
        }
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
        case .poweredOn: finish()
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

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        finish(error ?? BLEError.noWatch)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        finish(BLEError.failed(String(localized: "The watch disconnected.")))
        onDisconnect?()
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
        Self.notifies.compactMap { chars[$0] }.forEach { p.setNotifyValue(true, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error { return finish(error) }
        if Self.notifies.compactMap({ chars[$0] }).allSatisfy(\.isNotifying) { finish() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let value = c.value, let name = Self.known.first(where: { $0.0 == c.uuid })?.1 else { return }
        lock.withLock { handlers }.forEach { $0(name, value) }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        finish(error)
    }
}
