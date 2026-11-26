import Foundation

/// The chats app's protocol (cmf-watch-sdk sdk/examples/chats/src/model.rs; hosts/inboxhost.py is the reference for
/// its Mail and Notes modes). Every message ≤ 128 bytes, text cut on a character.
public enum ChatsProto {
    public static let maxRows = 12, maxMsgs = 12, maxQuick = 6
    /// Bytes of a message's text on the watch.
    public static let text = 120
    /// Message kinds: text, a reminder to do, a reminder done.
    public static let plain: UInt8 = 0, todo: UInt8 = 3, done: UInt8 = 4

    public struct Row: Equatable, Sendable {
        public var id: UInt8, unread: Bool, name: String, preview: String
        /// How many are unread (the watch shows the number; 0: `unread` alone, as 1).
        public var count: Int = 0
        /// A status line ("Syncing..."): red on the watch, not a chat.
        public var status = false
        public init(id: UInt8, unread: Bool = false, name: String, preview: String) {
            self.id = id; self.unread = unread; self.name = name; self.preview = preview
        }
        public init(id: UInt8, unreadCount: Int, name: String, preview: String) {
            self.init(id: id, unread: unreadCount > 0, name: name, preview: preview)
            count = unreadCount
        }
        var unreadByte: UInt8 { status ? 255 : count > 0 ? UInt8(min(count, 254)) : (unread ? 1 : 0) }
    }

    /// `L n`, then `C idx id unread nlen name… plen preview…` per row (12 at most).
    public static func list(_ rows: [Row]) -> [Data] {
        let rows = rows.prefix(maxRows)
        var out = [Data([UInt8(ascii: "L"), UInt8(rows.count)])]
        for (i, r) in rows.enumerated() {
            out.append(Data([UInt8(ascii: "C"), UInt8(i), r.id, r.unreadByte]) + field(r.name, 24, emoji: true) + field(r.preview, 40, emoji: true))
        }
        return out
    }

    /// `H id title…`: a chat opened, its messages follow and replace.
    public static func open(_ id: UInt8, title: String) -> Data { Data([UInt8(ascii: "H"), id]) + utf8(title, 24, emoji: true) }

    /// The `me` byte: bit 0 ours, bits 1–2 its state (0 sent, 1 delivered, 2 read).
    static func meByte(_ me: Bool, _ state: Int) -> UInt8 { me ? 1 | UInt8(min(max(state, 0), 2)) << 1 : 0 }

    /// `M idx me kind text…`, idx 0 the oldest.
    public static func message(_ idx: Int, me: Bool = false, state: Int = 0, kind: UInt8 = plain, _ text: String) -> Data {
        Data([UInt8(ascii: "M"), UInt8(idx & 0xFF), meByte(me, state), kind]) + utf8(text, Self.text, emoji: true)
    }

    /// `A me kind text…`: one more at the end.
    public static func append(me: Bool = false, state: Int = 0, kind: UInt8 = plain, _ text: String) -> Data {
        Data([UInt8(ascii: "A"), meByte(me, state), kind]) + utf8(text, Self.text, emoji: true)
    }

    /// `S idx state`: our message idx was delivered (1) or read (2).
    public static func state(_ idx: Int, _ state: Int) -> Data {
        Data([UInt8(ascii: "S"), UInt8(idx & 0xFF), UInt8(min(max(state, 0), 2))])
    }

    /// `P online`: the open chat's contact is online.
    public static func online(_ on: Bool) -> Data { Data([UInt8(ascii: "P"), on ? 1 : 0]) }

    /// `W text`: the line under the open chat's name ("last seen 16:42").
    public static func seen(_ s: String) -> Data { Data([UInt8(ascii: "W")]) + utf8(s, 40) }

    /// "last seen 16:42" (today), "last seen yesterday 21:05", "last seen 2 Nov" (older): short, for the watch's top.
    public static func lastSeen(_ t: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        if calendar.isDate(t, inSameDayAs: now) { return "last seen \(f.string(from: t))" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(t, inSameDayAs: y) {
            return "last seen yesterday \(f.string(from: t))"
        }
        f.dateFormat = "d MMM"
        return "last seen \(f.string(from: t))"
    }

    /// The side of the open chat's picture on the watch (12 × 12, shown as a disc).
    public static let dpSide = 12

    /// `G part px…`: the open chat's picture, 12 × 12 RGBA (row-major) → 3 parts of 4 rows, RGB565 LE.
    public static func dp(rgba: [UInt8]) -> [Data] {
        let n = dpSide
        guard rgba.count >= n * n * 4 else { return [] }
        return (0..<3).map { part in
            var d = Data([UInt8(ascii: "G"), UInt8(part)])
            for i in part * 4 * n..<(part + 1) * 4 * n {
                let c = Rle.rgb565(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2])
                d.append(UInt8(c & 0xFF)); d.append(UInt8(c >> 8))
            }
            return d
        }
    }

