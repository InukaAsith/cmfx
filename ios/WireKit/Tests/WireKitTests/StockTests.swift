import Foundation
import Testing
@testable import WireKit

/// Made by tools/watchface-vectors.ts from fmc_frontend's own Codec, pair math, dialId and flash gate.
struct FaceVectors: Decodable {
    struct Enc: Decodable { let c1: UInt32; let c2: UInt32; let payload: String; let frames: [String] }
    struct Pair: Decodable {
        let secret, random1, random2, request, reply, k1, nonce, session: String
    }
    struct FaceV: Decodable { let name, hex: String; let refuse: String?; let confirm: String? }
    let mtu: Int
    let key: String
    let encode: [Enc]
    let pair: Pair
    let dial_id: [String: UInt32]
    let faces: [FaceV]

    static let shared: FaceVectors = {
        let url = Bundle.module.url(forResource: "watchface-vectors", withExtension: "json")!
        return try! JSONDecoder().decode(FaceVectors.self, from: Data(contentsOf: url))
    }()
}

let fv = FaceVectors.shared

@Test func framesMatchSite() throws {
    for e in fv.encode {
        let cmd = e.c1 << 16 | e.c2
        let frames = stockFrames(cmd, hex(e.payload), key: hex(fv.key), mtu: fv.mtu)
        #expect(frames == e.frames.map(hex), "\(String(cmd, radix: 16))")
        var p = StockParser()
        let out = try frames.compactMap { try p.feed($0, key: hex(fv.key)) }
        if !StockCmd.plain.contains(cmd) { #expect(out.map(\.payload) == [hex(e.payload)]) }
    }
}

@Test func pairMathMatchesSite() {
    let p = fv.pair, secret = hex(p.secret)
    #expect(pairRequest(random1: hex(p.random1), secret: secret) == hex(p.request))
    #expect(pairKey(random1: hex(p.random1), reply: hex(p.reply), secret: secret) == hex(p.k1))
    var forged = hex(p.reply)
    forged[20] ^= 1
    #expect(pairKey(random1: hex(p.random1), reply: forged, secret: secret) == nil, "a reply without the secret")
    #expect(sessionKey(nonce: hex(p.nonce), k1: hex(p.k1)) == hex(p.session))
}

@Test func dialIdMatchesSite() {
    for (seed, id) in fv.dial_id { #expect(dialId(seed) == id, "\(seed)") }
}

@Test func faceGateMatchesSite() {
    let want: [String: FaceVerdict] = [
        "ok": .ok, "main_no_preview": .ok, "aod_no_preview": .refuse(.aodWithoutPreview),
        "too_big": .refuse(.imageTooBig(w: 1386, h: 1386)), "needs_confirm": .confirm(w: 576, h: 530),
    ]
    for f in fv.faces {
        let v = checkFace(hex(f.hex))
        #expect(v == want[f.name], "\(f.name)")
        // the site's own outcome, so a changed gate there fails here
        switch v {
        case .refuse: #expect(f.refuse != nil)
        case .confirm: #expect(f.refuse == nil && f.confirm != nil)
        case .ok: #expect(f.refuse == nil && f.confirm == nil)
        }
    }
    #expect(checkFace(Data(count: 100)) == .refuse(.notAWatchface))
}

/// The watch's side of the stock session and the watchface upload, scripted.
final class StockWatch: Link, @unchecked Sendable {
    let secret = hex(fv.pair.secret)
    var k1: Data?, key: Data?
    var handler: (@Sendable (String, Data) -> Void)?
    var parser = StockParser()
    var init2: Data?, received = Data(), init2Answer: UInt8 = 1, finish: [UInt8] = [1]
    var chunk = 300, finishes = 0
    /// The bind popup: open after the first 0x8049 that follows 0x8047. `confirmPopup` taps it once.
    var popup = 0, confirmPopup = false, binds = 0
    /// Nothing X's frames under the old session key, answered with authFailed in the middle of an upload.
    var nothingX = false

    func onNotify(_ handler: @escaping @Sendable (String, Data) -> Void) { self.handler = handler }

    func reply(_ cmd: UInt32, _ p: Data, key: Data? = nil) {
        // the watch answers on the pair the request came in on
        let uuid = [StockCmd.wfInit1Rep, StockCmd.wfInit2Rep, StockCmd.wfChunkReq, StockCmd.wfFinishAck1]
            .contains(cmd) ? DataUuid.notify : Uuid.cmdNotify
        for f in stockFrames(cmd, p, key: key ?? self.key) { handler?(uuid, f) }
    }

    func askNext() {
        let size = Int(init2!.le(UInt32.self, at: 9))
        guard received.count < size else {
            finishes += 1
            reply(StockCmd.wfFinishAck1, Data([finish.count >= finishes ? finish[finishes - 1] : finish.last!]))
            return
        }
        var r = Data()
        r.be(UInt32(received.count))
        r.be(UInt32(min(chunk, size - received.count)))
        r.append(UInt8(received.count * 100 / size))
        reply(StockCmd.wfChunkReq, r)
    }

    func write(_ uuid: String, _ f: Data) async throws {
        let cmd = UInt32(f.be16(at: 3)) << 16 | UInt32(f.be16(at: 9))
        #expect(uuid == (StockCmd.data.contains(cmd) ? DataUuid.write : Uuid.cmdWrite), "\(String(cmd, radix: 16))")
        if cmd == StockCmd.wfChunkWrite {
            received += f.dropFirst(11).dropLast(4)
            if nothingX { reply(StockCmd.authFailed, Data([1])) }
            if f.be16(at: 5) == f.be16(at: 7) { askNext() }
            return
        }
        // 0x8049 and 0x804B (and their replies) go under the authkey, the rest under the session key
        let auth = [StockCmd.authName, StockCmd.authNonceReq].contains(cmd)
        guard let (c, p) = try parser.feed(f, key: auth ? k1 : key) else { return }
        switch c {
        case StockCmd.authPairReq:
            let random2 = Data(repeating: 7, count: 16)
            k1 = Data(sha256(Data(p.prefix(16)), random2, secret).prefix(16))
            reply(StockCmd.authPairRep, random2 + sha256(random2, secret))
            key = k1
            popup = 1
            binds += 1
        case StockCmd.authName:
            if popup == 1 { popup = 2; return } // opens the popup, no answer
            if popup == 2, confirmPopup {
                confirmPopup = false
                popup = 0
                k1 = Data(count: 16)
                reply(StockCmd.authMac, Data([1]), key: k1)
                return
            }
            reply(StockCmd.authMac, Data([1]), key: k1)
        case StockCmd.authNonceReq:
            let nonce = Data(repeating: 9, count: 16)
            reply(StockCmd.authNonceRep, nonce, key: k1)
            key = sessionKey(nonce: nonce, k1: k1!)
        case StockCmd.authConfirmReq:
            popup = 0
            reply(StockCmd.authConfirmRep, Data([1]))
        case StockCmd.wfInit1Req: reply(StockCmd.wfInit1Rep, Data([1]))
        case StockCmd.wfInit2Req:
            init2 = p
            received = Data()
            reply(StockCmd.wfInit2Rep, Data([init2Answer]))
            if init2Answer == 1 { askNext() }
        default: break
        }
    }
}

/// A face that passes the gate, `n` bytes long.
func testFace(_ n: Int = 1000) -> Data {
    var d = hex(fv.faces.first { $0.name == "ok" }!.hex)
    let body = Data((0..<(n - d.count)).map { UInt8($0 & 0xFF) })
    // stretch the last image's data, keeping the header ‖ … ‖ header shape
    d.insert(contentsOf: body, at: d.count - 36)
    return d
}

@Test func pairsAndUploads() async throws {
    let w = StockWatch()
    let s = StockSession(link: w)
    let k1 = try await s.pair(secret: w.secret)
    #expect(k1 == w.k1)
    let bin = testFace()
    nonisolated(unsafe) var seen: [Int] = []
    let id = try await installFace(s, bin, seed: "rec1", installed: [273, 274], capacity: 6) { seen.append($0) }
    #expect(id == dialId("rec1"))
    #expect(w.init2 == uploadInit(old: 0, new: id, size: bin.count))
    #expect(w.received == bin)
    #expect(seen.last == 100)
}

@Test func reinstallReplacesItself() async throws {
    let w = StockWatch()
    let s = StockSession(link: w)
    _ = try await s.pair(secret: w.secret)
    let id = dialId("rec1")
    _ = try await installFace(s, testFace(), seed: "rec1", installed: [1, 2, 3, 4, 5, id], capacity: 6) { _ in }
    #expect(w.init2 == uploadInit(old: id, new: id, size: testFace().count))
}

@Test func fullWatchAsksBeforeSending() async throws {
    let w = StockWatch()
    let s = StockSession(link: w)
    _ = try await s.pair(secret: w.secret)
    await #expect(throws: UploadError.noFreeSlot) {
        try await installFace(s, testFace(), seed: "new", installed: [1, 2, 3, 4, 5, 6], capacity: 6) { _ in }
    }
    #expect(w.init2 == nil, "nothing shipped to be told no")
}

@Test func appendRefusedAtFinishAsksForSlot() async throws {
    let w = StockWatch()
    w.finish = [0x0A]
    let s = StockSession(link: w)
    _ = try await s.pair(secret: w.secret)
    await #expect(throws: UploadError.noFreeSlot) {
        try await installFace(s, testFace(), seed: "new", installed: [], capacity: 6) { _ in }
    }
}

