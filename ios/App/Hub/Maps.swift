import CoreLocation
import Foundation
import HubKit
import UIKit

// The watch's Offline Maps app (cmf-watch-sdk sdk/examples/maps; hosts/mapbuild.py is the reference). A region
// picked here is built on the phone (OpenStreetMap tiles → the Nothing dark style) and saved on the watch, which
// then needs no phone at all. Tiles are fetched once, slowly (OSM's tile policy), and cached.

@MainActor @Observable final class MapsService: WatchService {
    static let app = "Offline Maps"
    var radiusKm = 2.0
    var zooms = 13...16
    private(set) var progress: (done: Int, total: Int)?
    var status: String?
    private var acks: [CheckedContinuation<Data, Never>] = []
    private var job: Task<Void, Never>?

    func receive(_ m: Data) {
        switch m.first {
        case UInt8(ascii: "a"), UInt8(ascii: "k"):
            if !acks.isEmpty { acks.removeFirst().resume(returning: m) }
        case UInt8(ascii: "R"):
            // the app opened: where the phone is, for the red dot
            Task { await sendPosition() }
        default: break
        }
    }

    private func ack() async -> Data { await withCheckedContinuation { acks.append($0) } }

    func tileCount(_ c: CLLocationCoordinate2D) -> Int {
        MapPack.levels(lat: c.latitude, lon: c.longitude, radiusKm: radiusKm, zooms: zooms).reduce(0) { $0 + $1.w * $1.h }
    }

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
        let levels = MapPack.levels(lat: c.latitude, lon: c.longitude, radiusKm: radiusKm, zooms: zooms)
        let total = levels.reduce(0) { $0 + $1.w * $1.h } + 1
        guard total <= 400 else { status = "Too many tiles (\(total)): pick a smaller area"; return }
        var done = 0
        status = nil
        do {
            for (li, l) in levels.enumerated() {
                for row in 0..<l.h {
                    for col in 0..<l.w {
                        try Task.checkCancellation()
                        progress = (done, total)
                        let rgb = try await Self.osm(z: l.z, x: l.x0 + col, y: l.y0 + row)
                        let file = await Task.detached { MapPack.tileFile(MapPack.styled(rgb: rgb)) }.value
                        if done % 4 == 0 { try await Hub.shared.send(Self.app, MapPack.progress(done: done, total: total)) }
                        try await sendFile(MapPack.tileName(level: li, col: col, row: row), file)
                        done += 1
                    }
                }
            }
            try await sendFile("idx", MapPack.index(levels, lat: c.latitude, lon: c.longitude))
            try await Hub.shared.send(Self.app, Data("Z".utf8))
            _ = await ack()
            status = "Saved on the watch: \(total) files"
        } catch is CancellationError {
        } catch {
            status = error.localizedDescription
        }
    }

    private func sendFile(_ name: String, _ data: Data) async throws {
        try await Hub.shared.send(Self.app, MapPack.fileMessages(name: name, data: data))
        _ = await ack()
    }

    private func sendPosition() async {
        guard let loc = CLLocationManager().location else { return }
        try? await Hub.shared.send(Self.app, MapPack.position(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude))
    }

    /// One OSM tile's RGB, from the cache or (politely) the tile server.
    static func osm(z: Int, x: Int, y: Int) async throws -> [UInt8] {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "osm")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(z)_\(x)_\(y).png")
        var data = try? Data(contentsOf: file)
        if data == nil {
            var req = URLRequest(url: URL(string: "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png")!)
            req.setValue("CMFX/1.0 (offline watch maps)", forHTTPHeaderField: "User-Agent")
            let (d, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw HubError.failed("Map tiles unavailable") }
            try? d.write(to: file)
            data = d
            try await Task.sleep(for: .milliseconds(300))
        }
        guard let img = UIImage(data: data!)?.cgImage else { throw HubError.failed("Bad map tile") }
        return Pixels.bytes(img, side: MapPack.tile)
    }
}
