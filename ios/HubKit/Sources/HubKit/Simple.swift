import CoreGraphics
import Foundation
import ImageIO

/// Simple screens for sites the watch can't usefully draw as they are (YouTube, Instagram): the phone reads what the
/// site lists (videos, posts) and lays out its own screen in page view's ops (Layout's format): a search bar, then a
/// row (or a tile) each. A tap on a row opens it (a video: the player); the search bar brings the keyboard.
public enum Simple {
    public enum Site: String, Sendable { case youtube, instagram }

    /// The site's list pages (not a video: those open in the player).
    public static func site(for u: URL) -> Site? {
        let h = (u.host ?? "").lowercased(), p = u.path.lowercased()
        if h.hasSuffix("youtube.com") && !BrowserProto.isVideo(u) && (p == "/" || p.isEmpty || p.hasPrefix("/results") || p.hasPrefix("/feed")) {
            return .youtube
        }
        if h.hasSuffix("instagram.com") && !BrowserProto.isVideo(u) && (p == "/" || p.isEmpty || p.hasPrefix("/explore") || p.hasPrefix("/reels")) {
            return .instagram
        }
        return nil
    }

    public static func search(_ site: Site, _ q: String) -> URL {
        var c: URLComponents
        switch site {
        case .youtube:
            c = URLComponents(string: "https://m.youtube.com/results")!
            c.queryItems = [.init(name: "search_query", value: q)]
        case .instagram:
            c = URLComponents(string: "https://www.instagram.com/explore/search/keyword/")!
            c.queryItems = [.init(name: "q", value: q)]
        }
        return c.url!
    }

    /// What the page lists: JSON [[title, link, byline, length, thumbnail]…].
    public static func script(_ site: Site) -> String {
        switch site {
        case .youtube:
            return """
            (() => { const out = [], seen = new Set();
              for (const e of document.querySelectorAll('ytm-video-with-context-renderer, ytm-compact-video-renderer, ytm-rich-item-renderer, ytm-shorts-lockup-view-model')) {
                const a = e.querySelector('a[href*="/watch?v="], a[href*="/shorts/"]'); if (!a) continue;
                const href = a.href; const id = (/[?&]v=([\\w-]{6,})/.exec(href) || /shorts\\/([\\w-]{6,})/.exec(href) || [])[1];
                if (!id || seen.has(id)) continue; seen.add(id);
                const t = (e.querySelector('h3, .media-item-headline, [class*=headline]') || a).innerText.trim();
                const by = (e.querySelector('ytm-badge-and-byline-renderer, .media-item-byline, [class*=byline]') || {}).innerText || '';
                const len = (e.querySelector('ytm-thumbnail-overlay-time-status-renderer, .badge-shape-wiz__text, [class*=time-status]') || {}).innerText || '';
                out.push([t, href, by.replace(/\\s*\\n\\s*/g, ' ').trim(), len.trim(), 'https://i.ytimg.com/vi/' + id + '/mqdefault.jpg']);
                if (out.length >= 20) break; }
              return JSON.stringify(out); })()
            """
        case .instagram:
            return """
            (() => { const out = [], seen = new Set();
              for (const a of document.querySelectorAll('a[href*="/p/"], a[href*="/reel/"]')) {
                const img = a.querySelector('img'); if (!img || seen.has(a.href)) continue; seen.add(a.href);
                out.push([(img.alt || '').slice(0, 80), a.href, '', a.href.includes('/reel/') ? 'Reel' : '', img.currentSrc || img.src]);
                if (out.length >= 24) break; }
              return JSON.stringify(out); })()
            """
        }
    }

    public struct Item: Sendable {
        public let title: String, link: URL, byline: String, length: String, thumb: URL?
    }

