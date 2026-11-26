import Foundation

/// Offline Maps' map (cmf-watch-sdk sdk/examples/maps/src/pack.rs): OpenStreetMap vector data (OpenFreeMap) cut into
/// square cells at three levels, each cell a file of Maps' scene records (AtlasScene) clipped to its square, in
/// metres of one frame round the area's centre. The watch draws them itself, as Maps draws its map, so a city or a
/// hike tens of km across fits: the overview (main roads, water, towns) reaches the whole area, streets and paths
/// the part round the centre you pick.
public enum VectorPack {
    public struct Level: Equatable, Sendable {
        /// cell side, metres; tile zoom read; drawn from watch zoom `minK` (px a metre × 256) on
        public var side: Int, z: Int, minK: Int
        /// grid: south-west corner (x0 = y0), cells a side
        public var x0: Int, n: Int
        /// the largest road class kept (AtlasScene: 0 motorway … 5 path, 6 rail, 7 waterway); POI labels kept
        public var maxRoad: Int, pois: Int
        public var tol: Double
    }

    /// The farthest the frame reaches (i16 metres, a cell's margin spare).
    public static let maxRadiusKm = 28.0
    public static let maxDetailKm = 8.0

    /// The levels for an area of `radiusKm` with streets and paths `detailKm` round the centre.
    public static func levels(radiusKm: Double, detailKm: Double) -> [Level] {
        let r = min(radiusKm, maxRadiusKm) * 1000
        let d = min(detailKm, maxDetailKm, radiusKm) * 1000
        func grid(_ side: Int, _ reach: Double) -> (Int, Int) {
            let k = max(1, Int((reach / Double(side)).rounded(.up)))
            return (-k * side, 2 * k)
        }
        let specs: [(side: Int, z: Int, minK: Int, reach: Double, maxRoad: Int, pois: Int, tol: Double)] = [
            (8000, 11, 0, r, AtlasScene.secondary, 0, 10),
            (3000, 12, 24, min(r, 10_000), AtlasScene.tertiary, 0, 4),
            (1500, 14, 60, d, AtlasScene.waterway, 48, 1),
        ]
        return specs.map { s in
            let (x0, n) = grid(s.side, s.reach)
            return Level(side: s.side, z: s.z, minK: s.minK, x0: x0, n: n, maxRoad: s.maxRoad, pois: s.pois, tol: s.tol)
        }
    }

    public static func cellCount(_ levels: [Level]) -> Int { levels.reduce(0) { $0 + $1.n * $1.n } }

    /// `idx`: WMV1, lat0 lon0 (1e-7°), mm a degree of longitude, levels, then per level side x0 y0 cols rows min_k.
    public static func index(_ levels: [Level], lat: Double, lon: Double) -> Data {
        var d = Data("WMV1".utf8)
        d.le(Int32((lat * 1e7).rounded())); d.le(Int32((lon * 1e7).rounded()))
        d.le(UInt32((cos(lat * .pi / 180) * 111_320_000).rounded()))
        d.append(UInt8(levels.count))
        for l in levels {
            d.le(UInt16(l.side)); d.le(Int16(l.x0)); d.le(Int16(l.x0))
            d += Data([UInt8(l.n), UInt8(l.n), UInt8(l.minK)])
        }
        return d
    }

    public static func cellName(level: Int, col: Int, row: Int) -> String { "v\(level)_\(col)_\(row)" }

    /// Cell (col, row)'s square: south-west and north-east corners, frame metres.
    public static func square(_ l: Level, col: Int, row: Int) -> (lo: AtlasScene.Pt, hi: AtlasScene.Pt) {
        let x = Double(l.x0 + col * l.side), y = Double(l.x0 + row * l.side), s = Double(l.side)
        return ((x, y), (x + s, y + s))
    }

