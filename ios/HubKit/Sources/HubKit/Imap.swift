import Foundation

/// IMAP4rev1 (RFC 3501) wire pieces for the phone's IMAP client, without the network: whole responses out of the
/// bytes read so far (literals `{n}` included), their values, FETCH's ENVELOPE and FLAGS, LIST, and quoting.
public enum Imap {
    /// A value in a response: an atom (`UID`, `\Seen`, `BODY[]<0>`), a string (quoted or a literal, as bytes),
    /// a parenthesised list, or NIL.
    public indirect enum Value: Equatable, Sendable {
        case atom(String), string(Data), list([Value]), nil_

        public var atom: String? { if case .atom(let a) = self { return a }; return nil }
        public var list: [Value]? { if case .list(let l) = self { return l }; return nil }
        public var data: Data? {
            switch self {
            case .string(let d): d
            case .atom(let a): Data(a.utf8)
            default: nil
            }
        }
        /// A string's text (UTF-8, else Windows-1252), encoded words left as they are.
        public var text: String? { data.map { Mime.string($0, charset: nil) } }
    }

    /// The bytes read so far → whole responses (each a line, with its literals and the lines that follow them).
    public struct Reader: Sendable {
        public private(set) var buffer = Data()
        public init() {}

        public mutating func feed(_ d: Data) { buffer.append(d) }

        /// The next whole response, CRLF included; nil until it has all come.
        public mutating func next() -> Data? {
            let b = buffer
            var i = b.startIndex
            while true {
                guard let lf = b[i...].firstIndex(of: 10) else { return nil }
                if let n = Imap.literal(b[i..<lf]) {
                    let after = lf + 1 + n
                    guard after <= b.endIndex else { return nil }
                    i = after
                    continue
                }
                let out = Data(b[b.startIndex...lf])
                buffer = Data(b[(lf + 1)...])
                return out
            }
        }

        /// One line (SMTP, a greeting), without its CRLF; nil until it has come.
        public mutating func line() -> String? {
            guard let lf = buffer.firstIndex(of: 10) else { return nil }
            var l = buffer[buffer.startIndex..<lf]
            if l.last == 13 { l = l.dropLast() }
            let s = Mime.string(Data(l), charset: nil)
            buffer = Data(buffer[(lf + 1)...])
            return s
        }
    }

    /// `… {123}\r` at a line's end → 123 (`{123+}` too).
    static func literal(_ line: Data) -> Int? {
        var l = line
        if l.last == 13 { l = l.dropLast() }
        guard l.last == UInt8(ascii: "}"), let open = l.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var digits = l[(open + 1)..<(l.endIndex - 1)]
        if digits.last == UInt8(ascii: "+") { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    /// A response's values. Never fails: what it cannot read ends the list.
    public static func values(_ d: Data) -> [Value] {
        var p = Parser(b: [UInt8](d))
        return p.values(until: nil)
    }

    struct Parser {
        let b: [UInt8]
        var i = 0

        mutating func values(until close: UInt8?) -> [Value] {
            var out: [Value] = []
            while i < b.count {
                let c = b[i]
                if c == 32 || c == 13 || c == 10 || c == 9 { i += 1; continue }
                if let close, c == close { i += 1; return out }
                if c == UInt8(ascii: ")") { i += 1; continue }
                if c == UInt8(ascii: "(") { i += 1; out.append(.list(values(until: UInt8(ascii: ")")))); continue }
                if c == UInt8(ascii: "\"") {
                    i += 1
                    var s: [UInt8] = []
                    while i < b.count, b[i] != UInt8(ascii: "\"") {
                        if b[i] == UInt8(ascii: "\\"), i + 1 < b.count { i += 1 }
                        s.append(b[i])
                        i += 1
                    }
                    i += 1
                    out.append(.string(Data(s)))
                    continue
                }
                if c == UInt8(ascii: "{") {
                    var j = i + 1
                    while j < b.count, (48...57).contains(b[j]) { j += 1 }
                    if j < b.count, b[j] == UInt8(ascii: "+") { j += 1 }
                    if j < b.count, b[j] == UInt8(ascii: "}"), let n = Int(String(decoding: b[(i + 1)..<j].filter { $0 != 43 }, as: UTF8.self)) {
                        var k = j + 1
                        if k < b.count, b[k] == 13 { k += 1 }
                        if k < b.count, b[k] == 10 { k += 1 }
                        let end = min(k + n, b.count)
                        out.append(.string(Data(b[k..<end])))
                        i = end
                        continue
                    }
                }
                // an atom; a [section] in it may hold spaces and parentheses
                var s: [UInt8] = []
                var depth = 0
                while i < b.count {
                    let x = b[i]
                    if depth == 0, x == 32 || x == 13 || x == 10 || x == UInt8(ascii: "(") || x == UInt8(ascii: ")") { break }
                    if x == UInt8(ascii: "[") { depth += 1 }
                    if x == UInt8(ascii: "]") { depth = max(0, depth - 1) }
                    s.append(x)
                    i += 1
                }
                let a = String(decoding: s, as: UTF8.self)
                out.append(a.uppercased() == "NIL" ? .nil_ : .atom(a))
            }
            return out
        }
    }

    /// `* 12 FETCH (UID 34 FLAGS (\Seen) …)` → its items by name (uppercased; `BODY[]<0>` as it came).
    public static func fetch(_ response: Data) -> (seq: Int, items: [String: Value])? {
        let v = values(response)
        guard v.count >= 4, v[0].atom == "*", let seq = v[1].atom.flatMap({ Int($0) }), v[2].atom?.uppercased() == "FETCH",
              let l = v[3].list else { return nil }
        var items: [String: Value] = [:]
        var k = 0
        while k + 1 < l.count {
            if let name = l[k].atom { items[name.uppercased()] = l[k + 1] }
            k += 2
        }
        return (seq, items)
    }

    /// One message in the list: its UID, flags and envelope.
    public struct Summary: Equatable, Sendable {
        public var uid: UInt32, seen: Bool, from: String, subject: String, date: String, messageID: String
    }

    /// FETCH items (UID FLAGS ENVELOPE) → a summary; From as `Name <a@b>` with its name decoded.
    public static func summary(_ items: [String: Value]) -> Summary? {
        guard let uid = items["UID"]?.atom.flatMap({ UInt32($0) }) else { return nil }
        let flags = items["FLAGS"]?.list?.compactMap { $0.atom?.lowercased() } ?? []
        let env = items["ENVELOPE"]?.list ?? []
        func s(_ i: Int) -> String { i < env.count ? (env[i].text ?? "") : "" }
        let from = env.count > 2 ? address(env[2]) : ""
        return Summary(uid: uid, seen: flags.contains("\\seen"), from: from, subject: Mime.words(s(1)), date: s(0),
                       messageID: s(9))
    }

    /// An ENVELOPE address list's first: `Name <mailbox@host>`, or the bare address.
    public static func address(_ v: Value) -> String {
        guard let a = v.list?.first?.list, a.count >= 4 else { return "" }
        let name = Mime.words(a[0].text ?? "").trimmingCharacters(in: .whitespaces)
        let box = a[2].text ?? "", host = a[3].text ?? ""
        let addr = host.isEmpty ? box : "\(box)@\(host)"
        return name.isEmpty ? addr : "\(name.replacingOccurrences(of: "\"", with: "")) <\(addr)>"
    }

