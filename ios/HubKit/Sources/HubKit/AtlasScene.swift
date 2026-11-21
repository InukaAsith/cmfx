import Foundation

/// The map for the watch's Maps app as data (cmf-watch-sdk sdk/examples/atlas/src/scene.rs has the format; the watch
/// draws it, render.rs): OpenStreetMap's water, parks, roads from paths up to motorways, street names, places and
/// places of interest round a point, from OpenMapTiles vector tiles (OpenFreeMap, zoom 14), in metres east (x) and
/// north (y) of a frame origin, as much as fits the watch's store. The same as cmf-watch-sdk hosts/atlasscene.py.
public enum AtlasScene {
    /// The watch's store (scene.rs CAP), less a margin.
    public static let cap = 32 * 1024 - 512
    public static let zoom = 14
    static let maxRing = 512

    // record kinds and classes (scene.rs)
    static let area: UInt8 = 0x10, line: UInt8 = 0x20, name: UInt8 = 0x30, label: UInt8 = 0x40
    static let water = 0, park = 1
    static let motorway = 0, primary = 1, secondary = 2, tertiary = 3, minor = 4, path = 5, rail = 6, waterway = 7
    static let carrier = 8
    static let place = 0, poi = 1, waterName = 2
    /// kinds of places of interest: food, shop, green, transit, health, learning and worship, stay, culture, money,
    /// car (label classes 3 … 12), a searched place (13, a red pin)
    public static let food = 3, shop = 4, greenPOI = 5, transit = 6, health = 7, learn = 8, stay = 9, culture = 10,
        money = 11, car = 12, searched = 13

    static let road: [String: Int] = [
        "motorway": motorway, "trunk": motorway, "primary": primary, "secondary": secondary, "tertiary": tertiary,
        "minor": minor, "service": minor, "residential": minor, "unclassified": minor, "living_street": minor,
        "raceway": minor, "busway": minor, "path": path, "track": path, "pedestrian": path, "footway": path,
        "cycleway": path, "steps": path, "bridleway": path, "rail": rail, "transit": rail,
    ]
    static let green: Set<String> = ["grass", "wood", "park", "garden", "forest", "meadow", "recreation_ground",
                                     "cemetery", "golf_course"]
    static let places: Set<String> = ["suburb", "neighbourhood", "quarter", "village", "town", "hamlet", "city"]
    static let poiKind: [String: Int] = {
        var m: [String: Int] = [:]
        for (kind, names) in [
            (food, ["restaurant", "cafe", "fast_food", "bar", "beer", "ice_cream", "bakery", "food_court", "pub"]),
            (shop, ["shop", "grocery", "clothing_store", "supermarket", "jewelry", "mobile_phone", "books", "hardware",
                    "furniture", "electronics", "alcohol_shop", "convenience", "department_store", "gift", "shoes",
                    "marketplace", "florist", "laundry", "hairdresser"]),
            (greenPOI, ["park", "garden", "playground", "pitch", "sports", "stadium", "swimming", "golf", "zoo",
                        "dog_park", "campsite"]),
            (transit, ["bus", "railway", "ferry_terminal", "airport", "aerialway", "harbor", "bicycle_rental", "taxi"]),
            (health, ["hospital", "doctors", "pharmacy", "dentist", "veterinary", "clinic"]),
            (learn, ["school", "college", "university", "library", "kindergarten", "place_of_worship", "town_hall",
                     "police", "fire_station", "post", "embassy", "townhall"]),
            (stay, ["lodging", "hotel", "hostel", "motel", "guest_house"]),
            (culture, ["museum", "attraction", "art_gallery", "theatre", "cinema", "monument", "castle", "music",
                       "entertainment"]),
            (money, ["bank", "atm", "money"]),
            (car, ["fuel", "parking", "car", "car_repair", "charging_station"]),
        ] { for n in names { m[n] = kind } }
        return m
    }()

    // MARK: the frame

    public typealias LatLon = (lat: Double, lon: Double)

    /// Metres east, north of `o` (as NavService's route frame).
    public static func xy(_ p: LatLon, _ o: LatLon) -> (Double, Double) {
        ((p.lon - o.lon) * cos(o.lat * .pi / 180) * 111_320, (p.lat - o.lat) * 110_540)
    }

    public static func latLon(_ x: Double, _ y: Double, _ o: LatLon) -> LatLon {
        (o.lat + y / 110_540, o.lon + x / (cos(o.lat * .pi / 180) * 111_320))
    }

