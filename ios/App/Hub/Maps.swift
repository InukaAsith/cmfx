import CoreLocation
import Foundation
import MapKit
import HubKit
import UIKit

// The watch's Offline Maps app (cmf-watch-sdk sdk/examples/maps). An area picked here is cut from OpenStreetMap's
// vector data (OpenFreeMap, as Maps) into cells at three levels (VectorPack) and saved on the watch, which draws the
// map itself and then needs no phone: its own GPS, pins, a track and the way back to its start. The phone only
// finds a route when the watch asks for one (Walk / Drive route), which the watch then follows offline.
// Nothing is kept here: the tiles are fetched for the build and dropped (no growing storage).

@MainActor @Observable final class MapsService: WatchService {
    static let app = "Offline Maps"
    /// The whole area (overview: main roads, water, towns).
    var radiusKm = 10.0
    /// Streets and paths round the centre.
    var detailKm = 3.0
    private(set) var progress: (done: Int, total: Int)?
    private(set) var cleaning = false
    var status: String?
    private var acks: [CheckedContinuation<Data, Never>] = []
    private var job: Task<Void, Never>?
    private let tiles = VectorTiles()
    private let here = PhoneFix()
    /// The routes last found for the watch (it picks one), and the search for them.
    private var found: [(pts: [AtlasScene.Pt], metres: Double, secs: Double)] = []
    private var routeJob: Task<Void, Never>?

    func receive(_ m: Data) {
        switch m.first {
        case UInt8(ascii: "a"), UInt8(ascii: "k"), UInt8(ascii: "w"):
            if !acks.isEmpty { acks.removeFirst().resume(returning: m) }
        case UInt8(ascii: "x") where m.count == 4:
            // the watch cleaned its storage: files deleted, 0 all, 1 some it couldn't see, 2 only the map
            let n = Int(m[1]) | Int(m[2]) << 8
            status = ["Watch storage clean: \(n) files deleted", "\(n) files deleted; some were out of the watch's view: clean again",
                      "Only the map deleted (the watch's loader needs updating to clean everything)"][min(Int(m[3]), 2)]
            cleaning = false
        case UInt8(ascii: "D"):
            if let ask = VectorPack.parseAsk(m) {
                routeJob?.cancel()
                routeJob = Task { await route(ask) }
            }
        case UInt8(ascii: "p") where m.count == 2:
            // the route picked of those `O` listed
            let k = Int(m[m.startIndex + 1])
            guard found.indices.contains(k) else { return }
            let r = found[k]
            Task { try? await Hub.shared.send(Self.app, VectorPack.route(r.pts, metres: r.metres, secs: r.secs)) }
        case UInt8(ascii: "l"):
            // the watch asks where the phone is (every 2 s while Offline Maps is open): it uses it while its own
            // GPS has no fix
            let r = here.ask()
            Task { try? await Hub.shared.send(Self.app, r) }
        default: break
        }
    }

    private func ack() async -> Data { await withCheckedContinuation { acks.append($0) } }

    var levels: [VectorPack.Level] { VectorPack.levels(radiusKm: radiusKm, detailKm: detailKm) }
    var cellCount: Int { VectorPack.cellCount(levels) }

    func build(at c: CLLocationCoordinate2D) {
        job?.cancel()
        job = Task { await run(c) }
    }

    /// Everything Offline Maps keeps on the watch goes: the map, older versions' leftovers, the pins.
    func cleanWatch() {
        job?.cancel()
        progress = nil
        cleaning = true
        status = "Cleaning the watch's storage…"
        Task {
            do { try await Hub.shared.send(Self.app, Data("X".utf8)) } catch {
                cleaning = false
                status = error.localizedDescription
            }
        }
    }

    func cancel() {
        job?.cancel()
        progress = nil
        status = "Stopped"
    }

    private func run(_ c: CLLocationCoordinate2D) async {
        let bg = UIApplication.shared.beginBackgroundTask(withName: "map")
        defer { UIApplication.shared.endBackgroundTask(bg); progress = nil }
        let levels = self.levels
        let o: AtlasScene.LatLon = (c.latitude, c.longitude)
        let total = VectorPack.cellCount(levels)
        var done = 0, files = 0, bytes = 0
        var named: [VectorPack.Named] = []
        do {
            progress = (0, total)
            try await Hub.shared.send(Self.app, VectorPack.progressMessage(done: 0, total: total))
            for (li, l) in levels.enumerated() {
                // this level's tiles, then its cells (the tiles go when the level is done)
                status = "Fetching map data (\(["overview", "roads", "streets"][min(li, 2)]))…"
                let need = AtlasScene.tiles(round: (0, 0), r: Double(-l.x0) + 30, origin: o, z: l.z)
                var got: [String: [AtlasScene.Feature]] = [:]
                for batch in stride(from: 0, to: need.count, by: 8) {
                    try Task.checkCancellation()
                    for t in try await tiles.features(Array(need[batch..<min(batch + 8, need.count)]), z: l.z, keep: false) {
                        got["\(t.tile.x)-\(t.tile.y)"] = t.features
                    }
                }
                status = nil
                for row in 0..<l.n {
                    for col in 0..<l.n {
                        try Task.checkCancellation()
                        let under = VectorPack.tiles(l, col: col, row: row, origin: o)
                            .compactMap { t in got["\(t.x)-\(t.y)"].map { (tile: t, features: $0) } }
                        let (data, names) = await Task.detached {
                            (VectorPack.cell(under, level: l, col: col, row: row, origin: o),
                             VectorPack.names(under, level: l, col: col, row: row, origin: o))
                        }.value
                        named += names
                        if !data.isEmpty {
                            try await sendFile(VectorPack.cellName(level: li, col: col, row: row), data)
                            files += 1
                            bytes += data.count
                        }
                        done += 1
                        progress = (done, total)
                        if done % 4 == 0 { try await Hub.shared.send(Self.app, VectorPack.progressMessage(done: done, total: total)) }
                    }
                }
            }
            // the names for the watch's search, then the index (which makes the map whole)
            status = "Saving names for search…"
            let n = await Task.detached { VectorPack.namesFile(named) }.value
            try await sendFile("n", n)
            bytes += n.count
            status = nil
            try await sendFile("idx", VectorPack.index(levels, lat: c.latitude, lon: c.longitude))
            try await Hub.shared.send(Self.app, Data("Z".utf8))
            _ = await ack()
            status = "Saved on the watch: \(files) parts, \(bytes / 1024) KB"
        } catch is CancellationError {
        } catch {
            status = error.localizedDescription
        }
    }

