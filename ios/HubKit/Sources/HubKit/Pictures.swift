import CoreGraphics
import Foundation

/// The watch's page view: a page as pictures of the real page, rendered by the phone's (or the Mac's) browser
/// (cmf-watch-sdk browser long.rs on the watch). A screen at a time down the real page, the browser scrolled as a
/// person would, so lazy pictures load and endless pages (feeds) keep growing:
/// - each screen goes out as soon as it is shot (the watch shows the first while the rest come);
/// - pictures not in yet are striped stand-ins, sent again in their place once they are (`late`);
/// - the end of a part asks for the next (`more`), the watch's view kept where it was;
/// - headers that stay on screen show once; each video gets a play button (a tap plays it on the watch's player).
/// Platform-free: the browser comes as `js` (run a script, its answer) and `shot` (part of the view as RGB).
@MainActor public final class PagePictures {
    /// The view's width in page px (the watch's 466 panel px); the view is as tall.
    public let side: Double
    let js: (String) async -> String?
    /// The view's `rect` (page px, in the view) as RGB `width` px wide; its height.
    let shot: (CGRect, Int) async -> (rgb: [UInt8], height: Int)?

    /// The part sent: its top and height on the page (page px).
    public private(set) var top = 0.0, height = 0.0
    public private(set) var active = false
    var pending: [(id: Int, x: Double, y: Double, w: Double, h: Double)] = []

    /// Watch px a picture pixel (233 px across), screens a part, bytes the watch keeps.
    static let scale = 2, steps = 6, cap = 55 * 1024

    public init(side: Double, js: @escaping (String) async -> String?,
                shot: @escaping (CGRect, Int) async -> (rgb: [UInt8], height: Int)?) {
        (self.side, self.js, self.shot) = (side, js, shot)
    }

    /// A new page: nothing of the last one.
    public func reset() {
        active = false
        pending = []
    }

    /// Where a tap on the watch's part is on the page (watch px from the part's top → from the page's).
    public var tapTop: Int { active ? Int(top * 466 / side) : 0 }

    func number(_ s: String) async -> Double? { Double(await js(s) ?? "") }

