import Foundation

/// The watch's Maps app (cmf-watch-sdk sdk/examples/atlas/src/proto.rs): search, a place, a route checked step by
/// step, then turn by turn (NavProto). Maps come as pictures in bands of 16 colours whose chunks carry their place,
/// so they go over the sliding window (Hub.stream) and may land in any order or twice.
public enum AtlasProto {
    public static let hello = Data("A".utf8)
    public static let navigating = Data("N".utf8)
    public static let chunk = 124
    /// The watch's picture store (proto.rs CAP).
    public static let cap = 36 * 1024

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

    /// A picture (RGB, 3 bytes a pixel) as `M`, `K` per band, `d` chunks: 16 colours per band, fewer and smoothed
    /// until it fits the watch's store.
    public static func picture(id: UInt8, rgb: [UInt8], width w: Int, height h: Int, scale: UInt8 = 2,
                               x0: Int16 = 0, y0: Int16 = 0, bands: Int = 8, cap: Int = cap) -> [Data] {
        var pals: [[UInt16]] = [], offs: [Int] = [], data = Data()
        for (colours, smooth) in [(16, false), (16, true), (10, true), (6, true), (4, true)] {
            pals = []; offs = []; data = Data()
            for k in 0..<bands {
                let r0 = h * k / bands, r1 = h * (k + 1) / bands
                let part = Array(rgb[(3 * w * r0)..<(3 * w * r1)])
                var (palette, idx) = Quantize.refined(rgb: part, colours: colours)
                if smooth { idx = modeFilter(idx, width: w, height: r1 - r0) }
                pals.append((0..<16).map { $0 < palette.count ? Rle.rgb565(palette[$0].0, palette[$0].1, palette[$0].2) : 0 })
                offs.append(data.count)
                data += Rle.tokens(idx, width: w, height: r1 - r0)
            }
            if data.count <= cap { break }
        }
        var m = Data([UInt8(ascii: "M"), id])
        m.le(UInt16(w)); m.le(UInt16(h)); m.append(scale); m.le(x0); m.le(y0)
        m.append(UInt8(bands)); m.le(UInt16(clamping: data.count))
        var out = [m]
        for k in 0..<bands {
            var p = Data([UInt8(ascii: "K"), id, UInt8(k)])
            p.le(UInt16(offs[k]))
            for c in pals[k] { p.le(c) }
            out.append(p)
        }
        out += chunks(id: id, data: data)
        return out
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

    /// Each index takes the most common one of its 3×3 neighbourhood (speckle and anti-aliasing cost a run each).
    static func modeFilter(_ px: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var out = px
        var count = [Int](repeating: 0, count: 16)
        for y in 0..<h {
            for x in 0..<w {
                for i in 0..<16 { count[i] = 0 }
                for yy in max(y - 1, 0)...min(y + 1, h - 1) {
                    for xx in max(x - 1, 0)...min(x + 1, w - 1) { count[Int(px[yy * w + xx] & 15)] += 1 }
                }
                var best = Int(px[y * w + x] & 15)
                for i in 0..<16 where count[i] > count[best] { best = i }
                out[y * w + x] = UInt8(best)
            }
        }
        return out
    }

    /// What the watch asked for.
    public enum Ask: Equatable {
        case ready, home(id: UInt8, zoom: Int), search(String), place(id: UInt8, idx: Int)
        case directions(mode: Int, idx: Int), view(id: UInt8, step: Int), start, stop, again(id: UInt8)
    }

    public static func parse(_ m: Data) -> Ask? {
        let b = [UInt8](m)
        guard let c = b.first else { return nil }
        switch (Character(UnicodeScalar(c)), b.count) {
        case ("R", 1): return .ready
        case ("H", 3): return .home(id: b[1], zoom: Int(b[2]))
        case ("Q", 2...): return .search(String(decoding: b.dropFirst(), as: UTF8.self))
        case ("O", 3): return .place(id: b[1], idx: Int(b[2]))
        case ("D", 3): return .directions(mode: Int(b[1]), idx: Int(b[2]))
        case ("P", 3): return .view(id: b[1], step: Int(b[2]))
        case ("S", 1): return .start
        case ("X", 1): return .stop
        case ("g", 2): return .again(id: b[1])
        default: return nil
        }
    }
}
