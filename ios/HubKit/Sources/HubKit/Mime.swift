import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// An email as IMAP gives it (RFC 5322 + MIME) → what the watch shows: headers decoded (RFC 2047 encoded words),
/// and the text: text/plain if there is one, else text/html as text, through nested multiparts, base64 or
/// quoted-printable, in its charset. Lenient: a message cut short (a fetch of its first bytes) still gives its text.
public enum Mime {
    /// A part: its headers (names lowercased, values unfolded, not decoded) and its body bytes.
    public struct Part: Sendable {
        public var headers: [(name: String, value: String)]
        public var body: Data

        /// The first header `name` (any case), raw.
        public func raw(_ name: String) -> String? {
            let n = name.lowercased()
            return headers.first { $0.name == n }?.value
        }

        /// The first header `name`, encoded words decoded.
        public func header(_ name: String) -> String? { raw(name).map(Mime.words) }

        /// `text/plain` from Content-Type (text/plain when there is none).
        public var type: String {
            let t = raw("content-type").map { Mime.value($0).lowercased() } ?? ""
            return t.isEmpty ? "text/plain" : t
        }

        public func param(_ header: String, _ name: String) -> String? { raw(header).flatMap { Mime.param($0, name) } }

        /// The body with its transfer encoding undone.
        public var decoded: Data {
            switch raw("content-transfer-encoding").map({ Mime.value($0).lowercased() }) {
            case "base64": Mime.base64(body)
            case "quoted-printable": Mime.quotedPrintable(body, header: false)
            default: body
            }
        }

        /// A text part's text in its charset.
        public var text: String { Mime.string(decoded, charset: param("content-type", "charset")) }

        public var attachment: Bool {
            raw("content-disposition").map { Mime.value($0).lowercased() == "attachment" } ?? false
        }

        /// A multipart's parts (empty for any other part).
        public var parts: [Part] {
            guard type.hasPrefix("multipart/"), let b = param("content-type", "boundary"), !b.isEmpty else { return [] }
            return Mime.split(body, boundary: b).map(Mime.parse)
        }
    }

