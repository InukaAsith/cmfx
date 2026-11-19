import CoreLocation
import Foundation
import HubKit
import MapKit

// The watch's Navigation app (cmf-watch-sdk sdk/examples/nav; hosts/navhost.py is the reference). Directions
// from MapKit; turns go to the watch as the phone moves. Location runs only while a route is on, and stops at
// the end: nothing in the background otherwise.

@MainActor @Observable final class NavService: NSObject, WatchService, CLLocationManagerDelegate {
    static let app = "Navigation"
    var walking = true
    private var transport: MKDirectionsTransportType { walking ? .walking : .automobile }
    private(set) var destination: MKMapItem?
    private(set) var active = false
    var status: String?

    private let manager = CLLocationManager()
    private var origin = CLLocationCoordinate2D()
    private var pts: [(Double, Double)] = []
    private var cum: [Double] = []
    private var steps: [(at: Double, kind: UInt8, dir: UInt8, name: String)] = []
    private var expected: TimeInterval = 0
    private var last: Date = .distantPast
    private var lastIdx = -1

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func receive(_ m: Data) {
        if m == Data("R".utf8), active { Task { try? await sendRoute() } }
    }

    func start(to item: MKMapItem) async {
        destination = item
        status = nil
        guard let here = await here() else {
            status = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
                ? "Location is off for CMFX: turn it on in Settings › CMFX › Location" : "Couldn't find where you are"
            return
        }
        let to = item.placemark.coordinate
        let src = MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate))
        // OpenStreetMap's routes first: Apple has no directions in many countries (Sri Lanka among them). Then
        // Apple's; a straight line only when neither has a route.
        var why = ""
        if let ok = await osrm(from: here.coordinate, to: to) {
            if !ok { status = "No walking route there: following the roads" }
        } else if let r = await appleRoute(src, item, &why) {
            load(r)
        } else {
            loadDirect(from: here.coordinate, to: to)
            status = "No route found\(why.isEmpty ? "" : " (\(why))"): the watch points straight at it"
        }
        active = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        do { try await sendRoute() } catch { status = error.localizedDescription }
    }

    /// Apple's route, walking (when chosen) then the roads.
    private func appleRoute(_ src: MKMapItem, _ dest: MKMapItem, _ why: inout String) async -> MKRoute? {
        for t: MKDirectionsTransportType in walking ? [.walking, .automobile] : [.automobile] {
            let req = MKDirections.Request()
            req.source = src
            req.destination = dest
            req.transportType = t
            do {
                if let r = try await MKDirections(request: req).calculate().routes.first { return r }
            } catch { why = error.localizedDescription }
        }
        return nil
    }

    /// A route from OpenStreetMap (routing.openstreetmap.de, the FOSSGIS OSRM servers: the start and the end are
    /// all they get). → nil: no answer; true: the chosen way; false: walking had none, the roads are used.
    private func osrm(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) async -> Bool? {
        for profile in walking ? ["foot", "car"] : ["car"] {
            let url = URL(string: "https://routing.openstreetmap.de/routed-\(profile)/route/v1/driving/" +
                "\(a.longitude),\(a.latitude);\(b.longitude),\(b.latitude)?steps=true&overview=full&geometries=geojson")!
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            req.setValue("CMFX (watch navigation)", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  j["code"] as? String == "Ok", let r = (j["routes"] as? [[String: Any]])?.first,
                  let line = (r["geometry"] as? [String: Any])?["coordinates"] as? [[Double]], line.count >= 2
            else { continue }
            let coords = line.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
            origin = coords[0]
            pts = coords.map(local)
            cum = [0]
            for i in 1..<pts.count { cum.append(cum[i - 1] + hypot(pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1)) }
            expected = r["duration"] as? Double ?? 0
            // each maneuver where it happens: the step's start along the route
            var at = 0.0
            steps = []
            for leg in r["legs"] as? [[String: Any]] ?? [] {
                for st in leg["steps"] as? [[String: Any]] ?? [] {
                    let m = st["maneuver"] as? [String: Any] ?? [:]
                    let type = m["type"] as? String ?? "", modifier = m["modifier"] as? String ?? ""
                    if type != "depart" {
                        let (kind, dir) = Self.osrmManeuver(type, modifier)
                        let name = st["name"] as? String ?? ""
                        steps.append((at, kind, dir, kind == 2 ? "Arrive" : name.isEmpty ? "Continue" : name))
                    }
                    at += st["distance"] as? Double ?? 0
                }
            }
            if steps.isEmpty || steps.last?.kind != 2 { steps.append((cum.last ?? at, 2, 0, "Arrive")) }
            return profile == "foot" || !walking
        }
        return nil
    }

    /// OSRM's maneuver → the watch's (kind, dir): kinds 0 turn, 1 roundabout, 2 arrive, 3 straight, 4 ramp;
    /// dir 1-3 slight/plain/sharp left, 4-6 right, 7 u-turn.
    static func osrmManeuver(_ type: String, _ modifier: String) -> (UInt8, UInt8) {
        let dir: UInt8 = switch modifier {
        case "slight left": 1
        case "left": 2
        case "sharp left": 3
        case "slight right": 4
        case "right": 5
        case "sharp right": 6
        case "uturn": 7
        default: 0
        }
        switch type {
        case "arrive": return (2, 0)
        case "roundabout", "rotary", "roundabout turn", "exit roundabout", "exit rotary":
            return (1, dir == 0 ? 5 : (dir <= 3 ? 2 : 5))
        case "on ramp", "off ramp", "fork": return (4, dir)
        default: return dir == 0 ? (3, 0) : (0, dir)
        }
    }

    /// A pin with no route to it: one straight leg.
    private func loadDirect(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) {
        origin = a
        pts = [local(a), local(b)]
        let d = hypot(pts[1].0, pts[1].1)
        cum = [0, d]
        expected = d / (walking ? 1.4 : 11)
        steps = [(d, 2, 0, "Straight to the pin")]
    }

    private var fixWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var authWaiters: [CheckedContinuation<Void, Never>] = []

    /// Where the phone is now: asks for location access the first time, then one fix (10 s at most).
    private func here() async -> CLLocation? {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { c in
                authWaiters.append(c)
                manager.requestWhenInUseAuthorization()
            }
        }
        guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else { return nil }
        if let l = manager.location, -l.timestamp.timeIntervalSinceNow < 20, l.horizontalAccuracy < 100 { return l }
        Task { try? await Task.sleep(for: .seconds(10)); self.fix(nil) }
        return await withCheckedContinuation { c in
            fixWaiters.append(c)
            manager.requestLocation()
        }
    }

    private func fix(_ l: CLLocation?) {
        let w = fixWaiters
        fixWaiters = []
        for c in w { c.resume(returning: l ?? manager.location) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.fix(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            guard self.manager.authorizationStatus != .notDetermined else { return }
            let w = self.authWaiters
            self.authWaiters = []
            for c in w { c.resume() }
        }
    }

    func stop() {
        active = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
    }

    private func local(_ c: CLLocationCoordinate2D) -> (Double, Double) {
        ((c.longitude - origin.longitude) * cos(origin.latitude * .pi / 180) * 111_320, (c.latitude - origin.latitude) * 110_540)
    }

    private func load(_ r: MKRoute) {
        let n = r.polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: n)
        r.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        origin = coords.first ?? .init()
        pts = coords.map(local)
        cum = [0]
        for i in 1..<max(pts.count, 1) where pts.count > 1 {
            cum.append(cum[i - 1] + hypot(pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1))
        }
        expected = r.expectedTravelTime
        var at = 0.0
        steps = r.steps.map { s in
            defer { at += s.distance }
            let (kind, dir) = Self.maneuver(s.instructions)
            return (at + s.distance, kind, dir, s.instructions.isEmpty ? "Continue" : s.instructions)
        }
        if let lastStep = steps.indices.last { steps[lastStep].kind = 2 }
    }

    /// MapKit gives words, not maneuver types: read the turn from them (English).
    static func maneuver(_ t: String) -> (UInt8, UInt8) {
        let s = t.lowercased()
        if s.contains("arrive") || s.contains("destination") { return (2, 0) }
        if s.contains("roundabout") { return (1, s.contains("left") ? 2 : 5) }
        if s.contains("u-turn") { return (0, 7) }
        let slight = s.contains("slight") || s.contains("bear") || s.contains("keep")
        let sharp = s.contains("sharp")
        if s.contains("left") { return (s.contains("ramp") || s.contains("exit") ? 4 : 0, sharp ? 3 : slight ? 1 : 2) }
        if s.contains("right") { return (s.contains("ramp") || s.contains("exit") ? 4 : 0, sharp ? 6 : slight ? 4 : 5) }
        return (3, 0)
    }

    private func sendRoute() async throws {
        try await Hub.shared.send(Self.app, NavProto.route(NavProto.simplify(pts)))
    }

    /// Distance along the route nearest to `p`.
    private func along(_ p: (Double, Double)) -> (s: Double, off: Double) {
        var best = (s: 0.0, off: Double.infinity)
        for i in 0..<max(pts.count - 1, 0) {
            let (a, b) = (pts[i], pts[i + 1])
            let (dx, dy) = (b.0 - a.0, b.1 - a.1)
            let len2 = max(dx * dx + dy * dy, 1e-9)
            let t = min(max(((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2, 0), 1)
            let (x, y) = (a.0 + dx * t, a.1 + dy * t)
            let d = hypot(p.0 - x, p.1 - y)
            if d < best.off { best = (cum[i] + t * (cum[i + 1] - cum[i]), d) }
        }
        return best
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        Task { @MainActor in
            if !self.fixWaiters.isEmpty { self.fix(loc) }
            await self.update(loc)
        }
    }

    private func update(_ loc: CLLocation) async {
        guard active, !pts.isEmpty, -last.timeIntervalSinceNow >= 1 else { return }
        last = .now
        let p = local(loc.coordinate)
        let (s, off) = along(p)
        let length = cum.last ?? 0
        if off > 60, let destination {
            try? await Hub.shared.send(Self.app, NavProto.rerouting)
            await start(to: destination)
            return
        }
        if length - s < 20 {
            try? await Hub.shared.send(Self.app, NavProto.arrived)
            stop()
            return
        }
        let idx = steps.firstIndex { $0.at > s + 3 } ?? (steps.count - 1)
        let st = steps[idx]
        let left = length - s
        let secs = expected * left / max(length, 1)
        let eta = Calendar.current.dateComponents([.hour, .minute], from: .now + secs)
        let heading = loc.course >= 0 ? loc.course : 0
        try? await Hub.shared.send(Self.app, [
            NavProto.position(x: p.0, y: p.1, heading: heading),
            NavProto.step(idx: idx, kind: st.kind, dir: st.dir, distM: Int(st.at - s), etaMin: Int(secs / 60),
                          leftM: Int(left), arrive: (eta.hour ?? 0, eta.minute ?? 0), street: st.name),
        ])
        if idx != lastIdx { lastIdx = idx }
    }
}