    /// The zoom-`l.z` tiles under a cell.
    public static func tiles(_ l: Level, col: Int, row: Int, origin o: AtlasScene.LatLon) -> [(x: Int, y: Int)] {
        let (lo, hi) = square(l, col: col, row: row)
        let c = ((lo.0 + hi.0) / 2, (lo.1 + hi.1) / 2)
        return AtlasScene.tiles(round: c, r: Double(l.side) / 2 + 30, origin: o, z: l.z)
    }

    /// The most a cell may take: the watch reads one at a time into a 16 KB buffer (maps main.rs SCENE_CAP).
    public static let cellMax = 16 * 1024 - 64

    /// One cell's records from the tiles under it (empty: nothing there, no file), under `cellMax`: a dense one
    /// keeps fewer places of interest, then simpler lines, then fewer kinds of roads.
    public static func cell(_ tiles: [(tile: (x: Int, y: Int), features: [AtlasScene.Feature])], level l: Level,
                            col: Int, row: Int, origin o: AtlasScene.LatLon) -> Data {
        let items = cellItems(tiles, level: l, col: col, row: row, origin: o)
        var pois = l.pois, tol = l.tol, maxRoad = l.maxRoad
        var data = Data()
        for _ in 0..<8 {
            var n = 0
            let keep = items.filter { it in
                switch it.kind {
                case .line, .carrier: return it.cls <= maxRoad
                case .label where it.cls == AtlasScene.poi || it.cls >= AtlasScene.food:
                    n += 1
                    return n <= pois
                default: return true
                }
            }
            data = AtlasScene.build(keep, tol: tol).data
            if data.count <= cellMax { return data }
            if pois > 0 { pois /= 2 } else if tol < l.tol * 4 { tol *= 1.6 } else { maxRoad = max(maxRoad - 1, AtlasScene.motorway) }
        }
        return data.count <= cellMax ? data : Data()
    }

    /// A cell's items, clipped to it.
    static func cellItems(_ tiles: [(tile: (x: Int, y: Int), features: [AtlasScene.Feature])], level l: Level,
                          col: Int, row: Int, origin o: AtlasScene.LatLon) -> [AtlasScene.Item] {
        let (lo, hi) = square(l, col: col, row: row)
        let c = ((lo.0 + hi.0) / 2, (lo.1 + hi.1) / 2)
        let feats = tiles.flatMap { t in t.features.map { (tile: t.tile, f: $0) } }
        // a wide square first (a road crossing the cell with no point in it), then cut exactly to the cell
        var out: [AtlasScene.Item] = []
        var pois = 0
        let minArea = l.tol * l.tol * 64
        for it in AtlasScene.items(feats, origin: o, centre: c, r: Double(l.side), z: l.z) {
            switch it.kind {
            case .area:
                let xs = it.pts.map(\.0), ys = it.pts.map(\.1)
                guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(),
                      (x1 - x0) * (y1 - y0) >= minArea else { continue }
                let ring = clipRing(it.pts, lo, hi)
                if ring.count >= 3 { out.append(.init(kind: .area, cls: it.cls, pts: ring)) }
            case .line, .carrier:
                guard it.cls <= l.maxRoad else { continue }
                for piece in clipLine(it.pts, lo, hi) where piece.count >= 2 {
                    out.append(.init(kind: it.kind, cls: it.cls, pts: piece, name: it.name))
                }
            case .label:
                let p = it.pts[0]
                guard lo.0 <= p.0, p.0 < hi.0, lo.1 <= p.1, p.1 < hi.1 else { continue }
                let isPOI = it.cls == AtlasScene.poi || it.cls >= AtlasScene.food
                if isPOI {
                    guard pois < l.pois else { continue }
                    pois += 1
                }
                out.append(it)
            }
        }
        return out
    }

    // MARK: names for search

    /// A name on the map for the watch's search (find.rs): kind 0 place, 1 and 3 … 12 places of interest, 2 water,
    /// 20 a street; frame metres.
    public struct Named: Equatable, Sendable {
        public var kind: Int, x: Int, y: Int, name: String
        public init(kind: Int, x: Int, y: Int, name: String) { (self.kind, self.x, self.y, self.name) = (kind, x, y, name) }
    }
    public static let street = 20
    public static let namesMax = 3000

