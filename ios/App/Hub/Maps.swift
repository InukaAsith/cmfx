import CoreLocation
import Foundation
import MapKit
import HubKit
import UIKit

// The watch's Offline Maps app (cmf-watch-sdk sdk/examples/maps; hosts/mapbuild.py is the reference). A region
// picked here is built on the phone from Apple Maps (one snapshot per zoom level at 2×, as hosts/mapbuild.py
// --style hd: big sharp labels, none cut at a tile edge; 16 colours fitted to the map) and saved on the watch, which
// then needs no phone at all. Not OpenStreetMap's tile server: it refuses bulk downloads ("policy violation" tiles).

@MainActor @Observable final class MapsService: WatchService {
    static let app = "Offline Maps"
    var radiusKm = 2.0
    /// Zoom levels saved (1…5), out from street level (zoom 16): 4 is 13…16.
    var levels = 4
    var zooms: ClosedRange<Int> { (17 - levels)...16 }
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
        status = "Drawing the map…"
        // OSM's refused tiles from older builds
        try? FileManager.default.removeItem(at: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "osm"))
        do {
            progress = (0, total)
            var shots: [CGImage] = []
            for l in levels {
                try Task.checkCancellation()
                shots.append(try await Self.snapshot(l))
            }
            // one palette for the whole pack, from a sample of every level
            let tile = MapPack.tile
            let tiles: [(li: Int, col: Int, row: Int, rgb: [UInt8])] = levels.enumerated().flatMap { li, l in
                (0..<l.h).flatMap { row in (0..<l.w).compactMap { col -> (Int, Int, Int, [UInt8])? in
                    guard let cg = shots[li].cropping(to: CGRect(x: col * tile, y: row * tile, width: tile, height: tile))
                    else { return nil }
                    return (li, col, row, Pixels.bytes(cg, side: tile))
                } }
            }
            shots = []
            let palette = await Task.detached { () -> [(UInt8, UInt8, UInt8)] in
                var sample: [UInt8] = []
                let step = max(1, tiles.count / 24)
                for t in stride(from: 0, to: tiles.count, by: step) {
                    let rgb = tiles[t].rgb
                    for k in stride(from: 0, to: rgb.count, by: 3 * 7) { sample += rgb[k..<k + 3] }
                }
                return Quantize.medianCut(rgb: sample, colours: 16).0
            }.value
            status = nil
            for t in tiles {
                try Task.checkCancellation()
                progress = (done, total)
                let file = await Task.detached { MapPack.tileFile(Quantize.nearest(rgb: t.rgb, palette: palette)) }.value
                if done % 4 == 0 { try await Hub.shared.send(Self.app, MapPack.progress(done: done, total: total)) }
                try await sendFile(MapPack.tileName(level: t.li, col: t.col, row: t.row), file)
                done += 1
            }
            try await sendFile("idx", MapPack.index(levels, lat: c.latitude, lon: c.longitude, palette: palette))
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

    /// One zoom level from Apple Maps: (256·w)×(256·h) px, drawn at 2× (labels twice a desktop tile's size).
    static func snapshot(_ l: MapPack.Level) async throws -> CGImage {
        let side = 256.0 * pow(2.0, Double(20 - l.z))  // MKMapRect's world is 256·2²⁰ points
        let o = MKMapSnapshotter.Options()
        o.mapRect = MKMapRect(x: Double(l.x0) * side, y: Double(l.y0) * side, width: side * Double(l.w),
                              height: side * Double(l.h))
        o.size = CGSize(width: 128 * l.w, height: 128 * l.h)
        o.pointOfInterestFilter = .includingAll
        o.traitCollection = UITraitCollection(traitsFrom: [.init(userInterfaceStyle: .light), .init(displayScale: 2)])
        let shot = try await MKMapSnapshotter(options: o).start()
        let px = CGSize(width: 256 * l.w, height: 256 * l.h)
        let r = UIGraphicsImageRendererFormat()
        r.scale = 1
        let img = UIGraphicsImageRenderer(size: px, format: r).image { _ in shot.image.draw(in: CGRect(origin: .zero, size: px)) }
        guard let cg = img.cgImage else { throw HubError.failed("Apple Maps gave no picture") }
        return cg
    }
}
