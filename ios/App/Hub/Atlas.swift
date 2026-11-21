import CoreLocation
import Foundation
import HubKit
import MapKit
import UIKit
import WireKit

// The watch's Maps app (cmf-watch-sdk sdk/examples/atlas, proto.rs): the map round us with the last search's places
// on it, search near us (MapKit, then OpenStreetMap's Nominatim when Apple has nothing), how long a place is by car,
// bike and on foot, a route that way (NavService: OpenStreetMap's routes first, then Apple's), each step of it
// checked on the map, then turn by turn. The map is OpenStreetMap's (OpenFreeMap's vector tiles, cached here):
// streets, names, parks, water and places cut round a point as data (HubKit AtlasScene) that the watch draws itself,
// sent over the sliding window. Nothing runs unless Maps is open on the watch; location only for an answer, and all
// the time only while navigating.

@MainActor @Observable final class AtlasService: WatchService {
    static let app = "Maps"

    let nav = NavService(target: AtlasService.app)
    private(set) var results: [MKMapItem] = []
    private(set) var place: MKMapItem?
    var status: String?

    /// Where the watch's map is measured from (metres east, north): where we were for Home, the route's start
    /// (NavService's frame) once a route is shown.
    private var frame: CLLocationCoordinate2D?
    private let tiles = VectorTiles()

    /// The scene being sent; a newer request ends an older one.
    private var gen = 0
    private var queue: [Data] = []
    private var last: (id: UInt8, msgs: [Data])?

    func receive(_ m: Data) {
        guard let ask = AtlasProto.parse(m) else { return }
        switch ask {
        case .ready:
            Task { try? await Hub.shared.send(Self.app, AtlasProto.hello) }
        case .home(let id, let round):
            picture(id) { await self.homeMap(round: round.map { (Double($0.x), Double($0.y)) }) }
        case .search(let q):
            Task { await search(q) }
        case .ways(let idx):
            guard idx < results.count else { return fail("That place is gone: search again") }
            place = results[idx]
            Task { await ways(to: results[idx]) }
        case .directions(let mode, let idx, let id):
            Task { await directions(mode: mode, idx: idx, id: id) }
        case .start:
            Task {
                try? await Hub.shared.send(Self.app, AtlasProto.navigating)
                await nav.begin()
            }
        case .stop:
            nav.stop()
        case .again(let id):
            guard let l = last, l.id == id else { return }
            gen += 1
            let g = gen
            Task { await send(l.msgs, gen: g) }
        }
    }

    // --- answers

    private func search(_ q: String) async {
        guard let here = await nav.here() else { return fail("Location is off for CMFX") }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        var items = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
        if items.isEmpty { items = await nominatim(q, near: here.coordinate) }
        items.sort { distance($0, here) < distance($1, here) }
        results = Array(items.prefix(8))
        let rows = results.map { (name: $0.name ?? "Place", sub: Self.sub($0), dist: Int(distance($0, here))) }
        status = rows.isEmpty ? "Nothing found for \(q)" : nil
        do { try await Hub.shared.send(Self.app, AtlasProto.results(rows)) } catch { status = error.localizedDescription }
    }

    private func distance(_ i: MKMapItem, _ here: CLLocation) -> Double {
        let c = i.placemark.coordinate
        return here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    /// The street and the town, short.
    static func sub(_ i: MKMapItem) -> String {
        let p = i.placemark
        let street = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let parts = [street, p.locality ?? p.subAdministrativeArea ?? ""].filter { !$0.isEmpty && $0 != i.name }
        return parts.joined(separator: ", ")
    }

    /// OpenStreetMap's search (Nominatim, its usage policy: one request at a time, a real User-Agent) where Apple
    /// has no places: the query and the area round us are all it gets.
    private func nominatim(_ q: String, near c: CLLocationCoordinate2D) async -> [MKMapItem] {
        var u = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        let d = 0.3
        u.queryItems = [.init(name: "q", value: q), .init(name: "format", value: "jsonv2"), .init(name: "limit", value: "8"),
                        .init(name: "viewbox", value: "\(c.longitude - d),\(c.latitude + d),\(c.longitude + d),\(c.latitude - d)")]
        var req = URLRequest(url: u.url!)
        req.timeoutInterval = 15
        req.setValue("CMFX (watch maps)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let lat = Double(r["lat"] as? String ?? ""), let lon = Double(r["lon"] as? String ?? "") else { return nil }
            let item = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: lat, longitude: lon)))
            let full = r["display_name"] as? String ?? q
            let parts = full.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            item.name = (r["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? parts.first ?? q
            return item
        }
    }

