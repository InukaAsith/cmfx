import CoreLocation
import Foundation
import HubKit
import MapKit
import UIKit
import WireKit

// The watch's Maps app (cmf-watch-sdk sdk/examples/atlas, proto.rs), as Google Maps behaves: the map round us; search
// near where the map is looking (Apple's places and OpenStreetMap's through Photon, the best matches nearest first,
// kept together so their pins fit one map), kinds of places, an area (the map goes there), a pin on the map (tapped
// or dropped) as a place with what is known of it, how long a place is by car, bike and on foot, the ways there to
// pick (OpenStreetMap's routes first, then Apple's), each step checked on the map, then turn by turn. The map is
// OpenStreetMap's (OpenFreeMap's vector tiles, cached here) cut round a point as data (HubKit AtlasScene) the watch
// draws itself, over the sliding window. Nothing runs unless Maps is open on the watch; location only for an answer,
// and all the time only while navigating.

@MainActor @Observable final class AtlasService: WatchService {
    static let app = "Maps"

    let nav = NavService(target: AtlasService.app)
    /// A place found, with what the watch's card shows.
    struct Found {
        var item: MKMapItem
        var kind = "", address = "", phone = "", more = ""
        /// ISO country code ("" unknown): Apple's placemark, or OpenStreetMap's
        var country = ""
        var coord: CLLocationCoordinate2D { item.placemark.coordinate }
        var name: String { item.name ?? "Place" }
    }
    private(set) var results: [Found] = []
    /// A pin on the watch's map (`P`): result 8.
    private var picked: Found?
    var status: String?

    /// Where the watch's map is measured from (metres east, north): where we were, a search's or an area's place,
    /// the route's start (NavService's frame) once a route is shown.
    private var frame: CLLocationCoordinate2D?
    /// Where the map is looking: searches go round it (nil: round us).
    private var focus: CLLocationCoordinate2D?
    private let tiles = VectorTiles()
    /// `D` that listed ways to pick: the place and the mode they are for.
    private var listed: (mode: Int, idx: Int)?

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
            picture(id) { await self.homeMap(round: round.map { (Double($0.x), Double($0.y)) }, id: id) }
        case .search(let id, let q):
            if let c = Self.category(of: q) { return find(id) { await self.kind(c, near: $0) } }
            find(id, town: q) { await self.places(q, near: $0) }
        case .category(let id, let c):
            find(id) { await self.kind(c, near: $0) }
        case .area(let id, let q):
            Task { await area(q, id: id) }
        case .pick(let x, let y, let name):
            Task { await pick((Double(x), Double(y)), name: name) }
        case .focusRow(let id, let idx):
            Task { await focusGroup(of: idx, id: id) }
        case .clear:
            // ✕ on the watch: the pins go, and new maps come without them
            nearCount = 0
            results = []
            picked = nil
            focus = nil
        case .info(let idx):
            guard let f = found(idx) else { return }
            Task {
                try? await Hub.shared.send(Self.app, AtlasProto.info(idx, [f.kind, f.address, f.phone, f.more]))
                // what Wikipedia says of it, when it has an article on this place (pulled up on the watch)
                if let text = await Self.about(f.name, at: f.coord) {
                    try? await Hub.shared.send(Self.app, AtlasProto.about(idx, text))
                }
            }
        case .ways(let idx):
            guard let f = found(idx) else { return fail("That place is gone: search again") }
            Task { await ways(to: f.item) }
        case .directions(let mode, let idx, let id, let alt):
            Task { await directions(mode: mode, idx: idx, id: id, alt: alt) }
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

    private func found(_ idx: Int) -> Found? {
        idx == AtlasProto.picked ? picked : results.indices.contains(idx) ? results[idx] : nil
    }

    // --- search

