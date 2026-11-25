import CoreLocation
import Foundation
import HubKit
import MapKit
import UIKit

// The watch's Navigation app (cmf-watch-sdk sdk/examples/nav; hosts/navhost.py is the reference). Directions
// from MapKit; turns go to the watch as the phone moves. Location runs only while a route is on, and stops at
// the end: nothing in the background otherwise.

@MainActor @Observable final class NavService: NSObject, WatchService, CLLocationManagerDelegate {
    nonisolated static let app = "Navigation"
    enum Mode: Int { case drive, bike, walk }
    var mode: Mode = .walk
    /// Navigation's page picker: walking or the roads.
    var walking: Bool {
        get { mode == .walk }
        set { mode = newValue ? .walk : .drive }
    }
    /// The watch app the turns go to (Navigation, or Maps' own copy of this service).
    let target: String
    private(set) var destination: MKMapItem?
    private(set) var active = false
    var status: String?
    /// What it is doing now (the page shows a spinner with it), nil when idle.
    var working: String?

    private let manager = CLLocationManager()
    private var origin = CLLocationCoordinate2D()
    private var pts: [(Double, Double)] = []
    private var cum: [Double] = []
    /// The route as planned: its line, its steps (where along it, the watch's kind and dir, the street), the time.
    private(set) var coords: [CLLocationCoordinate2D] = []
    private(set) var steps: [(at: Double, kind: UInt8, dir: UInt8, name: String)] = []
    private(set) var expected: TimeInterval = 0
    var length: Double { cum.last ?? 0 }
    private var last: Date = .distantPast
    private var lastIdx = -1
    /// Rerouting keeps the frame: the watch's map and the turns so far are in it (a new origin shifted the line
    /// off the roads by as far as we had come).
    private var keepOrigin = false
    /// Where along the route we were (metres): the next fix is looked for near it, not anywhere on the route.
    private var lastS: Double?
    /// (when, metres along) over the last minute: how fast we really go, for the time left.
    private var progress: [(t: Date, s: Double)] = []
    private var rerouting = false
    private var reroutedAt: Date = .distantPast
    private var offCount = 0
    private var ticker: Task<Void, Never>?
    /// Stops on the way, in order (Maps adds them, searched for on the watch); passed ones drop off, so a reroute
    /// goes through the rest.
    var stops: [MKMapItem] = []
    /// where along the route each stop left is (metres)
    private var stopAt: [Double] = []

