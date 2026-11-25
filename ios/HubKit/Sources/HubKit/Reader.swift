import Foundation

/// The watch's Browser (cmf-watch-sdk sdk/examples/browser): a page's reading text pulled out of its HTML (no
/// scripts run: it works with the phone in a pocket), sent as blocks the watch lays out (page.rs).
public enum Reader {
    public static let heading: UInt8 = 0, para: UInt8 = 1, link: UInt8 = 2, item: UInt8 = 3, more: UInt8 = 4

    public struct Block: Equatable {
        public var kind: UInt8
        public var link: Int?
        public var text: String
        public init(kind: UInt8, link: Int?, text: String) {
            self.kind = kind
            self.link = link
            self.text = text
        }
    }

    public struct Page {
        public var title: String
        public var blocks: [Block]
        public var links: [URL]
    }

    /// Whole elements left out: never reading text.
    static let skipped: Set<String> = ["script", "style", "noscript", "svg", "template", "iframe", "head", "nav",
                                       "footer", "aside", "form", "button", "select", "canvas", "object"]
    /// Elements that end a block of text.
    static let blockish: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "br", "section",
                                        "article", "tr", "td", "th", "blockquote", "pre", "ul", "ol", "dt", "dd",
                                        "header", "main", "table", "figcaption", "hr", "body", "dl", "summary"]
    static let maxText = 10_000, maxBlocks = 200, maxLinks = 250

    public static func parse(_ html: String, base: URL) -> Page {
        let b = Array(html.utf8)
        var title = ""
        var blocks: [Block] = []
        var links: [URL] = []
        var text = ""
        // the open link: where it goes (nil: not a link we keep), its text so far
        var anchor: (url: URL?, text: String)?
        // this block's links: where and their text
        var inBlock: [(URL, String)] = []
        // a link's index on the page: given when its line is made (only the links shown count)
        func index(_ u: URL) -> Int? {
            if let k = links.firstIndex(of: u) { return k }
            guard links.count < maxLinks else { return nil }
            links.append(u)
            return links.count - 1
        }
        var skip: (name: String, depth: Int)?
        var heading = 0, items = 0
        var total = 0
        var inTitle = false

        func flush() {
            let t = collapse(text)
            text = ""
            defer { inBlock = [] }
            guard blocks.count < maxBlocks, total < maxText else { return }
            let kind = heading > 0 ? Reader.heading : items > 0 ? Reader.item : Reader.para
            let named = inBlock.filter { $0.1.count >= 2 }
            // a block that is one link (most of its text): the link alone
            if named.count == 1, named[0].1.count * 5 >= t.count * 4, let i = index(named[0].0) {
                blocks.append(Block(kind: link, link: i, text: named[0].1))
                total += named[0].1.utf8.count
                return
            }
            if !t.isEmpty {
                blocks.append(Block(kind: kind, link: nil, text: t))
                total += t.utf8.count
            }
            // a paragraph's own link or two under it (more: an article's every term linked, left as text)
            guard named.count <= 2 else { return }
            for (u, s) in named where blocks.count < maxBlocks {
                guard let i = index(u), blocks.last?.link != i else { continue }
                blocks.append(Block(kind: link, link: i, text: s))
                total += s.utf8.count
            }
        }

        var i = 0
        while i < b.count {
            if b[i] == UInt8(ascii: "<") {
                // a comment
                if i + 3 < b.count, b[i + 1] == UInt8(ascii: "!"), b[i + 2] == UInt8(ascii: "-"), b[i + 3] == UInt8(ascii: "-") {
                    i = find(b, [UInt8(ascii: "-"), UInt8(ascii: "-"), UInt8(ascii: ">")], from: i + 4).map { $0 + 3 } ?? b.count
                    continue
                }
                guard let end = b[i...].firstIndex(of: UInt8(ascii: ">")) else { break }
                let tag = Tag(Array(b[(i + 1)..<end]))
                i = end + 1
                guard !tag.name.isEmpty else { continue }
                if tag.name == "title" {
                    inTitle = !tag.closing
                    continue
                }
                if let s = skip {
                    if tag.name == s.name, !tag.selfClosing {
                        let d = s.depth + (tag.closing ? -1 : 1)
                        skip = d == 0 ? nil : (s.name, d)
                    }
                    continue
                }
                if skipped.contains(tag.name), !tag.closing, !tag.selfClosing, !["br", "hr"].contains(tag.name) {
                    skip = (tag.name, 1)
                    continue
                }
                if blockish.contains(tag.name) {
                    flush()
                    if ["h1", "h2", "h3"].contains(tag.name) { heading = max(0, heading + (tag.closing ? -1 : 1)) }
                    if tag.name == "li" { items = max(0, items + (tag.closing ? -1 : 1)) }
                    continue
                }
                if tag.name == "a" {
                    if tag.closing {
                        if let a = anchor, let u = a.url { inBlock.append((u, collapse(a.text))) }
                        anchor = nil
                    } else {
                        anchor = (tag.href.flatMap { target($0, base: base) }, "")
                    }
                }
                continue
            }
            // text up to the next tag
            let j = b[i...].firstIndex(of: UInt8(ascii: "<")) ?? b.count
            let s = entities(String(decoding: b[i..<j], as: UTF8.self))
            i = j
            if inTitle {
                title += s
                continue
            }
            guard skip == nil else { continue }
            text += s
            anchor?.text += s
        }
        flush()
        return Page(title: collapse(title), blocks: tidy(blocks), links: links)
    }

    /// The same link again right after (a search result's title, its address, its summary): an address-like
    /// repeat goes, other text stays as plain text.
    static func tidy(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        var lastLink: Int?
        for var b in blocks {
            if b.kind == link, let l = b.link {
                if l == lastLink {
                    if !b.text.contains(" "), b.text.contains(".") { continue }
                    b.kind = para
                    b.link = nil
                } else {
                    lastLink = l
                }
            } else if b.kind != para {
                lastLink = nil
            }
            out.append(b)
        }
        return out
    }

    /// A link's place: absolute http(s) (DuckDuckGo's result redirects to where they go); nil for the rest.
    static func target(_ href: String, base: URL) -> URL? {
        let h = entities(href).trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !h.hasPrefix("#"), !h.lowercased().hasPrefix("javascript:"), !h.lowercased().hasPrefix("mailto:"),
              let u = URL(string: h, relativeTo: base)?.absoluteURL, ["http", "https"].contains(u.scheme?.lowercased() ?? "")
        else { return nil }
        if u.host?.hasSuffix("duckduckgo.com") == true {
            if u.path.hasPrefix("/y.js") { return nil }
            if u.path == "/l" || u.path.hasPrefix("/l/"), let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems,
               let to = q.first(where: { $0.name == "uddg" })?.value, let t = URL(string: to) {
                return t
            }
        }
        return u
    }

    struct Tag {
        var name = ""
        var closing = false
        var selfClosing = false
        var href: String?

        init(_ b: [UInt8]) {
            var s = String(decoding: b, as: UTF8.self)
            if s.hasPrefix("/") {
                closing = true
                s.removeFirst()
            }
            if s.hasSuffix("/") { selfClosing = true }
            name = String(s.prefix { $0.isLetter || $0.isNumber }).lowercased()
            if name == "a", !closing, let r = s.range(of: "href", options: .caseInsensitive) {
                var rest = s[r.upperBound...].drop { $0 == " " }
                guard rest.first == "=" else { return }
                rest = rest.dropFirst().drop { $0 == " " }
                if let q = rest.first, q == "\"" || q == "'" {
                    href = String(rest.dropFirst().prefix { $0 != q })
                } else {
                    href = String(rest.prefix { $0 != " " && $0 != ">" })
                }
            }
        }
    }

    static func find(_ b: [UInt8], _ pat: [UInt8], from: Int) -> Int? {
        guard pat.count <= b.count else { return nil }
        var i = from
        while i + pat.count <= b.count {
            if b[i] == pat[0], Array(b[i..<(i + pat.count)]) == pat { return i }
            i += 1
        }
        return nil
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                          "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
                                          "rdquo": "”", "ldquo": "“", "copy": "©", "middot": "·", "bull": "•"]

    static func entities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = s[s.index(after: i)..<semi]
                var rep: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    rep = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if body.hasPrefix("#") {
                    rep = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    rep = named[String(body)]
                }
                if let rep {
                    out += rep
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    /// The page as the watch takes it: `N title`, `t kind link text` (a long block in pieces: kind 4 for the rest),
    /// `F`.
    public static func messages(_ p: Page) -> [Data] {
        var out = [Data("N".utf8) + utf8(p.title, 80)]
        for bl in p.blocks {
            for (k, piece) in pieces(bl.text, 120).enumerated() {
                out.append(Data([UInt8(ascii: "t"), k == 0 ? bl.kind : more, UInt8(bl.link.map { min($0, 254) } ?? 255)])
                           + Data(piece.utf8))
            }
        }
        out.append(Data("F".utf8))
        return out
    }

    /// `s` in pieces of at most `n` bytes, cut at a space when there is one (whole characters always).
    static func pieces(_ s: String, _ n: Int) -> [String] {
        var out: [String] = []
        var rest = Substring(s)
        while !rest.isEmpty {
            if rest.utf8.count <= n {
                out.append(String(rest))
                break
            }
            var cut = rest.startIndex, bytes = 0
            for c in rest.indices {
                let w = String(rest[c]).utf8.count
                if bytes + w > n { break }
                bytes += w
                cut = rest.index(after: c)
            }
            if let sp = rest[..<cut].lastIndex(of: " "), sp > rest.startIndex {
                cut = rest.index(after: sp)
            }
            out.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
            rest = rest[cut...]
        }
        return out
    }
}

