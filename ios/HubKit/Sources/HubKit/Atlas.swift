import Foundation

/// The watch's Maps app (cmf-watch-sdk sdk/examples/atlas/src/proto.rs): search, a place, a route checked step by
/// step, then turn by turn (NavProto). The map goes as data the watch draws (AtlasScene, scene.rs) in chunks that
/// carry their place, so they go over the sliding window (Hub.stream) and may land in any order or twice.
public enum AtlasProto {
    public static let hello = Data("A".utf8)
    public static let navigating = Data("N".utf8)
    public static let chunk = 124

    public static func error(_ t: String) -> Data { Data("E".utf8) + utf8(t, 59) }

    /// The place a pin on the map stands for (`P`): after the search's 8.
    public static let picked = 8

    public typealias Row = (name: String, sub: String, dist: Int, at: (Double, Double))

    /// `L n [near]`, then `l idx dist:u32 x:i16 y:i16 name 0 sub…` (8 at most; `at` frame metres, NaN: not on this
    /// map, sent as -32768). `near` > 0: a mixed search, the first `near` round us, the rest round a town far away.
    public static func results(_ rows: [Row], near: Int = 0) -> [Data] {
        let rows = rows.prefix(8)
        let head = near > 0 ? Data([UInt8(ascii: "L"), UInt8(rows.count), UInt8(min(near, rows.count))])
            : Data([UInt8(ascii: "L"), UInt8(rows.count)])
        return [head] + rows.enumerated().map { row($0.offset, $0.element) }
    }

    /// One `l`.
    public static func row(_ i: Int, _ r: Row) -> Data {
        var m = Data([UInt8(ascii: "l"), UInt8(i)])
        m.le(UInt32(clamping: max(r.dist, 0)))
        if r.at.0.isNaN {
            m.le(Int16.min); m.le(Int16.min)
        } else {
            m.le(AtlasScene.i16(r.at.0)); m.le(AtlasScene.i16(r.at.1))
        }
        let name = utf8(r.name, 44)
        return m + name + Data([0]) + utf8(r.sub, Rle.msgMax - m.count - name.count - 1)
    }

    /// `i idx k text`: line k (0 kind, 1 address, 2 phone, 3 more) about result idx; empty lines are left out.
    public static func info(_ idx: Int, _ lines: [String]) -> [Data] {
        lines.prefix(4).enumerated().compactMap { k, t in
            t.isEmpty ? nil : Data([UInt8(ascii: "i"), UInt8(idx), UInt8(k)]) + utf8(t, Rle.msgMax - 3)
        }
    }

    /// `i idx k text` for k 4 and up: the place's description in pieces (480 bytes at most, whole characters).
    public static func about(_ idx: Int, _ text: String) -> [Data] {
        var pieces: [String] = [""]
        var total = 0
        for ch in text {
            let n = String(ch).utf8.count
            if total + n > 480 { break }
            if pieces[pieces.count - 1].utf8.count + n > Rle.msgMax - 3 { pieces.append("") }
            pieces[pieces.count - 1].append(ch)
            total += n
        }
        return pieces.enumerated().filter { !$0.element.isEmpty }.map {
            Data([UInt8(ascii: "i"), UInt8(idx), UInt8(4 + $0.offset)]) + Data($0.element.utf8)
        }
    }

    /// `w k part unit pts…`: way k's line (frame metres), at most 60 points, 30 a message; `unit` metres a step so
    /// that the farthest point fits an i16.
    public static func altLines(_ lines: [[(Double, Double)]]) -> [Data] {
        let far = lines.joined().map { max(abs($0.0), abs($0.1)) }.max() ?? 0
        let unit = max(1, Int((far / 32000).rounded(.up)))
        var out: [Data] = []
        for (k, line) in lines.prefix(3).enumerated() {
            // evenly thinned, the ends kept
            let pts: [(Double, Double)] = line.count <= 60 ? line
                : (0..<60).map { line[Int((Double($0) * Double(line.count - 1) / 59).rounded())] }
            for (part, start) in stride(from: 0, to: pts.count, by: 30).enumerated() {
                var m = Data([UInt8(ascii: "w"), UInt8(k), UInt8(part)])
                m.le(UInt16(unit))
                for p in pts[start..<min(start + 30, pts.count)] {
                    m.le(AtlasScene.i16(p.0 / Double(unit))); m.le(AtlasScene.i16(p.1 / Double(unit)))
                }
                out.append(m)
            }
        }
        return out
    }

