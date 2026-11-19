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
        chats(&bad)
        return bad
    }

    /// The chats app's Mail and Notes modes (hosts/inboxhost.py builds the same bytes).
    static func chats(_ bad: inout [String]) {
        func eq(_ name: String, _ a: String, _ b: String) { if a != b { bad.append("\(name):\n  got  \(a)\n  want \(b)") } }
        let rows = ChatsProto.list([.init(id: 1, name: "+ New note", preview: "Write one on the watch"),
                                    .init(id: 7, unread: true, name: "Priya Perera", preview: "Lunch on Friday?")])
        eq("chats list", rows.map(hex).joined(separator: ","),
           "4c02," + hex(Data([0x43, 0, 1, 0, 10]) + Data("+ New note".utf8) + Data([22]) + Data("Write one on the watch".utf8))
           + "," + hex(Data([0x43, 1, 7, 1, 12]) + Data("Priya Perera".utf8) + Data([16]) + Data("Lunch on Friday?".utf8)))
        let long = ChatsProto.list([.init(id: 2, name: String(repeating: "é", count: 20), preview: String(repeating: "a", count: 60))])
        if long[1].count != 6 + 24 + 40 || long[1][4] != 24 || long[1][29] != 40 { bad.append("chats row cut \(long[1].count)") }
        if ChatsProto.list((0..<20).map { .init(id: UInt8($0), name: "n", preview: "") }).count != 13 { bad.append("chats max rows") }
        eq("chats open", hex(ChatsProto.open(9, title: "Groceries")), "4809" + hex(Data("Groceries".utf8)))
        eq("chats message", hex(ChatsProto.message(2, kind: ChatsProto.todo, "Milk")), "4d020003" + hex(Data("Milk".utf8)))
        eq("chats append", hex(ChatsProto.append(me: true, "On it")), "410100" + hex(Data("On it".utf8)))
        if ChatsProto.message(0, String(repeating: "€", count: 50)).count != 4 + 120 { bad.append("chats message cut") }
        let q = ChatsProto.quick(["• Archive", "a", "b", "c", "d", "e", "f"])
        if q.count != 6 || q[0] != Data([0x51, 0]) + Data("• Archive".utf8) { bad.append("chats quick") }
        let words = (0..<60).map { "w\($0)" }.joined(separator: " ")
        let ch = ChatsProto.chunks(words)
        if ch.contains(where: { $0.utf8.count > 120 }) || ch.joined(separator: " ") != words { bad.append("chunks \(ch)") }
        let big = ChatsProto.chunks("x " + String(repeating: "é", count: 100))
        if big.map(\.utf8.count) != [1, 120, 80] { bad.append("chunks long word \(big.map(\.utf8.count))") }
        let a1 = String(repeating: "word ", count: 14) + "end.", b1 = "Short one!", c1 = String(repeating: "long ", count: 30) + "tail"
        let pg = ChatsProto.page([a1, b1, c1].joined(separator: " "))
        if pg.count < 3 || pg[0] != a1 + " " + b1 || !pg[1].hasPrefix("long") || pg.contains(where: { $0.utf8.count > 120 }) {
            bad.append("page \(pg)")
        }
        if ChatsProto.parse(Data("R".utf8)) != .ready || ChatsProto.parse(Data([0x6f, 7])) != .open(7)
            || ChatsProto.parse(Data([0x74, 3])) != .tap(3) || ChatsProto.parse(Data([0x73, 7]) + Data("Thanks! ".utf8)) != .send(7, "Thanks!")
            || ChatsProto.parse(Data([0x73, 7])) != nil {
            bad.append("chats parse")
        }
        if ChatsProto.action("• Clear done") != "Clear done" || ChatsProto.action("Buy") != nil { bad.append("chats action") }
        var ids = ChatsProto.Ids(first: 2)
        let a = ids.id("thread-a"), b = ids.id("thread-b")
        if a != 2 || b != 3 || ids.id("thread-a") != 2 || ids.key(3) != "thread-b" { bad.append("ids") }
        for k in 0..<300 { _ = ids.id("k\(k)") }
        if ids.id("again") < 2 { bad.append("ids wrap") }
        // mail text
        eq("strip html", MailText.body(MailText.strip(html: "<style>p{}</style><p>Hi&nbsp;there &amp; <b>you</b></p><br>Bye&#33;")),
           "Hi there & you Bye!")
        eq("quote", MailText.body("Sounds good.\n\nOn Mon, 3 Nov 2026 at 10:00, Sam <sam@example.com>\nwrote:\n> earlier\n> text"),
           "Sounds good.")
        eq("quoted lines", MailText.body("Yes\n> no\n  more"), "Yes more")
        eq("name", MailText.name("\"Priya Perera\" <priya@example.com>"), "Priya Perera")
        eq("bare name", MailText.name("noreply@example.com"), "noreply")
        eq("address", MailText.address("Sam <sam@example.com>"), "sam@example.com")
        let raw = String(decoding: MailText.reply(to: "Zoë <z@example.com>", subject: "Lunch", messageID: "<a@mail>",
                                                  references: "<r@mail>", text: "On it"), as: UTF8.self)
        for want in ["To: =?UTF-8?B?Wm/Dqw==?= <z@example.com>\r\n", "Subject: Re: Lunch\r\n", "In-Reply-To: <a@mail>\r\n",
                     "References: <r@mail> <a@mail>\r\n", "\r\n\r\nT24gaXQ=\r\n"] where !raw.contains(want) {
            bad.append("reply lacks \(want.debugDescription)")
        }
        if MailText.reply(to: "a@b.c", subject: "Re: x", messageID: "", references: "", text: "").count == 0
            || !String(decoding: MailText.reply(to: "a@b.c", subject: "Re: x", messageID: "", references: "", text: ""), as: UTF8.self)
                .hasPrefix("To: a@b.c\r\nSubject: Re: x\r\n") {
            bad.append("reply bare")
        }
    }
}
