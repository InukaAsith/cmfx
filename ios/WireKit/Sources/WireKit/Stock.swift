import CryptoKit
import Foundation

// The stock session (Nothing X's protocol) and the watchface upload over it: port of fmc_frontend device/lib
// ble-protocol.ts (Codec) and ble.ts (pair, authenticate, uploadWatchface); docs/cmf-protocol.md §9.5.
//
// Not K: watchface commands are sealed with the stock session key, and pair/authenticate replace the authkey and
// session key the watch keeps for Nothing X (cmf-watch-sdk docs/recon.md, "Bind popup, authkey and session key").
// Two stock sessions can't share the link: Nothing X has to be closed first, as with Bluefy (FMC-8, item 2).
// Channels as on the site: auth on fff2/fff1 (`send`), the upload on ffe1/ffe2 (`sendData`).

public enum StockCmd {
    static func k(_ c2: UInt16) -> UInt32 { 0xFFFF_0000 | UInt32(c2) }
    public static let authPairReq = k(0x8047), authPairRep = k(0x0048), authName = k(0x8049), authMac = k(0x0049)
    public static let authNonceReq = k(0x804B), authNonceRep = k(0x004C), authConfirmReq = k(0x804D)
    public static let authConfirmRep = k(0x0004), authFailed = k(0xA061)
    public static let wfInit1Req = k(0x8052), wfInit1Rep = k(0x0052), wfInit2Req = k(0x9075), wfInit2Rep = k(0xA075)
    public static let wfChunkReq = k(0xA064), wfChunkWrite = k(0x9064), wfFinishAck1 = k(0xA065)
    public static let wfFinishAck2 = k(0x9065), wfInstalled = k(0xA055)
    /// get (`00`) or set (`01 ‖ active ‖ count ‖ 00 ‖ ids`) the dial list (cmf-watch-sdk docs/recon.md, "Stock watch faces")
    public static let wfList = k(0x9055)
    /// ble-protocol.ts `time`, `fwGet`
    public static let time = k(0x8004), fwGet = k(0x8006)
    /// The firmware update (ble.ts flashFirmware, cmf-watch-sdk docs/ota.md). a043/a044 end it, meaning undocumented.
    public static let otaBeginReq = k(0x9052), otaBeginRep = k(0xA052), otaStartReq = k(0x9040), otaStartRep = k(0xA040)
    public static let otaChunkReq = k(0xA042), otaChunkWrite = k(0x9042), otaVerdict = k(0xA041), otaCommit = k(0x9041)
    public static let otaStatus43 = k(0xA043), otaStatus44 = k(0xA044)
    /// Sent and read in the clear (body ‖ crc32le); `authFailed` because the watch could not decrypt.
    static let plain: Set<UInt32> = [authPairReq, authPairRep, wfChunkWrite, otaChunkWrite, authFailed]
    /// What goes over the data pair (ffe1); everything else goes over fff2.
    static let data: Set<UInt32> = [wfInit1Req, wfInit2Req, wfChunkWrite, wfFinishAck2]
    /// Not a command: a `0x0049` that opens only with the all-zero key (the bind popup was confirmed).
    static let zeroKeyReply: UInt32 = 0
}

public let marker: UInt8 = 0xA5
/// `UUID.dataWrite` / `dataRead`: the stock session's pair.
public enum DataUuid {
    public static let write = "02F00000-0000-0000-0000-00000000FFE1"
    public static let notify = "02F00000-0000-0000-0000-00000000FFE2"
}

/// `UUID.otaWrite` / `otaRead`: the firmware update's pair.
public enum OtaUuid {
    public static let write = "02F00000-0000-0000-0000-00000000FF01"
    public static let notify = "02F00000-0000-0000-0000-00000000FF02"
}

