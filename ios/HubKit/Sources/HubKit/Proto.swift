import Foundation

/// Bytes that fit `n` without cutting a character.
func utf8(_ s: String, _ n: Int) -> Data {
    var d = Data(s.utf8.prefix(n))
    while !d.isEmpty, String(data: d, encoding: .utf8) == nil { d.removeLast() }
    return d
}

func field(_ s: String, _ n: Int) -> Data {
    let b = utf8(s, n)
    return Data([UInt8(b.count)]) + b
}

/// The watch's Spotify app (cmf-watch-sdk sdk/examples/spotify/src/model.rs).
public enum SpotifyProto {
    public static let playing: UInt8 = 1, premium: UInt8 = 2, liked: UInt8 = 4, shuffle: UInt8 = 8, idle: UInt8 = 16
    public static let artSize = 152

    public static func now(flags: UInt8, pos: Int, dur: Int, vol: Int, title: String, artist: String, device: String) -> Data {
        var m = Data("N".utf8)
        m.append(flags)
        m.le(UInt16(clamping: max(pos, 0))); m.le(UInt16(clamping: max(dur, 0)))
        m.append(UInt8(clamping: min(max(vol, 0), 100)))
        m += field(title, 48) + field(artist, 40)
        return (m + utf8(device, Rle.msgMax - m.count)).prefix(Rle.msgMax)
    }

    /// `L kind n` then `l idx flags title sub` per row (24 at most).
    public static func list(kind: Character, rows: [(title: String, sub: String, active: Bool)]) -> [Data] {
        let k = kind.asciiValue ?? 0
        var out = [Data([UInt8(ascii: "L"), k, UInt8(min(rows.count, 24))])]
        for (i, r) in rows.prefix(24).enumerated() {
            var m = Data([UInt8(ascii: "l"), UInt8(i), r.active ? 1 : 0]) + field(r.title, 40)
            m += utf8(r.sub, Rle.msgMax - m.count)
            out.append(m)
        }
        return out
    }

    public static func note(_ text: String) -> Data { Data("X".utf8) + utf8(text, 60) }

    /// What the watch asked for.
    public enum Ask: Equatable {
        case ready, playPause, next, previous, volume(Int), like, open(Character), search(String), pick(Character, Int)
    }

    public static func parse(_ m: Data) -> Ask? {
        let b = [UInt8](m)
        guard let c = b.first else { return nil }
        switch (Character(UnicodeScalar(c)), b.count) {
        case ("R", _): return .ready
        case ("k", 2): return b[1] == UInt8(ascii: "p") ? .playPause : b[1] == UInt8(ascii: "n") ? .next : .previous
        case ("v", 2): return .volume(Int(b[1]))
        case ("h", _): return .like
        case ("o", 2): return .open(Character(UnicodeScalar(b[1])))
        case ("s", _): return .search(String(decoding: b.dropFirst(), as: UTF8.self))
        case ("p", 3): return .pick(Character(UnicodeScalar(b[1])), Int(b[2]))
        default: return nil
        }
    }
}

/// The watch's Gemini app (the chats app in assistant mode, cmf-watch-sdk sdk/examples/chats/src/model.rs).
public enum GeminiProto {
    public static let prompts = ["Fun fact", "Quick workout idea", "Explain black holes", "Dinner idea", "Motivate me"]
    /// Bytes a bubble takes before the next starts.
    public static let bubble = 90

    public static func hello() -> [Data] {
        [Data([UInt8(ascii: "H"), 1]) + Data("Gemini".utf8)]
            + prompts.enumerated().map { Data([UInt8(ascii: "Q"), UInt8($0.offset)]) + Data($0.element.utf8) }
    }