    /// Message idx's picture: `i idx <I header>`, `d idx seq tokens…` (125 bytes each), `e idx`; 16 colours.
    public static func picture(_ idx: Int, rgb: [UInt8], width: Int, height: Int, scale: UInt8 = 1) -> [Data] {
        let (palette, px) = Quantize.medianCut(rgb: rgb, colours: 16)
        let header = Rle.header(width: width, height: height, scale: scale,
                                palette: palette.map { Rle.rgb565($0.0, $0.1, $0.2) })
        let tokens = Rle.tokens(px, width: width, height: height)
        let i = UInt8(idx & 0xFF)
        var out = [Data([UInt8(ascii: "i"), i]) + header]
        var seq: UInt8 = 0
        var at = tokens.startIndex
        while at < tokens.endIndex {
            let end = min(at + 125, tokens.endIndex)
            out.append(Data([UInt8(ascii: "d"), i, seq]) + tokens[at..<end])
            seq &+= 1
            at = end
        }
        out.append(Data([UInt8(ascii: "e"), i]))
        return out
    }

    /// `H` then the last 12 messages as `M`.
    public static func chat(_ id: UInt8, title: String, _ msgs: [(me: Bool, kind: UInt8, text: String)]) -> [Data] {
        [open(id, title: title)] + msgs.suffix(maxMsgs).enumerated().map { message($0.offset, me: $0.element.me, kind: $0.element.kind, $0.element.text) }
    }

    /// `N id`: something new in id (the watch buzzes).
    public static func buzz(_ id: UInt8) -> Data { Data([UInt8(ascii: "N"), id]) }

    /// `Q idx text…` per quick reply (6 at most).
    public static func quick(_ q: [String]) -> [Data] {
        q.prefix(maxQuick).enumerated().map { Data([UInt8(ascii: "Q"), UInt8($0.offset)]) + utf8($0.element, 24, emoji: true) }
    }

    /// Text → pieces of at most `n` bytes, on spaces (a longer word is cut on a character).
    public static func chunks(_ text: String, _ n: Int = text) -> [String] {
        var out: [String] = [], cur = ""
        for w in text.split(whereSeparator: \.isWhitespace) {
            var w = String(w)
            let next = cur.isEmpty ? w : cur + " " + w
            if next.utf8.count <= n { cur = next; continue }
            if !cur.isEmpty { out.append(cur); cur = "" }
            while w.utf8.count > n {
                let head = String(decoding: utf8(w, n, emoji: true), as: UTF8.self)
                out.append(head)
                w = String(w.dropFirst(head.count))
            }
            cur = w
        }
        return cur.isEmpty ? out : out + [cur]
    }

    /// Text → pieces of at most `n` bytes, whole sentences where they fit, else on spaces (a page of a note).
    public static func page(_ text: String, _ n: Int = text) -> [String] {
        var sentences: [String] = [], cur = ""
        for w in text.split(whereSeparator: \.isWhitespace) {
            cur += cur.isEmpty ? String(w) : " " + w
            if let l = w.last, ".!?".contains(l) { sentences.append(cur); cur = "" }
        }
        if !cur.isEmpty { sentences.append(cur) }
        var out: [String] = []
        cur = ""
        for s in sentences {
            let next = cur.isEmpty ? s : cur + " " + s
            if next.utf8.count <= n { cur = next; continue }
            if !cur.isEmpty { out.append(cur); cur = "" }
            if s.utf8.count <= n { cur = s; continue }
            var parts = chunks(s, n)
            cur = parts.removeLast()
            out += parts
        }
        return cur.isEmpty ? out : out + [cur]
    }

    /// What the watch asked for.
    public enum Ask: Equatable, Sendable {
        case ready, open(UInt8), send(UInt8, String), tap(Int)
    }