/// `Codec.encode`: frames of at most `mtu` bytes; sealed chunks of `(mtu-11)/16*16 - 5` plain bytes, plain chunks of
/// `mtu - 20`, or `plainSize` (the firmware's 224, proven on hardware). Header: F5, length, c1, count, index, c2 (big endian).
public func stockFrames(_ cmd: UInt32, _ payload: Data, key: Data?, mtu: Int = 180, plainSize: Int? = nil) -> [Data] {
    var chunks: [Data] = []
    let isPlain = StockCmd.plain.contains(cmd)
    let size = isPlain ? plainSize ?? mtu - 20 : (mtu - 11) / 16 * 16 - 5
    if payload.isEmpty {
        chunks = [Data()]
    } else {
        for off in stride(from: 0, to: payload.count, by: size) {
            let ch = payload[payload.startIndex + off..<payload.startIndex + min(off + size, payload.count)]
            if isPlain {
                var b = Data(ch)
                b.le(crc32(Data(ch)))
                chunks.append(b)
            } else {
                chunks.append(seal(key!, Data(ch)))
            }
        }
    }
    return chunks.enumerated().map { i, ch in
        var f = Data([0xF5])
        f.be(UInt16(ch.count))
        f.be(UInt16(cmd >> 16))
        f.be(UInt16(chunks.count))
        f.be(UInt16(i + 1))
        f.be(UInt16(cmd & 0xFFFF))
        return f + ch
    }
}

/// `Codec.decode`: one notification is one frame; multi-frame commands are reassembled per command.
public struct StockParser {
    var bufs: [UInt32: (expected: Int, data: Data)] = [:]
    public init() {}

    public enum Failure: Error, Equatable { case badFrame, cannotOpen(UInt32) }

    /// The whole command once its last frame is in, else nil.
    public mutating func feed(_ f: Data, key: Data?) throws -> (cmd: UInt32, payload: Data)? {
        guard f.count >= 11, f.first == 0xF5 else { throw Failure.badFrame }
        let len = Int(f.be16(at: 1)), cmd = UInt32(f.be16(at: 3)) << 16 | UInt32(f.be16(at: 9))
        let count = Int(f.be16(at: 5)), index = Int(f.be16(at: 7))
        var payload = Data()
        if len > 0 {
            if StockCmd.plain.contains(cmd) {
                // body ‖ crc32le
                payload = Data(f.dropFirst(11).prefix(max(len - 4, 0)))
            } else {
                let body = Data(f.dropFirst(11).prefix(len))
                guard let key, body.count == len, let p = open(key, body) else { throw Failure.cannotOpen(cmd) }
                payload = p
            }
        }
        if count <= 1 { return (cmd, payload) }
        var b = bufs[cmd] ?? (1, Data())
        if index != b.expected {
            if index != 1 { return nil }
            b.data = Data()
        }
        b.data += payload
        b.expected = index + 1
        bufs[cmd] = b
        guard index == count else { return nil }
        bufs[cmd] = nil
        return (cmd, b.data)
    }
}

func sha256(_ parts: Data...) -> Data { Data(SHA256.hash(data: parts.reduce(Data(), +))) }

/// `pair()`: the request for random1, and k1 once the watch's reply proved it knows the secret too.
public func pairRequest(random1: Data, secret: Data) -> Data { random1 + sha256(random1, secret) }
public func pairKey(random1: Data, reply: Data, secret: Data) -> Data? {
    guard reply.count >= 48 else { return nil }
    let random2 = Data(reply.prefix(16)), sig = Data(reply[reply.startIndex + 16..<reply.startIndex + 48])
    guard sig == sha256(random2, secret) else { return nil }
    return Data(sha256(random1, random2, secret).prefix(16))
}
public func sessionKey(nonce: Data, k1: Data) -> Data { Data(sha256(nonce, k1).prefix(16)) }

/// `a055`: built-ins ‖ FFFFFFFF ‖ gallery ids after a 4-byte header, flattened.
public func parseInstalledDials(_ p: Data) -> [UInt32] {
    stride(from: 4, to: p.count - 3, by: 4).map { p.le(UInt32.self, at: $0) }.filter { $0 != 0xFFFF_FFFF }
}