/// The Browser's protocol beyond the page (cmf-watch-sdk sdk/examples/browser/src/ui.rs).
public enum BrowserProto {
    public static func note(_ t: String) -> Data { Data("!".utf8) + utf8(t, 78) }
    public static func recent(_ i: Int, _ title: String) -> Data { Data([UInt8(ascii: "H"), UInt8(i)]) + utf8(title, 46) }
    public static let nothingBefore = Data("Z".utf8)
    public static let field = Data("K".utf8)

    /// The watch's bottom bar: what was searched on Google, else the site.
    public static func label(_ u: URL) -> Data {
        let host = u.host ?? ""
        let q = host.contains("google.") ? URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "q" })?.value : nil
        var t = q ?? host
        for p in ["www.", "m."] where t == host && t.hasPrefix(p) { t.removeFirst(p.count) }
        return Data("b".utf8) + utf8(t, 64)
    }
    public static func video(_ on: Bool) -> Data { Data([UInt8(ascii: "M"), on ? 1 : 0]) }

    /// Images still to come on a page laid out tall (`h` CSS px): lazy ones told to load now. The page's picture
    /// waits till this is 0 (a short while at most).
    public static func imagesPending(_ h: Double) -> String {
        """
        (() => { let n = 0; for (const i of document.images) {
            if (i.loading == 'lazy') i.loading = 'eager';
            const ds = i.dataset && (i.dataset.src || i.dataset.lazySrc); if (ds && !i.src) i.src = ds;
            const r = i.getBoundingClientRect();
            if (r.width > 1 && r.top < \(h) && !(i.complete && i.naturalWidth > 0)) n++; }
          return n; })()
        """
    }

    /// The video player (page view while a video plays): its title, `U title`.
    public static func videoTitle(_ t: String) -> Data { Data([UInt8(ascii: "U")]) + utf8(t, 80) }

    /// Where it is: `u cur:u16 dur:u16 paused` (seconds).
    public static func progress(cur: Double, dur: Double, paused: Bool) -> Data {
        var d = Data([UInt8(ascii: "u")])
        d.le(UInt16(clamping: Int(cur.isFinite ? cur : 0)))
        d.le(UInt16(clamping: Int(dur.isFinite ? dur : 0)))
        d.append(paused ? 1 : 0)
        return d
    }

    /// The player's video: `[exists, paused, ended, cur, dur, title]` as JSON.
    public static let videoState = """
    (() => { const v = [...document.querySelectorAll('video')].find(v => v.readyState > 0) || document.querySelector('video');
      if (!v) return JSON.stringify([0]);
      // an ad (YouTube's player says so), and whether it can be skipped now
      const ad = !!document.querySelector('.ad-showing, .ad-interrupting');
      const skip = !!document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, [id^=skip-button] button');
      return JSON.stringify([1, v.paused ? 1 : 0, v.ended ? 1 : 0, v.currentTime || 0, isFinite(v.duration) ? v.duration : 0,
        (document.title || '').replace(/ - YouTube$/, ''), ad ? 1 : 0, skip ? 1 : 0]); })()
    """

    /// Pause / play the player's video.
    public static let toggleScript = """
    (() => { const sk = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, [id^=skip-button] button');
      if (sk) { sk.click(); return 3; } const v = [...document.querySelectorAll('video')].find(v => v.readyState > 0) || document.querySelector('video');
      if (!v) return 0; if (v.paused) { v.play(); return 1; } v.pause(); return 2; })()
    """

    public static func seekScript(_ dt: Int) -> String {
        """
        (() => { const v = [...document.querySelectorAll('video')].find(v => v.readyState > 0); if (!v) return 0;
          v.currentTime = Math.max(0, v.currentTime + \(dt)); return 1; })()
        """
    }

    /// The watch goes to page view by itself: a page with no text, a video.
    public static let toPage = Data([UInt8(ascii: "G")])

    /// After a page's `J`: `y scroll:u16 more` where the view starts on it and what else there is (1 more below,
    /// 2 above, 4 no drawn view for this site: its mode button goes picture → text).
    public static func pageInfo(scroll: Int = 0, more: UInt8) -> Data {
        var d = Data([UInt8(ascii: "y")])
        d.le(UInt16(clamping: max(scroll, 0)))
        d.append(more)
        return d
    }

    /// The site's logo built into the watch's Browser (its ids): 0 Google, 1 YouTube, 2 Wikipedia, 3 Fandom.
    public static func logo(_ u: URL?) -> UInt8? {
        let h = (u?.host ?? "").lowercased()
        if h.contains("google.") { return 0 }
        if h.hasSuffix("youtube.com") || h.hasSuffix("youtu.be") { return 1 }
        if h.hasSuffix("wikipedia.org") { return 2 }
        if h.hasSuffix("fandom.com") { return 3 }
        return nil
    }

    /// The sites the watch draws by default (their own look, laid out here): Google, YouTube, Wikipedia, Fandom.
    /// Every other site comes as a picture of the page.
    public static func known(_ u: URL?) -> Bool {
        let h = (u?.host ?? "").lowercased()
        return h.contains("google.") || h.hasSuffix("youtube.com") || h.hasSuffix("youtu.be")
            || h.hasSuffix("wikipedia.org") || h.hasSuffix("fandom.com")
    }

    /// A video page (YouTube, Instagram): opened in page view and played, its frames to the watch.
    public static func isVideo(_ u: URL) -> Bool {
        let h = (u.host ?? "").lowercased(), p = u.path.lowercased()
        if h == "youtu.be" { return true }
        // a video file itself
        if [".mp4", ".webm", ".mov", ".m4v", ".m3u8"].contains(where: { p.hasSuffix($0) }) { return true }
        if h.hasSuffix("youtube.com") { return p.hasPrefix("/watch") || p.hasPrefix("/shorts/") || p.hasPrefix("/live/") }
        if h.hasSuffix("instagram.com") { return p.hasPrefix("/reel") || p.hasPrefix("/p/") || p.hasPrefix("/tv/") }
        return false
    }

    /// Starts a page's video with its sound: YouTube's play button, else the first video.
    public static let playScript = """
    (() => { const b = document.querySelector('.ytp-large-play-button, .ytmCuedOverlayPlayButton, button[aria-label="Play"]');
      if (b && b.offsetParent !== null) b.click();
      const v = document.querySelector('video'); if (!v) return 0;
      v.muted = false; if (v.paused) v.play(); return 1; })()
    """

    /// A tap in page view did nothing to the page: the watch takes its outline off.
    public static let unchanged = Data([UInt8(ascii: "Y")])

    /// The whole page laid out tall (`cssHeight`) at the phone's width: its tappable places (page px) and folded
    /// sections opened. → JSON [[x, y, w, h, kind]…], document coordinates in CSS px.
    public static let pageBoxes = """
    (() => { document.querySelectorAll('details:not([open])').forEach(d => d.open = true);
      const out = [];
      document.querySelectorAll('a[href], button, input, textarea, select, [role=button], [onclick], summary').forEach(e => {
        const r = e.getBoundingClientRect(); if (r.width < 4 || r.height < 4) return;
        const st = getComputedStyle(e); if (st.visibility == 'hidden' || st.display == 'none') return;
        const t = e.tagName.toLowerCase(), ty = (e.type || '').toLowerCase();
        const k = (t == 'textarea' || (t == 'input' && !['button','submit','checkbox','radio','image','reset','hidden'].includes(ty))) ? 1 : (t == 'a' ? 0 : 2);
        out.push([r.left + scrollX, r.top + scrollY, r.width, r.height, k]); });
      out.sort((a, b) => a[1] - b[1]);
      return JSON.stringify(out.slice(0, 400)); })()
    """

    /// The page's height to lay it out at, CSS px: all of it up to `cap` (folded sections opened first).
    public static let pageHeight = """
    (() => { document.querySelectorAll('details:not([open])').forEach(d => d.open = true);
      return Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0); })()
    """

    /// A tap at page px (x, y) on a page laid out `side` CSS px wide: scrolled to it, then clicked; 2 a text field
    /// (focused), 1 clicked, 0 nothing there.
    public static func tapScript(x: Int, y: Int, side: Double) -> String {
        let k = side / 466
        let px = Double(x) * k, py = Double(y) * k
        return """
        (() => { window.scrollTo(0, Math.max(0, \(py) - innerHeight / 2));
          const e = document.elementFromPoint(\(px), \(py) - scrollY); if (!e) return 0;
          const f = e.closest('input,textarea,[contenteditable="true"]');
          if (f && !['button','submit','checkbox','radio','image','reset'].includes((f.type||'').toLowerCase())) { f.focus(); return 2; }
          const v = e.closest('video') || (e.closest('div,figure') || document.body).querySelector('video');
          if (v && v.paused && v.getBoundingClientRect().height > 20) { v.muted = false; v.play(); }
          e.click(); return 1; })()
        """
    }

    /// What tells whether a tap changed the page: its address, height and text length.
    public static let pageState = "location.href + '|' + document.documentElement.scrollHeight + '|' + (document.body ? document.body.innerText.length : 0)"

    /// Page view's tappable places on the page just sent, page px: `A n`, then `a x y w h kind` each
    /// (i16s; kind 0 link, 1 text field, 2 button), 160 at most, 12 a message.
    public static func boxes(_ b: [(x: Int, y: Int, w: Int, h: Int, kind: UInt8)]) -> [Data] {
        let b = Array(b.prefix(160))
        var out = [Data([UInt8(ascii: "A"), UInt8(b.count)])]
        for start in stride(from: 0, to: b.count, by: 12) {
            var m = Data([UInt8(ascii: "a"), UInt8(start)])
            for r in b[start..<min(start + 12, b.count)] {
                for v in [r.x, r.y, r.w, r.h] { m.le(Int16(clamping: v)) }
                m.append(r.kind)
            }
            out.append(m)
        }
        return out
    }

    public enum Ask: Equatable {
        /// `view`: 0 text, 1 page view (drawn for the sites the watch knows, else a picture), 2 a picture of the page;
        /// `remove`: a recent page held on the start screen (`D idx`)
        case ready, go(String), recent(Int), link(Int), back, view(mode: Int), tap(x: Int, y: Int), scroll(Int),
             type(String), leave, toggle, seek(Int), remove(Int)
    }

    public static func parse(_ m: Data) -> Ask? {
        let b = [UInt8](m)
        guard let c = b.first else { return nil }
        switch (Character(UnicodeScalar(c)), b.count) {
        case ("R", 1): return .ready
        case ("Q", 2...): return .go(String(decoding: b.dropFirst(), as: UTF8.self))
        case ("O", 2): return .recent(Int(b[1]))
        case ("L", 2): return .link(Int(b[1]))
        case ("B", 1): return .back
        case ("V", 2): return .view(mode: Int(min(b[1], 2)))
        case ("D", 2): return .remove(Int(b[1]))
        case ("T", 5): return .tap(x: Int(UInt16(b[1]) | UInt16(b[2]) << 8), y: Int(UInt16(b[3]) | UInt16(b[4]) << 8))
        case ("S", 3): return .scroll(Int(Int16(bitPattern: UInt16(b[1]) | UInt16(b[2]) << 8)))
        case ("W", 1...): return .type(String(decoding: b.dropFirst(), as: UTF8.self))
        case ("X", 1): return .leave
        case ("P", 1): return .toggle
        case ("k", 3): return .seek(Int(Int16(bitPattern: UInt16(b[1]) | UInt16(b[2]) << 8)))
        default: return nil
        }
    }

    /// Typed words: an address (has a dot and no spaces, or a scheme) or a Google search.
    public static func url(for typed: String) -> URL {
        let t = typed.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://"), let u = URL(string: t) { return u }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t), u.host?.contains(".") == true { return u }
        var c = URLComponents(string: "https://www.google.com/search")!
        // udm=14: Google's plain web results (no AI overview, no widgets): about twice as fast, half the bytes
        c.queryItems = [.init(name: "q", value: t), .init(name: "udm", value: "14")]
        return c.url!
    }

    /// The same search on DuckDuckGo's plain page (no scripts needed): when Google gives nothing.
    public static func fallback(for google: URL) -> URL? {
        guard let q = URLComponents(url: google, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value
        else { return nil }
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [.init(name: "q", value: q)]
        return c.url
    }

    /// On Google's plain results (udm=14): a "Show AI Overview" button at the top, a link to the full results.
    public static let overviewButton = """
    (() => { const u = new URL(location.href); if (u.searchParams.get('udm') != '14' || document.getElementById('cmf-ai')) return 0;
      u.searchParams.delete('udm');
      const a = document.createElement('a'); a.id = 'cmf-ai'; a.href = u.toString(); a.textContent = 'Show AI Overview';
      a.style.cssText = 'display:inline-block;margin:10px 16px 4px;padding:9px 18px;border-radius:20px;background:#303134;'
        + 'color:#8ab4f8;font:500 15px Arial,sans-serif;text-decoration:none';
      // above the results (under Google's bar and its tabs)
      const at = document.querySelector('#search, #rso, #botstuff');
      if (at) at.before(a); else document.body.prepend(a);
      return 1; })()
    """

    public static func isGoogleSearch(_ u: URL) -> Bool {
        (u.host ?? "").contains("google.") && u.path == "/search"
    }

    /// Google's results (title, address, summary) as a reader page.
    public static func results(_ rows: [[String]], query: String) -> Reader.Page {
        var blocks: [Reader.Block] = []
        var links: [URL] = []
        for r in rows where r.count >= 2 {
            guard let u = URL(string: r[1]), ["http", "https"].contains(u.scheme ?? ""), !links.contains(u),
                  !r[0].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            links.append(u)
            blocks.append(.init(kind: Reader.link, link: links.count - 1, text: Reader.collapse(r[0])))
            if r.count >= 3, !r[2].isEmpty { blocks.append(.init(kind: Reader.para, link: nil, text: Reader.collapse(r[2]))) }
        }
        return Reader.Page(title: query + " - Google", blocks: blocks, links: links)
    }
}