    public static func tile(_ p: LatLon, z: Int = zoom) -> (x: Int, y: Int) {
        let n = Double(1 << z)
        let x = Int((p.lon + 180) / 360 * n)
        let y = Int((1 - asinh(tan(p.lat * .pi / 180)) / .pi) / 2 * n)
        return (x, y)
    }

    /// The zoom-14 tiles that cover the square of half side `r` round `centre` (frame metres of `o`).
    public static func tiles(round centre: (Double, Double), r: Double, origin o: LatLon) -> [(x: Int, y: Int)] {
        let a = tile(latLon(centre.0 - r, centre.1 - r, o)), b = tile(latLon(centre.0 + r, centre.1 + r, o))
        var out: [(x: Int, y: Int)] = []
        for x in a.x...max(a.x, b.x) { for y in min(a.y, b.y)...max(a.y, b.y) { out.append((x, y)) } }
        return out
    }

    // MARK: vector tiles (Mapbox Vector Tile 2: protobuf)

    public struct Feature: Sendable {
        public var layer: String
        public var props: [String: String]
        /// 1 point, 2 line, 3 polygon
        public var type: Int
        /// parts (points, lines or rings), tile units (0 … extent, y down)
        public var parts: [[(Int, Int)]]
        public var extent: Int
    }

    struct PB {
        let b: [UInt8]
        var i: Int
        var end: Int
        init(_ b: [UInt8], _ i: Int = 0, _ end: Int? = nil) { self.b = b; self.i = i; self.end = end ?? b.count }
        var more: Bool { i < end }
        mutating func varint() -> UInt64 {
            var v: UInt64 = 0, s: UInt64 = 0
            while i < end {
                let c = b[i]; i += 1
                v |= UInt64(c & 0x7F) << s
                if c & 0x80 == 0 { break }
                s += 7
                if s > 63 { break }
            }
            return v
        }
        /// (field, wire type)
        mutating func key() -> (Int, Int) { let k = varint(); return (Int(k >> 3), Int(k & 7)) }
        /// a length-delimited field: its byte range
        mutating func bytes() -> Range<Int> {
            let n = Int(varint())
            let r = i..<min(i + n, end)
            i = r.upperBound
            return r
        }
        mutating func skip(_ wire: Int) {
            switch wire {
            case 0: _ = varint()
            case 1: i += 8
            case 2: _ = bytes()
            case 5: i += 4
            default: i = end
            }
        }
    }

    /// The features of a tile, by layer.
    public static func decode(_ data: Data) -> [Feature] {
        let b = [UInt8](data)
        var p = PB(b)
        var out: [Feature] = []
        while p.more {
            let (f, w) = p.key()
            if f == 3, w == 2 { out += layer(b, p.bytes()) } else { p.skip(w) }
        }
        return out
    }

    static func layer(_ b: [UInt8], _ r: Range<Int>) -> [Feature] {
        var p = PB(b, r.lowerBound, r.upperBound)
        var name = "", keys: [String] = [], values: [String] = [], feats: [Range<Int>] = [], extent = 4096
        while p.more {
            let (f, w) = p.key()
            switch (f, w) {
            case (1, 2): name = String(decoding: b[p.bytes()], as: UTF8.self)
            case (2, 2): feats.append(p.bytes())
            case (3, 2): keys.append(String(decoding: b[p.bytes()], as: UTF8.self))
            case (4, 2): values.append(value(b, p.bytes()))
            case (5, 0): extent = Int(p.varint())
            default: p.skip(w)
            }
        }
        guard ["transportation", "transportation_name", "water", "landcover", "park", "waterway", "poi", "place",
               "water_name"].contains(name) else { return [] }
        return feats.compactMap { feature(b, $0, layer: name, keys: keys, values: values, extent: extent) }
    }

    static func value(_ b: [UInt8], _ r: Range<Int>) -> String {
        var p = PB(b, r.lowerBound, r.upperBound)
        var v = ""
        while p.more {
            let (f, w) = p.key()
            switch (f, w) {
            case (1, 2): v = String(decoding: b[p.bytes()], as: UTF8.self)
            case (4, 0), (5, 0): v = String(p.varint())
            case (6, 0): let u = p.varint(); v = String(Int64(bitPattern: (u >> 1) ^ (0 &- (u & 1))))
            case (7, 0): v = p.varint() != 0 ? "true" : "false"
            default: p.skip(w)
            }
        }
        return v
    }