    /// A search's places, then the map round them (scene `id`) in a frame where they are: round where the map looks
    /// when the best match is near it, else round the best match (a town far away: the map goes there, as Google's).
    private func find(_ id: UInt8, town q: String? = nil, _ look: @escaping (CLLocationCoordinate2D) async -> [Found]) {
        currentID = id
        gen += 1
        let g = gen
        Task {
            guard let here = await nav.here() else { return fail("Location is off for CMFX") }
            let near = focus ?? here.coordinate
            // a town of that name far away too (Matara from Colombo): its own group after the places round us
            async let far = q == nil ? nil : self.town(q!, from: near)
            var all = await look(near)
            let town = await far
            guard g == gen else { return }
            nearCount = 0
            group = 0
            let km = { (a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) in
                CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            }
            if let town, let q {
                var close = all.filter { km($0.coord, near) < 20_000 }
                if let first = close.first { close = close.filter { km($0.coord, first.coord) < 6000 } }
                if !close.isEmpty {
                    let there = await places(q, near: town.coord).filter {
                        km($0.coord, town.coord) < 12_000 && !($0.name == town.name && km($0.coord, town.coord) < 2000)
                    }
                    guard g == gen else { return }
                    let n = min(close.count, 3)
                    results = Array(close.prefix(n)) + [town] + Array(there.prefix(8 - n - 1))
                    nearCount = n
                    nearFrame = near
                    frame = near
                    status = nil
                    try? await Hub.shared.send(Self.app, rows(here))
                    let pts = results.prefix(n).map { xy($0.coord) }
                    let centre = ((pts.map(\.0).min()! + pts.map(\.0).max()!) / 2, (pts.map(\.1).min()! + pts.map(\.1).max()!) / 2)
                    focus = latLon(centre)
                    picture(id) { await self.scene(round: centre, me: self.xy(here.coordinate)) }
                    return
                }
            }
            // together: the best match and those near it, so the pins fit one map
            if let first = all.first {
                let a = CLLocation(latitude: first.coord.latitude, longitude: first.coord.longitude)
                all = all.filter { a.distance(from: CLLocation(latitude: $0.coord.latitude, longitude: $0.coord.longitude)) < 6000 }
            }
            results = Array(all.prefix(8))
            if let first = results.first,
               CLLocation(latitude: near.latitude, longitude: near.longitude)
                .distance(from: CLLocation(latitude: first.coord.latitude, longitude: first.coord.longitude)) > 20_000 {
                frame = first.coord
            } else {
                frame = near
            }
            status = results.isEmpty ? "Nothing found" : nil
            try? await Hub.shared.send(Self.app, rows(here))
            // the map round the places
            let pts = results.map { xy($0.coord) }
            let centre = pts.isEmpty ? (0.0, 0.0)
                : ((pts.map(\.0).min()! + pts.map(\.0).max()!) / 2, (pts.map(\.1).min()! + pts.map(\.1).max()!) / 2)
            focus = latLon(centre)
            picture(id) { await self.scene(round: centre, me: self.xy(here.coordinate)) }
        }
    }

    private func xy(_ c: CLLocationCoordinate2D) -> (Double, Double) {
        guard let f = frame else { return (0, 0) }
        return AtlasScene.xy((c.latitude, c.longitude), (f.latitude, f.longitude))
    }

    private func latLon(_ p: (Double, Double)) -> CLLocationCoordinate2D {
        guard let f = frame else { return .init() }
        let ll = AtlasScene.latLon(p.0, p.1, (f.latitude, f.longitude))
        return .init(latitude: ll.lat, longitude: ll.lon)
    }

    /// `L` and the rows, where each is in the frame now (a mixed search: the other group's not on this map).
    private func rows(_ here: CLLocation) -> [Data] {
        AtlasProto.results(results.enumerated().map { i, r in
            let placed = nearCount == 0 || (i < nearCount) == (group == 0)
            return (name: r.name, sub: Self.short(r), dist: Int(here.distance(from: CLLocation(latitude: r.coord.latitude, longitude: r.coord.longitude))),
                    at: placed ? xy(r.coord) : (.nan, .nan))
        }, near: nearCount)
    }

