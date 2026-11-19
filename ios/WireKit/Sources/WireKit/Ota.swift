import Foundation

// The full firmware update over the stock session: port of fmc_frontend device/lib ota-image.ts (inspectOtaImage,
// checkOtaTarget) and ble.ts flashFirmware; cmf-watch-sdk docs/ota.md. ota-vectors.json holds the site's verdicts
// and the bytes its flashFirmware writes.
//
//   fff2  0x9052 A5              → A052 01   "may I update"
//   ff01  0x9040 01 00 00 5a     → A040 01   start
//   ff02  A042 off len pct       ← the watch pulls ranges, in any order, only what differs
//   ff01  0x9042 bytes           → plaintext, 224 bytes a frame, no ack: the next A042 is one
//   fff2  0x9041 A5              ← on A041 (01 = image valid) or a zero range: commit; the watch installs and reboots
//
// The characteristic is part of the protocol: 0x9040 on fff2 with a live session reboots the watch. Nothing is
// written to flash before A040, so a refusal up to there leaves the watch as it was.

public enum OtaError: LocalizedError, Equatable {
    /// The image fails a check (ota-image.ts): nothing was sent.
    case notFlashable(String)
    case refused(String)
    case rejected(String)
    case stopped(String)
    case stalled

    public var errorDescription: String? {
        switch self {
        case .notFlashable(let why): "Not a flashable image: \(why)."
        case .refused(let m), .rejected(let m), .stopped(let m): m
        case .stalled: "The watch stopped asking for data."
        }
    }
}

/// The board the Watch Pro 2's images are built for, the one watch this update has ever run against.
public let otaBoard = "jx402_01_3089c"
/// Boards of the known watches: an image for another board is refused as "no known watch has" (ota-image.ts BOARDS).
let knownBoards: Set<String> = [otaBoard, "jx402_08"]

public struct OtaImage: Equatable, Sendable {
    public let board: String
    /// The header's build string, e.g. "1.00_2509131556".
    public let version: String
    /// `version_code` from ota.xml.
    public let versionCode: Int?
}

/// `inspectOtaImage`: throws `notFlashable` with the site's reason when the watch shouldn't be offered `d`. The
/// watch has no signature check, only these CRCs.
public func inspectOtaImage(_ d: Data) throws -> OtaImage {
    func need(_ ok: @autoclosure () -> Bool, _ why: String) throws { if !ok() { throw OtaError.notFlashable(why) } }
    func ascii(_ off: Int, _ len: Int) -> String {
        let s = d[d.startIndex + off..<d.startIndex + min(off + len, d.count)]
        return String(decoding: s.prefix { $0 != 0 }, as: UTF8.self)
    }
    func sub(_ a: Int, _ b: Int) -> Data { d[d.startIndex + a..<d.startIndex + b] }
    let hdr = 0x400, table = 0x200
    try need(d.count >= hdr, "too small")
    try need(ascii(0, 4) == "AOTA", "no AOTA magic")
    try need(crc32(sub(8, hdr)) == d.le(UInt32.self, at: 4), "header checksum")
    let count = Int(d.le(UInt32.self, at: 0x0C))
    try need(count >= 1 && count <= (hdr - table) / 32, "entry count \(count)")
    let start = Int(d.le(UInt16.self, at: 0x12)), end = Int(d.le(UInt32.self, at: 0x14))
    try need(start >= hdr && start <= end && end <= d.count, "data bounds")
    try need(crc32(sub(start, end)) == d.le(UInt32.self, at: 0x18), "data checksum")
    let board = ascii(0x60, 28)
    try need(knownBoards.contains(board), "built for board \"\(board)\", which no known watch has")

    let entries = (0..<count).map { i in
        let o = table + i * 32
        return (name: ascii(o, 16), off: Int(d.le(UInt32.self, at: o + 16)), size: Int(d.le(UInt32.self, at: o + 20)),
                flags: d.le(UInt32.self, at: o + 24), crc: d.le(UInt32.self, at: o + 28))
    }
    var seen = Set<String>(), prev = start
    for e in entries.sorted(by: { $0.off < $1.off }) {
        try need(!e.name.isEmpty && !seen.contains(e.name) && e.flags == 0 && e.size > 0 && e.off >= prev
                 && e.off + e.size <= end, "entry \"\(e.name)\" out of place")
        try need(crc32(sub(e.off, e.off + e.size)) == e.crc, "checksum of \(e.name)")
        seen.insert(e.name)
        prev = e.off + e.size
    }
    guard let x = entries.first(where: { $0.name == "ota.xml" }), x.size <= 65536 else {
        throw OtaError.notFlashable("no ota.xml")
    }
    let xml = String(decoding: sub(x.off, x.off + x.size), as: UTF8.self)
    // ponytail: a manifest this regular is read by tag name, as the site does; a disagreeing table is refused below
    // JS Number(): the real manifests write sizes in hex
    func number(_ s: String) -> Int? { s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s) }
    func tag(_ name: String, in from: String? = nil) -> String? {
        let s = from ?? xml
        guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex)
        else { return nil }
        let v = s[a.upperBound..<b.lowerBound]
        return v.contains("<") ? nil : v.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try need(tag("board_name") == board, "ota.xml names another board")
    let declared = xml.components(separatedBy: "<partition>").dropFirst().map { p in
        (name: tag("file_name", in: p) ?? "", size: tag("file_size", in: p).flatMap(number))
    }
    let parts = entries.filter { $0.name != "ota.xml" }
    try need(declared.count == parts.count
             && parts.allSatisfy { p in declared.contains { $0.name == p.name && $0.size == p.size } },
             "ota.xml doesn't match the file table")
    try need(seen.contains("TEMP.bin"), "no TEMP.bin — nothing for the watch to install")
    // the stock receiver asks for the AGPS record too: an image without it stalls a real watch mid-transfer
    let trailer = d.count - end
    try need(trailer > 24 && ascii(end, 4) == "AGPS" && d.le(UInt64.self, at: end + 8) == UInt64(trailer - 24),
             "no AGPS trailer (an emulator-only image?)")
    let code = tag("version_code").flatMap(number)
    return OtaImage(board: board, version: ascii(0x40, 32), versionCode: code)
}