    static func feature(_ b: [UInt8], _ r: Range<Int>, layer: String, keys: [String], values: [String],
                        extent: Int) -> Feature? {
        var p = PB(b, r.lowerBound, r.upperBound)
        var tags: [UInt64] = [], type = 0, geom: [UInt32] = []
        while p.more {
            let (f, w) = p.key()
            switch (f, w) {
            case (2, 2):
                let rr = p.bytes(); var q = PB(b, rr.lowerBound, rr.upperBound)
                while q.more { tags.append(q.varint()) }
            case (3, 0): type = Int(p.varint())
            case (4, 2):
                let rr = p.bytes(); var q = PB(b, rr.lowerBound, rr.upperBound)
                while q.more { geom.append(UInt32(truncatingIfNeeded: q.varint())) }
            default: p.skip(w)
            }
        }
        var props: [String: String] = [:]
        var k = 0
        while k + 1 < tags.count {
            let (ki, vi) = (Int(tags[k]), Int(tags[k + 1]))
            if ki < keys.count, vi < values.count { props[keys[ki]] = values[vi] }
            k += 2
        }
        // geometry: commands (id & 7, count >> 3) and zigzag deltas
        var parts: [[(Int, Int)]] = [], cur: [(Int, Int)] = []
        var x = 0, y = 0, i = 0
        let zz = { (v: UInt32) -> Int in Int(Int32(bitPattern: (v >> 1) ^ (0 &- (v & 1)))) }
        while i < geom.count {
            let cmd = Int(geom[i] & 7), n = Int(geom[i] >> 3)
            i += 1
            if cmd == 7 {
                if !cur.isEmpty { parts.append(cur); cur = [] }
                continue
            }
            for _ in 0..<n where i + 1 < geom.count {
                x += zz(geom[i]); y += zz(geom[i + 1]); i += 2
                if cmd == 1, !cur.isEmpty, type != 1 { parts.append(cur); cur = [] }
                cur.append((x, y))
            }
        }
        if !cur.isEmpty { parts.append(cur) }
        if type == 1 { parts = parts.flatMap { $0.map { [$0] } } }
        return Feature(layer: layer, props: props, type: type, parts: parts, extent: extent)
    }

    // MARK: shapes

    public typealias Pt = (Double, Double)