    /// `* LIST (\HasNoChildren \Archive) "/" "Archive"` → its flags (lowercased) and name (as the server spells it).
    public static func list(_ response: Data) -> (flags: [String], name: String)? {
        let v = values(response)
        guard v.count >= 5, v[0].atom == "*", ["LIST", "XLIST"].contains(v[1].atom?.uppercased() ?? ""),
              let flags = v[2].list, let name = v[4].text else { return nil }
        return (flags.compactMap { $0.atom?.lowercased() }, name)
    }

    /// `* SEARCH 1 2 3` → the numbers.
    public static func search(_ response: Data) -> [UInt32]? {
        let v = values(response)
        guard v.count >= 2, v[0].atom == "*", v[1].atom?.uppercased() == "SEARCH" else { return nil }
        return v.dropFirst(2).compactMap { $0.atom.flatMap { UInt32($0) } }
    }

    /// `* 23 EXISTS` → 23.
    public static func exists(_ response: Data) -> Int? {
        let v = values(response)
        guard v.count >= 3, v[0].atom == "*", v[2].atom?.uppercased() == "EXISTS" else { return nil }
        return v[1].atom.flatMap { Int($0) }
    }

    /// A response code's value: `* OK [UIDVALIDITY 3857529045] UIDs valid` → "3857529045" for UIDVALIDITY.
    public static func code(_ response: Data, _ name: String) -> String? {
        let s = String(decoding: response, as: UTF8.self)
        guard let r = s.range(of: "[" + name + " ", options: .caseInsensitive) else { return nil }
        let rest = s[r.upperBound...]
        return rest.firstIndex(of: "]").map { String(rest[..<$0]) }
    }

    /// `* CAPABILITY IMAP4rev1 MOVE …` (or the `[CAPABILITY …]` code) → the names, uppercased.
    public static func capabilities(_ response: Data) -> [String]? {
        let s = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.uppercased().hasPrefix("* CAPABILITY ") {
            return s.dropFirst(13).split(separator: " ").map { $0.uppercased() }
        }
        return code(response, "CAPABILITY").map { $0.split(separator: " ").map { $0.uppercased() } }
    }

    /// A string argument: an atom-safe or quoted string, or nil when it must go as a literal (CR, LF, NUL, 8-bit).
    public static func quote(_ s: String) -> String? {
        guard s.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A tagged response's status: `A3 NO [AUTHENTICATIONFAILED] Invalid credentials` → ("NO", "Invalid credentials").
    public static func status(_ line: Data, tag: String) -> (ok: Bool, kind: String, text: String)? {
        let s = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(tag + " ") else { return nil }
        let rest = s.dropFirst(tag.count + 1)
        let kind = String(rest.prefix { $0 != " " }).uppercased()
        var text = rest.dropFirst(kind.count).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let t = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { text = t }
        }
        return (kind == "OK", kind, text)
    }
}

/// SMTP (RFC 5321) pieces: replies, the DATA body, AUTH PLAIN.
public enum Smtp {
    /// Lines of a reply (`250-…` then `250 …`) → its code and text, once the last line has come.
    public static func reply(_ lines: [String]) -> (code: Int, text: String)? {
        guard let last = lines.last, last.count >= 3, let code = Int(last.prefix(3)),
              last.count == 3 || last[last.index(last.startIndex, offsetBy: 3)] == " " else { return nil }
        let text = lines.map { $0.count > 4 ? String($0.dropFirst(4)) : "" }.joined(separator: "\n")
        return (code, text)
    }

    /// A message for DATA: CRLF line ends, a dot doubled at a line's start, ended by `.` alone.
    public static func data(_ message: Data) -> Data {
        let s = String(decoding: message, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var lines = s.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let body = lines.map { $0.hasPrefix(".") ? "." + $0 : $0 }.joined(separator: "\r\n")
        return Data((body + "\r\n.\r\n").utf8)
    }

    /// AUTH PLAIN's argument: base64 of NUL user NUL password.
    public static func plain(user: String, password: String) -> String {
        (Data([0]) + Data(user.utf8) + Data([0]) + Data(password.utf8)).base64EncodedString()
    }
}