/// `a055`'s 4-byte header, read as `01 ‖ active? ‖ count ‖ capacity`. Unconfirmed reading from five samples
/// (watch_health docs/cmf-protocol.md §9.5d-h, fmc_frontend ble.ts): `count` matched the dials on the watch side-loaded
/// ones included (which the id list leaves out), `capacity` was always 7. nil when it doesn't look like that.
public func parseDialCount(_ p: Data) -> (count: Int, capacity: Int)? {
    guard p.count >= 4 else { return nil }
    let count = Int(p[p.startIndex + 2]), capacity = Int(p[p.startIndex + 3])
    return capacity > 0 && count <= capacity ? (count, capacity) : nil
}

/// `init2`: ctr_type 3 ‖ old_wf_id ‖ new_wf_id ‖ size, little endian.
public func uploadInit(old: UInt32, new: UInt32, size: Int) -> Data {
    var d = Data([3])
    d.le(old)
    d.le(new)
    d.le(UInt32(size))
    return d
}

public enum UploadError: Error, Equatable {
    /// The watch has no free slot: ask which dial to replace.
    case noFreeSlot
    /// The watch refused to replace this dial (it isn't there, or won't take it as a target).
    case staleSlot(UInt32)
    case rejected(String)
    case stalled
    case authFailed
    /// The bind popup was confirmed on the watch, which zeroed the new authkey: bind again without touching it.
    case rebind
}