    /// The names in a cell: its labels, and each street once (a point of it inside the cell).
    public static func names(_ tiles: [(tile: (x: Int, y: Int), features: [AtlasScene.Feature])], level l: Level,
                             col: Int, row: Int, origin o: AtlasScene.LatLon) -> [Named] {
        var out: [Named] = []
        var streets: Set<String> = []
        for it in cellItems(tiles, level: l, col: col, row: row, origin: o) where !it.name.isEmpty {
            switch it.kind {
            case .label:
                let p = it.pts[0]
                out.append(Named(kind: it.cls, x: Int(p.0.rounded()), y: Int(p.1.rounded()), name: it.name))
            case .line, .carrier:
                guard it.cls <= AtlasScene.path, !streets.contains(it.name), let p = it.pts.dropFirst(it.pts.count / 2).first else { continue }
                streets.insert(it.name)
                out.append(Named(kind: street, x: Int(p.0.rounded()), y: Int(p.1.rounded()), name: it.name))
            default: break
            }
        }
        return out
    }

    /// The `n` file: `WMN1`, then `kind:u8 x:i16 y:i16 len:u8 text` each. The same name within 300 m once; places
    /// first, then places of interest, water, streets; `namesMax` at most.
    public static func namesFile(_ all: [Named]) -> Data {
        func rank(_ k: Int) -> Int { k == 0 ? 0 : k == 2 ? 2 : k == street ? 3 : 1 }
        var kept: [String: [Named]] = [:]
        var order: [Named] = []
        for n in all.sorted(by: { rank($0.kind) < rank($1.kind) }) {
            let key = n.name.lowercased()
            if kept[key, default: []].contains(where: { hypot(Double($0.x - n.x), Double($0.y - n.y)) < 300 }) { continue }
            kept[key, default: []].append(n)
            order.append(n)
            if order.count >= namesMax { break }
        }
        var d = Data("WMN1".utf8)
        for n in order {
            let t = AtlasScene.text(n.name, 40)
            d.append(UInt8(clamping: n.kind))
            d.le(AtlasScene.i16(Double(n.x))); d.le(AtlasScene.i16(Double(n.y)))
            d.append(UInt8(t.count)); d += t
        }
        return d
    }

    // MARK: clipping to a cell

