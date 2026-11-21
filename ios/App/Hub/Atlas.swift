import CoreLocation
import Foundation
import HubKit
import MapKit
import UIKit
import WireKit

// The watch's Maps app (cmf-watch-sdk sdk/examples/atlas, proto.rs): the map round us with the last search's places
// on it, search near us (MapKit, then OpenStreetMap's Nominatim when Apple has nothing), how long a place is by car,
// bike and on foot, a route that way (NavService: OpenStreetMap's routes first, then Apple's), each step of it
// checked on the map, then turn by turn. The maps are Apple Maps snapshots in
// dark mode with the route drawn on, sent as pictures over the sliding window. Nothing runs unless Maps is open on
// the watch; location only for an answer, and all the time only while navigating.

@MainActor @Observable final class AtlasService: WatchService {
    static let app = "Maps"
    /// The watch app's layout (atlas ui.rs `band`): the rows each screen gives the map.
    enum Band {
        static let home = (top: 0, bottom: 466)
        static let route = (top: 104, bottom: 376)
    }
    /// Metres per watch pixel for Home's zooms 0 … 4.
    static let homeScale: [Double] = [16, 8, 4, 2, 1]

    let nav = NavService(target: AtlasService.app)
    private(set) var results: [MKMapItem] = []
    private(set) var place: MKMapItem?
    var status: String?

    /// The picture being sent; a newer request ends an older one.
    private var gen = 0
    private var queue: [Data] = []
    private var last: (id: UInt8, msgs: [Data])?