    /// The country we are in (ISO code, "" unknown): Apple's reverse geocoder, once a session.
    private var myCountry: String?
    private func country(_ c: CLLocationCoordinate2D) async -> String {
        if let m = myCountry { return m }
        let p = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)).first
        let code = p?.isoCountryCode?.uppercased() ?? ""
        if !code.isEmpty { myCountry = code }
        return code
    }

    /// A mixed search (places round us, then a town far away and its places): where the far group starts in
    /// `results`, which group the map shows, and the near group's frame.
    private var nearCount = 0
    private var group = 0
    private var nearFrame: CLLocationCoordinate2D?

    /// The watch tapped a row of the other group: the map goes round that group (a new frame), the rows again.
    private func focusGroup(of idx: Int, id: UInt8) async {
        currentID = id
        gen += 1
        guard nearCount > 0, idx < results.count, let here = await nav.here() else { return }
        group = idx < nearCount ? 0 : 1
        let members = group == 0 ? Array(results.prefix(nearCount)) : Array(results.dropFirst(nearCount))
        frame = group == 0 ? (nearFrame ?? here.coordinate) : results[nearCount].coord
        try? await Hub.shared.send(Self.app, rows(here))
        let pts = members.map { xy($0.coord) }
        let centre = ((pts.map(\.0).min()! + pts.map(\.0).max()!) / 2, (pts.map(\.1).min()! + pts.map(\.1).max()!) / 2)
        focus = latLon(centre)
        picture(id) { await self.scene(round: centre, me: self.xy(here.coordinate)) }
    }

    /// A town or district named `q` more than 20 km from `c` (Apple's addresses within 300 km): the far group's head.
    private func town(_ q: String, from c: CLLocationCoordinate2D) async -> Found? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.resultTypes = .address
        req.region = MKCoordinateRegion(center: c, latitudinalMeters: 600_000, longitudinalMeters: 600_000)
        let items = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
        let mine = await country(c)
        guard let item = items.first(where: { $0.placemark.isoCountryCode?.uppercased() == mine }) ?? items.first else { return nil }
        let fold = { (s: String) in s.lowercased().folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: .whitespaces) }
        let want = fold(q)
        let p = item.placemark
        let names = [p.locality, p.subLocality, p.subAdministrativeArea, p.administrativeArea, item.name].compactMap { $0 }.map(fold)
        guard want.count >= 3, names.contains(where: { $0 == want }),
              CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: CLLocation(latitude: p.coordinate.latitude, longitude: p.coordinate.longitude)) > 20_000
        else { return nil }
        var f = Self.found(item)
        f.kind = "Area"
        return f
    }

    /// Places for `q` round `near`: Apple's and OpenStreetMap's (Photon), the ones named like the query first, then
    /// the nearest (Google's order: what you asked for, near where you look).
    private func places(_ q: String, near: CLLocationCoordinate2D) async -> [Found] {
        async let apple = appleSearch(q, near: near, km: 10)
        async let osm = photon(q, near: near, tags: [])
        var all = await apple
        if all.count < 5 { all += await appleSearch(q, near: near, km: 60) }
        all = merge(all, await osm)
        let words = q.lowercased().split(separator: " ").map(String.init)
        func match(_ f: Found) -> Int {
            let n = f.name.lowercased()
            if n.contains(q.lowercased()) { return 0 }
            if words.allSatisfy({ n.contains($0) }) { return 1 }
            return f.address.lowercased().contains(q.lowercased()) ? 2 : 3
        }
        let here = CLLocation(latitude: near.latitude, longitude: near.longitude)
        func km(_ f: Found) -> Double { here.distance(from: CLLocation(latitude: f.coord.latitude, longitude: f.coord.longitude)) / 1000 }
        // a far match only when nothing near is like it
        let close = all.filter { km($0) < 50 }
        if !close.isEmpty { all = close }
        // as well named: this country's before another's (far searches: Matara the town, not one abroad)
        let mine = await country(near)
        func abroad(_ f: Found) -> Int { mine.isEmpty || f.country.isEmpty || f.country == mine ? 0 : 1 }
        return all.sorted { (match($0), abroad($0), km($0)) < (match($1), abroad($1), km($1)) }
    }

    /// A kind of place (proto.rs CATEGORIES) round `near`, nearest first.
    private func kind(_ c: Int, near: CLLocationCoordinate2D) async -> [Found] {
        guard Self.kinds.indices.contains(c) else { return [] }
        let k = Self.kinds[c]
        async let osm = photon(k.word, near: near, tags: k.osm)
        var all: [Found] = []
        for radius in [3000.0, 12_000] where all.count < 6 {
            let req = MKLocalPointsOfInterestRequest(center: near, radius: radius)
            req.pointOfInterestFilter = MKPointOfInterestFilter(including: k.apple)
            all = (try? await MKLocalSearch(request: req).start().mapItems.map(Self.found)) ?? []
        }
        all = merge(all, await osm)
        let here = CLLocation(latitude: near.latitude, longitude: near.longitude)
        return all.sorted {
            here.distance(from: CLLocation(latitude: $0.coord.latitude, longitude: $0.coord.longitude))
                < here.distance(from: CLLocation(latitude: $1.coord.latitude, longitude: $1.coord.longitude))
        }
    }

    /// The watch's kinds of places: Apple's categories, OpenStreetMap's tags (Photon `osm_tag`), the word for them.
    static let kinds: [(word: String, apple: [MKPointOfInterestCategory], osm: [String])] = [
        ("restaurant", [.restaurant, .bakery], ["amenity:restaurant", "amenity:fast_food"]),
        ("cafe", [.cafe], ["amenity:cafe"]),
        ("fuel", [.gasStation, .evCharger], ["amenity:fuel", "amenity:charging_station"]),
        ("hotel", [.hotel], ["tourism:hotel", "tourism:guest_house"]),
        ("supermarket", [.store, .foodMarket], ["shop:supermarket", "shop:convenience", "shop:mall"]),
        ("atm", [.atm, .bank], ["amenity:atm", "amenity:bank"]),
        ("pharmacy", [.pharmacy], ["amenity:pharmacy"]),
        ("hospital", [.hospital], ["amenity:hospital", "amenity:clinic"]),
    ]

    /// A typed search that is a kind of place ("gas station", "food"): searched as that kind.
    static func category(of q: String) -> Int? {
        let words: [(Int, [String])] = [
            (0, ["food", "restaurant", "restaurants", "eat", "fast food"]), (1, ["cafe", "cafes", "café", "coffee"]),
            (2, ["fuel", "gas", "gas station", "petrol", "petrol station", "filling station", "ev charging"]),
            (3, ["hotel", "hotels", "stay", "guest house"]), (4, ["shop", "shops", "supermarket", "grocery", "mall"]),
            (5, ["atm", "bank", "atms"]), (6, ["pharmacy", "chemist", "pharmacies"]), (7, ["hospital", "hospitals", "clinic"]),
        ]
        let t = q.lowercased().trimmingCharacters(in: .whitespaces)
        return words.first { $0.1.contains(t) }?.0
    }

    private func appleSearch(_ q: String, near: CLLocationCoordinate2D, km: Double) async -> [Found] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.region = MKCoordinateRegion(center: near, latitudinalMeters: km * 1000, longitudinalMeters: km * 1000)
        req.resultTypes = [.pointOfInterest, .address]
        return (try? await MKLocalSearch(request: req).start().mapItems.map(Self.found)) ?? []
    }

    /// OpenStreetMap's places through Photon (photon.komoot.io): the query and where to look are all it gets.
    private func photon(_ q: String, near c: CLLocationCoordinate2D, tags: [String], layers: [String] = []) async -> [Found] {
        var u = URLComponents(string: "https://photon.komoot.io/api/")!
        u.queryItems = [.init(name: "q", value: q), .init(name: "lat", value: String(c.latitude)),
                        .init(name: "lon", value: String(c.longitude)), .init(name: "limit", value: "12"),
                        .init(name: "lang", value: "en")]
            + tags.map { .init(name: "osm_tag", value: $0) } + layers.map { .init(name: "layer", value: $0) }
        var req = URLRequest(url: u.url!)
        req.timeoutInterval = 12
        req.setValue("CMFX (watch maps)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feats = j["features"] as? [[String: Any]] else { return [] }
        return feats.compactMap { f in
            guard let p = f["properties"] as? [String: Any],
                  let xy = (f["geometry"] as? [String: Any])?["coordinates"] as? [Double], xy.count == 2 else { return nil }
            let item = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: xy[1], longitude: xy[0])))
            let street = [p["housenumber"] as? String, p["street"] as? String].compactMap { $0 }.joined(separator: " ")
            let town = p["district"] as? String ?? p["city"] as? String ?? p["county"] as? String ?? ""
            item.name = p["name"] as? String ?? (street.isEmpty ? q : street)
            let kind = (p["osm_value"] as? String ?? "").replacingOccurrences(of: "_", with: " ").capitalized
            return Found(item: item, kind: kind == "Yes" ? "" : kind,
                         address: [street, town, p["state"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: ", "),
                         country: (p["countrycode"] as? String ?? "").uppercased())
        }
    }

    /// Both lists, one of each place (the same name within 150 m).
    private func merge(_ a: [Found], _ b: [Found]) -> [Found] {
        var out = a
        for f in b where !out.contains(where: {
            $0.name.lowercased() == f.name.lowercased()
                && CLLocation(latitude: $0.coord.latitude, longitude: $0.coord.longitude)
                    .distance(from: CLLocation(latitude: f.coord.latitude, longitude: f.coord.longitude)) < 150
        }) { out.append(f) }
        return out
    }

    static func found(_ i: MKMapItem) -> Found {
        let p = i.placemark
        let address = [[p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " "),
                       p.subLocality ?? "", p.locality ?? p.subAdministrativeArea ?? ""]
            .filter { !$0.isEmpty && $0 != i.name }.joined(separator: ", ")
        return Found(item: i, kind: i.pointOfInterestCategory.map(Self.kindName) ?? "", address: address,
                     phone: i.phoneNumber ?? "", more: i.url?.host() ?? "", country: i.placemark.isoCountryCode?.uppercased() ?? "")
    }

    /// "MKPOICategoryGasStation" → "Gas Station".
    static func kindName(_ c: MKPointOfInterestCategory) -> String {
        let raw = c.rawValue.replacingOccurrences(of: "MKPOICategory", with: "")
        return raw.reduce(into: "") { s, ch in
            if ch.isUppercase, !s.isEmpty { s.append(" ") }
            s.append(ch)
        }
    }

    /// The street and the town, short (the sheet's second line).
    static func short(_ f: Found) -> String {
        let parts = f.address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.suffix(2).joined(separator: ", ")
    }

    /// An area (a town, a district): the map goes there, the area its one result.
    private func area(_ q: String, id: UInt8) async {
        currentID = id
        gen += 1
        let g = gen
        guard let here = await nav.here() else { return fail("Location is off for CMFX") }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.resultTypes = .address
        req.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 400_000, longitudinalMeters: 400_000)
        var a = (try? await MKLocalSearch(request: req).start().mapItems.first.map(Self.found)) ?? nil
        if a == nil {
            a = await photon(q, near: here.coordinate, tags: [], layers: ["city", "district", "locality", "county", "state"]).first
        }
        guard g == gen else { return }
        guard var area = a else { return fail("No area called \(q)") }
        if area.kind.isEmpty { area.kind = "Area" }
        nearCount = 0
        results = [area]
        frame = area.coord
        focus = area.coord
        try? await Hub.shared.send(Self.app, rows(here))
        picture(id) { await self.scene(round: (0, 0), me: self.xy(here.coordinate)) }
    }

    /// A pin on the watch's map (frame metres): a place it tapped (its name), else a dropped pin with the address there.
    private func pick(_ p: (Double, Double), name: String) async {
        let c = latLon(p)
        let at = CLLocation(latitude: c.latitude, longitude: c.longitude)
        var f: Found?
        if !name.isEmpty {
            f = results.first { $0.name == name && at.distance(from: CLLocation(latitude: $0.coord.latitude, longitude: $0.coord.longitude)) < 80 }
            if f == nil {
                let near = await appleSearch(name, near: c, km: 1)
                f = near.min { at.distance(from: CLLocation(latitude: $0.coord.latitude, longitude: $0.coord.longitude))
                    < at.distance(from: CLLocation(latitude: $1.coord.latitude, longitude: $1.coord.longitude)) }
                    .flatMap { at.distance(from: CLLocation(latitude: $0.coord.latitude, longitude: $0.coord.longitude)) < 300 ? $0 : nil }
            }
        }
        if f == nil {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
            item.name = name.isEmpty ? "Dropped pin" : name
            var g = Found(item: item)
            if let mark = try? await CLGeocoder().reverseGeocodeLocation(at).first {
                let street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
                g.address = [street, mark.subLocality ?? "", mark.locality ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
            }
            f = g
        }
        guard var pin = f else { return }
        // the pin stays where it was put on the watch
        if name.isEmpty { pin.item = MKMapItem(placemark: MKPlacemark(coordinate: c)); pin.item.name = "Dropped pin" }
        picked = pin
        let here = await nav.here()
        let d = here.map { Int($0.distance(from: at)) } ?? 0
        let row = AtlasProto.row(AtlasProto.picked, (name: pin.name, sub: Self.short(pin), dist: d, at: p))
        try? await Hub.shared.send(Self.app, [row] + AtlasProto.info(AtlasProto.picked, [pin.kind, pin.address, pin.phone, pin.more]))
    }

    /// The route by `mode` to result `idx`. With two or three ways there they go to the watch to pick from first;
    /// `alt` is the one picked.
    private func directions(mode: Int, idx: Int, id: UInt8, alt: Int?) async {
        guard let f = found(idx) else { return fail("That place is gone: search again") }
        if let alt, let l = listed, l.mode == mode, l.idx == idx, nav.alternatives.count > alt {
            nav.choose(alt)
        } else {
            nav.stop()
            nav.mode = NavService.Mode(rawValue: mode) ?? .drive
            guard await nav.plan(to: f.item) else { return fail(nav.status ?? "Couldn't find where you are") }
            if alt == nil, nav.alternatives.count >= 2 {
                listed = (mode, idx)
                let rows = nav.alternativeRows.map { r in
                    let eta = Calendar.current.dateComponents([.hour, .minute], from: .now + r.secs)
                    return (secs: r.secs, metres: r.metres, arrive: (eta.hour ?? 0, eta.minute ?? 0), via: r.via)
                }
                let lines = nav.alternativeLines.map { $0.map(xy) }
                try? await Hub.shared.send(Self.app, AtlasProto.alternatives(rows) + AtlasProto.altLines(lines))
                return
            }
            if let alt { nav.choose(alt) }
        }
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

    /// Home's map: round where we are (a new frame there; the search's places sent again in it), or round a point
    /// of the frame the watch has moved to (where it looks: searches go round it).
    private func homeMap(round: (Double, Double)?, id: UInt8 = 0) async -> [Data]? {
        guard let here = await nav.here() else {
            fail("Location is off for CMFX")
            return nil
        }
        // Maps opened again near where the last map round us was made: that map, from memory, at once (no tiles to
        // read, nothing to build); only where we are is new
        let dist = { (k: Home) in here.distance(from: CLLocation(latitude: k.origin.latitude, longitude: k.origin.longitude)) }
        if round == nil, let k = homes.filter({ dist($0) < $0.r / 3 }).min(by: { dist($0) < dist($1) }) {
            frame = k.origin
            focus = nil
            group = 0
            if !results.isEmpty { try? await Hub.shared.send(Self.app, rows(here)) }
            return AtlasProto.scene(id: id, data: k.data, me: xy(here.coordinate), centre: (0, 0), r: k.r)
        }
        if round == nil || frame == nil {
            frame = here.coordinate
            focus = nil
            // the near group is the one round us again
            group = 0
            if !results.isEmpty { try? await Hub.shared.send(Self.app, rows(here)) }
        } else if let round {
            focus = latLon(round)
        }
        let me = xy(here.coordinate)
        let msgs = await scene(round: round ?? me, me: me, keep: round == nil)
        return msgs
    }

    /// Maps round us lately (8), in memory only: the frame's origin (their centre), the bytes, the half side (m).
    typealias Home = (origin: CLLocationCoordinate2D, data: Data, r: Double)
    private var homes: [Home] = []
    /// Every map built lately (24), by frame and centre: a place seen again in this frame comes at once.
    private var built: [String: (data: Data, r: Double)] = [:]
    private var builtOrder: [String] = []

    private func builtKey(_ o: (lat: Double, lon: Double), _ c: (Double, Double)) -> String {
        String(format: "%.5f,%.5f,%d,%d", o.lat, o.lon, Int((c.0 / 25).rounded()), Int((c.1 / 25).rounded()))
    }

    /// The scene round `centre` (metres in `frame`); the watch draws the search's pins itself.
    private func scene(round centre: (Double, Double), me: (Double, Double), keep: Bool = false) async -> [Data]? {
        guard let f = frame else { return nil }
        let o = (lat: f.latitude, lon: f.longitude)
        let id = currentID
        let key = builtKey(o, centre)
        if let b = built[key] {
            builtOrder.removeAll { $0 == key }
            builtOrder.append(key)
            if keep { homes = [(f, b.data, b.r)] + homes.filter { $0.data != b.data }.prefix(7) }
            return AtlasProto.scene(id: id, data: b.data, me: me, centre: centre, r: b.r)
        }
        let need = AtlasScene.tiles(round: centre, r: AtlasScene.radii[0], origin: o)
        let got: [(tile: (x: Int, y: Int), features: [AtlasScene.Feature])]
        do { got = try await tiles.features(need) } catch {
            fail("No map here: \(error.localizedDescription)")
            return nil
        }
        let (msgs, data, r) = await Task.detached(priority: .userInitiated) {
            let (data, r) = AtlasScene.scene(tiles: got, origin: o, centre: centre)
            return (AtlasProto.scene(id: id, data: data, me: me, centre: centre, r: r), data, r)
        }.value
        if keep { homes = [(f, data, r)] + homes.prefix(7) }
        built[key] = (data, r)
        builtOrder.append(key)
        while builtOrder.count > 24 { built[builtOrder.removeFirst()] = nil }
        // the tiles round this map, ahead of a move to its edge (to disk and memory, in the background)
        let ring = AtlasScene.tiles(round: centre, r: AtlasScene.radii[0] * 2.2, origin: o)
        Task.detached(priority: .utility) { [tiles] in _ = try? await tiles.features(ring) }
        return msgs
    }

    /// Wikipedia's summary of a place: an article within 1.5 km of it whose title is its name (or holds it). Only
    /// the place's position and name go to Wikipedia; nil when there is none.
    static func about(_ name: String, at c: CLLocationCoordinate2D) async -> String? {
        func get(_ u: URL) async -> [String: Any]? {
            var r = URLRequest(url: u)
            r.timeoutInterval = 10
            r.setValue("CMFX (watch maps)", forHTTPHeaderField: "User-Agent")
            guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        var q = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        q.queryItems = [.init(name: "action", value: "query"), .init(name: "list", value: "geosearch"),
                        .init(name: "gscoord", value: "\(c.latitude)|\(c.longitude)"), .init(name: "gsradius", value: "1500"),
                        .init(name: "gslimit", value: "20"), .init(name: "format", value: "json")]
        guard let u = q.url, let j = await get(u),
              let pages = (j["query"] as? [String: Any])?["geosearch"] as? [[String: Any]] else { return nil }
        let want = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let titles = pages.compactMap { $0["title"] as? String }
        guard let title = titles.first(where: { $0.lowercased().folding(options: .diacriticInsensitive, locale: nil) == want })
            ?? titles.first(where: {
                let t = $0.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                return want.count >= 5 && (t.contains(want) || (t.count >= 5 && want.contains(t)))
            }),
              let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let s = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/" + path),
              let sum = await get(s), let text = sum["extract"] as? String, !text.isEmpty else { return nil }
        return text
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
        // tiles unused for three months go
        let fm = FileManager.default
        let old = Date.now.addingTimeInterval(-90 * 86400)
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
                if let f = decoded[key] {
                    out.append((tile, f))
                    order.removeAll { $0 == key }
                    order.append(key)
                    continue
                }
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

    /// Decoded tiles kept in memory: the 64 used last (a map needs 4–9; the prefetched ring round it too).
    private func remember(_ key: String, _ f: [AtlasScene.Feature]) {
        if decoded[key] == nil { order.append(key) }
        decoded[key] = f
        while order.count > 64 { decoded[order.removeFirst()] = nil }
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