    private func sendFile(_ name: String, _ data: Data) async throws {
        try await Hub.shared.send(Self.app, MapPack.fileMessages(name: name, data: data))
        _ = await ack()
    }

    /// Routes the watch asked for (car, bike, walk): up to three, OpenStreetMap's (FOSSGIS OSRM), else Apple's; their
    /// times go to the watch, which picks one (`p`), followed then with no phone.
    private func route(_ ask: VectorPack.RouteAsk) async {
        let o: AtlasScene.LatLon = ask.origin
        let src: CLLocationCoordinate2D
        if let f = ask.from {
            let p = AtlasScene.latLon(f.0, f.1, o)
            src = .init(latitude: p.lat, longitude: p.lon)
        } else if let here = CLLocationManager().location?.coordinate {
            src = here
        } else {
            try? await Hub.shared.send(Self.app, VectorPack.routeFailed("No GPS fix yet"))
            return
        }
        let t = AtlasScene.latLon(ask.to.0, ask.to.1, o)
        let dst = CLLocationCoordinate2D(latitude: t.lat, longitude: t.lon)
        var ways = await osrm(src, dst, profile: ["car", "bike", "foot"][ask.mode])
        if ways.isEmpty { ways = await apple(src, dst, walk: ask.mode != 0) }
        guard !Task.isCancelled else { return }
        found = ways.prefix(3).map { w in
            (w.coords.map { AtlasScene.xy(($0.latitude, $0.longitude), o) }, w.metres, w.secs)
        }
        if found.isEmpty {
            try? await Hub.shared.send(Self.app, VectorPack.routeFailed("No route: needs the internet"))
            return
        }
        try? await Hub.shared.send(Self.app, VectorPack.ways(found.map { ($0.secs, $0.metres) }))
    }

    private typealias Way = (coords: [CLLocationCoordinate2D], metres: Double, secs: Double)

    private func osrm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, profile: String) async -> [Way] {
        let s = String(format: "%.6f,%.6f;%.6f,%.6f", a.longitude, a.latitude, b.longitude, b.latitude)
        guard let url = URL(string: "https://routing.openstreetmap.de/routed-\(profile)/route/v1/driving/\(s)?alternatives=3&overview=full&geometries=geojson") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["code"] as? String == "Ok",
              let routes = j["routes"] as? [[String: Any]] else { return [] }
        return routes.compactMap { r in
            guard let line = (r["geometry"] as? [String: Any])?["coordinates"] as? [[Double]], line.count >= 2 else { return nil }
            return (line.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) },
                    r["distance"] as? Double ?? 0, r["duration"] as? Double ?? 0)
        }
    }

    private func apple(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, walk: Bool) async -> [Way] {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        req.transportType = walk ? .walking : .automobile
        req.requestsAlternateRoutes = true
        guard let routes = try? await MKDirections(request: req).calculate().routes else { return [] }
        return routes.map { r in
            let n = r.polyline.pointCount, p = r.polyline.points()
            return ((0..<n).map { p[$0].coordinate }, r.distance, r.expectedTravelTime)
        }
    }
}

/// The phone's location for Offline Maps: on while the watch asks (`l`), off 8 s after it stops (the app closed,
/// out of reach). The answer is `L lat_e7:i32 lon_e7:i32 acc_m:u16`, or a bare `L` with no fix.
@MainActor final class PhoneFix: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var on = false
    private var askedAt: Date = .distantPast

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
    }

    func ask() -> Data {
        askedAt = .now
        if !on {
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            on = true
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
            Task { await idle() }
        }
        var m = Data([UInt8(ascii: "L")])
        guard let l = manager.location, -l.timestamp.timeIntervalSinceNow < 10, l.horizontalAccuracy >= 0,
              l.horizontalAccuracy < 100 else { return m }
        for v in [Int32((l.coordinate.latitude * 1e7).rounded()), Int32((l.coordinate.longitude * 1e7).rounded())] {
            withUnsafeBytes(of: v.littleEndian) { m.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: UInt16(l.horizontalAccuracy.rounded()).littleEndian) { m.append(contentsOf: $0) }
        return m
    }

    /// Off once the watch stops asking.
    private func idle() async {
        while on {
            try? await Task.sleep(for: .seconds(4))
            if -askedAt.timeIntervalSinceNow >= 8 {
                on = false
                manager.stopUpdatingLocation()
                manager.allowsBackgroundLocationUpdates = false
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {}
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
