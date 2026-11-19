import Foundation
@testable import HubKit

/// Every check against the Python hosts' bytes (vectors.json, Tests/make_vectors.py). Run by HubKitTests on CI
/// and by Tests/run.sh with swiftc where SwiftPM is not there.
enum Checks {
    struct V: Decodable {
        struct Px: Decodable { let w: Int, h: Int, px: [UInt8], out: String }
        struct Idx: Decodable { let z: Int, x0: Int, y0: Int, w: Int, h: Int, mm: Int, lat: Double, lon: Double, out: String }
        let tokens: Px, long: Px, rgb565: [[Int]], header: String, now: String, list: [String], palette: [UInt16]
        let idx: Idx, world: [Double]
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// → failures, empty when all pass.
    static func run(_ json: Data) throws -> [String] {
        let v = try JSONDecoder().decode(V.self, from: json)
        var bad: [String] = []
        func eq(_ name: String, _ a: String, _ b: String) { if a != b { bad.append("\(name):\n  swift  \(a)\n  python \(b)") } }
        eq("tokens", hex(Rle.tokens(v.tokens.px, width: v.tokens.w, height: v.tokens.h)), v.tokens.out)
        eq("long run", hex(Rle.tokens(v.long.px, width: v.long.w, height: v.long.h)), v.long.out)
        for c in v.rgb565 {
            eq("rgb565", "\(Rle.rgb565(UInt8(c[0]), UInt8(c[1]), UInt8(c[2])))", "\(c[3])")
        }
        eq("header", hex(Rle.header(width: 152, height: 152, palette: (0..<16).map { UInt16($0) * 0x1111 })), v.header)
        eq("now", hex(SpotifyProto.now(flags: 3, pos: 83, dur: 215, vol: 60, title: "Midnight City é", artist: "M83",
                                       device: "iPhone")), v.now)
        let rows = SpotifyProto.list(kind: "P", rows: [("Chill", "42 songs", true), ("Gym", "2 songs", false)])
        eq("list", rows.map(hex).joined(separator: ","), v.list.joined(separator: ","))
        eq("palette", "\(MapPack.palette565)", "\(v.palette)")
        let i = v.idx
        let lvl = MapPack.Level(z: i.z, x0: i.x0, y0: i.y0, w: i.w, h: i.h, mmPerPx: i.mm)
        eq("idx", hex(MapPack.index([lvl], lat: i.lat, lon: i.lon)), i.out)
        let w = MapPack.world(lat: v.world[0], lon: v.world[1], z: Int(v.world[2]))
        if abs(w.x - v.world[3]) > 1e-6 || abs(w.y - v.world[4]) > 1e-6 { bad.append("world: \(w) vs \(v.world[3...])") }
        // round trips the reference cannot give
        let msgs = Rle.messages(header: Data("I".utf8), tokens: Data(repeating: 7, count: 300))
        if msgs.count != 5 || msgs[1].count != 128 || msgs[3].count != 300 - 252 + 2 || msgs[4] != Data("E".utf8) {
            bad.append("messages split: \(msgs.map(\.count))")
        }
        let file = MapPack.fileMessages(name: "t0_1_2", data: Data(repeating: 1, count: 300))
        if file.first != Data("Ft0_1_2".utf8) || file.last != Data("c".utf8) || file.dropFirst().dropLast().map(\.count) != [128, 128, 47] {
            bad.append("file messages: \(file.map(\.count))")
        }
        var g = GeminiProto.Streamer()
        let out = g.feed("**Hello** there ") + g.feed("world 🌍.")
        let text = out.filter { $0.first == UInt8(ascii: "T") }.map { String(decoding: $0.dropFirst(), as: UTF8.self) }.joined()
        if out.first != Data([UInt8(ascii: "A"), 0, 0]) || text != "Hello there world ." { bad.append("gemini: \(text)") }
        if SpotifyProto.parse(Data([UInt8(ascii: "p"), UInt8(ascii: "T"), 3])) != .pick("T", 3) { bad.append("parse pick") }
        if SpotifyProto.parse(Data("smidnight".utf8)) != .search("midnight") { bad.append("parse search") }
        let simple = NavProto.simplify((0..<1000).map { (Double($0), sin(Double($0) / 50) * 30) }, max: 120)
        if simple.count > 120 || simple.first! != (0, 0) || simple.last!.0 != 999 { bad.append("simplify \(simple.count)") }
        let (pal, idx) = Quantize.medianCut(rgb: [255, 0, 0, 250, 0, 0, 0, 0, 255, 0, 0, 250], colours: 2)
        if pal.count != 2 || idx[0] != idx[1] || idx[2] != idx[3] || idx[0] == idx[2] { bad.append("median cut \(idx)") }
        let tile = MapPack.tileFile([UInt8](repeating: 4, count: 256 * 256))
        if tile.first != 1 || tile.count != 1 + 2 * 256 { bad.append("tile file \(tile.count)") }
        return bad
    }
}
