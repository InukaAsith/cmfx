import Foundation

/// Offline map packs for the watch's Offline Maps app (cmf-watch-sdk sdk/examples/maps/src/pack.rs; the Mac's
/// hosts/mapbuild.py builds the same). OSM tiles → the Nothing dark style (a fixed 16 colours), speckle merged,
/// run-length coded; `idx` lists the levels.
public enum MapPack {
    public static let tile = 256
    public static let cap = 32 * 1024
    public static let worldZ = 20

    /// OSM carto colour → the watch's colour (index = palette entry).
    public static let style: [(src: (UInt8, UInt8, UInt8), dst: (UInt8, UInt8, UInt8))] = [
        ((0xF2, 0xEF, 0xE9), (0x0E, 0x0E, 0x0E)), // land
        ((0xE0, 0xDF, 0xDF), (0x13, 0x13, 0x13)), // residential
        ((0xD9, 0xD0, 0xC9), (0x24, 0x24, 0x24)), // building
        ((0xC4, 0xB6, 0xAB), (0x2E, 0x2E, 0x2E)), // building edge
        ((0xFF, 0xFF, 0xFF), (0x6A, 0x6A, 0x6A)), // minor road, label halo
        ((0xF7, 0xFA, 0xBF), (0x9C, 0x9C, 0x9C)), // secondary
        ((0xFC, 0xD6, 0xA4), (0xC4, 0xC4, 0xC4)), // primary
        ((0xF9, 0xB2, 0x9C), (0xE8, 0xE8, 0xE8)), // trunk
        ((0xE8, 0x92, 0xA2), (0xD7, 0x19, 0x21)), // motorway: the red accent
        ((0xAA, 0xD3, 0xDF), (0x15, 0x25, 0x2E)), // water
        ((0xC8, 0xFA, 0xCC), (0x12, 0x21, 0x18)), // park
        ((0xAD, 0xD1, 0x9E), (0x16, 0x27, 0x18)), // grass, wood
        ((0x33, 0x33, 0x33), (0xF0, 0xF0, 0xF0)), // label text
        ((0x77, 0x77, 0x77), (0xA8, 0xA8, 0xA8)), // grey labels, paths
        ((0xDD, 0xDD, 0xE8), (0x1B, 0x1B, 0x22)), // pedestrian areas
        ((0xBB, 0xBB, 0xBB), (0x48, 0x48, 0x48)), // rail, casings
    ]
    /// More OSM colours, drawn as one of the 16 (shops, borders and brown labels would else match the red).
    public static let alias: [((UInt8, UInt8, UInt8), Int)] = [
        ((0xFF, 0xD6, 0xD1), 1), ((0xF2, 0xDA, 0xD9), 1), ((0xEB, 0xDB, 0xE8), 1), ((0xE5, 0xDD, 0xD5), 2),
        ((0xD0, 0x8F, 0x55), 13), ((0x73, 0x4A, 0x08), 13), ((0xC7, 0x7C, 0x7C), 13), ((0xE4, 0xA8, 0xA0), 3),
        ((0xAC, 0x39, 0xAC), 13), ((0x8D, 0x8D, 0x8D), 13), ((0xF5, 0xE9, 0xC6), 1), ((0xDE, 0xF6, 0xC0), 10),
    ]

    public static var palette565: [UInt16] { style.map { Rle.rgb565($0.dst.0, $0.dst.1, $0.dst.2) } }

    /// An OSM tile (RGB, tile × tile) → palette indices: nearest reference colour, then a 3×3 mode filter.
    public static func styled(rgb: [UInt8], size: Int = tile) -> [UInt8] {
        let refs = style.map(\.src) + alias.map(\.0)
        let to = Array(0..<style.count) + alias.map(\.1)
        let near = Quantize.nearest(rgb: rgb, palette: refs).map { UInt8(to[Int($0)]) }
        return modeFilter(near, size: size)
    }