    private func directions(mode: Int, idx: Int, id: UInt8) async {
        guard idx < results.count else { return fail("That place is gone: search again") }
        nav.stop()
        nav.mode = NavService.Mode(rawValue: mode) ?? .drive
        guard await nav.plan(to: results[idx]) else { return fail(nav.status ?? "Couldn't find where you are") }
        let eta = Calendar.current.dateComponents([.hour, .minute], from: .now + nav.expected)
        let msgs = AtlasProto.route(mode: UInt8(mode), secs: nav.expected, metres: nav.length,
                                    arrive: (eta.hour ?? 0, eta.minute ?? 0), steps: nav.steps)
        do { try await Hub.shared.send(Self.app, msgs + nav.routeMessages()) } catch { status = error.localizedDescription }
        // the route's map, in its frame, round the middle of it
        frame = nav.frame
        let line = nav.coords.map { AtlasScene.xy(($0.latitude, $0.longitude), (nav.frame.latitude, nav.frame.longitude)) }
        let xs = line.map(\.0), ys = line.map(\.1)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return }
        let mid = ((x0 + x1) / 2, (y0 + y1) / 2)
        picture(id) { await self.scene(round: mid, me: (0, 0)) }
    }

    /// Car, bike and foot to `item`, each sent as it is known.
    private func ways(to item: MKMapItem) async {
        await withTaskGroup(of: Void.self) { g in
            for way in [NavService.Mode.drive, .bike, .walk] {
                g.addTask { @MainActor in
                    let r = await self.nav.summary(to: item, by: way)
                    let eta = r.map { Calendar.current.dateComponents([.hour, .minute], from: .now + $0.secs) }
                    let msg = AtlasProto.way(mode: UInt8(way.rawValue),
                                             r.map { (secs: $0.secs, metres: $0.metres, arrive: (eta?.hour ?? 0, eta?.minute ?? 0)) })
                    try? await Hub.shared.send(Self.app, msg)
                }
            }
        }
    }

    private func fail(_ why: String) {
        status = why
        Task { try? await Hub.shared.send(Self.app, AtlasProto.error(why)) }
    }

    // --- the map

    private func picture(_ id: UInt8, _ make: @escaping @MainActor () async -> [Data]?) {
        currentID = id
        gen += 1
        let g = gen
        Task {
            guard let msgs = await make(), g == gen else { return }
            last = (id, msgs)
            await send(msgs, gen: g)
        }
    }

    /// Over the sliding window: 4 in flight; refused ones go again (their place is in them, order doesn't matter).
    private func send(_ msgs: [Data], gen g: Int) async {
        queue = msgs
        var delay = 25
        let start = ContinuousClock.now
        while g == gen, !queue.isEmpty, ContinuousClock.now - start < .seconds(30) {
            do {
                let again = try await Hub.shared.stream(Self.app) { @MainActor [weak self] in
                    guard let self, self.gen == g, !self.queue.isEmpty else { return nil }
                    return self.queue.removeFirst()
                }
                guard g == gen else { return }
                if again.isEmpty {
                    delay = 25
                } else {
                    queue.insert(contentsOf: again, at: 0)
                    try? await Task.sleep(for: .milliseconds(delay))
                    delay = min(delay * 2, 250)
                }
            } catch WireError.noApp {
                return
            } catch {
                status = error.localizedDescription
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Home's map: round where we are (a new frame there), or round a point of the frame the watch has moved to.
    private func homeMap(round: (Double, Double)?) async -> [Data]? {
        guard let here = await nav.here() else {
            fail("Location is off for CMFX")
            return nil
        }
        if round == nil || frame == nil { frame = here.coordinate }
        let f = frame!
        let me = AtlasScene.xy((here.coordinate.latitude, here.coordinate.longitude), (f.latitude, f.longitude))
        return await scene(round: round ?? me, me: me)
    }

    /// The scene round `centre` (metres in `frame`), the last search's places on it as red pins.
    private func scene(round centre: (Double, Double), me: (Double, Double)) async -> [Data]? {
        guard let f = frame else { return nil }
        let o = (lat: f.latitude, lon: f.longitude)
        let pins = results.map { i -> ((Double, Double), String) in
            let c = i.placemark.coordinate
            return (AtlasScene.xy((c.latitude, c.longitude), o), i.name ?? "")
        }
        let need = AtlasScene.tiles(round: centre, r: AtlasScene.radii[0], origin: o)
        let got: [(tile: (x: Int, y: Int), features: [AtlasScene.Feature])]
        do { got = try await tiles.features(need) } catch {
            fail("No map here: \(error.localizedDescription)")
            return nil
        }
        let id = currentID
        return await Task.detached(priority: .userInitiated) {
            let (data, r) = AtlasScene.scene(tiles: got, origin: o, centre: centre, pins: pins)
            return AtlasProto.scene(id: id, data: data, me: me, centre: centre, r: r)
        }.value
    }

    /// The id of the scene being made (the last one asked for).
    private var currentID: UInt8 = 0
}

/// OpenFreeMap's vector tiles (OpenStreetMap, OpenMapTiles schema, no key; https://openfreemap.org): zoom 14, kept in
/// Caches so a place seen once is quick (a tile is ~100–300 KB; ones unused for 30 days go).
actor VectorTiles {
    private static let tileJSON = URL(string: "https://tiles.openfreemap.org/planet")!
    private var template: (url: String, at: Date)?
    private var decoded: [String: [AtlasScene.Feature]] = [:]
    private var order: [String] = []
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("vtiles")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() {
        // tiles unused for a month go
        let fm = FileManager.default
        let old = Date.now.addingTimeInterval(-30 * 86400)
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentAccessDateKey])) ?? [] {
            if let d = try? u.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate, d < old {
                try? fm.removeItem(at: u)
            }
        }
    }

    /// The tiles' features, fetched (a few at once) where not cached.
    func features(_ tiles: [(x: Int, y: Int)]) async throws -> [(tile: (x: Int, y: Int), features: [AtlasScene.Feature])] {
        let t = try await urlTemplate()
        var out: [(tile: (x: Int, y: Int), features: [AtlasScene.Feature])] = []
        try await withThrowingTaskGroup(of: ((x: Int, y: Int), [AtlasScene.Feature]).self) { g in
            for tile in tiles {
                let key = "\(AtlasScene.zoom)-\(tile.x)-\(tile.y)"
                if let f = decoded[key] { out.append((tile, f)); continue }
                let file = dir.appendingPathComponent(key + ".pbf")
                let url = URL(string: t.replacingOccurrences(of: "{z}", with: String(AtlasScene.zoom))
                    .replacingOccurrences(of: "{x}", with: String(tile.x)).replacingOccurrences(of: "{y}", with: String(tile.y)))!
                g.addTask {
                    let data: Data
                    if let d = try? Data(contentsOf: file) {
                        data = d
                    } else {
                        var req = URLRequest(url: url)
                        req.timeoutInterval = 20
                        req.setValue("CMFX (watch maps)", forHTTPHeaderField: "User-Agent")
                        let (d, resp) = try await URLSession.shared.data(for: req)
                        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                        try? d.write(to: file)
                        data = d
                    }
                    return (tile, AtlasScene.decode(data))
                }
            }
            for try await (tile, f) in g { out.append((tile, f)); remember("\(AtlasScene.zoom)-\(tile.x)-\(tile.y)", f) }
        }
        return out
    }

    /// Decoded tiles kept in memory: the last 9.
    private func remember(_ key: String, _ f: [AtlasScene.Feature]) {
        decoded[key] = f
        order.append(key)
        while order.count > 9 { decoded[order.removeFirst()] = nil }
    }

    /// Tile URLs change with each planet build: OpenFreeMap's TileJSON names the current one (read daily).
    private func urlTemplate() async throws -> String {
        if let t = template, Date.now.timeIntervalSince(t.at) < 86400 { return t.url }
        var req = URLRequest(url: Self.tileJSON)
        req.timeoutInterval = 20
        req.setValue("CMFX (watch maps)", forHTTPHeaderField: "User-Agent")
        let (d, _) = try await URLSession.shared.data(for: req)
        guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any], let url = (j["tiles"] as? [String])?.first
        else { throw URLError(.cannotParseResponse) }
        template = (url, .now)
        return url
    }
}
