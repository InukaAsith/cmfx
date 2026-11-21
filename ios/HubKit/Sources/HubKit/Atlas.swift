import Foundation

/// The watch's Maps app (cmf-watch-sdk sdk/examples/atlas/src/proto.rs): search, a place, a route checked step by
/// step, then turn by turn (NavProto). The map goes as data the watch draws (AtlasScene, scene.rs) in chunks that
/// carry their place, so they go over the sliding window (Hub.stream) and may land in any order or twice.
public enum AtlasProto {
    public static let hello = Data("A".utf8)
    public static let navigating = Data("N".utf8)
    public static let chunk = 124

    public static func error(_ t: String) -> Data { Data("E".utf8) + utf8(t, 59) }

    /// `L n`, then `l idx dist:u32 name 0 sub…` (8 at most).
    public static func results(_ rows: [(name: String, sub: String, dist: Int)]) -> [Data] {
        let rows = rows.prefix(8)
        var out = [Data([UInt8(ascii: "L"), UInt8(rows.count)])]
        for (i, r) in rows.enumerated() {
            var m = Data([UInt8(ascii: "l"), UInt8(i)])
            m.le(UInt32(clamping: max(r.dist, 0)))
            let name = utf8(r.name, 44)
            m += name + Data([0]) + utf8(r.sub, Rle.msgMax - m.count - name.count - 1)
            out.append(m)
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
        case ready, home(id: UInt8, round: (x: Int, y: Int)?), search(String), ways(idx: Int)
        /// directions: the route's map comes as scene `id`
        case directions(mode: Int, idx: Int, id: UInt8), start, stop, again(id: UInt8)

        public static func == (a: Ask, b: Ask) -> Bool {
            switch (a, b) {
            case (.ready, .ready), (.start, .start), (.stop, .stop): return true
            case let (.home(i, r), .home(j, s)): return i == j && r?.x == s?.x && r?.y == s?.y
            case let (.search(p), .search(q)): return p == q
            case let (.ways(i), .ways(j)): return i == j
            case let (.directions(m, i, d), .directions(n, j, e)): return m == n && i == j && d == e
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
        case ("Q", 2...): return .search(String(decoding: b.dropFirst(), as: UTF8.self))
        case ("U", 2): return .ways(idx: Int(b[1]))
        case ("D", 4): return .directions(mode: Int(b[1]), idx: Int(b[2]), id: b[3])
        case ("S", 1): return .start
        case ("X", 1): return .stop
        case ("g", 2): return .again(id: b[1])
        default: return nil
        }
    }
}