    /// `O n`, then `o k secs metres hh mm via…`: the ways there to pick (2 or 3).
    public static func alternatives(_ alts: [(secs: Double, metres: Double, arrive: (Int, Int), via: String)]) -> [Data] {
        let alts = alts.prefix(3)
        var out = [Data([UInt8(ascii: "O"), UInt8(alts.count)])]
        for (k, a) in alts.enumerated() {
            var m = Data([UInt8(ascii: "o"), UInt8(k)])
            m.le(UInt32(clamping: Int(a.secs.rounded()))); m.le(UInt32(clamping: Int(a.metres.rounded())))
            m += Data([UInt8(a.arrive.0), UInt8(a.arrive.1)])
            out.append(m + utf8(a.via, 40))
        }
        return out
    }

    /// `u mode ok secs metres hh mm`: the way there by car (0), bike (1) or on foot (2); nil: no route that way.
    public static func way(mode: UInt8, _ r: (secs: Double, metres: Double, arrive: (Int, Int))?) -> Data {
        var m = Data([UInt8(ascii: "u"), mode, r == nil ? 0 : 1])
        m.le(UInt32(clamping: Int((r?.secs ?? 0).rounded()))); m.le(UInt32(clamping: Int((r?.metres ?? 0).rounded())))
        return m + Data([UInt8(r?.arrive.0 ?? 0), UInt8(r?.arrive.1 ?? 0)])
    }

    /// `T mode secs metres n hh mm`, then `t k kind dir at name` per step (48 at most).
    public static func route(mode: UInt8, secs: Double, metres: Double, arrive: (Int, Int),
                             steps: [(at: Double, kind: UInt8, dir: UInt8, name: String)]) -> [Data] {
        let steps = steps.prefix(48)
        var t = Data([UInt8(ascii: "T"), mode])
        t.le(UInt32(clamping: Int(secs.rounded()))); t.le(UInt32(clamping: Int(metres.rounded())))
        t += Data([UInt8(steps.count), UInt8(arrive.0), UInt8(arrive.1)])
        var out = [t]
        for (k, s) in steps.enumerated() {
            var m = Data([UInt8(ascii: "t"), UInt8(k), s.kind, s.dir])
            m.le(UInt32(clamping: Int(max(s.at, 0).rounded())))
            out.append(m + utf8(s.name, Rle.msgMax - m.count))
        }
        return out
    }

    /// A scene (AtlasScene) as `S id total me_x me_y cx cy r`, then its `d` chunks: `me` where we are, the square
    /// it covers (centre, half side), frame metres.
    public static func scene(id: UInt8, data: Data, me: (Double, Double), centre: (Double, Double), r: Double) -> [Data] {
        var m = Data([UInt8(ascii: "S"), id])
        m.le(UInt16(clamping: data.count))
        for v in [me.0, me.1, centre.0, centre.1] { m.le(AtlasScene.i16(v)) }
        m.le(UInt16(clamping: Int(r.rounded())))
        return [m] + chunks(id: id, data: data)
    }

    static func chunks(id: UInt8, data: Data) -> [Data] {
        var out: [Data] = []
        var seq = 0, i = data.startIndex
        while i < data.endIndex {
            let j = min(i + chunk, data.endIndex)
            var d = Data([UInt8(ascii: "d"), id])
            d.le(UInt16(seq))
            out.append(d + data[i..<j])
            seq += 1
            i = j
        }
        return out
    }