    /// The watch font has ASCII, Latin-1 and a few marks: no markdown, no emoji.
    public static func clean(_ t: String) -> String {
        var s = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "* ", with: "")
        let keep: Set<UInt32> = [0x2019, 0x201C, 0x201D, 0x2026, 0x2022]
        return String(String.UnicodeScalarView(s.unicodeScalars.filter {
            ($0.value >= 0x20 && $0.value < 0x7F) || ($0.value >= 0xA0 && $0.value <= 0xFF) || keep.contains($0.value)
        }))
    }

    /// Streams answer text: `A 0 0` starts a bubble, `T words…` fills it.
    public struct Streamer {
        var used: Int? = nil
        public init() {}

        public mutating func feed(_ piece: String) -> [Data] {
            var out: [Data] = []
            var word = ""
            func flush(_ w: String) {
                var w = w
                if used == nil || used! + w.utf8.count > bubble {
                    out.append(Data([UInt8(ascii: "A"), 0, 0]))
                    used = 0
                    w = String(w.drop { $0 == " " })
                }
                guard !w.isEmpty else { return }
                out.append(Data("T".utf8) + utf8(w, 120))
                used! += w.utf8.count
            }
            for ch in GeminiProto.clean(piece) {
                word.append(ch)
                if ch == " " { flush(word); word = "" }
            }
            if !word.isEmpty { flush(word) }
            return out
        }

        public func finish() -> [Data] {
            used == nil ? [Data([UInt8(ascii: "A"), 0, 0]) + Data("(no answer)".utf8)] : []
        }
    }

    /// `s id text…` from the watch → the prompt.
    public static func prompt(_ m: Data) -> String? {
        guard m.first == UInt8(ascii: "s"), m.count > 2 else { return nil }
        return String(decoding: m.dropFirst(2), as: UTF8.self)
    }
}

/// The watch's Navigation app (cmf-watch-sdk sdk/examples/nav/src/state.rs).
public enum NavProto {
    /// kind: 0 turn, 1 roundabout, 2 arrive, 3 straight on, 4 fork or ramp. dir: 0 straight, 1 slight left,
    /// 2 left, 3 sharp left, 4 slight right, 5 right, 6 sharp right, 7 U-turn.
    public static func step(idx: Int, kind: UInt8, dir: UInt8, distM: Int, etaMin: Int, leftM: Int, arrive: (Int, Int),
                            street: String) -> Data {
        var m = Data([UInt8(ascii: "V"), UInt8(idx & 0xFF), kind, dir])
        m.le(UInt16(clamping: max(distM, 0))); m.le(UInt16(clamping: max(etaMin, 0)))
        m.le(UInt16(clamping: max(leftM / 10, 0)))
        m.append(UInt8(arrive.0)); m.append(UInt8(arrive.1))
        return m + utf8(street, Rle.msgMax - m.count)
    }

    /// `G n`, then `g off points…` (29 a message), metres east/north of the route's origin.
    public static func route(_ pts: [(Double, Double)]) -> [Data] {
        var g = Data("G".utf8); g.le(UInt16(pts.count))
        var out = [g]
        var off = 0
        while off < pts.count {
            var m = Data("g".utf8); m.le(UInt16(off))
            for (x, y) in pts[off..<min(off + 29, pts.count)] {
                m.le(Int16(clamping: Int(x.rounded()))); m.le(Int16(clamping: Int(y.rounded())))
            }
            out.append(m)
            off += 29
        }
        return out
    }

    public static func position(x: Double, y: Double, heading: Double) -> Data {
        var m = Data("X".utf8)
        m.le(Int16(clamping: Int(x.rounded()))); m.le(Int16(clamping: Int(y.rounded())))
        m.le(UInt16(Int(heading.rounded()) % 360))
        return m
    }

    public static let arrived = Data("W".utf8)
    public static let rerouting = Data("r".utf8)

    /// Douglas–Peucker to at most `max` points (the watch keeps 400).
    public static func simplify(_ pts: [(Double, Double)], max: Int = 400) -> [(Double, Double)] {
        var tol = 1.0
        var out = pts
        while out.count > max {
            out = dp(pts, tol)
            tol *= 1.6
        }
        return out
    }

    static func dp(_ p: [(Double, Double)], _ tol: Double) -> [(Double, Double)] {
        guard p.count > 2 else { return p }
        let (a, b) = (p[0], p[p.count - 1])
        let (dx, dy) = (b.0 - a.0, b.1 - a.1)
        let len = max((dx * dx + dy * dy).squareRoot(), 1e-9)
        var far = 0, farD = 0.0
        for i in 1..<(p.count - 1) {
            let d = abs((p[i].0 - a.0) * dy - (p[i].1 - a.1) * dx) / len
            if d > farD { (far, farD) = (i, d) }
        }
        if farD <= tol { return [a, b] }
        return Array(dp(Array(p[...far]), tol).dropLast()) + dp(Array(p[far...]), tol)
    }
}