    /// The parts of a line inside the square [lo, hi], cut at its sides.
    public static func clipLine(_ pts: [AtlasScene.Pt], _ lo: AtlasScene.Pt, _ hi: AtlasScene.Pt) -> [[AtlasScene.Pt]] {
        var out: [[AtlasScene.Pt]] = [], cur: [AtlasScene.Pt] = []
        for i in 1..<max(pts.count, 1) {
            let a = pts[i - 1], b = pts[i]
            let dx = b.0 - a.0, dy = b.1 - a.1
            var t0 = 0.0, t1 = 1.0, hit = true
            for (p, q) in [(-dx, a.0 - lo.0), (dx, hi.0 - a.0), (-dy, a.1 - lo.1), (dy, hi.1 - a.1)] {
                if p == 0 {
                    if q < 0 { hit = false; break }
                } else {
                    let r = q / p
                    if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
                    if t0 > t1 { hit = false; break }
                }
            }
            guard hit else {
                if !cur.isEmpty { out.append(cur); cur = [] }
                continue
            }
            let s = (a.0 + dx * t0, a.1 + dy * t0), e = (a.0 + dx * t1, a.1 + dy * t1)
            if cur.isEmpty || t0 > 0 {
                if !cur.isEmpty { out.append(cur) }
                cur = [s]
            }
            cur.append(e)
            if t1 < 1 { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.filter { $0.count >= 2 }
    }

    /// A ring cut to the square [lo, hi] (Sutherland–Hodgman: the square's sides become part of it).
    public static func clipRing(_ ring: [AtlasScene.Pt], _ lo: AtlasScene.Pt, _ hi: AtlasScene.Pt) -> [AtlasScene.Pt] {
        var pts = ring
        let edges: [(inside: (AtlasScene.Pt) -> Bool, cut: (AtlasScene.Pt, AtlasScene.Pt) -> AtlasScene.Pt)] = [
            ({ $0.0 >= lo.0 }, { a, b in (lo.0, a.1 + (b.1 - a.1) * (lo.0 - a.0) / (b.0 - a.0)) }),
            ({ $0.0 <= hi.0 }, { a, b in (hi.0, a.1 + (b.1 - a.1) * (hi.0 - a.0) / (b.0 - a.0)) }),
            ({ $0.1 >= lo.1 }, { a, b in (a.0 + (b.0 - a.0) * (lo.1 - a.1) / (b.1 - a.1), lo.1) }),
            ({ $0.1 <= hi.1 }, { a, b in (a.0 + (b.0 - a.0) * (hi.1 - a.1) / (b.1 - a.1), hi.1) }),
        ]
        for e in edges {
            guard !pts.isEmpty else { break }
            var next: [AtlasScene.Pt] = []
            for i in 0..<pts.count {
                let a = pts[(i + pts.count - 1) % pts.count], b = pts[i]
                switch (e.inside(a), e.inside(b)) {
                case (true, true): next.append(b)
                case (true, false): next.append(e.cut(a, b))
                case (false, true): next += [e.cut(a, b), b]
                case (false, false): break
                }
            }
            pts = next
        }
        return pts
    }

    // MARK: routes for the watch

    /// The watch asks for a route: `D mode lat0 lon0 from_x from_y to_x to_y` (mode 0 drive, 2 walk; from i16.min:
    /// where the phone is).
    public struct RouteAsk: Equatable, Sendable {
        /// 0 car, 1 bike, 2 walk
        public var mode: Int
        public var walk: Bool { mode == 2 }
        public var origin: (lat: Double, lon: Double)
        public var from: (Double, Double)?
        public var to: (Double, Double)
        public static func == (a: Self, b: Self) -> Bool {
            a.mode == b.mode && a.origin == b.origin && a.from.map { [$0.0, $0.1] } == b.from.map { [$0.0, $0.1] }
                && a.to == b.to
        }
    }

    public static func parseAsk(_ m: Data) -> RouteAsk? {
        let b = [UInt8](m)
        guard b.count == 18, b[0] == UInt8(ascii: "D") else { return nil }
        func i32(_ i: Int) -> Int32 { Int32(bitPattern: UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24) }
        func i16(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8) }
        let fx = i16(10), fy = i16(12)
        return RouteAsk(mode: Int(min(b[1], 2)), origin: (Double(i32(2)) / 1e7, Double(i32(6)) / 1e7),
                        from: fx == .min ? nil : (Double(fx), Double(fy)), to: (Double(i16(14)), Double(i16(16))))
    }

    public static let routeMax = 1500
    static let perMessage = 30

    /// A route (frame metres) as `G n metres secs` then `g seq points…`: simplified until it fits the watch.
    public static func route(_ pts: [AtlasScene.Pt], metres: Double, secs: Double) -> [Data] {
        var tol = 2.0, p = AtlasScene.simplify(pts, tol)
        while p.count > routeMax { tol *= 1.5; p = AtlasScene.simplify(pts, tol) }
        var head = Data("G".utf8)
        head.le(UInt16(p.count)); head.le(UInt32(max(0, metres))); head.le(UInt32(max(0, secs)))
        var out = [head]
        for (k, i) in stride(from: 0, to: p.count, by: perMessage).enumerated() {
            var d = Data([UInt8(ascii: "g"), UInt8(k)])
            for q in p[i..<min(i + perMessage, p.count)] {
                d.le(AtlasScene.i16(q.0)); d.le(AtlasScene.i16(q.1))
            }
            out.append(d)
        }
        return out
    }

    public static func routeFailed(_ why: String) -> Data { Data("E".utf8) + AtlasScene.text(why, 40) }

    /// The routes found by one mode (0 car, 1 bike, 2 walk): `O mode n` (0: none), then `o mode k secs:u32
    /// metres:u32` each (the watch picks one with `p mode k`).
    public static func ways(mode: Int, _ r: [(secs: Double, metres: Double)]) -> [Data] {
        var out = [Data([UInt8(ascii: "O"), UInt8(mode), UInt8(r.count)])]
        for (k, w) in r.enumerated() {
            var d = Data([UInt8(ascii: "o"), UInt8(mode), UInt8(k)])
            d.le(UInt32(max(0, w.secs))); d.le(UInt32(max(0, w.metres)))
            out.append(d)
        }
        return out
    }

    /// A turn of a route, as Navigation's (nav state.rs): kind 0 turn, 1 roundabout, 2 arrive, 3 straight on, 4 fork
    /// or ramp; dir 0 straight, 1 slight left, 2 left, 3 sharp left, 4 slight right, 5 right, 6 sharp right, 7 U-turn.
    public struct Turn: Equatable, Sendable {
        public var kind: Int, dir: Int, at: AtlasScene.Pt, street: String
        public init(kind: Int, dir: Int, at: AtlasScene.Pt, street: String) {
            (self.kind, self.dir, self.at, self.street) = (kind, dir, at, street)
        }
        public static func == (a: Turn, b: Turn) -> Bool {
            a.kind == b.kind && a.dir == b.dir && a.at == b.at && a.street == b.street
        }
    }
    public static let turnsMax = 64

    /// The route's turns for the watch: `S n`, then `s k kind dir x:i16 y:i16 street` each (sent before its points).
    public static func turns(_ t: [Turn]) -> [Data] {
        let t = Array(t.prefix(turnsMax))
        var out = [Data([UInt8(ascii: "S"), UInt8(t.count)])]
        for (k, s) in t.enumerated() {
            var d = Data([UInt8(ascii: "s"), UInt8(k), UInt8(s.kind), UInt8(s.dir)])
            d.le(AtlasScene.i16(s.at.0)); d.le(AtlasScene.i16(s.at.1))
            d += AtlasScene.text(s.street, 32)
            out.append(d)
        }
        return out
    }

    static let dirs: [String: Int] = ["straight": 0, "slight left": 1, "left": 2, "sharp left": 3, "slight right": 4,
                                      "right": 5, "sharp right": 6, "uturn": 7]

    /// OSRM's manoeuvre as a turn (kind, dir); nil for the start.
    public static func osrmTurn(_ type: String, _ modifier: String?) -> (Int, Int)? {
        let d = dirs[modifier ?? "straight"] ?? 0
        switch type {
        case "depart": return nil
        case "arrive": return (2, 0)
        case "roundabout", "rotary", "roundabout turn", "exit roundabout", "exit rotary": return (1, d)
        case "fork", "on ramp", "off ramp", "merge": return (4, d)
        case "continue", "new name" where d == 0: return (3, 0)
        default: return (0, d)
        }
    }

    /// Apple's step words as a turn, roughly.
    public static func appleTurn(_ words: String, last: Bool) -> (Int, Int) {
        let w = words.lowercased()
        if last || w.contains("arrive") || w.contains("destination") { return (2, 0) }
        if w.contains("u-turn") { return (0, 7) }
        if w.contains("roundabout") { return (1, 0) }
        let slight = w.contains("slight") || w.contains("keep") || w.contains("bear")
        if w.contains("left") { return slight ? (4, 1) : (0, 2) }
        if w.contains("right") { return slight ? (4, 4) : (0, 5) }
        return (3, 0)
    }
}

extension VectorPack {
    /// `P done total`: the watch shows it while saving (and drops the old map on the first).
    public static func progressMessage(done: Int, total: Int) -> Data {
        var d = Data("P".utf8); d.le(UInt16(min(done, 65535))); d.le(UInt16(min(total, 65535))); return d
    }
}
