import CoreGraphics
import HubKit
import Foundation

/// The known sites' own look (Google, YouTube, Wikipedia, Fandom: their logos, icons, buttons), cut from a page's
/// picture whenever the phone could draw it and kept here (Application Support, per site). When it can't (locked,
/// asleep: WebKit draws nothing), the watch's drawn page gets them back where the page has the same image places,
/// so its look stays while its content (text, fetched pictures) is the new page's.
enum SiteLooks {
    struct Look: Codable {
        /// CSS px on the page
        var x, y, w, h: Double
        /// the cut, `pw` × `ph` RGB
        var pw, ph: Int
        var rgb: Data
    }

    /// Only the small, top-of-page images (logos, icons): content pictures change from page to page.
    static let maxSide = 220.0, maxTop = 900.0, maxLooks = 24

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiteLooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// One file per site (google.com, not www.google.com: one look for its pages).
    static func key(_ host: String) -> String {
        let h = host.lowercased()
        for s in ["google.", "youtube.com", "wikipedia.org", "fandom.com"] where h.contains(s) {
            return s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return h
    }

    private static func file(_ host: String) -> URL { dir.appendingPathComponent(key(host) + ".json") }

    /// Keep the small images of a page drawn here (`rgb` the page's picture, `scale` its px per CSS px), merged
    /// with what was kept (newer wins at the same place).
    static func save(host: String, json: String, rgb: [UInt8], width: Int, height: Int, scale: Double) {
        let (boxes, _) = Layout.images(json: json)
        var new: [Look] = []
        for b in boxes where b[2] >= 6 && b[3] >= 6 && b[2] <= maxSide && b[3] <= maxSide && b[1] < maxTop && b[1] >= 0 {
            let x0 = max(0, Int((b[0] * scale).rounded(.down))), y0 = max(0, Int((b[1] * scale).rounded(.down)))
            let x1 = min(width, Int(((b[0] + b[2]) * scale).rounded(.up))), y1 = min(height, Int(((b[1] + b[3]) * scale).rounded(.up)))
            guard x1 - x0 >= 2, y1 - y0 >= 2 else { continue }
            var d = Data(capacity: (x1 - x0) * (y1 - y0) * 3)
            for y in y0..<y1 {
                let row = (y * width + x0) * 3
                d.append(contentsOf: rgb[row..<(row + (x1 - x0) * 3)])
            }
            new.append(Look(x: b[0], y: b[1], w: b[2], h: b[3], pw: x1 - x0, ph: y1 - y0, rgb: d))
            if new.count >= maxLooks { break }
        }
        guard !new.isEmpty else { return }
        let old = read(host).filter { o in !new.contains { overlap($0, o.x, o.y, o.w, o.h) > 0.5 } }
        let all = Array((new + old).prefix(maxLooks * 2))
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: file(host), options: .atomic) }
    }

    /// What was kept for `host` that sits on one of this page's image places: where to draw it (px, `scale` px per
    /// CSS px).
    static func load(host: String, boxes: [[Double]], scale: Double) -> [(rect: CGRect, rgb: Data, pw: Int, ph: Int)] {
        read(host).compactMap { l in
            guard boxes.contains(where: { $0.count == 4 && overlap(l, $0[0], $0[1], $0[2], $0[3]) > 0.6 }) else { return nil }
            return (CGRect(x: l.x * scale, y: l.y * scale, width: l.w * scale, height: l.h * scale), l.rgb, l.pw, l.ph)
        }
    }

    /// An RGB cut as an image to draw.
    static func image(_ rgb: Data, width: Int, height: Int) -> CGImage? {
        guard rgb.count == width * height * 3, let p = CGDataProvider(data: rgb as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: p, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Everything kept (the Browser page lists and clears it).
    static func sites() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }.sorted()
    }

    static func clear() { try? FileManager.default.removeItem(at: dir) }

    private static func read(_ host: String) -> [Look] {
        (try? Data(contentsOf: file(host))).flatMap { try? JSONDecoder().decode([Look].self, from: $0) } ?? []
    }

    /// Intersection over union of a kept look and a box.
    private static func overlap(_ l: Look, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Double {
        let ix = max(0, min(l.x + l.w, x + w) - max(l.x, x)), iy = max(0, min(l.y + l.h, y + h) - max(l.y, y))
        let i = ix * iy
        let u = l.w * l.h + w * h - i
        return u > 0 ? i / u : 0
    }
}