    func receive(_ m: Data) {
        guard let ask = AtlasProto.parse(m) else { return }
        switch ask {
        case .ready:
            Task { try? await Hub.shared.send(Self.app, AtlasProto.hello) }
        case .home(let id, let zoom, let east, let south):
            picture(id) { await self.homeMap(zoom: zoom, east: east, south: south) }
        case .search(let q):
            Task { await search(q) }
        case .ways(let idx):
            guard idx < results.count else { return fail("That place is gone: search again") }
            place = results[idx]
            Task { await ways(to: results[idx]) }
        case .directions(let mode, let idx):
            Task { await directions(mode: mode, idx: idx) }
        case .view(let id, let step):
            picture(id) { await self.routeMap(step: step) }
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

    private func directions(mode: Int, idx: Int) async {
        guard idx < results.count else { return fail("That place is gone: search again") }
        nav.stop()
        nav.mode = NavService.Mode(rawValue: mode) ?? .drive
        guard await nav.plan(to: results[idx]) else { return fail(nav.status ?? "Couldn't find where you are") }
        let eta = Calendar.current.dateComponents([.hour, .minute], from: .now + nav.expected)
        let msgs = AtlasProto.route(mode: UInt8(mode), secs: nav.expected, metres: nav.length,
                                    arrive: (eta.hour ?? 0, eta.minute ?? 0), steps: nav.steps)
        do { try await Hub.shared.send(Self.app, msgs) } catch { status = error.localizedDescription }
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

    // --- pictures

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

    /// Round us, moved `east`/`south` thirds of the view (the watch's edge taps); the last search's places as
    /// labelled pins.
    private func homeMap(zoom: Int, east: Int, south: Int) async -> [Data]? {
        guard let here = await nav.here() else {
            fail("Location is off for CMFX")
            return nil
        }
        let k = Self.homeScale[min(max(zoom, 0), Self.homeScale.count - 1)]
        let step = k * 466 / 3 * MKMapPointsPerMeterAtLatitude(here.coordinate.latitude)
        let p = MKMapPoint(here.coordinate)
        let centre = MKMapPoint(x: p.x + Double(east) * step, y: p.y + Double(south) * step).coordinate
        let places = results.map { ($0.placemark.coordinate, $0.name ?? "") }
        return await MapArt.picture(id: currentID, band: Band.home, centre: centre,
                                    metresPerPx: k, focusY: (Band.home.top + Band.home.bottom) / 2) { snap, _ in
            for (c, name) in places { MapArt.pin(snap, c, label: name) }
            MapArt.me(snap, here.coordinate)
        }
    }

    private func routeMap(step: Int) async -> [Data]? {
        let line = nav.coords
        guard line.count >= 2 else { return nil }
        let dest = nav.destination?.placemark.coordinate ?? line[line.count - 1]
        let draw: (MKMapSnapshotter.Snapshot, CGContext) -> Void = { snap, _ in
            MapArt.route(snap, line)
            MapArt.pin(snap, dest)
            MapArt.me(snap, line[0])
        }
        let b = Band.route
        if step == 0 || step > nav.steps.count {
            return await MapArt.fitted(id: currentID, band: b, line: line, draw: draw)
        }
        let st = nav.steps[step - 1]
        guard let at = nav.coordinate(at: st.at) else { return nil }
        return await MapArt.picture(id: currentID, band: b, centre: at, metresPerPx: 1.5, focusY: (b.top + b.bottom) / 2) { snap, ctx in
            draw(snap, ctx)
            MapArt.focus(snap, at)
        }
    }

    /// The id of the picture being made (the last one asked for).
    private var currentID: UInt8 = 0
}

/// Apple Maps snapshots for the watch: 233 px square (the watch draws each pixel 2 × 2), dark, cut to the rows the
/// screen gives the map and to the round panel, black elsewhere.
@MainActor enum MapArt {
    static let side = 233
    static let red = UIColor(red: 0xD7 / 255, green: 0x19 / 255, blue: 0x21 / 255, alpha: 1)

    /// `centre` at watch pixel (233, focusY), `metresPerPx` metres a watch pixel.
    static func picture(id: UInt8, band: (top: Int, bottom: Int), centre: CLLocationCoordinate2D, metresPerPx: Double,
                        focusY: Int, draw: @escaping (MKMapSnapshotter.Snapshot, CGContext) -> Void) async -> [Data]? {
        let perPx = metresPerPx * 2 * MKMapPointsPerMeterAtLatitude(centre.latitude)  // map points a picture pixel
        let p = MKMapPoint(centre)
        let w = perPx * Double(side)
        let rect = MKMapRect(x: p.x - w / 2, y: p.y - perPx * Double(focusY) / 2, width: w, height: w)
        return await render(id: id, band: band, rect: rect, draw: draw)
    }

    /// All of `line` inside the band, with a margin.
    static func fitted(id: UInt8, band: (top: Int, bottom: Int), line: [CLLocationCoordinate2D],
                       draw: @escaping (MKMapSnapshotter.Snapshot, CGContext) -> Void) async -> [Data]? {
        let pts = line.map(MKMapPoint.init)
        let (x0, x1) = (pts.map(\.x).min()!, pts.map(\.x).max()!)
        let (y0, y1) = (pts.map(\.y).min()!, pts.map(\.y).max()!)
        // the band's usable box in watch pixels: its height less a margin, the chord at its middle
        let h = Double(band.bottom - band.top - 40), wpx = 340.0
        let perWatchPx = max((x1 - x0) / wpx, (y1 - y0) / h, 0.5 * MKMapPointsPerMeterAtLatitude(line[0].latitude))
        let perPx = perWatchPx * 2
        let w = perPx * Double(side)
        let cy = Double(band.top + band.bottom) / 2
        let rect = MKMapRect(x: (x0 + x1) / 2 - w / 2, y: (y0 + y1) / 2 - perPx * cy / 2, width: w, height: w)
        return await render(id: id, band: band, rect: rect, draw: draw)
    }

    static func render(id: UInt8, band: (top: Int, bottom: Int), rect: MKMapRect,
                       draw: @escaping (MKMapSnapshotter.Snapshot, CGContext) -> Void) async -> [Data]? {
        let o = MKMapSnapshotter.Options()
        o.mapRect = rect
        o.size = CGSize(width: side, height: side)
        o.traitCollection = UITraitCollection { t in
            t.userInterfaceStyle = .dark
            t.displayScale = 1
        }
        let cfg = MKStandardMapConfiguration(emphasisStyle: .default)
        cfg.pointOfInterestFilter = .excludingAll
        o.preferredConfiguration = cfg
        guard let snap = try? await MKMapSnapshotter(options: o).start() else { return nil }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let full = CGRect(x: 0, y: 0, width: side, height: side)
        let img = UIGraphicsImageRenderer(size: full.size, format: fmt).image { ctx in
            UIColor.black.setFill()
            ctx.fill(full)
            ctx.cgContext.saveGState()
            UIBezierPath(ovalIn: full).addClip()
            snap.image.draw(in: full)
            draw(snap, ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
        // only the band's rows go (each picture row is 2 watch rows)
        let r0 = band.top / 2, r1 = min((band.bottom + 1) / 2, side)
        guard let cg = img.cgImage?.cropping(to: CGRect(x: 0, y: r0, width: side, height: r1 - r0)) else { return nil }
        let rgb = rgbBytes(cg, width: side, height: r1 - r0)
        return AtlasProto.picture(id: id, rgb: rgb, width: side, height: r1 - r0, scale: 2, x0: 0, y0: Int16(r0 * 2))
    }

    static func rgbBytes(_ cg: CGImage, width: Int, height: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[3 * i] = rgba[4 * i]; rgb[3 * i + 1] = rgba[4 * i + 1]; rgb[3 * i + 2] = rgba[4 * i + 2]
        }
        return rgb
    }

    /// We are here: a red dot in a white ring.
    static func me(_ s: MKMapSnapshotter.Snapshot, _ c: CLLocationCoordinate2D) {
        let p = s.point(for: c)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)).fill()
        red.setFill()
        UIBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
    }

    /// The place: a red pin with a white edge and a black eye; its name beside it, white on a dark edge.
    static func pin(_ s: MKMapSnapshotter.Snapshot, _ c: CLLocationCoordinate2D, label: String? = nil) {
        let p = s.point(for: c)
        if let label, !label.isEmpty, CGRect(x: 0, y: 0, width: side, height: side).contains(p) {
            let text = label.count > 18 ? String(label.prefix(17)) + "…" : label
            let font = UIFont.systemFont(ofSize: 10, weight: .bold)
            let x = p.x + 9 + (text as NSString).size(withAttributes: [.font: font]).width > CGFloat(side) - 4
                ? p.x - 9 - (text as NSString).size(withAttributes: [.font: font]).width : p.x + 9
            for (colour, width) in [(UIColor.black, 4.0), (UIColor.white, 0.0)] {
                (text as NSString).draw(at: CGPoint(x: x, y: p.y - 18), withAttributes: [
                    .font: font, .foregroundColor: UIColor.white, .strokeColor: colour, .strokeWidth: width])
            }
        }
        let head = CGRect(x: p.x - 7, y: p.y - 19, width: 14, height: 14)
        let body = UIBezierPath(ovalIn: head)
        body.move(to: CGPoint(x: p.x - 6, y: p.y - 9))
        body.addLine(to: CGPoint(x: p.x, y: p.y))
        body.addLine(to: CGPoint(x: p.x + 6, y: p.y - 9))
        body.close()
        UIColor.white.setStroke()
        body.lineWidth = 3
        body.stroke()
        red.setFill()
        body.fill()
        UIColor.black.setFill()
        UIBezierPath(ovalIn: CGRect(x: p.x - 2.5, y: p.y - 14.5, width: 5, height: 5)).fill()
    }

    /// The route: red on a black casing.
    static func route(_ s: MKMapSnapshotter.Snapshot, _ line: [CLLocationCoordinate2D]) {
        let path = UIBezierPath()
        for (i, c) in line.enumerated() {
            let p = s.point(for: c)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        UIColor.black.setStroke()
        path.lineWidth = 6
        path.stroke()
        red.setStroke()
        path.lineWidth = 3.5
        path.stroke()
    }

    /// The step being checked: a white ring round it.
    static func focus(_ s: MKMapSnapshotter.Snapshot, _ c: CLLocationCoordinate2D) {
        let p = s.point(for: c)
        let ring = UIBezierPath(ovalIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
        ring.lineWidth = 2.5
        UIColor.white.setStroke()
        ring.stroke()
    }
}