/// One stock session over the GATT link: auth on fff2 (replies on fff1), the upload on ffe1 (replies on ffe2).
public actor StockSession {
    let link: Link
    let mtu: Int
    var key: Data?
    private var parser = StockParser()
    let inbox = Inbox<(UInt32, Data)>()
    /// Latest `a055`: the dials the watch reported (side-loaded ones are missing from it).
    public private(set) var reported: [UInt32]?
    /// Every entry of the latest `a055`, the photo face (FFFFFFFF) included: what a set sends back.
    public private(set) var listed: [UInt32]?
    /// Latest `a055` header: how many dials, side-loaded included, and how many fit (`parseDialCount`).
    public private(set) var dialCount: (count: Int, capacity: Int)?
    /// Latest `a055` header, raw, for field reports.
    public private(set) var dialHeader: Data?

    public init(link: Link, mtu: Int = 180, key: Data? = nil) {
        (self.link, self.mtu, self.key) = (link, mtu, key)
        let (stream, sink) = AsyncStream<Data>.makeStream()
        link.onNotify { uuid, value in
            // K frames on fff1 don't open with F5: the parser drops them
            if [DataUuid.notify, OtaUuid.notify, Uuid.cmdNotify].contains(uuid.uppercased()) { sink.yield(value) }
        }
        Task { [weak self] in
            for await f in stream { await self?.feed(f) }
        }
    }

    func feed(_ f: Data) async {
        let got: (cmd: UInt32, payload: Data)?
        do {
            got = try parser.feed(f, key: key)
        } catch StockParser.Failure.cannotOpen(StockCmd.authMac) {
            // recon.md, "Bind popup…": confirming the popup zeroes the authkey and the reply comes under zero
            var zero = StockParser()
            if (try? zero.feed(f, key: Data(count: 16))) != nil { await inbox.put((StockCmd.zeroKeyReply, Data())) }
            return
        } catch { return }
        guard let (cmd, p) = got else { return }
        // a set's ack is a055 with the single byte 00
        if cmd == StockCmd.wfInstalled, p.count >= 4 {
            listed = stride(from: 4, to: p.count - 3, by: 4).map { p.le(UInt32.self, at: $0) }
            reported = parseInstalledDials(p)
            dialHeader = Data(p.prefix(4))
            dialCount = parseDialCount(p)
        }
        await inbox.put((cmd, p))
    }

    func send(_ cmd: UInt32, _ payload: Data) async throws {
        let uuid = StockCmd.data.contains(cmd) ? DataUuid.write : Uuid.cmdWrite
        for f in stockFrames(cmd, payload, key: key, mtu: mtu) { try await link.write(uuid, f) }
    }

    /// The next command out of `wanted`. `authFailed` ends the wait only during auth: on the shared link it also
    /// answers Nothing X's frames under the key we replaced, which must not cut an upload short.
    func next(_ wanted: Set<UInt32>, timeout: Duration = .seconds(8), auth: Bool = false) async throws
        -> (UInt32, Data) {
        let deadline = ContinuousClock.now + timeout
        while true {
            let left = deadline - ContinuousClock.now
            guard left > .zero, let m = await inbox.next(timeout: left) else {
                throw WireError.timeout("no " + wanted.map { String(format: "%04X", $0 & 0xFFFF) }.joined(separator: "/"))
            }
            if auth, m.0 == StockCmd.authFailed { throw UploadError.authFailed }
            if auth, m.0 == StockCmd.zeroKeyReply { throw UploadError.rebind }
            if wanted.contains(m.0) { return m }
        }
    }

    /// A new bind: the watch shows its "Paired" popup, and the authkey Nothing X knows is replaced. As the SDK's
    /// host (`link.py` `_bind`): the first `0x8049` only opens the popup, the second is answered; a confirmed popup
    /// zeroes the authkey, so that attempt starts over.
    public func pair(secret: Data, attempts: Int = 3) async throws -> Data {
        for attempt in 1...attempts {
            key = nil
            await inbox.drain()
            let random1 = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            try await send(StockCmd.authPairReq, pairRequest(random1: random1, secret: secret))
            let (_, reply) = try await next([StockCmd.authPairRep], auth: true)
            guard let k1 = pairKey(random1: random1, reply: reply, secret: secret) else {
                throw UploadError.rejected("watch signature mismatch")
            }
            key = k1
            try await send(StockCmd.authName, Self.phone)
            do {
                do {
                    try await name(timeout: .seconds(2))
                } catch WireError.timeout {
                    try await name(timeout: .seconds(8))
                }
                try await openSession(k1: k1)
                return k1
            } catch UploadError.rebind where attempt < attempts {
                continue
            }
        }
        throw UploadError.rebind
    }

    static let phone = Data([marker]) + Data("fmc".utf8)

    private func name(timeout: Duration) async throws {
        try await send(StockCmd.authName, Self.phone)
        _ = try await next([StockCmd.authMac], timeout: timeout, auth: true)
    }

    /// Opens a session with a known authkey: replaces the session key the watch keeps (and saves to NVRAM).
    public func authenticate(k1: Data) async throws {
        key = k1
        await inbox.drain()
        try await name(timeout: .seconds(8))
        try await openSession(k1: k1)
    }

    /// The dials on the watch. a055 comes with the housekeeping after the time and fwGet the site sends right after
    /// auth (ble.ts fetchInfo), not on auth alone; waits up to `timeout` for it.
    public func installedDials(timeout: Duration = .seconds(4)) async -> [UInt32]? {
        if reported == nil {
            let now = UInt32(Date().timeIntervalSince1970)
            let tz = UInt32(bitPattern: Int32(TimeZone.current.secondsFromGMT() * 1000))
            var t = Data()
            for v in [now, tz] { withUnsafeBytes(of: v.bigEndian) { t.append(contentsOf: $0) } }
            try? await send(StockCmd.time, t)
            try? await send(StockCmd.fwGet, Data())
            _ = try? await next([StockCmd.wfInstalled], timeout: timeout)
        }
        return reported
    }

    /// Sets the dial list: the watch keeps the given ids it has, in this order, drops the rest, and shows
    /// `ids[active]`. It can't add a face. Reads the list again (the ack says nothing about what matched).
    public func setDials(_ ids: [UInt32], active: Int) async throws {
        var p = Data([1, UInt8(active), UInt8(ids.count), 0])
        for id in ids { p.le(id) }
        try await send(StockCmd.wfList, p)
        _ = try await next([StockCmd.wfInstalled], timeout: .seconds(4))
        reported = nil
        try await send(StockCmd.wfList, Data([0]))
        _ = try await next([StockCmd.wfInstalled], timeout: .seconds(4))
    }

    private func openSession(k1: Data) async throws {
        try await send(StockCmd.authNonceReq, Data([marker]))
        let (_, nonce) = try await next([StockCmd.authNonceRep], auth: true)
        key = sessionKey(nonce: nonce, k1: k1)
        try await send(StockCmd.authConfirmReq, Data([marker]))
        _ = try await next([StockCmd.authConfirmRep], auth: true)
    }

    /// One upload attempt: init1, init2, then the watch pulls ranges until it says yes or no.
    public func upload(_ bin: Data, old: UInt32, new: UInt32, progress: @Sendable (Int) -> Void) async throws {
        await inbox.drain()
        try await send(StockCmd.wfInit1Req, Data([marker]))
        let (_, r1) = try await next([StockCmd.wfInit1Rep])
        guard r1.first == 1 else { throw UploadError.rejected("init1 \(r1.hexString)") }
        try await send(StockCmd.wfInit2Req, uploadInit(old: old, new: new, size: bin.count))
        let (_, r2) = try await next([StockCmd.wfInit2Rep])
        guard r2.first == 1 else { throw old == 0 ? UploadError.noFreeSlot : UploadError.staleSlot(old) }
        while true {
            let (cmd, p): (UInt32, Data)
            do {
                (cmd, p) = try await next([StockCmd.wfChunkReq, StockCmd.wfFinishAck1], timeout: .seconds(30))
            } catch WireError.timeout { throw UploadError.stalled }
            if cmd == StockCmd.wfFinishAck1 {
                try? await send(StockCmd.wfFinishAck2, Data([marker]))
                if p.first == 1 { progress(100); return }
                // 0x0A, "stored but not activated": on an append the only answer a full watch gives
                if p.first == 0x0A { throw old == 0 ? UploadError.noFreeSlot : UploadError.staleSlot(old) }
                throw UploadError.rejected("finish \(p.hexString)")
            }
            guard p.count >= 9 else { throw UploadError.rejected("short chunk request \(p.hexString)") }
            let off = Int(UInt32(p.be16(at: 0)) << 16 | UInt32(p.be16(at: 2)))
            let len = Int(UInt32(p.be16(at: 4)) << 16 | UInt32(p.be16(at: 6)))
            guard off + len <= bin.count else { throw UploadError.rejected("chunk out of bounds \(off)+\(len)") }
            progress(Int(p[p.startIndex + 8]))
            try await send(StockCmd.wfChunkWrite, bin[bin.startIndex + off..<bin.startIndex + off + len])
        }
    }
}