    /// What the watch asked for.
    public enum Ask: Equatable {
        /// home: the map round where we are (`round` nil: a new frame may start there) or round a frame point
        case ready, home(id: UInt8, round: (x: Int, y: Int)?), ways(idx: Int)
        /// search, category, area: the map round the answer comes as scene `id`, in a new frame
        case search(id: UInt8, String), category(id: UInt8, Int), area(id: UInt8, String)
        /// a place on the map (a pin tapped, or dropped: no name), frame metres; what is known of result idx
        case pick(x: Int, y: Int, name: String), info(idx: Int)
        /// the search's places cleared on the watch (✕)
        case clear
        /// a mixed search's other group: the map round result idx's group as scene `id`
        case focusRow(id: UInt8, idx: Int)
        /// directions: the route's map comes as scene `id`; `alt` the way picked of those `O` listed
        case directions(mode: Int, idx: Int, id: UInt8, alt: Int?), start, stop, again(id: UInt8)

        public static func == (a: Ask, b: Ask) -> Bool {
            switch (a, b) {
            case (.ready, .ready), (.start, .start), (.stop, .stop), (.clear, .clear): return true
            case let (.home(i, r), .home(j, s)): return i == j && r?.x == s?.x && r?.y == s?.y
            case let (.search(i, p), .search(j, q)), let (.area(i, p), .area(j, q)): return i == j && p == q
            case let (.category(i, p), .category(j, q)): return i == j && p == q
            case let (.pick(x, y, n), .pick(u, v, m)): return x == u && y == v && n == m
            case let (.ways(i), .ways(j)), let (.info(i), .info(j)): return i == j
            case let (.focusRow(i, p), .focusRow(j, q)): return i == j && p == q
            case let (.directions(m, i, d, a), .directions(n, j, e, b)): return m == n && i == j && d == e && a == b
            case let (.again(i), .again(j)): return i == j
            default: return false
            }
        }
    }

    public static func parse(_ m: Data) -> Ask? {
        let b = [UInt8](m)
        guard let c = b.first else { return nil }
        switch (Character(UnicodeScalar(c)), b.count) {
        case ("R", 1): return .ready
        case ("H", 7):
            let x = Int(Int16(bitPattern: UInt16(b[3]) | UInt16(b[4]) << 8))
            let y = Int(Int16(bitPattern: UInt16(b[5]) | UInt16(b[6]) << 8))
            return .home(id: b[1], round: b[2] == 1 ? nil : (x, y))
        case ("Q", 3...): return .search(id: b[1], String(decoding: b.dropFirst(2), as: UTF8.self))
        case ("Z", 3...): return .area(id: b[1], String(decoding: b.dropFirst(2), as: UTF8.self))
        case ("C", 3): return .category(id: b[1], Int(b[2]))
        case ("P", 5...):
            let x = Int(Int16(bitPattern: UInt16(b[1]) | UInt16(b[2]) << 8))
            let y = Int(Int16(bitPattern: UInt16(b[3]) | UInt16(b[4]) << 8))
            return .pick(x: x, y: y, name: String(decoding: b.dropFirst(5), as: UTF8.self))
        case ("I", 2): return .info(idx: Int(b[1]))
        case ("K", 1): return .clear
        case ("F", 3): return .focusRow(id: b[1], idx: Int(b[2]))
        case ("U", 2): return .ways(idx: Int(b[1]))
        case ("D", 4): return .directions(mode: Int(b[1]), idx: Int(b[2]), id: b[3], alt: nil)
        case ("D", 5): return .directions(mode: Int(b[1]), idx: Int(b[2]), id: b[3], alt: Int(b[4]))
        case ("S", 1): return .start
        case ("X", 1): return .stop
        case ("g", 2): return .again(id: b[1])
        default: return nil
        }
    }
}
