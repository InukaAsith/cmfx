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
        struct Sp: Decodable { let `in`: [Int], tuned: [Int], blocks: [String] }
        let speaker: Sp
        let speaker_x: Sp
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// → failures, empty when all pass.
    static func run(_ json: Data) throws -> [String] {
        let v = try JSONDecoder().decode(V.self, from: json)
        var bad: [String] = []
        func eq(_ name: String, _ a: String, _ b: String) { if a != b { bad.append("\(name):\n  swift  \(a)\n  python \(b)") } }
        // YouTube Music's credit with held, and the song heard (not the last one sent) is the current one
        if YTMusicProto.parse(Data([0x46, 0x2C, 0x01, 9, 3, 0x40, 0x01])) != .credit(next: 300, room: 9, gen: 3, held: 320) {
            bad.append("ytmusic credit with held")
        }
        var st = YTStream(gen: 3)
        let one = YTSong(id: "a", title: "A", artist: "x", seconds: 3)
        st.add(one, index: 0, from: 0, samples: [Int16](repeating: 0, count: 244 * 200))
        st.add(one, index: 1, from: 0, samples: [Int16](repeating: 0, count: 244 * 200))
        st.setCredit(next: 300, room: 20, held: 250)
        if st.playing(-1) != 0 { bad.append("ytmusic: song 1 is sent, song 0 still heard") }
        st.setCredit(next: 300, room: 20, held: 50)
        if st.playing(-1) != 1 { bad.append("ytmusic: song 1 heard") }
        let four = st.take(4)
        let before = st.sent
        st.requeue([four[1]])  // refused: again first, nothing else lost or overwritten
        let again = st.take(2)
        if st.sent != before + 1 || again.first != four[1] || st.out[before - 4..<before] != four[...] {
            bad.append("ytmusic requeue")
        }
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
        mime(&bad)
        imap(&bad)
        // the speaker stream: the tuning within 1 LSB (libm), the ADPCM messages byte for byte
        let sp = v.speaker
        let tuned = SpeakerTune.forSpeaker(sp.in.map { Int16($0) }, rate: SpeakerProto.rate)
        let off = zip(tuned, sp.tuned).map { abs(Int($0) - $1) }.max() ?? 99
        if tuned.count != sp.tuned.count || off > 1 { bad.append("speaker tune: \(tuned.count) vs \(sp.tuned.count), off by \(off)") }
        eq("speaker blocks", SpeakerProto.blocks(sp.tuned.map { Int16($0) }).map(hex).joined(separator: ","),
           sp.blocks.joined(separator: ","))
        // the options: levelling and the trellis encoder on, volume smoothing off
        let sx = v.speaker_x
        let tx = SpeakerTune.forSpeaker(sx.in.map { Int16($0) }, rate: SpeakerProto.rate, level: true, smooth: false)
        let offx = zip(tx, sx.tuned).map { abs(Int($0) - $1) }.max() ?? 99
        if tx.count != sx.tuned.count || offx > 1 { bad.append("speaker tune (options): off by \(offx)") }
        eq("speaker blocks (trellis)", SpeakerProto.blocks(sx.tuned.map { Int16($0) }, paths: SpeakerProto.paths).map(hex)
            .joined(separator: ","), sx.blocks.joined(separator: ","))
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
        // wahost.py: `C idx id unread nlen name plen preview`, unread a count
        eq("chats unread count", hex(ChatsProto.list([.init(id: 4, unreadCount: 3, name: "Mum", preview: "Hi")])[1]),
           "4300040303" + hex(Data("Mum".utf8)) + "02" + hex(Data("Hi".utf8)))
        eq("chats open", hex(ChatsProto.open(9, title: "Groceries")), "4809" + hex(Data("Groceries".utf8)))
        eq("chats message", hex(ChatsProto.message(2, kind: ChatsProto.todo, "Milk")), "4d020003" + hex(Data("Milk".utf8)))
        eq("chats append", hex(ChatsProto.append(me: true, "On it")), "410100" + hex(Data("On it".utf8)))
        if ChatsProto.message(0, String(repeating: "€", count: 50)).count != 4 + 120 { bad.append("chats message cut") }
        eq("chats read", hex(ChatsProto.message(1, me: true, state: 2, "ok")), "4d010500" + hex(Data("ok".utf8)))
        eq("chats delivered", hex(ChatsProto.append(me: true, state: 1, "x")), "410300" + hex(Data("x".utf8)))
        eq("chats state", hex(ChatsProto.state(3, 2)), "530302")
        eq("emoji", Emoji.text("Hi 😂👍🏽 ❤️ 🦖 🇱🇰 é 1#"), "Hi XD(y) <3 * (flag) é 1#")
        eq("emoji message", hex(ChatsProto.message(0, "ok 👍")), "4d000000" + hex(Data("ok (y)".utf8)))
        eq("chats online", hex(ChatsProto.online(true)), "5001")
        var st = ChatsProto.Row(id: 1, name: "Syncing...", preview: "")
        st.status = true
        eq("chats status row", String(hex(ChatsProto.list([st])[1]).prefix(8)), "430001ff")
        let pic = ChatsProto.picture(2, rgb: [UInt8](repeating: 200, count: 8 * 8 * 3), width: 8, height: 8)
        if pic.first?.prefix(3) != Data([0x69, 2, 0x49]) || pic.last != Data([0x65, 2]) || pic.count < 3 { bad.append("chats picture") }
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

    /// MIME (Mime): sample emails as IMAP gives them.
    static func mime(_ bad: inout [String]) {
        func eq(_ name: String, _ a: String?, _ b: String) { if a != b { bad.append("\(name):\n  got  \(a ?? "nil")\n  want \(b)") } }
        func crlf(_ s: String) -> Data { Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }
        // multipart/alternative, quoted-printable plain, Q- and B-encoded headers
        let alt = crlf("""
            From: =?UTF-8?B?Wm/DqyBNw7xsbGVy?= <zoe@example.com>
            To: Sam <sam@example.org>
            Subject: =?iso-8859-1?Q?R=E9union_de?=
             =?iso-8859-1?Q?_lundi?= ok
            Message-ID: <abc@example.com>
            MIME-Version: 1.0
            Content-Type: multipart/alternative;
             boundary="b1=_x"

            This is a multi-part message.
            --b1=_x
            Content-Type: text/plain; charset="utf-8"
            Content-Transfer-Encoding: quoted-printable

            Caf=C3=A9 at 10? It's a long line that goes on and on and gets a soft =
            break.
            --b1=_x
            Content-Type: text/html; charset="utf-8"

            <p>HTML version</p>
            --b1=_x--
            """)
        let m = Mime.parse(alt)
        eq("mime from", m.header("From"), "Zoë Müller <zoe@example.com>")
        eq("mime name", MailText.name(m.header("From") ?? ""), "Zoë Müller")
        eq("mime subject", m.header("subject"), "Réunion de lundi ok")
        eq("mime message-id", m.header("message-id"), "<abc@example.com>")
        eq("mime alternative", Mime.text(m), "Café at 10? It's a long line that goes on and on and gets a soft break.")
        // HTML only, base64, Windows-1252
        let html = "<html><head><style>p{}</style></head><body><p>Price \u{2013} €5</p><p>See you&nbsp;soon</p></body></html>"
        let b64 = html.data(using: .windowsCP1252)!.base64EncodedString(options: .lineLength76Characters)
        let h = crlf("From: shop@example.com\nSubject: Order\nContent-Type: text/html; charset=windows-1252\nContent-Transfer-Encoding: base64\n\n" + b64 + "\n")
        eq("mime html only", Mime.text(h).map(MailText.body), "Price \u{2013} \u{20AC}5 See you soon")
        // nested: mixed > (alternative > plain, html) + an attachment; LF line ends, 8-bit
        let nested = Data("""
            From: "Doe, Jane" <jane@example.com>
            Subject: =?utf-8?q?Caf=C3=A9_?= =?utf-8?b?4pyT?=
            Content-Type: multipart/mixed; boundary=outer

            --outer
            Content-Type: multipart/alternative; boundary="inner"

            --inner
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: 8bit

            Hello ✓ ünïcode
            --inner
            Content-Type: text/html

            <b>no</b>
            --inner--

            --outer
            Content-Type: text/plain; name="notes.txt"
            Content-Disposition: attachment; filename="notes.txt"

            not this
            --outer--
            """.utf8)
        let n = Mime.parse(nested)
        eq("mime nested", Mime.text(n), "Hello ✓ ünïcode")
        eq("mime adjacent words", n.header("subject"), "Café ✓")
        eq("mime quoted name", MailText.name(n.header("from") ?? ""), "Doe, Jane")
        // a UTF-8 character split across two B words; Q underscores; ISO-8859-1 plain body
        eq("mime split word", Mime.words("=?UTF-8?B?w6k=?= =?UTF-8?B?w6k=?= x"), "éé x")
        eq("mime split char", Mime.words("=?UTF-8?B?4pw=?= =?UTF-8?B?kw==?="), "✓")
        eq("mime plain words", Mime.words("Re: hello =?ISO-8859-1?Q?J=F6rg?= there"), "Re: hello Jörg there")
        eq("mime bad word", Mime.words("=?bogus"), "=?bogus")
        let latin = Data("Content-Type: text/plain; charset=ISO-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nGr=FC=DFe".utf8)
        eq("mime latin1 qp", Mime.text(latin), "Grüße")
        // cut short (the first bytes fetched): base64 mid-group, no closing boundary
        let cut = crlf("Content-Type: multipart/mixed; boundary=zz\n\n--zz\nContent-Type: text/plain\nContent-Transfer-Encoding: base64\n\n"
                       + Data("Hello there, general.".utf8).base64EncodedString().dropLast(3))
        eq("mime cut", Mime.text(cut), "Hello there, gener")
        eq("mime no type", Mime.text(Data("Subject: x\n\nJust text".utf8)), "Just text")
        eq("mime rfc2231", Mime.param("attachment; filename*=UTF-8''na%C3%AFve.txt", "filename"), "naïve.txt")
        // a reply for SMTP
        let r = String(decoding: MailText.reply(to: "\"Doe, Jane\" <jane@example.com>", subject: "Café ✓", messageID: "<m@x>",
                                                references: "", text: "ok", from: "me@example.org",
                                                date: Date(timeIntervalSince1970: 0), id: "<id@example.org>"), as: UTF8.self)
        for want in ["From: me@example.org\r\n", "To: \"Doe, Jane\" <jane@example.com>\r\n", "Subject: =?UTF-8?B?",
                     "Date: Thu, 01 Jan 1970", "Message-ID: <id@example.org>\r\n", "References: <m@x>\r\n"] where !r.contains(want) {
            bad.append("smtp reply lacks \(want.debugDescription)")
        }
        if !MailText.newID("Me <me@example.org>").hasSuffix("@example.org>") { bad.append("new id") }
    }

    /// IMAP and SMTP wire pieces (Imap, Smtp).
    static func imap(_ bad: inout [String]) {
        func eq(_ name: String, _ a: String?, _ b: String) { if a != b { bad.append("\(name):\n  got  \(a ?? "nil")\n  want \(b)") } }
        var r = Imap.Reader()
        let env = "* 7 FETCH (UID 4242 FLAGS (\\Answered) ENVELOPE (\"Thu, 19 Nov 2026 10:00:00 +0000\" {26}\r\n=?UTF-8?Q?Caf=C3=A9_time?= "
            + "((\"Priya \\\"P\\\" Perera\" NIL \"priya\" \"example.com\")) NIL NIL ((NIL NIL \"me\" \"example.org\")) NIL NIL NIL \"<id1@example.com>\"))\r\n"
        let whole = Data(env.utf8) + Data("* 8 FETCH (UID 4243 FLAGS (\\Seen) BODY[]<0> {5}\r\nHi)\r\n)\r\nA4 OK Fetch completed\r\n".utf8)
        // in two pieces, cut inside the literal
        r.feed(whole.prefix(60))
        if r.next() != nil { bad.append("imap reader: a response before its literal came") }
        r.feed(whole.dropFirst(60))
        let first = r.next(), second = r.next(), third = r.next()
        if first != Data(env.utf8) { bad.append("imap reader first: \(String(decoding: first ?? Data(), as: UTF8.self))") }
        if let f = first.flatMap(Imap.fetch), let s = Imap.summary(f.items) {
            if f.seq != 7 || s.uid != 4242 || s.seen { bad.append("imap fetch \(f.seq) \(s)") }
            eq("imap envelope subject", s.subject, "Café time")
            eq("imap envelope from", s.from, "Priya P Perera <priya@example.com>")
            eq("imap envelope id", s.messageID, "<id1@example.com>")
        } else { bad.append("imap fetch parse") }
        if let f = second.flatMap(Imap.fetch) {
            eq("imap body literal", f.items["BODY[]<0>"]?.text, "Hi)\r\n")
            if Imap.summary(f.items)?.seen != true { bad.append("imap seen") }
        } else { bad.append("imap fetch 2") }
        if let t = third, let st = Imap.status(t, tag: "A4") { if !st.ok { bad.append("imap status ok") } } else { bad.append("imap third") }
        if r.next() != nil { bad.append("imap reader leftover") }
        let no = Imap.status(Data("A1 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n".utf8), tag: "A1")
        if no?.ok != false || no?.kind != "NO" || no?.text != "Invalid credentials (Failure)" { bad.append("imap status no \(String(describing: no))") }
        if Imap.status(Data("A10 OK x".utf8), tag: "A1") != nil { bad.append("imap status tag") }
        let l = Imap.list(Data("* LIST (\\HasNoChildren \\All) \"/\" \"[Gmail]/All Mail\"\r\n".utf8))
        if l?.flags != ["\\hasnochildren", "\\all"] || l?.name != "[Gmail]/All Mail" { bad.append("imap list \(String(describing: l))") }
        if Imap.list(Data("* LIST () \".\" INBOX\r\n".utf8))?.name != "INBOX" { bad.append("imap list atom") }
        if Imap.list(Data("* LIST (\\Archive) \"/\" {7}\r\nArchive\r\n".utf8))?.flags != ["\\archive"] { bad.append("imap list literal") }
        if Imap.search(Data("* SEARCH 3 9 12\r\n".utf8)) != [3, 9, 12] { bad.append("imap search") }
        if Imap.exists(Data("* 23 EXISTS\r\n".utf8)) != 23 { bad.append("imap exists") }
        eq("imap uidvalidity", Imap.code(Data("* OK [UIDVALIDITY 3857529045] UIDs valid\r\n".utf8), "UIDVALIDITY"), "3857529045")
        if Imap.capabilities(Data("* CAPABILITY IMAP4rev1 MOVE UIDPLUS literal+\r\n".utf8)) != ["IMAP4REV1", "MOVE", "UIDPLUS", "LITERAL+"] {
            bad.append("imap capabilities")
        }
        eq("imap quote", Imap.quote("pa\"ss\\word"), "\"pa\\\"ss\\\\word\"")
        if Imap.quote("pässword") != nil || Imap.quote("a\r\nb") != nil { bad.append("imap quote needs literal") }
        if Imap.values(Data("* 1 FETCH (BODY[HEADER.FIELDS (FROM)] \"x\")".utf8)).last?.list?.first?.atom != "BODY[HEADER.FIELDS (FROM)]" {
            bad.append("imap section atom")
        }
        _ = Imap.values(Data("* OK [ALERT] don't \"unbalanced ( {99}\r\nab".utf8))  // must not trap
        // SMTP
        if Smtp.reply(["250-smtp.example.com", "250-AUTH PLAIN LOGIN"]) != nil { bad.append("smtp reply partial") }
        let rep = Smtp.reply(["250-smtp.example.com", "250-AUTH PLAIN LOGIN", "250 STARTTLS"])
        if rep?.code != 250 || rep?.text != "smtp.example.com\nAUTH PLAIN LOGIN\nSTARTTLS" { bad.append("smtp reply \(String(describing: rep))") }
        if Smtp.reply(["535 5.7.8 Bad credentials"])?.code != 535 { bad.append("smtp 535") }
        eq("smtp data", String(decoding: Smtp.data(Data("a\n.b\r\n..\nc\n".utf8)), as: UTF8.self), "a\r\n..b\r\n...\r\nc\r\n.\r\n")
        eq("smtp plain", Smtp.plain(user: "u@x", password: "p"), "AHVAeABw")
    }
}
