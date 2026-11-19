import CoreLocation
import Foundation

/// A place from Google Maps' Share › Copy (a dropped pin or a place): its link, maps.app.goo.gl short links
/// included, or plain "lat, lng". Short links are followed to the full one; nothing else is sent anywhere.
enum MapsLink {
    struct Place { let coordinate: CLLocationCoordinate2D; let name: String }

    static func place(in text: String) async -> Place? {
        if let p = parse(text) { return p }
        guard let url = firstURL(text) else { return nil }
        if let p = parse(url.absoluteString) { return p }
        // a short link: follow the redirects; the coordinates are in the final link (or, failing that, the page)
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        if let final = resp.url?.absoluteString, let p = parse(final) { return p }
        let page = String(decoding: data.prefix(400_000), as: UTF8.self)
        return parse(page, page: true)
    }

    static func firstURL(_ text: String) -> URL? {
        let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return d?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }

    /// The pin's coordinates in a link (or a page): the place's own (!3d…!4d…, q=, /search/, /place/) before
    /// the map's view centre (@…).
    static func parse(_ raw: String, page: Bool = false) -> Place? {
        var s = raw
        // consent pages wrap the link, encoded once or twice
        for _ in 0..<2 { s = (s.removingPercentEncoding ?? s) }
        s = s.replacingOccurrences(of: "+", with: " ")
        let num = #"(-?\d{1,3}\.\d+)"#
        var patterns = [
            #"!3d"# + num + #"!4d"# + num,
            #"[?&](?:q|query|ll|destination|daddr|center|sll)="# + num + #",\s*"# + num,
            #"/(?:search|place|dir/[^/]*)/"# + num + #",\s*"# + num,
        ]
        if !page {
            patterns += [#"@"# + num + "," + num, #"^\s*"# + num + #"\s*,\s*"# + num + #"\s*$"#]
        }
        for p in patterns {
            guard let r = s.range(of: p, options: .regularExpression),
                  let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: s, range: NSRange(r, in: s)),
                  let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s),
                  let lat = Double(s[a]), let lng = Double(s[b]),
                  abs(lat) <= 90, abs(lng) <= 180, lat != 0 || lng != 0 else { continue }
            return Place(coordinate: .init(latitude: lat, longitude: lng), name: name(s) ?? "Dropped pin")
        }
        return nil
    }

    /// A place link's name: /maps/place/<name>/ (not when the name is itself coordinates).
    private static func name(_ s: String) -> String? {
        guard let r = s.range(of: #"/place/([^/@?]+)"#, options: .regularExpression) else { return nil }
        let n = s[r].dropFirst("/place/".count).trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n.first?.isNumber == true || n.first == "-" { return nil }
        return String(n.prefix(40))
    }
}
