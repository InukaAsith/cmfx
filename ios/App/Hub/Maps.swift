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
    var status: String?
    private var acks: [CheckedContinuation<Data, Never>] = []
    private var job: Task<Void, Never>?
    private let tiles = VectorTiles()

    func receive(_ m: Data) {
        switch m.first {
        case UInt8(ascii: "a"), UInt8(ascii: "k"), UInt8(ascii: "w"):
            if !acks.isEmpty { acks.removeFirst().resume(returning: m) }
        case UInt8(ascii: "D"):
            if let ask = VectorPack.parseAsk(m) { Task { await route(ask) } }
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
                        let data = await Task.detached { VectorPack.cell(under, level: l, col: col, row: row, origin: o) }.value
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

    /// A route the watch asked for: Apple's, as frame metres; the watch follows it with no phone.
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
        let to = AtlasScene.latLon(ask.to.0, ask.to.1, o)
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: src))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: to.lat, longitude: to.lon)))
        req.transportType = ask.walk ? .walking : .automobile
        do {
            guard let r = try await MKDirections(request: req).calculate().routes.first else {
                try? await Hub.shared.send(Self.app, VectorPack.routeFailed("No route found"))
                return
            }
            let n = r.polyline.pointCount, p = r.polyline.points()
            let pts = (0..<n).map { i -> AtlasScene.Pt in
                let c = p[i].coordinate
                return AtlasScene.xy((c.latitude, c.longitude), o)
            }
            try await Hub.shared.send(Self.app, VectorPack.route(pts, metres: r.distance, secs: r.expectedTravelTime))
        } catch {
            try? await Hub.shared.send(Self.app, VectorPack.routeFailed("No route: needs the internet"))
        }
    }
}