@Test func staleGuessRetriesAsAppend() async throws {
    let w = StockWatch()
    w.finish = [0x0A, 1]
    let s = StockSession(link: w)
    _ = try await s.pair(secret: w.secret)
    let id = dialId("rec1")
    _ = try await installFace(s, testFace(), seed: "rec1", installed: [id], capacity: 6) { _ in }
    #expect(w.init2 == uploadInit(old: 0, new: id, size: testFace().count))
    #expect(w.finishes == 2)
}

@Test func installedDials() {
    var p = Data([1, 5, 6, 7])
    for id: UInt32 in [273, 0xFFFF_FFFF, 12345] { p.le(id) }
    #expect(parseInstalledDials(p) == [273, 12345])
    #expect(parseDialCount(p)! == (6, 7))
    #expect(parseDialCount(Data([1, 0, 9, 7])) == nil)
    #expect(parseDialCount(Data([1, 0])) == nil)
}

@Test func confirmedPopupBindsAgain() async throws {
    let w = StockWatch()
    w.confirmPopup = true
    let s = StockSession(link: w)
    let k1 = try await s.pair(secret: w.secret)
    #expect(w.binds == 2)
    #expect(k1 == w.k1 && k1 != Data(count: 16))
}

@Test func storedKeyAuthenticatesWithoutPopup() async throws {
    let w = StockWatch()
    let k1 = try await StockSession(link: w).pair(secret: w.secret)
    let s = StockSession(link: w)
    try await s.authenticate(k1: k1)
    #expect(w.binds == 1)
    _ = try await installFace(s, testFace(), seed: "rec1", installed: [], capacity: 6) { _ in }
}

@Test func nothingXAuthFailedDoesNotStopUpload() async throws {
    let w = StockWatch()
    let s = StockSession(link: w)
    _ = try await s.pair(secret: w.secret)
    w.nothingX = true
    let bin = testFace(2000)
    _ = try await installFace(s, bin, seed: "rec1", installed: [], capacity: 6) { _ in }
    #expect(w.received == bin)
}