    /// Each pixel takes the most common index of its 3×3 neighbourhood (ties: the pixel's own, then the lowest).
    public static func modeFilter(_ px: [UInt8], size n: Int) -> [UInt8] {
        var out = px
        var count = [Int](repeating: 0, count: 16)
        for y in 0..<n {
            for x in 0..<n {
                for i in 0..<16 { count[i] = 0 }
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < n else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0, xx < n else { continue }
                        count[Int(px[yy * n + xx] & 15)] += 1
                    }
                }
                let own = Int(px[y * n + x] & 15)
                var best = own
                for i in 0..<16 where count[i] > count[best] { best = i }
                out[y * n + x] = UInt8(best)
            }
        }
        return out
    }

    /// One tile file: scale byte, then tokens; 128² drawn doubled when the full size passes `cap`.
    public static func tileFile(_ idx: [UInt8]) -> Data {
        let full = Data([1]) + Rle.tokens(idx, width: tile, height: tile)
        if full.count <= cap { return full }
        let h = tile / 2
        var half = [UInt8](repeating: 0, count: h * h)
        for y in 0..<h { for x in 0..<h { half[y * h + x] = idx[(2 * y) * tile + 2 * x] } }
        return Data([2]) + Rle.tokens(half, width: h, height: h)
    }

    public struct Level: Equatable, Sendable {
        public var z: Int, x0: Int, y0: Int, w: Int, h: Int, mmPerPx: Int
        public init(z: Int, x0: Int, y0: Int, w: Int, h: Int, mmPerPx: Int) {
            (self.z, self.x0, self.y0, self.w, self.h, self.mmPerPx) = (z, x0, y0, w, h, mmPerPx)
        }
    }

    /// Web Mercator world pixels at zoom z.
    public static func world(lat: Double, lon: Double, z: Int) -> (x: Double, y: Double) {
        let s = Double(tile) * pow(2, Double(z))
        let r = lat * .pi / 180
        return ((lon + 180) / 360 * s, (1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * s)
    }

    /// The tile grids round (lat, lon) for `radiusKm`, one per zoom.
    public static func levels(lat: Double, lon: Double, radiusKm: Double, zooms: ClosedRange<Int>) -> [Level] {
        zooms.map { z in
            let (cx, cy) = world(lat: lat, lon: lon, z: z)
            let mpp = 156543.03 * cos(lat * .pi / 180) / pow(2, Double(z))
            let r = radiusKm * 1000 / mpp
            let t = Double(tile)
            let x0 = Int(floor((cx - r) / t)), y0 = Int(floor((cy - r) / t))
            let x1 = Int(floor((cx + r) / t)), y1 = Int(floor((cy + r) / t))
            return Level(z: z, x0: x0, y0: y0, w: min(x1 - x0 + 1, 255), h: min(y1 - y0 + 1, 255),
                         mmPerPx: Int((mpp * 1000).rounded()))
        }
    }

    /// `idx`: WMP1, levels, the palette, per level z x0 y0 w h mm_per_px, then the centre in z20 world pixels.
    public static func index(_ levels: [Level], lat: Double, lon: Double) -> Data {
        var d = Data("WMP1".utf8)
        d.append(UInt8(levels.count))
        for c in palette565 { d.le(c) }
        for l in levels {
            d.append(UInt8(l.z)); d.le(UInt32(l.x0)); d.le(UInt32(l.y0)); d.append(UInt8(l.w)); d.append(UInt8(l.h))
            d.le(UInt32(l.mmPerPx))
        }
        let (x, y) = world(lat: lat, lon: lon, z: worldZ)
        d.le(UInt32(x)); d.le(UInt32(y))
        return d
    }

    public static func tileName(level: Int, col: Int, row: Int) -> String { "t\(level)_\(col)_\(row)" }

    /// The messages of one file: `F name`, `f data…` (127 bytes each), `c`. The watch acks `a`.
    public static func fileMessages(name: String, data: Data) -> [Data] {
        var out = [Data("F".utf8) + Data(name.utf8)]
        var i = data.startIndex
        while i < data.endIndex {
            let j = min(i + Rle.msgMax - 1, data.endIndex)
            out.append(Data("f".utf8) + data[i..<j])
            i = j
        }
        out.append(Data("c".utf8))
        return out
    }

    public static func progress(done: Int, total: Int) -> Data {
        var d = Data("P".utf8); d.le(UInt16(done)); d.le(UInt16(total)); return d
    }

    /// Where the phone is, for the red dot: z20 world pixels.
    public static func position(lat: Double, lon: Double) -> Data {
        let (x, y) = world(lat: lat, lon: lon, z: worldZ)
        var d = Data("X".utf8); d.le(UInt32(x)); d.le(UInt32(y)); return d
    }
}