    public static func items(_ json: String) -> [Item] {
        guard let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String]] else { return [] }
        return rows.compactMap { r in
            guard r.count == 5, let u = URL(string: r[1]) else { return nil }
            return Item(title: r[0], link: u, byline: r[2], length: r[3], thumb: URL(string: r[4]))
        }
    }

    /// A picture's bytes (JPEG, PNG…) as `w` × `h` RGB, filled (cropped to the box).
    public static func rgb(_ data: Data, w: Int, h: Int) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { b -> Bool in
            guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            let k = max(Double(w) / Double(img.width), Double(h) / Double(img.height))
            let (dw, dh) = (Double(img.width) * k, Double(img.height) * k)
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: (Double(w) - dw) / 2, y: (Double(h) - dh) / 2, width: dw, height: dh))
            return true
        }
        guard ok else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { (out[3 * i], out[3 * i + 1], out[3 * i + 2]) = (px[4 * i], px[4 * i + 1], px[4 * i + 2]) }
        return out
    }

    /// Where things are on the simple screen (panel px from its top): the search bar, the rows (each opens its link).
    public struct Screen: Sendable {
        public let messages: [Data]
        public let field: (x: Int, y: Int, w: Int, h: Int)
        public let rows: [(x: Int, y: Int, w: Int, h: Int, link: URL)]
    }

    // the watch's font: about this many px a character (Inter 20 px)
    static let charW = 10

    /// Up to `lines` lines of about `px` wide.
    static func wrap(_ s: String, px: Int, lines: Int) -> [String] {
        let per = max(6, px / charW)
        var out: [String] = [], cur = ""
        for w in s.split(separator: " ").map(String.init) {
            if cur.isEmpty { cur = w } else if cur.count + 1 + w.count <= per { cur += " " + w } else {
                out.append(cur)
                cur = w
                if out.count == lines { break }
            }
        }
        if out.count < lines, !cur.isEmpty { out.append(cur) }
        if out.count == lines, s.count > out.joined(separator: " ").count { out[lines - 1] += "\u{2026}" }
        return out
    }

    /// The screen: its title, the search bar (`query` in it, or the site's placeholder), then a row per item (its
    /// thumbnail from `thumbs`, the same order, nil: a grey box).
    public static func screen(_ site: Site, query: String, items: [Item], thumbs: [[UInt8]?]) -> Screen {
        let (name, accent): (String, (UInt8, UInt8, UInt8)) = site == .youtube ? ("YouTube", (0xFF, 0x00, 0x33)) : ("Instagram", (0xE1, 0x30, 0x6C))
        let bg = Rle.rgb565(0x0F, 0x0F, 0x0F), card = Rle.rgb565(0x27, 0x27, 0x27)
        let white = Rle.rgb565(0xF1, 0xF1, 0xF1), grey = Rle.rgb565(0xAA, 0xAA, 0xAA)
        var ops: [(top: Int, bottom: Int, bytes: Data, text: Bool)] = []
        var pics: [(top: Int, msgs: [Data])] = []
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: UInt16, r: Int = 0, under: UInt16 = 0) {
            var d = Data([UInt8(ascii: "r")])
            d.le(Int16(clamping: x)); d.le(UInt16(clamping: y)); d.le(UInt16(clamping: w)); d.le(UInt16(clamping: h))
            d.le(c); d.le(under); d.append(UInt8(clamping: r))
            ops.append((y, y + h, d, false))
        }
        func text(_ x: Int, _ y: Int, _ w: Int, _ s: String, _ c: UInt16, bold: Bool = false) {
            let b = utf8(s, 100)
            var d = Data([UInt8(ascii: "t")])
            d.le(Int16(clamping: x)); d.le(UInt16(clamping: y)); d.le(UInt16(clamping: w)); d.le(c)
            d.append(bold ? 1 : 0); d.append(UInt8(b.count)); d.append(b)
            ops.append((y, y + 24, d, true))
        }
        let rowH = site == .youtube ? 132 : 150
        let top = 132
        let height = top + max(1, site == .youtube ? items.count : (items.count + 2) / 3) * rowH + 140
        rect(0, 0, 466, height, bg)
        // the name, the search bar
        text(C - name.count * 6, 22, 200, name, Rle.rgb565(accent.0, accent.1, accent.2), bold: true)
        let field = (x: 60, y: 62, w: 346, h: 48)
        rect(field.x, field.y, field.w, field.h, card, r: 24, under: bg)
        text(field.x + 24, field.y + 13, field.w - 40, query.isEmpty ? "Search \(name)" : query, query.isEmpty ? grey : white)
        var rows: [(x: Int, y: Int, w: Int, h: Int, link: URL)] = []
        if items.isEmpty {
            text(C - 80, top + 30, 300, "Nothing here yet", grey)
        }
        for (i, it) in items.enumerated() {
            let thumb = i < thumbs.count ? thumbs[i] : nil
            if site == .youtube {
                let y = top + i * rowH
                // thumbnail 16:9 (2 px a pixel), its length on it; title (2 lines), channel and views
                let (tx, tw, th) = (36, 176, 100)
                if let px = thumb {
                    pics.append((y, picture(px, w: tw / 2, h: th / 2, x: tx, y: y)))
                } else {
                    rect(tx, y, tw, th, card, r: 10, under: bg)
                }
                if !it.length.isEmpty {
                    let lw = it.length.count * 10 + 12
                    rect(tx + tw - lw - 6, y + th - 30, lw, 24, Rle.rgb565(0, 0, 0), r: 6, under: bg)
                    text(tx + tw - lw, y + th - 30, lw, it.length, white)
                }
                let lines = wrap(it.title, px: 220, lines: 2)
                for (k, l) in lines.enumerated() { text(tx + tw + 14, y + 2 + k * 26, 230, l, white, bold: true) }
                text(tx + tw + 14, y + 6 + lines.count * 26, 230, it.byline, grey)
                rows.append((tx, y, 400, th, it.link))
            } else {
                // a grid of three
                let (col, row) = (i % 3, i / 3)
                let side = 128
                let (x, y) = (42 + col * (side + 4), top + row * rowH)
                if let px = thumb {
                    pics.append((y, picture(px, w: side / 2, h: side / 2, x: x, y: y)))
                } else {
                    rect(x, y, side, side, card)
                }
                if !it.length.isEmpty { text(x + 6, y + side - 28, side - 8, it.length, white, bold: true) }
                rows.append((x, y, side, side, it.link))
            }
        }
        // as page view's ops: per watch screen, its boxes, its pictures, its text
        var out: [Data] = []
        var j = Data([UInt8(ascii: "J")]); j.le(UInt16(clamping: height)); out.append(j)
        var slab = 0
        while slab < height {
            let end = slab + 466
            let inSlab = { (t: Int) in t >= slab && t < end }
            for layer in [false, true] {
                if layer {
                    // the pictures between the boxes and the text
                    for p in pics where inSlab(p.top) { out += p.msgs }
                }
                let mine = ops.filter { $0.text == layer && inSlab($0.top) }
                guard !mine.isEmpty else { continue }
                var o = Data([UInt8(ascii: "o")])
                o.le(UInt16(clamping: mine.map(\.top).min()!)); o.le(UInt16(clamping: mine.map(\.bottom).max()!)); o.append(layer ? 1 : 0)
                out.append(o)
                var p = Data([UInt8(ascii: "p")])
                for m in mine {
                    if p.count + m.bytes.count > 127 { out.append(p); p = Data([UInt8(ascii: "p")]) }
                    p += m.bytes
                }
                if p.count > 1 { out.append(p) }
            }
            slab = end
        }
        out.append(Data([UInt8(ascii: "j")]))
        return Screen(messages: out, field: field, rows: rows)
    }

    static let C = 233

    /// A `w` × `h` RGB picture at panel (x, y), 2 px a pixel, its own 16 colours.
    static func picture(_ rgb: [UInt8], w: Int, h: Int, x: Int, y: Int) -> [Data] {
        let (palette, idx) = Quantize.refined(rgb: rgb, colours: 16)
        let pal = (palette + Array(repeating: (0, 0, 0), count: max(0, 16 - palette.count))).prefix(16).map { Rle.rgb565($0.0, $0.1, $0.2) }
        return Rle.messages(header: Rle.header(width: w, height: h, scale: 2, x0: Int16(x), y0: Int16(clamping: y), palette: pal),
                            tokens: Rle.tokens(idx, width: w, height: h))
    }

    /// Thumbnails fetched together (a few at once), each `w` × `h` RGB; nil where one didn't come.
    public static func thumbs(_ items: [Item], site: Site) async -> [[UInt8]?] {
        let (w, h) = site == .youtube ? (88, 50) : (64, 64)
        return await withTaskGroup(of: (Int, [UInt8]?).self) { g in
            for (i, it) in items.enumerated() {
                g.addTask {
                    guard let u = it.thumb, let (d, _) = try? await URLSession.shared.data(from: u) else { return (i, nil) }
                    return (i, rgb(d, w: w, h: h))
                }
            }
            var out = [[UInt8]?](repeating: nil, count: items.count)
            for await (i, px) in g { out[i] = px }
            return out
        }
    }
}