    /// Douglas–Peucker, the ends kept.
    public static func simplify(_ pts: [Pt], _ tol: Double) -> [Pt] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (a, b) = stack.popLast() {
            let (ax, ay) = pts[a], (bx, by) = pts[b]
            let dx = bx - ax, dy = by - ay, l = (dx * dx + dy * dy).squareRoot()
            var best = -1.0, at = -1
            for i in (a + 1)..<b {
                let (px, py) = pts[i]
                let d = l == 0 ? hypot(px - ax, py - ay) : abs(dy * (px - ax) - dx * (py - ay)) / l
                if d > best { best = d; at = i }
            }
            if at > 0, best > tol { keep[at] = true; stack += [(a, at), (at, b)] }
        }
        return zip(pts, keep).filter(\.1).map(\.0)
    }

    /// The pieces of a line near the square [lo, hi]: runs of segments with an end inside.
    static func clip(_ pts: [Pt], _ lo: Pt, _ hi: Pt) -> [[Pt]] {
        let inside = { (p: Pt) in lo.0 <= p.0 && p.0 <= hi.0 && lo.1 <= p.1 && p.1 <= hi.1 }
        var out: [[Pt]] = [], cur: [Pt] = []
        for i in 1..<max(pts.count, 1) {
            let a = pts[i - 1], b = pts[i]
            if inside(a) || inside(b) {
                if cur.isEmpty { cur = [a] }
                cur.append(b)
            } else if !cur.isEmpty { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func i16(_ v: Double) -> Int16 { Int16(max(-32000, min(32000, v.rounded()))) }

    static func encode(_ pts: [Pt]) -> Data {
        let q = pts.map { (Int(i16($0.0)), Int(i16($0.1))) }
        var out = Data()
        out.le(Int16(q[0].0)); out.le(Int16(q[0].1))
        for k in 1..<q.count {
            let dx = q[k].0 - q[k - 1].0, dy = q[k].1 - q[k - 1].1
            if (-127...127).contains(dx), (-127...127).contains(dy) {
                out += Data([UInt8(bitPattern: Int8(dx)), UInt8(bitPattern: Int8(dy))])
            } else {
                out.append(0x80); out.le(Int16(dx)); out.le(Int16(dy))
            }
        }
        return out
    }

    static let short: [String: String] = [
        "Mawatha": "Mw", "Mawatta": "Mw", "Road": "Rd", "Street": "St", "Avenue": "Ave", "Place": "Pl", "Lane": "Ln",
        "Drive": "Dr", "Terrace": "Terr", "Gardens": "Gdns", "Boulevard": "Blvd", "Highway": "Hwy",
        "Junction": "Jn", "Roundabout": "Rbt", "Expressway": "Expy",
    ]

    /// A street's name as a map writes it: no bracketed other name, the usual short words.
    public static func street(_ name: String) -> String {
        let plain = name.replacingOccurrences(of: #"\s*\(.*?\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return plain.split(separator: " ").enumerated()
            .map { $0.offset > 0 ? (short[String($0.element)] ?? String($0.element)) : String($0.element) }
            .joined(separator: " ")
    }

    static func text(_ s: String, _ n: Int = 60) -> Data {
        var d = Data(s.utf8.prefix(n))
        while !d.isEmpty, String(data: d, encoding: .utf8) == nil { d.removeLast() }
        return d
    }

    // MARK: features → records

    enum Kind { case area, line, carrier, label }
    struct Item {
        var kind: Kind
        var cls: Int
        var pts: [Pt]
        var name: String = ""
        var rank: Int = 0
    }

    /// What of `feats` (tile `t`) lies round `centre` (frame metres of `o`), half side `r`.
    static func items(_ feats: [(tile: (x: Int, y: Int), f: Feature)], origin o: LatLon, centre: Pt, r: Double) -> [Item] {
        let lo = (centre.0 - r, centre.1 - r), hi = (centre.0 + r, centre.1 + r)
        let n = Double(1 << zoom)
        var out: [Item] = []
        for (t, f) in feats {
            let ext = Double(f.extent)
            let geo = { (pts: [(Int, Int)]) -> [Pt] in
                pts.map { u, v in
                    let lon = (Double(t.x) + Double(u) / ext) / n * 360 - 180
                    let lat = atan(sinh(.pi * (1 - 2 * (Double(t.y) + Double(v) / ext) / n))) * 180 / .pi
                    return xy((lat, lon), o)
                }
            }
            let cls = f.props["class"] ?? "", sub = f.props["subclass"] ?? ""
            switch f.layer {
            case "water", "park", "landcover":
                guard f.type == 3 else { continue }
                if f.layer == "water", cls == "swimming_pool" { continue }
                if f.layer == "landcover", !green.contains(cls), !green.contains(sub) { continue }
                for ring in f.parts where signedArea(ring) > 0 {  // outer rings (holes are drawn over by the land)
                    let g = geo(ring)
                    let xs = g.map(\.0), ys = g.map(\.1)
                    guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(),
                          x1 >= lo.0, x0 <= hi.0, y1 >= lo.1, y0 <= hi.1 else { continue }
                    out.append(Item(kind: .area, cls: f.layer == "water" ? water : park, pts: g))
                }
            case "transportation", "transportation_name", "waterway":
                guard f.type == 2 else { continue }
                let c: Int
                if f.layer == "waterway" {
                    guard ["river", "canal", "stream"].contains(cls) else { continue }
                    c = waterway
                } else {
                    guard let rc = road[cls] ?? road[sub] else { continue }
                    c = rc
                }
                let name = f.layer == "transportation_name" ? (f.props["name"] ?? "") : ""
                if f.layer == "transportation_name", name.isEmpty { continue }
                for l in f.parts where l.count >= 2 {
                    for piece in clip(geo(l), lo, hi) {
                        out.append(Item(kind: name.isEmpty ? .line : .carrier, cls: c, pts: piece, name: name))
                    }
                }
            case "poi", "place", "water_name":
                guard f.type == 1, let name = f.props["name"], !name.isEmpty, let pt = f.parts.first?.first else { continue }
                let p = geo([pt])[0]
                guard lo.0 <= p.0, p.0 <= hi.0, lo.1 <= p.1, p.1 <= hi.1 else { continue }
                let c: Int
                switch f.layer {
                case "poi": c = poiKind[cls] ?? poiKind[sub] ?? poi
                case "place":
                    guard places.contains(cls) else { continue }
                    c = place
                default: c = waterName
                }
                out.append(Item(kind: .label, cls: c, pts: [p], name: name, rank: Int(f.props["rank"] ?? "") ?? 50))
            default: continue
            }
        }
        return out
    }

    /// Twice the area, tile units (y down): > 0 for an outer ring.
    static func signedArea(_ r: [(Int, Int)]) -> Int {
        var s = 0
        for i in 0..<r.count { let a = r[i], b = r[(i + 1) % r.count]; s += a.0 * b.1 - b.0 * a.1 }
        return s
    }

    /// The scene's bytes, most important first, as much as fits `cap`; `full`: something was left out.
    static func build(_ items: [Item], extra: [Item] = [], cap: Int = cap) -> (data: Data, full: Bool) {
        let isPOI = { (c: Int) in c == poi || c >= food }
        let tiers: [[Item]] = [
            extra,
            items.filter { $0.kind == .area && $0.cls == water },
            items.filter { $0.kind == .line && $0.cls <= tertiary },
            items.filter { $0.kind == .area && $0.cls == park },
            items.filter { $0.kind == .line && $0.cls == minor },
            items.filter { $0.kind == .carrier && $0.cls <= tertiary },
            items.filter { $0.kind == .label && ($0.cls == place || $0.cls == waterName) },
            Array(items.filter { $0.kind == .label && isPOI($0.cls) }.sorted { $0.rank < $1.rank }.prefix(48)),
            items.filter { $0.kind == .carrier && $0.cls == minor },
            items.filter { $0.kind == .line && $0.cls == waterway },
            items.filter { $0.kind == .line && $0.cls == path },
            items.filter { $0.kind == .line && $0.cls == rail },
        ]
        var out = Data(), names: [String: Int] = [:], full = false
        for tier in tiers {
            for it in tier {
                var rec = Data(), new: [String] = []
                switch it.kind {
                case .area:
                    var tol = 3.0, ring = simplify(it.pts, tol)
                    while ring.count > maxRing { tol *= 1.6; ring = simplify(it.pts, tol) }
                    guard ring.count >= 3 else { continue }
                    rec.append(area | UInt8(it.cls)); rec.le(UInt16(ring.count)); rec += encode(ring)
                case .line, .carrier:
                    let pts = simplify(it.pts, it.kind == .carrier ? 6 : it.cls >= minor ? 1.5 : 2.5)
                    var i = 0
                    while i < pts.count - 1 {
                        let piece = Array(pts[i..<min(i + 255, pts.count)])
                        i += 254
                        guard piece.count >= 2 else { continue }
                        var idx: UInt8 = 0xFF
                        if it.kind == .carrier {
                            if let k = names[it.name] { idx = UInt8(k) } else if let k = new.firstIndex(of: it.name) {
                                idx = UInt8(names.count + k)
                            } else {
                                guard names.count + new.count < 255 else { continue }
                                let t = text(street(it.name))
                                rec += Data([name, UInt8(t.count)]) + t
                                new.append(it.name)
                                idx = UInt8(names.count + new.count - 1)
                            }
                        }
                        let c = it.cls + (it.kind == .carrier ? carrier : 0)
                        rec += Data([line | UInt8(c), idx, UInt8(piece.count)]) + encode(piece)
                    }
                case .label:
                    let t = text(it.name)
                    rec.append(label | UInt8(it.cls)); rec.le(i16(it.pts[0].0)); rec.le(i16(it.pts[0].1))
                    rec += Data([UInt8(clamping: it.rank), UInt8(t.count)]) + t
                }
                if out.count + rec.count > cap { full = true; continue }
                out += rec
                for n in new { names[n] = names.count }
            }
        }
        return (out, full)
    }

    /// Half sides tried, widest first: a city's centre fits a smaller square than a village.
    public static let radii: [Double] = [1500, 1250, 1000, 800]

    /// The scene round `centre` (frame metres of `o`) from decoded tiles, as wide as fits whole; `pins`: searched
    /// places (frame metres, name), shown first. → (bytes, half side).
    public static func scene(tiles: [(tile: (x: Int, y: Int), features: [Feature])], origin o: LatLon,
                             centre: Pt, pins: [(Pt, String)] = [], cap: Int = cap) -> (data: Data, r: Double) {
        let feats = tiles.flatMap { t in t.features.map { (tile: t.tile, f: $0) } }
        for (k, r) in radii.enumerated() {
            let lo = (centre.0 - r, centre.1 - r), hi = (centre.0 + r, centre.1 + r)
            let extra = pins.filter { lo.0 <= $0.0.0 && $0.0.0 <= hi.0 && lo.1 <= $0.0.1 && $0.0.1 <= hi.1 }
                .enumerated().map { Item(kind: .label, cls: searched, pts: [$0.element.0], name: $0.element.1, rank: $0.offset) }
            let (data, full) = build(items(feats, origin: o, centre: centre, r: r), extra: extra, cap: cap)
            if !full || k == radii.count - 1 { return (data, r) }
        }
        return (Data(), radii[0])
    }
}