    /// Headers and body of a message or a part.
    public static func parse(_ raw: Data) -> Part {
        let b = [UInt8](raw)
        // the header ends at the first empty line (CRLF CRLF, or LF LF); none at all when the data starts with one
        var end = b.count, bodyStart = b.count
        if b.first == 10 { end = 0; bodyStart = 1 }
        else if b.count > 1, b[0] == 13, b[1] == 10 { end = 0; bodyStart = 2 }
        else {
            var i = 0
            while i < b.count {
                if b[i] == 10 {
                    if i + 1 < b.count, b[i + 1] == 10 { end = i; bodyStart = i + 2; break }
                    if i + 2 < b.count, b[i + 1] == 13, b[i + 2] == 10 { end = i; bodyStart = i + 3; break }
                }
                i += 1
            }
        }
        let head = string(Data(b[0..<end]), charset: nil).replacingOccurrences(of: "\r", with: "")
        var headers: [(name: String, value: String)] = []
        for line in head.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let f = line.first, f == " " || f == "\t" {
                if !headers.isEmpty { headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(),
                            line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return Part(headers: headers, body: bodyStart < b.count ? Data(b[bodyStart...]) : Data())
    }

    /// The text to show: the first text/plain that is not an attachment, else the first text/html as text.
    public static func text(_ raw: Data) -> String? { text(parse(raw)) }

    public static func text(_ p: Part) -> String? {
        func find(_ p: Part, _ mime: String) -> Part? {
            if p.type == mime, !p.attachment { return p }
            if p.type.hasPrefix("multipart/") {
                for c in p.parts { if let t = find(c, mime) { return t } }
            }
            return nil
        }
        if let t = find(p, "text/plain") { return t.text }
        if let h = find(p, "text/html") { return MailText.strip(html: h.text) }
        return nil
    }

    // MARK: pieces

    /// A multipart body → its parts' bytes (preamble and epilogue dropped; a missing close ends at the end).
    static func split(_ body: Data, boundary: String) -> [Data] {
        let b = [UInt8](body), d = [UInt8](("--" + boundary).utf8)
        // delimiter lines: at the start or after LF, "--boundary" then "--", spaces or the line's end
        var marks: [(start: Int, next: Int, close: Bool)] = []
        var i = 0
        while i + d.count <= b.count {
            if (i == 0 || b[i - 1] == 10), b[i] == 45, Array(b[i..<(i + d.count)]) == d {
                var j = i + d.count
                let close = j + 1 < b.count && b[j] == 45 && b[j + 1] == 45
                while j < b.count, b[j] != 10 { j += 1 }
                // the line break before the delimiter belongs to it
                var s = i
                if s > 0, b[s - 1] == 10 { s -= 1; if s > 0, b[s - 1] == 13 { s -= 1 } }
                marks.append((s, min(j + 1, b.count), close))
                if close { break }
                i = j
                continue
            }
            i += 1
        }
        var out: [Data] = []
        for (k, m) in marks.enumerated() where !m.close {
            let end = k + 1 < marks.count ? marks[k + 1].start : b.count
            if m.next <= end { out.append(Data(b[m.next..<end])) }
        }
        return out
    }

    /// `text/plain; charset="x"` → text/plain.
    static func value(_ h: String) -> String {
        String(h.split(separator: ";", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// A parameter of a header (`boundary`, `charset`), unquoted; RFC 2231 `name*=charset''x` too.
    static func param(_ h: String, _ name: String) -> String? {
        var rest = Substring(h)
        guard let semi = rest.firstIndex(of: ";") else { return nil }
        rest = rest[rest.index(after: semi)...]
        while !rest.isEmpty {
            rest = rest.drop { $0 == " " || $0 == "\t" || $0 == ";" }
            guard let eq = rest.firstIndex(of: "=") else { return nil }
            let key = rest[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            rest = rest[rest.index(after: eq)...].drop { $0 == " " }
            var val = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                while let c = rest.first, c != "\"" {
                    if c == "\\", rest.count > 1 { rest = rest.dropFirst() }
                    val.append(rest.first!)
                    rest = rest.dropFirst()
                }
                rest = rest.dropFirst()
                if let s = rest.firstIndex(of: ";") { rest = rest[s...] } else { rest = "" }
            } else {
                let s = rest.firstIndex(of: ";") ?? rest.endIndex
                val = rest[..<s].trimmingCharacters(in: .whitespaces)
                rest = rest[s...]
            }
            if key == name { return val }
            if key == name + "*" {
                // charset'lang'percent-encoded
                let p = val.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if p.count == 3 {
                    var bytes: [UInt8] = []
                    var s = Substring(p[2])
                    while let c = s.first {
                        if c == "%", s.count >= 3, let v = UInt8(s.dropFirst().prefix(2), radix: 16) { bytes.append(v); s = s.dropFirst(3) }
                        else { bytes += Array(String(c).utf8); s = s.dropFirst() }
                    }
                    return string(Data(bytes), charset: String(p[0]))
                }
                return val
            }
        }
        return nil
    }

    /// base64, lenient: line breaks and stray characters skipped, a cut-off tail dropped.
    public static func base64(_ d: Data) -> Data {
        var s = [UInt8]()
        s.reserveCapacity(d.count)
        for c in d {
            switch c {
            case 65...90, 97...122, 48...57, 43, 47: s.append(c)
            case 61: s.append(c)
            default: continue
            }
        }
        // padding only at the end of a group: cut at the first "=" group
        if let eq = s.firstIndex(of: 61) {
            let groupEnd = min(s.count, (eq / 4 + 1) * 4)
            s = Array(s[..<groupEnd])
            while s.count % 4 != 0 { s.append(61) }
        } else {
            s = Array(s[..<(s.count - s.count % 4)])
        }
        return Data(base64Encoded: Data(s)) ?? Data()
    }

    /// Quoted-printable (`=XX`, soft breaks); `header` (RFC 2047 Q) also reads `_` as a space.
    public static func quotedPrintable(_ d: Data, header: Bool) -> Data {
        let b = [UInt8](d)
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        while i < b.count {
            let c = b[i]
            if c == 61 {
                if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) { out.append(h << 4 | l); i += 3; continue }
                // a soft break ("=", maybe spaces, the line's end), or a cut-off tail
                var j = i + 1
                while j < b.count, b[j] == 32 || b[j] == 9 { j += 1 }
                if j == b.count { break }
                if b[j] == 13 || b[j] == 10 {
                    i = j + (b[j] == 13 && j + 1 < b.count && b[j + 1] == 10 ? 2 : 1)
                    continue
                }
                out.append(c)
            } else if header, c == 95 {
                out.append(32)
            } else {
                out.append(c)
            }
            i += 1
        }
        return Data(out)
    }

    /// Bytes in a charset → text. No charset or an unknown one: UTF-8 if valid, else Windows-1252.
    public static func string(_ d: Data, charset: String?) -> String {
        let cs = (charset ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).lowercased()
        func cp1252() -> String {
            String(data: d, encoding: .windowsCP1252) ?? String(data: d, encoding: .isoLatin1) ?? String(decoding: d, as: UTF8.self)
        }
        switch cs {
        case "", "utf-8", "utf8", "us-ascii", "ascii", "unknown-8bit", "x-unknown":
            return String(data: d, encoding: .utf8) ?? cp1252()
        case "iso-8859-1", "latin1", "iso8859-1", "iso_8859-1", "windows-1252", "cp1252", "x-cp1252":
            // ISO-8859-1 mail is usually Windows-1252 in fact (curly quotes in 0x80–0x9F)
            return cp1252()
        case "utf-16": return String(data: d, encoding: .utf16) ?? cp1252()
        default:
            #if canImport(CoreFoundation)
            let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: d, encoding: enc) { return s }
            }
            #endif
            return String(data: d, encoding: .utf8) ?? cp1252()
        }
    }

    /// RFC 2047: `=?UTF-8?B?…?=` and `=?iso-8859-1?Q?…?=` words → text. Space between two encoded words goes;
    /// adjacent words in one charset are joined as bytes first (a character split across them survives).
    public static func words(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        var out = "", gap = ""
        var pending: (charset: String, bytes: Data)?
        var lastWasWord = false
        var rest = Substring(s)
        func flush() {
            if let p = pending { out += string(p.bytes, charset: p.charset); pending = nil }
        }
        while let c = rest.first {
            if let (charset, bytes, after) = word(rest) {
                if !lastWasWord { out += gap }
                gap = ""
                if let p = pending, p.charset == charset {
                    pending = (charset, p.bytes + bytes)
                } else {
                    flush()
                    pending = (charset, bytes)
                }
                lastWasWord = true
                rest = after
            } else if c.isWhitespace {
                gap += " "
                rest = rest.dropFirst()
            } else {
                flush()
                out += gap
                gap = ""
                out.append(c)
                lastWasWord = false
                rest = rest.dropFirst()
            }
        }
        flush()
        return out + gap
    }

    /// One encoded word at the start of `s`: its charset, bytes and what follows.
    private static func word(_ s: Substring) -> (String, Data, Substring)? {
        guard s.hasPrefix("=?") else { return nil }
        let body = s.dropFirst(2)
        let f = body.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
        guard f.count == 3, f[0].count < 40, f[1].count == 1, let end = f[2].range(of: "?=") else { return nil }
        let charset = String(f[0].split(separator: "*").first ?? "").lowercased()
        let text = f[2][..<end.lowerBound]
        guard !text.contains(" ") else { return nil }
        let bytes: Data
        switch f[1].uppercased() {
        case "B": bytes = base64(Data(text.utf8))
        case "Q": bytes = quotedPrintable(Data(text.utf8), header: true)
        default: return nil
        }
        return (charset, bytes, f[2][end.upperBound...])
    }

    /// RFC 2047 for a header that is not ASCII (UTF-8, base64).
    public static func encode(_ s: String) -> String { MailText.word(s) }
}