    public static func parse(_ m: Data) -> Ask? {
        let b = [UInt8](m)
        switch (b.first, b.count) {
        case (UInt8(ascii: "R"), 1): return .ready
        case (UInt8(ascii: "o"), 2): return .open(b[1])
        case (UInt8(ascii: "t"), 2): return .tap(Int(b[1]))
        case (UInt8(ascii: "s"), 3...):
            let t = String(decoding: b.dropFirst(2), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : .send(b[1], t)
        default: return nil
        }
    }

    /// A quick reply that is an action ("• Archive"), not text to send.
    public static func action(_ text: String) -> String? {
        text.hasPrefix("• ") ? String(text.dropFirst(2)) : nil
    }

    /// The phone's ids for the watch (a u8 each) ↔ its own keys (a Gmail thread, a note). An id stays with its key;
    /// when they run out, the table starts again.
    public struct Ids: Sendable {
        let first: UInt8
        var byKey: [String: UInt8] = [:]
        var byId: [UInt8: String] = [:]
        var next: UInt8

        public init(first: UInt8 = 1) { self.first = first; next = first }

        public mutating func id(_ key: String) -> UInt8 {
            if let i = byKey[key] { return i }
            if byId.count >= 256 - Int(first) { byKey.removeAll(); byId.removeAll(); next = first }
            while byId[next] != nil { next = next == 255 ? first : next + 1 }
            let i = next
            byKey[key] = i; byId[i] = key
            next = i == 255 ? first : i + 1
            return i
        }

        public func key(_ id: UInt8) -> String? { byId[id] }
    }
}

/// Email → what the watch shows, and a reply (Gmail's raw RFC 2822).
public enum MailText {
    /// HTML → text: no styles or scripts, breaks as new lines, entities decoded.
    public static func strip(html: String) -> String {
        var s = html
        for (p, r) in [("(?is)<(style|script|head)[^>]*>.*?</\\1>", " "), ("(?i)<br\\s*/?>", "\n"),
                       ("(?i)</(p|div|tr|li|h[1-6]|blockquote)>", "\n"), ("(?s)<[^>]+>", " ")] {
            s = s.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return entities(s)
    }

    static func entities(_ s: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'", "zwnj": "",
                     "hellip": "…", "mdash": "-", "ndash": "-", "rsquo": "’", "lsquo": "'", "ldquo": "“", "rdquo": "”"]
        var out = "", rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[rest.index(after: amp)...]
            if let semi = tail.prefix(10).firstIndex(of: ";") {
                let name = String(tail[..<semi])
                var rep: String? = named[name.lowercased()]
                if rep == nil, name.hasPrefix("#") {
                    let num = name.dropFirst()
                    let v = num.lowercased().hasPrefix("x") ? UInt32(num.dropFirst(), radix: 16) : UInt32(num)
                    rep = v.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
                }
                if let rep {
                    out += rep
                    rest = tail[tail.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = tail
        }
        return out + rest
    }

    /// The new part of a message: no quoted lines (">"), nothing from "On … wrote:" on, whitespace collapsed.
    public static func body(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        var s = lines.joined(separator: "\n")
        for p in ["(?s)\\bOn [^\\n]{1,200}?(\\n[^\\n]{0,120}?)?wrote:", "(?m)^-+ ?Original Message ?-+"] {
            if let r = s.range(of: p, options: .regularExpression) { s = String(s[..<r.lowerBound]) }
        }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `"Name" <a@b.c>` → Name; a bare address → the part before @.
    public static func name(_ from: String) -> String {
        let f = from.trimmingCharacters(in: .whitespaces)
        if let lt = f.firstIndex(of: "<") {
            let n = f[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !n.isEmpty { return n }
        }
        let a = address(f)
        return String(a.split(separator: "@").first ?? Substring(a))
    }

    /// The address in a From/To header.
    public static func address(_ h: String) -> String {
        if let lt = h.firstIndex(of: "<"), let gt = h[lt...].firstIndex(of: ">") {
            return String(h[h.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
        }
        return h.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    /// RFC 2047 for a header word that is not ASCII.
    static func word(_ s: String) -> String {
        s.unicodeScalars.allSatisfy(\.isASCII) ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    /// A reply in the thread: "Re:" subject, In-Reply-To and References, UTF-8 text. Sent by SMTP it also needs
    /// `from`, `date` and its own `id` (Gmail's API adds them).
    public static func reply(to: String, subject: String, messageID: String, references: String, text: String,
                             from: String? = nil, date: Date? = nil, id: String? = nil) -> Data {
        let toH = mailbox(to)
        let subj = subject.lowercased().hasPrefix("re:") ? subject : "Re: " + subject
        var h: [String] = []
        if let from { h.append("From: \(mailbox(from))") }
        h += ["To: \(toH)", "Subject: \(word(subj))"]
        if let date { h.append("Date: \(rfc5322(date))") }
        if let id { h.append("Message-ID: \(id)") }
        if !messageID.isEmpty {
            h += ["In-Reply-To: \(messageID)", "References: \((references + " " + messageID).trimmingCharacters(in: .whitespaces))"]
        }
        h += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"]
        let b64 = Data(text.utf8).base64EncodedString(options: .lineLength76Characters)
        return Data((h.joined(separator: "\r\n") + "\r\n\r\n" + b64 + "\r\n").utf8)
    }

    /// `Zoë <z@example.com>` → `=?UTF-8?B?…?= <z@example.com>`; a bare address stays bare.
    static func mailbox(_ s: String) -> String {
        let n = name(s), a = address(s)
        if n.isEmpty || n == String(a.split(separator: "@").first ?? "") { return a }
        let special = n.unicodeScalars.allSatisfy(\.isASCII) && n.contains { "()<>[]:;@\\,.\"".contains($0) }
        let shown = special ? "\"" + n.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : word(n)
        return "\(shown) <\(a)>"
    }

    /// A Date header: `Fri, 20 Nov 2026 09:05:00 +0000`.
    public static func rfc5322(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }

    /// A new Message-ID at the sender's domain.
    public static func newID(_ from: String) -> String {
        let domain = address(from).split(separator: "@").last.map(String.init) ?? "cmfx.local"
        return "<\(UUID().uuidString.lowercased())@\(domain)>"
    }
}