    /// A part from `y0` (page px); `scroll` where the watch's view starts on it. Each screen goes to `emit` as it is
    /// shot: `J h`, `y scroll flags`, bands…, `j`, `y flags` (1 more below, 2 more above), the tappable places.
    public func section(from y0: Double, scroll: Int = 0, emit: ([Data]) async -> Void) async {
        let vh = side, w = 466 / Self.scale
        var rows: [[Double]] = []
        var top = max(0, y0), end = false
        var lines = 0, used = 0, full = false
        if y0 == 0 {
            // folded sections (mobile Wikipedia, Fandom) open: the whole page in the pictures
            _ = await js(Self.openFolds)
            // an app still building its page (a feed's splash: one screen, next to no text): 8 s for it to grow
            let shell = "document.documentElement.scrollHeight <= \(vh + 20) && document.body.innerText.length < 600 ? 1 : 0"
            for _ in 0..<40 where await js(shell) == "1" {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        // the part's height as it will be if all of it comes; less: `j` says so
        var j = Data([UInt8(ascii: "J")])
        j.le(UInt16(Self.steps * 466))
        var y = Data([UInt8(ascii: "y")])
        y.le(UInt16(clamping: scroll))
        y.append(y0 > 0 ? 2 : 0)
        await emit([j, y])
        for i in 0..<Self.steps where !full {
            let want = top + Double(i) * vh
            var got = await number("window.scrollTo(0, \(want)); \(Self.playButtons); scrollY") ?? want
            if got + 1 < want {
                // at the bottom: an endless page adds more a moment after it is reached; 3 s for it (8 s while
                // the whole page is still about a screen: an app that hasn't built its page yet)
                let h0 = await number("document.documentElement.scrollHeight") ?? 0
                for _ in 0..<(h0 <= vh * 1.5 ? 40 : 15) {
                    try? await Task.sleep(for: .milliseconds(200))
                    if (await number("document.documentElement.scrollHeight") ?? 0) > h0 + 50 { break }
                }
                got = await number("window.scrollTo(0, \(want)); \(Self.playButtons); scrollY") ?? got
            }
            if i == 0 { top = got }
            // banners over the page (an app's "get the app", a cookie wall): gone; then bars that stay on screen
            _ = await js(Self.hideBanners)
            if top > 0 || i > 0 { _ = await js(Self.hideFixed) }
            try? await Task.sleep(for: .milliseconds(i == 0 ? 120 : 80))
            // what is in view: its pictures (0.5 s), its web fonts (text in one is blank till it loads, 1 s)
            for _ in 0..<5 where (Int(await js(BrowserProto.imagesPending(vh)) ?? "0") ?? 0) > 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            for _ in 0..<10 where await js("document.fonts.status") == "loading" {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if i == 0 { pending = [] }
            pending += Self.marks(await js(Self.markPending)).filter { p in !pending.contains { $0.id == p.id } }
            let at = await number("scrollY") ?? got
            // the page ended: only what is below the last screen
            let already = i == 0 ? 0 : Int(((top + Double(i) * vh) - at) / vh * Double(w))
            if at + 1 < top + Double(i) * vh, already >= w { end = true; break }
            guard let s = await shot(CGRect(x: 0, y: 0, width: vh, height: vh), w), s.height > already else { break }
            let rgb = Array(s.rgb[(3 * w * max(0, already))...])
            let (msgs, done, bytes) = Self.bands(rgb, width: w, height: s.height - max(0, already), at: lines, room: Self.cap - used)
            used += bytes
            lines += done
            full = done < s.height - max(0, already)
            await emit(msgs)
            let shift = at - top
            let found = (await js(BrowserProto.pageBoxes)).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[Double]] } ?? []
            rows += found.filter { $0.count == 5 && $0[1] >= Double(already) * vh / Double(w) - 1 && $0[1] < vh }
                .map { [$0[0], $0[1] + shift, $0[2], $0[3], $0[4]] }
            if at + 1 < top + Double(i) * vh { end = true; break }
        }
        if ProcessInfo.processInfo.environment["PICTURES_DEBUG"] != nil {
            let page = await number("document.documentElement.scrollHeight") ?? 0
            FileHandle.standardError.write(Data("pictures: from \(y0) top \(top) lines \(lines) end \(end) full \(full) page \(page)\n".utf8))
        }
        self.top = top
        height = Double(lines) * vh / Double(w)
        active = true
        pending = pending.filter { $0.y < top + height }
        let page = await number("document.documentElement.scrollHeight") ?? 0
        let below = full || (!end && top + height + 4 < page)
        let came = lines * Self.scale
        let k = 466 / vh
        var seen = Set<[Int]>()
        let boxes = rows.compactMap { r -> (x: Int, y: Int, w: Int, h: Int, kind: UInt8)? in
            let b = (Int(r[0] * k), Int(r[1] * k), Int(r[2] * k), Int(r[3] * k))
            guard b.1 < came, seen.insert([b.0, b.1, b.2, b.3]).inserted else { return nil }
            return (b.0, b.1, b.2, b.3, UInt8(r[4]))
        }
        if lines == 0 {
            // nothing could be shot (the phone's browser not drawing: the app in the background, the phone locked):
            // said on the watch, not a blank page
            active = false
            await emit([BrowserProto.note("Couldn't show the page: open CMFX on the phone")])
            return
        }
        await emit([Data([UInt8(ascii: "j")]), Data([UInt8(ascii: "y"), (below ? 1 : 0) | (top > 0 ? 2 : 0)])]
                   + BrowserProto.boxes(boxes))
    }

    /// The next part (`dir` 1 down, -1 up), its first screen what the watch shows now. False: no part yet.
    public func more(_ dir: Int, emit: ([Data]) async -> Void) async -> Bool {
        guard active else { return false }
        // the watch shows the last 300 px (going down) or the first (going up): the new part keeps them in view
        let keep = 300 * side / 466
        if dir > 0 {
            await section(from: top + height - keep, emit: emit)
        } else {
            let y0 = max(0, top - height + keep)
            await section(from: y0, scroll: Int((top - y0) * 466 / side), emit: emit)
        }
        return true
    }

    /// Bands of `rgb` (`width` px) from picture row `at`, 32 rows each, 16 colours, while `room` bytes last:
    /// the messages, the rows they cover, their bytes.
    static func bands(_ rgb: [UInt8], width: Int, height: Int, at: Int, room: Int) -> ([Data], Int, Int) {
        var out: [Data] = [], rows = 0, used = 0
        while rows < height {
            let r1 = min(rows + 32, height)
            let part = Array(rgb[(3 * width * rows)..<(3 * width * r1)])
            let (palette, idx) = Quantize.refined(rgb: part, colours: 16)
            let pal = (palette + Array(repeating: (0, 0, 0), count: max(0, 16 - palette.count))).prefix(16)
                .map { Rle.rgb565($0.0, $0.1, $0.2) }
            let t = Rle.tokens(idx, width: width, height: r1 - rows)
            let hdr = Rle.header(width: width, height: r1 - rows, scale: UInt8(scale), x0: 0,
                                 y0: Int16(clamping: (at + rows) * scale), palette: pal)
            guard used + hdr.count + t.count <= room else { break }
            used += hdr.count + t.count
            out += Rle.messages(header: hdr, tokens: t)
            rows = r1
        }
        return (out, rows, used)
    }

    /// The marked pictures that came in since: each in its place on the watch's part, over its stand-in; how many
    /// are still out.
    public func late() async -> (messages: [Data], left: Int) {
        guard active, !pending.isEmpty else { return ([], 0) }
        let ids = pending.map { String($0.id) }.joined(separator: ",")
        let inNow = await js("JSON.stringify([\(ids)].filter(i => { const e = document.querySelector('[data-wp=\"' + i + '\"]'); return e && e.complete && e.naturalWidth > 0; }))") ?? "[]"
        let got = Set(((try? JSONSerialization.jsonObject(with: Data(inNow.utf8))) as? [Int]) ?? [])
        let ready = pending.filter { got.contains($0.id) }
        guard !ready.isEmpty else { return ([], pending.count) }
        pending.removeAll { got.contains($0.id) }
        _ = await js("document.querySelectorAll('[data-wp]').forEach(e => { if (e.complete && e.naturalWidth > 0) e.style.removeProperty('background'); }); 1")
        let k = 466 / side, px = Double(466 / Self.scale) / side
        var out: [Data] = []
        for p in ready where p.y >= top && p.y < top + height {
            let at = await number("window.scrollTo(0, \(max(0, p.y - 20))); scrollY") ?? 0
            try? await Task.sleep(for: .milliseconds(60))
            let w = max(2, Int(p.w * px))
            guard let s = await shot(CGRect(x: p.x, y: p.y - at, width: p.w, height: p.h), w) else { continue }
            let (palette, idx) = Quantize.refined(rgb: s.rgb, colours: 16)
            let pal = (palette + Array(repeating: (0, 0, 0), count: max(0, 16 - palette.count))).prefix(16)
                .map { Rle.rgb565($0.0, $0.1, $0.2) }
            let hdr = Rle.header(width: w, height: s.height, scale: UInt8(Self.scale), x0: Int16(clamping: Int(p.x * k)),
                                 y0: Int16(clamping: Int((p.y - top) * k)), palette: pal)
            out += Rle.messages(header: hdr, tokens: Rle.tokens(idx, width: w, height: s.height))
        }
        return (out, pending.count)
    }

    /// Marks each picture that isn't in yet (`data-wp`, stripes in its place); answers them as [[id, x, y, w, h]].
    static let markPending = """
    (() => { const out = []; let n = window.__wpn || 0;
      for (const e of document.querySelectorAll('img')) { if (e.complete && e.naturalWidth > 0) continue;
        const r = e.getBoundingClientRect(); if (r.width < 16 || r.height < 16 || r.bottom < 0 || r.top > innerHeight) continue;
        if (!e.dataset.wp) e.dataset.wp = String(++n);
        e.style.setProperty('background', 'repeating-linear-gradient(45deg,#6a6a6a 0 6px,#8a8a8a 6px 12px)', 'important');
        out.push([+e.dataset.wp, r.left + scrollX, r.top + scrollY, r.width, r.height]); }
      window.__wpn = n; return JSON.stringify(out); })()
    """

    static func marks(_ json: String?) -> [(id: Int, x: Double, y: Double, w: Double, h: Double)] {
        let a = (json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[Double]] }) ?? []
        return a.filter { $0.count == 5 }.map { (Int($0[0]), $0[1], $0[2], $0[3], $0[4]) }
    }

    /// Folded parts of the page opened: `hidden=until-found` sections, closed `<details>`.
    public static let openFolds = """
    (() => { document.querySelectorAll('[hidden="until-found"]').forEach(e => e.removeAttribute('hidden'));
      document.querySelectorAll('details:not([open])').forEach(e => e.open = true); return 1; })()
    """

    /// Fixed or sticky boxes over a quarter of the view or more: banners, not the page. Wikipedia's campaign banners
    /// (`#centralNotice`, in the page's flow, a screen tall) too.
    public static let hideBanners = """
    (() => { document.querySelectorAll('#centralNotice').forEach(e => e.style.setProperty('display', 'none', 'important'));
      for (const e of document.querySelectorAll('body *')) { const p = getComputedStyle(e).position;
      if (p != 'fixed' && p != 'sticky') continue; const r = e.getBoundingClientRect();
      if (r.width * r.height > innerWidth * innerHeight * 0.25) e.style.setProperty('display', 'none', 'important'); }
      return 1; })()
    """

    /// Headers and bars that stay on screen, hidden (not to repeat down the stitched picture); their room kept.
    public static let hideFixed = """
    (() => { for (const e of document.querySelectorAll('body *')) { const p = getComputedStyle(e).position;
      if (p == 'fixed' || p == 'sticky') e.style.setProperty('visibility', 'hidden', 'important'); } return 1; })()
    """

    /// A play button on each video (a tap plays it: the watch's player); on the page, so it is in the picture.
    public static let playButtons = """
    (() => { document.querySelectorAll('.__wpb').forEach(e => e.remove());
      for (const v of document.querySelectorAll('video')) { const r = v.getBoundingClientRect();
        if (r.width < 40 || r.height < 30) continue;
        const b = document.createElement('div'); b.className = '__wpb';
        const d = Math.min(64, r.width / 3, r.height / 2);
        b.style.cssText = `position:absolute;z-index:2147483647;pointer-events:none;left:${r.left + scrollX + r.width / 2 - d / 2}px;top:${r.top + scrollY + r.height / 2 - d / 2}px;width:${d}px;height:${d}px;border-radius:50%;background:rgba(0,0,0,.7);border:2px solid #fff;box-sizing:border-box`;
        const t = document.createElement('div');
        t.style.cssText = `position:absolute;left:${d * 0.38}px;top:${d * 0.27}px;width:0;height:0;border-style:solid;border-width:${d * 0.22}px 0 ${d * 0.22}px ${d * 0.34}px;border-color:transparent transparent transparent #fff`;
        b.appendChild(t); document.body.appendChild(b); }
      return 1; })()
    """
}
