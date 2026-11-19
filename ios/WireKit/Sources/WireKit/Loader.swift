import Foundation

// What the App Loader keeps on the watch, read only: the stub's release, the loader and the app in each slot
// (fmc_frontend device/lib ble.ts readWp2, wp2.ts; cmf-watch-sdk docs/abi-1.4.md "Stub version").

/// INFO for this slot answers the stub's release instead of a header (stub 2+).
public let stubSlot: UInt8 = 0xFE

public struct Stub: Equatable, Sendable {
    /// 1 for every stub from before the release was readable.
    public var version: UInt32
    /// The highest package abi_minor it takes; nil on stub 1.
    public var abiMinor: UInt8?

    public init(version: UInt32, abiMinor: UInt8?) {
        (self.version, self.abiMinor) = (version, abiMinor)
    }
}

public struct LoaderState: Equatable, Sendable {
    public var stub: Stub
    public var loader: PackageHeader?
    /// slot → app
    public var apps: [Int: PackageHeader]
    /// How many app slots this stub has.
    public var slots: Int { appSlots(stub: stub.version) }

    public init(stub: Stub, loader: PackageHeader?, apps: [Int: PackageHeader]) {
        (self.stub, self.loader, self.apps) = (stub, loader, apps)
    }
}

/// `status ‖ version:u32le ‖ abi_minor`; an older stub reads 0xFE as a bad slot (`01`).
public func parseStubReply(_ r: Data) -> Stub? {
    if r.first == Status.badRequest.rawValue { return Stub(version: 1, abiMinor: nil) }
    guard r.count == 6, r.first == Status.ok.rawValue else { return nil }
    return Stub(version: r.le(UInt32.self, at: 1), abiMinor: r[r.startIndex + 5])
}

/// nil: no stub answered (stock firmware, or a stub without K, anything before fw-wp2.bin of 2026-11-13).
/// INFO only reads headers; it also drops an install the stub had open, and nothing here opens one.
public func readLoader(_ s: Requester, probe: Duration = .milliseconds(2500)) async throws -> LoaderState? {
    let reply: Data
    do {
        // a stub answers at once; stock stays silent
        reply = try await s.call(Cmd.info, Data([stubSlot]), timeout: probe)
    } catch WireError.timeout {
        return nil
    }
    guard let stub = parseStubReply(reply) else { throw WireError.refused(reply.first ?? 0xFF) }
    func read(_ slot: Int) async throws -> PackageHeader? {
        let r = try await s.call(Cmd.info, Data([UInt8(slot)]), timeout: .seconds(4))
        return r.first == Status.ok.rawValue ? parseHeader(Data(r.dropFirst())) : nil
    }
    var apps: [Int: PackageHeader] = [:]
    for slot in 0..<appSlots(stub: stub.version) { apps[slot] = try await read(slot) }
    return LoaderState(stub: stub, loader: try await read(loaderSlot), apps: apps)
}