/// `uploadWatchface`'s slot policy. `installed`: what the watch reported plus what this app put there; `slot`: the
/// dial the user picked to replace. Returns the new dial id.
public func installFace(_ s: StockSession, _ bin: Data, seed: String?, installed: [UInt32], capacity: Int,
                        slot: UInt32? = nil, progress: @Sendable (Int) -> Void) async throws -> UInt32 {
    guard let name = faceName(bin), bin.count <= 32 << 20 else { throw UploadError.rejected("not a watchface") }
    let id = dialId(seed ?? name)
    let old = slot ?? (installed.contains(id) ? id : 0)
    if old == 0, installed.count >= capacity { throw UploadError.noFreeSlot }
    do {
        try await s.upload(bin, old: old, new: id, progress: progress)
    } catch UploadError.staleSlot(old) {
        // a dial a055 listed is no guess: the watch has it and won't take it as a target; the user picks another
        if (await s.reported ?? []).contains(old) { throw UploadError.staleSlot(old) }
        // a guessed target the watch doesn't have (deleted on the watch, a reset): append instead
        if installed.filter({ $0 != old }).count >= capacity { throw UploadError.noFreeSlot }
        do {
            try await s.upload(bin, old: 0, new: id, progress: progress)
        } catch UploadError.noFreeSlot where slot != nil {
            // 0A again on the append after the user's pick isn't about slots: no second slot dialog
            throw UploadError.rejected("stored but not activated")
        }
    }
    return id
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