    init(target: String = NavService.app) {
        self.target = target
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func receive(_ m: Data) {
        switch NavProto.parse(m) {
        case .ready:
            // the route if one is on (and where we are on it at once: the watch shows it straight away), else
            // where it may go: the last places gone to
            if active {
                Task {
                    try? await sendRoute()
                    await updateNow()
                }
            } else {
                Task { await offer(recent) }
            }
        case .resync:
            resync()
        case .cancel:
            end()
            Task { await offer(recent) }
        case .map(let id, let x, let y):
            // the streets round where the watch's map view is, as Maps draws them (only one at a time: a newer ask
            // drops the older)
            guard active, target == Self.app else { return }
            mapGen += 1
            let g = mapGen
            let o = origin
            Task {
                let centre = (Double(x), Double(y))
                guard let b = await Hub.shared.atlas.navScene(origin: o, centre: centre), g == mapGen, active else { return }
                let me = manager.location.map { local($0.coordinate) } ?? centre
                await stream(AtlasProto.scene(id: id, data: b.data, me: me, centre: centre, r: b.r), gen: g)
            }
        case .search(let q):
            Task {
                try? await Hub.shared.send(target, NavProto.note("Searching\u{2026}"))
                let found = await Place.search(q)
                if found.isEmpty { try? await Hub.shared.send(target, NavProto.note("Nothing found")) }
                await offer(found.map { (item: $0.item, detail: $0.detail) })
            }
        case .start(let idx, let walk):
            // as the phone's page does: the page shows it too, and its Stop ends it
            guard offered.indices.contains(idx) else { return }
            let item = offered[idx].item
            walking = walk
            // the phone may be in a pocket: kept awake till the route is found and on its way (planning can take
            // longer than the few seconds a watch message buys)
            let bg = UIApplication.shared.beginBackgroundTask(withName: "nav-start")
            Task {
                defer { UIApplication.shared.endBackgroundTask(bg) }
                try? await Hub.shared.send(target, NavProto.note("Finding a route\u{2026}"))
                await start(to: item)
                if !active { try? await Hub.shared.send(target, NavProto.note(status ?? "No route there")) }
            }
        case nil: break
        }
    }

    /// The places the watch was last sent (`S idx` picks one).
    private var offered: [(item: MKMapItem, detail: String)] = []

    private func offer(_ places: [(item: MKMapItem, detail: String)]) async {
        offered = Array(places.prefix(8))
        try? await Hub.shared.send(target, NavProto.places(offered.map { ($0.item.name ?? "Pin", $0.detail) }, walking: walking))
    }

    /// The last 3 places gone to (on this phone only), newest first: the watch offers them.
    private static let recentKey = "nav-recent"
    private var recent: [(item: MKMapItem, detail: String)] {
        (UserDefaults.standard.array(forKey: Self.recentKey) as? [[String: Any]] ?? []).compactMap { d in
            guard let lat = d["lat"] as? Double, let lon = d["lon"] as? Double else { return nil }
            let i = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: lat, longitude: lon)))
            i.name = d["name"] as? String
            return (i, d["detail"] as? String ?? "")
        }
    }

    private func remember(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        let p = item.placemark
        let detail = [p.thoroughfare, p.locality].compactMap { $0 }.joined(separator: ", ")
        let me: [String: Any] = ["name": item.name ?? "Pin", "lat": c.latitude, "lon": c.longitude,
                                 "detail": offered.first { $0.item === item }?.detail ?? detail]
        let rest = (UserDefaults.standard.array(forKey: Self.recentKey) as? [[String: Any]] ?? []).filter {
            abs(($0["lat"] as? Double ?? 0) - c.latitude) > 0.0003 || abs(($0["lon"] as? Double ?? 0) - c.longitude) > 0.0003
        }
        UserDefaults.standard.set(Array(([me] + rest).prefix(3)), forKey: Self.recentKey)
    }

    /// The page's Start: the route planned (and picked) on its way to the watch.
    func startPlanned() async {
        guard let d = destination, !coords.isEmpty else { return }
        if target == Self.app { remember(d) }
        await begin()
    }

    /// The page's plan dropped (not while navigating).
    func clearPlan() {
        guard !active else { return }
        destination = nil
        stops = []
        alternatives = []
        coords = []
        status = nil
    }

    func start(to item: MKMapItem) async {
        guard await plan(to: item) else { return }
        if target == Self.app { remember(item) }
        await begin()
    }

    /// The route to `item` from here, not started (Maps shows it first). false: we don't know where we are.
    func plan(to item: MKMapItem) async -> Bool {
        destination = item
        chosen = 0
        keepOrigin = active && !coords.isEmpty
        defer { keepOrigin = false }
        status = nil
        working = "Finding where you are…"
        defer { working = nil }
        guard let here = await here() else {
            planFix = nil
            status = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
                ? "Location is off for CMFX: turn it on in Settings › CMFX › Location" : "Couldn't find where you are"
            return false
        }
        planFix = here
        let to = item.placemark.coordinate
        let src = MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate))
        // OpenStreetMap's routes first: Apple has no directions in many countries (Sri Lanka among them). Then
        // Apple's; a straight line only when neither has a route.
        var why = ""
        working = "Finding a route…"
        alternatives = []
        if let ok = await osrm(from: here.coordinate, to: to) {
            if !ok { status = "No \(mode == .bike ? "cycling" : "walking") route there: following the roads" }
        } else if let legs = await appleLegs(from: src, to: item, &why) {
            load(legs)
        } else {
            loadDirect(from: here.coordinate, to: to)
            status = "No route found\(why.isEmpty ? "" : " (\(why))"): the watch points straight at it"
        }
        return true
    }

    /// Turns to the watch from now on, as the phone moves.
    func begin() async {
        active = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        lastS = nil
        progress = []
        offCount = 0
        do { try await sendRoute() } catch { status = error.localizedDescription }
        // the first turn at once, from the fix the plan used if no newer one: the watch leaves "Finding a route"
        await updateNow()
        // standing still brings no fixes: the time left and the arrival still move on
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                // standing still sends no fixes: the turn and position again every few seconds, so the watch
                // never goes quiet (it calls 12 s without one lost and asks again)
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.active else { return }
                if -self.last.timeIntervalSinceNow >= 4, let l = self.manager.location { await self.update(l) }
            }
        }
    }

    /// Apple's route, walking (when chosen) then the roads.
    private func appleRoute(_ src: MKMapItem, _ dest: MKMapItem, _ why: inout String) async -> MKRoute? {
        for t: MKDirectionsTransportType in mode == .drive ? [.automobile] : [.walking, .automobile] {
            let req = MKDirections.Request()
            req.source = src
            req.destination = dest
            req.transportType = t
            req.requestsAlternateRoutes = true
            do {
                let routes = try await MKDirections(request: req).calculate().routes
                if let r = routes.first {
                    alternatives = routes.prefix(3).map { .apple($0) }
                    return r
                }
            } catch { why = error.localizedDescription }
        }
        return nil
    }

    /// Apple's route through the stops: one route a leg (Apple takes no stops); nil when a leg has none.
    private func appleLegs(from src: MKMapItem, to dest: MKMapItem, _ why: inout String) async -> [MKRoute]? {
        let ends = [src] + stops + [dest]
        var legs: [MKRoute] = []
        for i in 0..<(ends.count - 1) {
            guard let r = await appleRoute(ends[i], ends[i + 1], &why) else { return nil }
            legs.append(r)
        }
        if legs.count > 1 { alternatives = [] }
        return legs
    }

    /// A way there: OSRM's route (its JSON) or Apple's.
    enum Alt { case osrm([String: Any]), apple(MKRoute) }
    /// The ways there the last plan found (the first is the one loaded), to pick from when there are two or three.
    private(set) var alternatives: [Alt] = []

    /// Each way's time, length and the roads it goes by.
    var alternativeRows: [(secs: Double, metres: Double, via: String)] {
        alternatives.map { a in
            switch a {
            case .osrm(let r):
                let via = ((r["legs"] as? [[String: Any]])?.first?["summary"] as? String) ?? ""
                return (r["duration"] as? Double ?? 0, r["distance"] as? Double ?? 0, via.isEmpty ? "the roads" : via)
            case .apple(let r):
                return (r.expectedTravelTime, r.distance, r.name.isEmpty ? "the roads" : r.name)
            }
        }
    }

    /// Each way's line, for the watch's pick map.
    var alternativeLines: [[CLLocationCoordinate2D]] {
        alternatives.map { a in
            switch a {
            case .osrm(let r):
                let line = (r["geometry"] as? [String: Any])?["coordinates"] as? [[Double]] ?? []
                return line.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
            case .apple(let r):
                var c = [CLLocationCoordinate2D](repeating: .init(), count: r.polyline.pointCount)
                r.polyline.getCoordinates(&c, range: NSRange(location: 0, length: c.count))
                return c
            }
        }
    }

    /// The way of `alternatives` loaded now.
    private(set) var chosen = 0

    /// Way `k` of the last plan's, loaded as the route.
    func choose(_ k: Int) {
        guard alternatives.indices.contains(k) else { return }
        chosen = k
        switch alternatives[k] {
        case .osrm(let r): loadOSRM(r)
        case .apple(let r): load([r])
        }
    }

    /// A route from OpenStreetMap (routing.openstreetmap.de, the FOSSGIS OSRM servers: the start and the end are
    /// all they get, and on a reroute the way we head). → nil: no answer; true: the chosen way; false: walking had
    /// none, the roads are used. `quick` (a reroute): each server once, a short wait.
    private func osrm(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, quick: Bool = false) async -> Bool? {
        // the FOSSGIS servers now and then fail a connection: each is tried twice; the OSRM demo server (roads
        // only) last
        let base = "https://routing.openstreetmap.de/routed-"
        let n = quick ? 1 : 2
        let own: [(String, String)] = switch mode {
        case .walk: Array(repeating: ("foot", base + "foot"), count: n)
        case .bike: Array(repeating: ("bike", base + "bike"), count: n)
        case .drive: []
        }
        let tries = own + Array(repeating: ("car", base + "car"), count: n) + [("car", "https://router.project-osrm.org")]
        for (profile, server) in tries {
            guard let routes = await osrmRoutes(server, a, b, wait: quick ? 8 : 20) else { continue }
            var all = routes
            // on foot, a way by the roads that is shorter (a footpath detour, a missing crossing): that one, at a
            // walking pace
            if mode == .walk, profile == "foot", let foot = all.first,
               let car = await osrmRoutes(base + "car", a, b, wait: quick ? 6 : 10)?.first,
               let fd = foot["distance"] as? Double, let cd = car["distance"] as? Double, cd < fd - 30 {
                var walked = car
                let pace = (foot["duration"] as? Double ?? fd / 1.4) / max(fd, 1)
                walked["duration"] = cd * pace
                all.insert(walked, at: 0)
            }
            // a way much longer than the shortest is a detour, not a choice
            let shortest = all.compactMap { $0["distance"] as? Double }.min() ?? 0
            all = all.filter { ($0["distance"] as? Double ?? 0) <= max(shortest * 1.8, shortest + 1500) }
            alternatives = all.prefix(3).map { .osrm($0) }
            loadOSRM(all[0])
            return profile != "car" || mode == .drive
        }
        return nil
    }

    /// One server's routes (OSRM JSON), nil when it gave none.
    private func osrmRoutes(_ server: String, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                            wait: TimeInterval) async -> [[String: Any]]? {
        let via = [a] + stops.map(\.placemark.coordinate) + [b]
        // other ways only between two points (OSRM gives none through stops)
        var q = "steps=true&overview=full&geometries=geojson&alternatives=\(via.count == 2)"
        if let h = heading { q += "&bearings=\(Int(h.rounded()) % 360),60" + String(repeating: ";", count: via.count - 1) }
        let url = URL(string: server + "/route/v1/driving/" +
            via.map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";") + "?" + q)!
        var req = URLRequest(url: url)
        req.timeoutInterval = wait
        req.setValue("CMFX (watch navigation)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              j["code"] as? String == "Ok", let routes = j["routes"] as? [[String: Any]], let r = routes.first,
              let line = (r["geometry"] as? [String: Any])?["coordinates"] as? [[Double]], line.count >= 2
        else { return nil }
        return routes
    }

    /// The way we head on a reroute (degrees), so the new route doesn't start with a U-turn.
    private var heading: Double?

    /// One OSRM route (steps, full geometry as GeoJSON) as the route.
    private func loadOSRM(_ r: [String: Any]) {
        guard let line = (r["geometry"] as? [String: Any])?["coordinates"] as? [[Double]], line.count >= 2 else { return }
        do {
            coords = line.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
            if !keepOrigin { origin = coords[0] }
            pts = coords.map(local)
            cum = [0]
            for i in 1..<pts.count { cum.append(cum[i - 1] + hypot(pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1)) }
            expected = r["duration"] as? Double ?? 0
            // each maneuver where it happens: the step's start along the route
            var at = 0.0
            steps = []
            stopAt = []
            let legs = r["legs"] as? [[String: Any]] ?? []
            for (li, leg) in legs.enumerated() {
                for st in leg["steps"] as? [[String: Any]] ?? [] {
                    let m = st["maneuver"] as? [String: Any] ?? [:]
                    let type = m["type"] as? String ?? "", modifier = m["modifier"] as? String ?? ""
                    if type != "depart" {
                        let (kind, dir) = Self.osrmManeuver(type, modifier)
                        let name = st["name"] as? String ?? ""
                        // a leg's end before the last: one of the stops
                        let stop = kind == 2 && li < legs.count - 1
                        if stop { stopAt.append(at) }
                        steps.append((at, kind, dir, stop ? stopName(li) : kind == 2 ? "Arrive" : name.isEmpty ? "Continue" : name))
                    }
                    at += st["distance"] as? Double ?? 0
                }
            }
            if steps.isEmpty || steps.last?.kind != 2 { steps.append((cum.last ?? at, 2, 0, "Arrive")) }
        }
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

    /// How long to `item` by `way` and how far, without changing the route: OpenStreetMap's profile for it, then
    /// Apple's estimate (not for bikes). nil: no route that way.
    func summary(to item: MKMapItem, by way: Mode) async -> (secs: Double, metres: Double)? {
        guard let here = await here() else { return nil }
        let a = here.coordinate, b = item.placemark.coordinate
        if way == .walk {
            // as the route itself (osrm): the roads' way when the footpaths' is longer, at a walking pace (OSM's
            // foot router now and then goes a long way round: 13 km to a place 650 m off)
            async let foot = osrmSummary("foot", a, b, way)
            async let car = osrmSummary("car", a, b, .drive)
            let (f, c) = await (foot, car)
            if let c, c.metres < (f?.metres ?? .infinity) - 30 {
                let pace = f.map { $0.secs / max($0.metres, 1) } ?? (1 / 1.35)
                return (c.metres * pace, c.metres)
            }
            if let f { return f }
        } else if let r = await osrmSummary(["car", "bike", "foot"][way.rawValue], a, b, way) {
            return r
        }
        guard way != .bike else { return nil }
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        req.destination = item
        req.transportType = way == .drive ? .automobile : .walking
        guard let eta = try? await MKDirections(request: req).calculateETA() else { return nil }
        return (eta.expectedTravelTime, eta.distance)
    }

    /// OSRM's time and length (no steps) by `profile`, nil when it has none.
    private func osrmSummary(_ profile: String, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                             _ way: Mode) async -> (secs: Double, metres: Double)? {
        let base = "https://routing.openstreetmap.de/routed-" + profile
        for server in [base, base] + (way == .drive ? ["https://router.project-osrm.org"] : []) {
            let url = URL(string: server + "/route/v1/driving/\(a.longitude),\(a.latitude);\(b.longitude),\(b.latitude)?overview=false")!
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            req.setValue("CMFX (watch navigation)", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard j["code"] as? String == "Ok", let r = (j["routes"] as? [[String: Any]])?.first,
                  let secs = r["duration"] as? Double, let metres = r["distance"] as? Double else { break }
            return (secs, metres)
        }
        return nil
    }

    /// A pin with no route to it: one straight leg.
    private func loadDirect(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) {
        alternatives = []
        if !keepOrigin { origin = a }
        coords = [a, b]
        pts = [local(a), local(b)]
        let d = hypot(pts[1].0 - pts[0].0, pts[1].1 - pts[0].1)
        cum = [0, d]
        expected = d / (mode == .walk ? 1.4 : mode == .bike ? 4.5 : 11)
        steps = [(d, 2, 0, "Straight to the pin")]
        stopAt = []
    }

    private var fixWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var authWaiters: [CheckedContinuation<Void, Never>] = []

    /// Where the phone is now: asks for location access the first time, then one fix (10 s at most).
    func here() async -> CLLocation? {
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

    /// The watch's last map ask: an older one's chunks stop going.
    private var mapGen = 0

    /// A map's chunks over the sliding window (as Maps sends them): refused ones go again, in any order.
    private var mapQueue: [Data] = []

    private func stream(_ msgs: [Data], gen g: Int) async {
        mapQueue = msgs
        var delay = 25
        let start = ContinuousClock.now
        while g == mapGen, !mapQueue.isEmpty, ContinuousClock.now - start < .seconds(30) {
            do {
                let again = try await Hub.shared.stream(target) { @MainActor [weak self] in
                    guard let self, self.mapGen == g, !self.mapQueue.isEmpty else { return nil }
                    return self.mapQueue.removeFirst()
                }
                guard g == mapGen else { return }
                mapQueue.insert(contentsOf: again, at: 0)
                if !again.isEmpty {
                    try? await Task.sleep(for: .milliseconds(delay))
                    delay = min(delay * 2, 250)
                } else {
                    delay = 25
                }
            } catch {
                return
            }
        }
    }

    /// The fix the last plan started from.
    private var planFix: CLLocation?

    /// Where we are on the route now, sent without waiting for the next fix.
    private func updateNow() async {
        guard active, let l = manager.location ?? planFix else { return }
        last = .distantPast
        await update(l)
    }

    /// Stopped by the person (the page's Stop, the watch's ✕): the Navigation app back to its start screen.
    func end() {
        let was = active
        stop()
        if was, target == Self.app { Task { try? await Hub.shared.send(target, NavProto.ended) } }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        active = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
    }

    private func local(_ c: CLLocationCoordinate2D) -> (Double, Double) {
        ((c.longitude - origin.longitude) * cos(origin.latitude * .pi / 180) * 111_320, (c.latitude - origin.latitude) * 110_540)
    }

    /// Stop k's name (the watch says "Arrive at <name>").
    private func stopName(_ k: Int) -> String {
        stops.indices.contains(k) ? stops[k].name ?? "your stop" : "your stop"
    }

    /// Apple's route, one MKRoute a leg (through the stops), as the route.
    private func load(_ legs: [MKRoute]) {
        var coords: [CLLocationCoordinate2D] = []
        for r in legs {
            let n = r.polyline.pointCount
            var c = [CLLocationCoordinate2D](repeating: .init(), count: n)
            r.polyline.getCoordinates(&c, range: NSRange(location: 0, length: n))
            coords += coords.isEmpty ? c : Array(c.dropFirst())
        }
        self.coords = coords
        if !keepOrigin { origin = coords.first ?? .init() }
        pts = coords.map(local)
        cum = [0]
        for i in 1..<max(pts.count, 1) where pts.count > 1 {
            cum.append(cum[i - 1] + hypot(pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1))
        }
        expected = legs.reduce(0) { $0 + $1.expectedTravelTime }
        var at = 0.0
        steps = []
        stopAt = []
        for (li, r) in legs.enumerated() {
            var leg = r.steps.map { s in
                defer { at += s.distance }
                let (kind, dir) = Self.maneuver(s.instructions)
                return (at: at + s.distance, kind: kind, dir: dir, name: s.instructions.isEmpty ? "Continue" : s.instructions)
            }
            if let last = leg.indices.last {
                leg[last].kind = 2
                if li < legs.count - 1 {
                    leg[last].name = stopName(li)
                    stopAt.append(leg[last].at)
                }
            }
            steps += leg
        }
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
        try await Hub.shared.send(target, routeMessages())
    }

    /// The route's points for the watch (`G`/`g`), metres in its frame (`frame`).
    func routeMessages() -> [Data] { NavProto.route(NavProto.simplify(pts)) }

    /// The route's frame: its start (the turns and positions are metres east and north of it).
    var frame: CLLocationCoordinate2D { origin }

    /// The point `s` metres along the route (Maps centres a step's picture on it).
    func coordinate(at s: Double) -> CLLocationCoordinate2D? {
        guard coords.count == cum.count, let first = coords.first else { return coords.first }
        guard let i = cum.firstIndex(where: { $0 >= s }) else { return coords.last }
        if i == 0 { return first }
        let t = (s - cum[i - 1]) / max(cum[i] - cum[i - 1], 1e-9)
        let (a, b) = (coords[i - 1], coords[i])
        return .init(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Distance along the route nearest to `p`: near where we were first (a route that passes by its own end, or
    /// doubles back, would else jump ahead), anywhere when we are not near that part.
    private func along(_ p: (Double, Double)) -> (s: Double, off: Double) {
        if let s0 = lastS {
            let near = along(p, from: s0 - 150, to: s0 + 1500)
            if near.off < 40 { return near }
            let any = along(p, from: -.infinity, to: .infinity)
            return any.off < near.off - 15 ? any : near
        }
        return along(p, from: -.infinity, to: .infinity)
    }

    private func along(_ p: (Double, Double), from lo: Double, to hi: Double) -> (s: Double, off: Double) {
        var best = (s: 0.0, off: Double.infinity)
        for i in 0..<max(pts.count - 1, 0) where cum[i + 1] >= lo && cum[i] <= hi {
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
        guard !rerouting else { return }
        let p = local(loc.coordinate)
        let (s, off) = along(p)
        let length = cum.last ?? 0
        // off the route: two fixes past a margin the fix's own accuracy widens (one far one at once)
        let margin = min(max(30, loc.horizontalAccuracy * 1.5), 60)
        offCount = off > margin ? offCount + 1 : 0
        if (offCount >= 2 || off > 90), let destination, -reroutedAt.timeIntervalSinceNow > 6 {
            await reroute(from: loc, to: destination)
            return
        }
        lastS = s
        // a stop passed: off the list, a reroute goes through the rest only
        while let a = stopAt.first, s >= a - 30 {
            stopAt.removeFirst()
            if !stops.isEmpty { stops.removeFirst() }
        }
        let end = coords.last.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: loc) } ?? 0
        if length - s < 20 && end < 50 {
            try? await Hub.shared.send(target, NavProto.arrived)
            stop()
            return
        }
        let idx = steps.firstIndex { $0.at > s + 3 } ?? (steps.count - 1)
        let st = steps[idx]
        let left = max(length - s, 0)
        let secs = timeLeft(left: left, s: s)
        let eta = Calendar.current.dateComponents([.hour, .minute], from: .now + secs)
        let heading = heading(for: loc)
        lastP = p
        try? await Hub.shared.send(target, [
            NavProto.position(x: p.0, y: p.1, heading: heading),
            NavProto.step(idx: idx, kind: st.kind, dir: st.dir, distM: Int(st.at - s), etaMin: Int(secs / 60),
                          leftM: Int(left), arrive: (eta.hour ?? 0, eta.minute ?? 0), street: st.name),
        ])
        if idx != lastIdx { lastIdx = idx }
    }

    /// Where the map on the watch points: the way we move when we really move, else the iPhone's compass (standing,
    /// walking slowly: the course is noise or none), so the heading-up map turns as the phone turns.
    private func heading(for loc: CLLocation) -> Double {
        if loc.course >= 0, loc.speed > 2 { return loc.course }
        return compass ?? max(loc.course, 0)
    }

    /// The iPhone's compass heading (true north when known), and the last position sent.
    private var compass: Double?
    private var lastP: (Double, Double)?
    private var headingSentAt: Date = .distantPast
    private var headingSent: Double?

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        let deg = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        guard h.headingAccuracy >= 0 else { return }
        Task { @MainActor in self.turned(deg) }
    }

    /// The compass moved: the position again with the new heading (not the turn: that comes with the fixes), at most
    /// 4 times a second and only on a turn of 6° or more, and only while the GPS course isn't in charge.
    private func turned(_ deg: Double) {
        compass = deg
        guard active, !rerouting, let p = lastP, let loc = manager.location, !(loc.course >= 0 && loc.speed > 2) else { return }
        let moved = headingSent.map { abs((deg - $0 + 540).truncatingRemainder(dividingBy: 360) - 180) } ?? 360
        guard moved >= 6, -headingSentAt.timeIntervalSinceNow >= 0.25 else { return }
        headingSentAt = .now
        headingSent = deg
        Task { try? await Hub.shared.send(target, NavProto.position(x: p.0, y: p.1, heading: deg)) }
    }

    /// The watch heard nothing for a while (`N`): the route and where we are again, or, with no route on any more,
    /// Navigation back to its start.
    func resync() {
        if active {
            Task {
                try? await sendRoute()
                await updateNow()
            }
        } else if target == Self.app {
            Task { try? await Hub.shared.send(target, NavProto.ended) }
        }
    }

    /// Time left: the plan's for the distance left, scaled by how fast we really went over the last minute (a
    /// jam, a stop at the lights, a fast road), so the arrival moves with us.
    private func timeLeft(left: Double, s: Double) -> Double {
        let length = max(cum.last ?? 0, 1)
        let planned = expected * left / length
        let now = Date.now
        progress.append((now, s))
        progress.removeAll { now.timeIntervalSince($0.t) > 60 }
        guard let first = progress.first, expected > 0 else { return planned }
        let dt = now.timeIntervalSince(first.t)
        guard dt >= 15 else { return planned }
        let real = max(s - first.s, 0) / dt
        let plan = length / expected
        let ratio = min(max(real / plan, 0.25), 2.5)
        let w = min(dt / 60, 1) * 0.6
        return planned / (1 - w + w * ratio)
    }

    /// Off the route: a way the last plan also had, if we are on it (no wait), else a new route from here that
    /// starts the way we are heading; the frame stays.
    private func reroute(from loc: CLLocation, to destination: MKMapItem) async {
        rerouting = true
        reroutedAt = .now
        offCount = 0
        defer { rerouting = false }
        try? await Hub.shared.send(target, NavProto.rerouting)
        let p = local(loc.coordinate)
        for (k, line) in alternativeLines.enumerated() {
            let lp = line.map(local)
            var best = Double.infinity
            for i in 0..<max(lp.count - 1, 0) {
                let (a, b) = (lp[i], lp[i + 1])
                let (dx, dy) = (b.0 - a.0, b.1 - a.1)
                let t = min(max(((p.0 - a.0) * dx + (p.1 - a.1) * dy) / max(dx * dx + dy * dy, 1e-9), 0), 1)
                best = min(best, hypot(p.0 - a.0 - dx * t, p.1 - a.1 - dy * t))
            }
            if best < 25 {
                keepOrigin = true
                choose(k)
                keepOrigin = false
                lastS = nil
                progress = []
                try? await sendRoute()
                return
            }
        }
        heading = loc.course >= 0 && loc.speed > 1 ? loc.course : nil
        defer { heading = nil }
        keepOrigin = true
        defer { keepOrigin = false }
        let to = destination.placemark.coordinate
        if await osrm(from: loc.coordinate, to: to, quick: true) == nil {
            let src = MKMapItem(placemark: MKPlacemark(coordinate: loc.coordinate))
            var why = ""
            if let legs = await appleLegs(from: src, to: destination, &why) { load(legs) } else { loadDirect(from: loc.coordinate, to: to) }
        }
        lastS = nil
        progress = []
        try? await sendRoute()
    }
}