/// `checkOtaTarget` for the one record the app offers (the Watch Pro 2's patched firmware): an image `inspectOtaImage`
/// passed is built for the Watch Pro 2, and the watch on the line advertises itself as one.
public func checkOtaTarget(_ info: OtaImage, watchName: String?) throws {
    guard info.board == otaBoard else {
        throw OtaError.notFlashable("built for board \"\(info.board)\", not the CMF Watch Pro 2's")
    }
    guard watchName?.range(of: "watch pro 2", options: .caseInsensitive) != nil else {
        throw OtaError.refused("Firmware updates are for the CMF Watch Pro 2 only, this is “\(watchName ?? "an unnamed watch")”.")
    }
}

extension StockSession {
    /// The bytes per 0x9042 frame every hardware flash so far used; not derived from the MTU.
    static let otaChunk = 224

    private func sendOta(_ cmd: UInt32, _ payload: Data) async throws {
        for f in stockFrames(cmd, payload, key: key, mtu: mtu, plainSize: Self.otaChunk) {
            try await link.write(OtaUuid.write, f)
        }
    }

    /// `flashFirmware`: `image` must have passed `checkOtaTarget`. `progress`: the watch's own percent (it skips
    /// what it already has, so bytes sent say little), 100 once it has the image and was told to install it.
    public func flashFirmware(_ image: Data, progress: @Sendable (Int) -> Void) async throws {
        await inbox.drain()
        try await send(StockCmd.otaBeginReq, Data([marker]))
        let (_, r1) = try await next([StockCmd.otaBeginRep], timeout: .seconds(6))
        // the watch's 0x9052 handler (cmf-watch-utils decomp FUN_100d343c): 0c battery under 20 %, 0a busy
        guard r1.first == 1 else {
            throw OtaError.refused(r1.first == 0x0C ? "The watch battery is below 20 %. Charge it and try again."
                                   : "The watch refused the update (\(r1.hexString)).")
        }
        try await sendOta(StockCmd.otaStartReq, Data([0x01, 0x00, 0x00, 0x5A]))
        let (_, r2) = try await next([StockCmd.otaStartRep], timeout: .seconds(5))
        guard r2.first == 1 else { throw OtaError.refused("The watch refused to start (\(r2.hexString)).") }
        var served = 0
        while true {
            let (cmd, p): (UInt32, Data)
            do {
                // the watch writes NAND between ranges; two minutes of silence is the reference client's "gone"
                (cmd, p) = try await next([StockCmd.otaChunkReq, StockCmd.otaVerdict, StockCmd.otaStatus43,
                                           StockCmd.otaStatus44], timeout: .seconds(120))
            } catch WireError.timeout { throw OtaError.stalled }
            switch cmd {
            case StockCmd.otaVerdict:
                // without the commit the update stays staged and is never installed
                try? await send(StockCmd.otaCommit, Data([marker]))
                guard p.first == 1 else { throw OtaError.rejected("The watch rejected the image (\(p.hexString)).") }
                progress(100)
                return
            case StockCmd.otaChunkReq:
                guard p.count >= 8 else { continue }
                let off = Int(UInt32(p.be16(at: 0)) << 16 | UInt32(p.be16(at: 2)))
                let len = Int(UInt32(p.be16(at: 4)) << 16 | UInt32(p.be16(at: 6)))
                // a zero range is the other way the watch says "that's all"
                if off == 0, len == 0 {
                    try? await send(StockCmd.otaCommit, Data([marker]))
                    progress(100)
                    return
                }
                guard off < image.count else { continue }
                let end = min(off + len, image.count)
                try await sendOta(StockCmd.otaChunkWrite, image[image.startIndex + off..<image.startIndex + end])
                served += end - off
                progress(min(p.count > 8 ? Int(p[p.startIndex + 8]) : served * 100 / image.count, 99))
            default:
                throw OtaError.stopped("The watch stopped the update (\(String(format: "%04X", cmd & 0xFFFF)) \(p.hexString)).")
            }
        }
    }
}
