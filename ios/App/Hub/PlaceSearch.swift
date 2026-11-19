import CoreLocation
import MapKit

/// A search result: OpenStreetMap's (photon.komoot.io, near where the phone is) first, then Apple's, 10 at most.
/// Only the typed words and the phone's rough position are sent.
struct Place: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let detail: String
    let lat: Double
    let lon: Double

    var item: MKMapItem {
        let i = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: lat, longitude: lon)))
        i.name = name
        return i
    }

    static func search(_ q: String) async -> [Place] {
        let here = CLLocationManager().location?.coordinate
        async let osm = photon(q, near: here)
        async let apple = appleSearch(q, near: here)
        var out = await osm
        for p in await apple where !out.contains(where: { abs($0.lat - p.lat) < 0.0005 && abs($0.lon - p.lon) < 0.0005 }) {
            out.append(p)
        }
        return Array(out.prefix(10))
    }

    private static func photon(_ q: String, near: CLLocationCoordinate2D?) async -> [Place] {
        var c = URLComponents(string: "https://photon.komoot.io/api/")!
        c.queryItems = [.init(name: "q", value: q), .init(name: "limit", value: "10")]
        if let near {
            // rounded: a bias, not a position
            c.queryItems! += [.init(name: "lat", value: String(format: "%.2f", near.latitude)),
                              .init(name: "lon", value: String(format: "%.2f", near.longitude))]
        }
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 12
        req.setValue("CMFX (watch navigation)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (j["features"] as? [[String: Any]] ?? []).compactMap { f in
            guard let xy = (f["geometry"] as? [String: Any])?["coordinates"] as? [Double], xy.count == 2 else { return nil }
            let p = f["properties"] as? [String: Any] ?? [:]
            func s(_ k: String) -> String? { (p[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            let street = [s("housenumber"), s("street")].compactMap { $0 }.joined(separator: " ")
            let name = s("name") ?? (street.isEmpty ? q : street)
            let detail = [street == name ? nil : (street.isEmpty ? nil : street), s("district"), s("city"), s("county"), s("country")]
                .compactMap { $0 }.joined(separator: ", ")
            return Place(name: name, detail: detail, lat: xy[1], lon: xy[0])
        }
    }

    private static func appleSearch(_ q: String, near: CLLocationCoordinate2D?) async -> [Place] {
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = q
        r.resultTypes = [.pointOfInterest, .address]
        if let near { r.region = MKCoordinateRegion(center: near, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        let items = (try? await MKLocalSearch(request: r).start().mapItems) ?? []
        return items.map {
            Place(name: $0.name ?? q, detail: $0.placemark.title ?? "", lat: $0.placemark.coordinate.latitude,
                  lon: $0.placemark.coordinate.longitude)
        }
    }
}
