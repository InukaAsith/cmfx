import AVFoundation
import Foundation
import HubKit
import SwiftUI
import UIKit
import WebKit
import WireKit

/// The watch's Browser (cmf-watch-sdk sdk/examples/browser). Reader view: the page fetched here and its text pulled
/// out (HubKit Reader; no scripts, so it works with the phone in a pocket). Page view: the page in a browser here
/// (WebKit, its cookies kept: a site signed in to on the Browser page is signed in for the watch), a picture of it
/// sent in 16-colour bands; taps, scrolling and typing come back. A video playing in it: its sound here, its frames
/// to the watch small and in 16 colours, one after another for as long as it plays (no timer stops them; the app
/// closing or the view changing does). History and recent pages are kept on the phone only.
@MainActor @Observable final class BrowserService: NSObject, WatchService, WKNavigationDelegate {
    nonisolated static let app = "Browser"
    var status: String?
    private(set) var current: URL?
    /// What the watch's page comes from, live (the Browser page shows it): the page view's address as it moves (taps,
    /// redirects), loading it, sending it
    private(set) var watching: URL?
    private(set) var loading = false
    private(set) var sending = false
    private var title = ""
    /// reader view's pages before this one (back)
    private var history: [URL] = []
    private var links: [URL] = []
    /// The watch's view: 0 text, 1 page view (drawn for the sites it knows, else a picture), 2 a picture of the page.
    private var mode = 0
    private var pageView: Bool {
        get { mode != 0 }
        set { mode = newValue ? 1 : 0 }
    }
    private var gen = 0
    /// page view's last picture and the video frames: a newer ask drops an older one
    private var picGen = 0
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    /// iOS runs and draws web pages only while CMFX is in front: with the phone locked or asleep (or another app
    /// open) WebKit's page process is suspended (its scripts held, snapshots blank or never back; Apple: by design,
    /// there is no way round it). Then page view doesn't wait on it: the page's text comes at once (fetched here,
    /// no browser), and its picture when the phone is unlocked (`pictureLater`).
    private var canDraw: Bool { UIApplication.shared.applicationState == .active }
    private var pictureLater = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.unlocked() }
        }
    }

    /// The phone unlocked: the picture the watch is still waiting for (its Browser still open, page view asked).
    private func unlocked() {
        guard pictureLater else { return }
        pictureLater = false
        guard Hub.shared.lastApp == Self.app, current != nil, mode != 0 else { return }
        Task { await showPage() }
    }

    /// Page view asked while the phone can't draw: the page's text now, the picture once it is unlocked.
    private func locked() async {
        pictureLater = true
        guard let url = current else { return }
        let m = mode
        mode = 0
        await open(url, push: false)
        // (the watch's choice stays: page view comes back by itself)
        if mode == 0 { mode = m }
        await note("iPhone locked: the text now, the picture once it's unlocked")
    }

    /// The browser page view draws from; one with the Browser page's (WebKit's default store: cookies shared).
    @ObservationIgnored private lazy var web: WKWebView = {
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = []
        c.websiteDataStore = .default()
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side), configuration: c)
        w.navigationDelegate = self
        w.isUserInteractionEnabled = false
        w.alpha = 0.011
        return w
    }()

    /// Page view's page: this many points square (the watch's 466 px).
    static let side: CGFloat = 360
    /// The watch's picture of it: 233 px (2 a pixel); video frames 155 px (3 a pixel).
    static let picture = 233, frame = 155

    func receive(_ m: Data) {
        guard let ask = BrowserProto.parse(m) else { return }
        switch ask {
        case .ready:
            history = []
            pageView = false
            Task { await sendRecent() }
        case .go(let typed):
            // page view by default (the watch's reader button asks for text)
            history = []
            pageView = true
            Task { await open(BrowserProto.url(for: typed), push: true) }
        case .recent(let i):
            let r = recent
            guard r.indices.contains(i) else { return }
            history = []
            pageView = true
            Task { await open(r[i].url, push: true) }
        case .link(let i):
            guard links.indices.contains(i) else { return }
            Task { await open(links[i], push: true) }
        case .back:
            Task { await back() }
        case .view(let m):
            mode = m
            if m != 0 {
                Task { await showPage() }
            } else {
                stopMedia()
                // the page view may have gone somewhere else: its text
                let at = (made ? web.url : nil).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil } ?? current
                if let at { Task { await open(at, push: at != current) } }
            }
        case .tap(let x, let y):
            Task { await tap(x, y) }
        case .scroll(let d):
            // the end of the part the watch has: the page's next part (the real page scrolled, a feed grows)
            Task { await more(d >= 0 ? 1 : -1) }
        case .type(let text):
            Task { await type(text) }
        case .leave:
            otherApp()
        case .toggle:
            Task { _ = await js(BrowserProto.toggleScript) }
        case .seek(let dt):
            Task { _ = await js(BrowserProto.seekScript(dt)) }
        case .remove(let i):
            // held on the watch's start screen: off the list (the watch took it off its own already)
            var r = recent
            guard r.indices.contains(i) else { return }
            r.remove(at: i)
            UserDefaults.standard.set(r.map { [$0.title, $0.url.absoluteString] }, forKey: Self.recentKey)
        }
    }

    /// Another watch app talks, or the Browser closed: the page's sound and pictures stop, and what the browser
    /// cached on disk while it ran is deleted (its cookies stay: sites signed in to stay signed in).
    /// Whatever was still loading ends here too (the reader's fetches, the page, a search): nothing goes on for a
    /// closed Browser, nor holds up the app the watch opened next.
    func otherApp() {
        gen += 1
        picGen += 1
        pictureLater = false
        outbox = []
        stopMedia()
        pageView = false
        Self.pages.getAllTasks { $0.forEach { $0.cancel() } }
        Self.fetcher.getAllTasks { $0.forEach { $0.cancel() } }
        let w = loadWaiters
        loadWaiters = []
        for c in w { c.resume() }
        guard made else { return }
        web.stopLoading()
        let caches: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
                                   WKWebsiteDataTypeOfflineWebApplicationCache]
        WKWebsiteDataStore.default().removeData(ofTypes: caches, modifiedSince: .distantPast) {}
    }

    /// The reader's pages and the plain searches: memory only, cancelled when the Browser closes.
    nonisolated static let pages: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 25
        return URLSession(configuration: c)
    }()

    /// Images fetched for a page drawn while the phone is locked: memory only, nothing on disk.
    nonisolated static let fetcher: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private func stopMedia() {
        picGen += 1
        guard made else { return }
        web.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(v => v.pause())", completionHandler: nil)
    }

    /// The browser exists (page view was used): nothing of it is made before.
    private var made = false

    /// A script's answer as text ("1" for true), nil for none (WebKit's async call traps on an empty answer).
    /// The page's answer to a script; nil after 6 s (iOS may hold a backgrounded web view's scripts while the
    /// phone is locked: then the page view falls back rather than waiting for ever).
    private func js(_ s: String) async -> String? {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            web.evaluateJavaScript(s) { r, _ in
                guard !once.done else { return }
                once.done = true
                c.resume(returning: r.map { "\($0)" })
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard !once.done else { return }
                once.done = true
                c.resume(returning: nil)
            }
        }
    }

    /// What is still to go to the watch, in order (a new page or part drops the rest of the last).
    private var outbox: [Data] = []
    private var pumping = false
    /// messages left to send one at a time: after the watch didn't take one (a refused frame may be followed by
    /// taken ones, sent again then: one at a time those are rare)
    private var quiet = 0

    /// Messages to the watch: queued, sent in the background in order (the page's next screen is shot meanwhile).
    private func send(_ msgs: [Data]) async {
        outbox += msgs
        guard !pumping else { return }
        pumping = true
        Task { await pump() }
    }

    /// Till everything queued is out.
    private func drained() async {
        while pumping || !outbox.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The queue out, 4 in flight (as the Mac host's channel.Pipe: about 3.5 times one at a time): each window's
    /// taken ones go; from the first the watch didn't take (its inbox full, a frame lost), again after a pause.
    private func pump() async {
        sending = true
        defer { sending = false; pumping = false }
        var delay = 20, tries = 0
        while !outbox.isEmpty {
            let batch = Array(outbox.prefix(quiet > 0 ? 1 : 4))
            do {
                let got = try await Hub.shared.sendWindow(Self.app, batch)
                let ok = got.firstIndex { $0 != Status.ok.rawValue } ?? got.count
                // (the queue may have been dropped meanwhile: only what is still its head)
                if outbox.starts(with: batch.prefix(ok)) { outbox.removeFirst(ok) }
                quiet = max(quiet - ok, 0)
                if ok == batch.count {
                    (delay, tries) = (20, 0)
                    continue
                }
            } catch WireError.noApp {
                outbox = []
                return
            } catch {
                // the link stumbled: tried again (40 tries, about 20 s, before the page is given up)
                status = error.localizedDescription
            }
            quiet = 32
            tries += 1
            if tries > 40 { status = "The watch stopped taking the page"; outbox = []; return }
            try? await Task.sleep(for: .milliseconds(delay))
            delay = min(delay * 2, 500)
        }
    }

    private func note(_ t: String) async { await send([BrowserProto.note(t)]) }

    // --- reader view

    private func open(_ url: URL, push: Bool) async {
        gen += 1
        let g = gen
        if push, let c = current, c != url { history.append(c) }
        current = url
        if BrowserProto.isVideo(url) {
            // a video (YouTube, Instagram): page view, played, its frames to the watch
            pageView = true
            await send([BrowserProto.toPage])
            await showPage(play: true)
            return
        }
        if pageView {
            await showPage()
            return
        }
        if BrowserProto.isGoogleSearch(url) {
            await google(url, g)
            return
        }
        await note("Loading \(url.host ?? "the page")\u{2026}")
        let bg = UIApplication.shared.beginBackgroundTask(withName: "browser")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await Self.pages.data(for: req), g == gen else {
            if g == gen { await note("Couldn't load \(url.host ?? "the page")") }
            return
        }
        let final = resp.url ?? url
        current = final
        let mime = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "text/html"
        guard mime.contains("html") || mime.contains("text") else {
            await note("Not a page: open it in page view")
            return
        }
        let html = Self.text(data, resp)
        let page = await Task.detached(priority: .userInitiated) { Reader.parse(html, base: final) }.value
        guard g == gen else { return }
        links = page.links
        title = page.title.isEmpty ? (final.host ?? "Page") : page.title
        var p = page
        p.title = title
        remember(title, final)
        if p.blocks.isEmpty {
            guard canDraw else {
                pictureLater = true
                await note("No text on this page: unlock the iPhone to see it")
                return
            }
            // no text here: page view by itself
            pageView = true
            await send([BrowserProto.toPage])
            await showPage()
            return
        }
        await send(Reader.messages(p))
    }

    /// Google's results need its scripts: the search in the browser here, its results read out of the page;
    /// nothing there (no answer, a check page): the same search on DuckDuckGo.
    private func google(_ url: URL, _ g: Int) async {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
        if !canDraw {
            // Google's results need its scripts, which don't run with the phone locked: plain HTML results instead
            await plainSearch(q, g)
            return
        }
        await note("Searching Google\u{2026}")
        host()
        committed = false
        web.load(URLRequest(url: url))
        await waitLoad()
        guard g == gen else { return }
        let script = """
        (() => { const out = [];
          document.querySelectorAll('a h3, a [role=heading]').forEach(h => { const a = h.closest('a'); if (!a || !a.href) return;
            let s = ''; const box = a.closest('div.MjjYud, div[data-hveid], div.g');
            if (box) { const sn = box.querySelector('div[data-sncf], div.VwiC3b, div[style*="-webkit-line-clamp"]');
              s = sn ? sn.innerText : box.innerText.replace(a.innerText, '').split('\\n').map(x => x.trim()).filter(x => x.length > 40).join(' ').slice(0, 300); }
            out.push([h.innerText, a.href, s]); });
          return JSON.stringify(out); })()
        """
        let rows = (await js(script)).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String]] } ?? []
        let page = BrowserProto.results(rows, query: q)
        guard g == gen else { return }
        if page.blocks.isEmpty {
            await plainSearch(q, g)
            return
        }
        links = page.links
        title = page.title
        await send(Reader.messages(page))
    }

    /// A search with no browser (the phone locked, or Google showed nothing): DuckDuckGo's HTML page, else
    /// Wikipedia's articles; each read here, its results to the watch as text. Always ends with the watch told.
    private func plainSearch(_ q: String, _ g: Int) async {
        guard !q.isEmpty else { await note("Nothing to search"); return }
        await note("Searching\u{2026}")
        let bg = UIApplication.shared.beginBackgroundTask(withName: "browser search")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        func get(_ u: URL) async -> Data? {
            var req = URLRequest(url: u)
            req.timeoutInterval = 10
            req.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
            guard let (d, r) = try? await Self.pages.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return d
        }
        let tries: [(String, URL, (Data) -> [[String]])] = [
            ("DuckDuckGo", PlainSearch.duckduckgo(q), { PlainSearch.parseDuckDuckGo(String(decoding: $0, as: UTF8.self)) }),
            ("Wikipedia", PlainSearch.wikipedia(q), { PlainSearch.parseWikipedia($0) }),
        ]
        for (name, u, parse) in tries {
            guard g == gen else { return }
            guard let d = await get(u) else { continue }
            let rows = await Task.detached(priority: .userInitiated) { parse(d) }.value
            guard g == gen else { return }
            var page = BrowserProto.results(rows, query: q)
            guard !page.blocks.isEmpty else { continue }
            page.title = q + " - " + name
            current = u
            links = page.links
            title = page.title
            await send(Reader.messages(page))
            return
        }
        if g == gen { await note("Search failed: no results (check the iPhone's internet)") }
    }

    private func back() async {
        if pageView, made, canDraw, web.canGoBack {
            web.goBack()
            await waitLoad()
            await snapshot()
            return
        }
        guard let prev = history.popLast() else {
            stopMedia()
            current = nil
            await send([BrowserProto.nothingBefore])
            await sendRecent()
            return
        }
        await open(prev, push: false)
    }

    /// iPhone Safari's: the mobile pages, which read best on a small screen.
    static let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// The page's text in its charset (the header's, else UTF-8 with bad bytes replaced).
    static func text(_ d: Data, _ r: URLResponse) -> String {
        if let name = r.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: d, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return s
            }
        }
        return String(decoding: d, as: UTF8.self)
    }

    // --- recent pages (the phone only)

    private static let recentKey = "browser-recent"
    var recent: [(title: String, url: URL)] {
        (UserDefaults.standard.array(forKey: Self.recentKey) as? [[String]] ?? []).compactMap { r in
            guard r.count == 2, let u = URL(string: r[1]) else { return nil }
            return (r[0], u)
        }
    }

    private func remember(_ title: String, _ url: URL) {
        // search pages aren't worth going back to from the start screen
        guard url.host?.hasSuffix("duckduckgo.com") != true else { return }
        let rest = recent.filter { $0.url.host != url.host || $0.url.path != url.path }
        UserDefaults.standard.set(([(title, url)] + rest).prefix(4).map { [$0.title, $0.url.absoluteString] }, forKey: Self.recentKey)
    }

    private func sendRecent() async {
        await send(recent.enumerated().map { BrowserProto.recent($0.offset, $0.element.title) })
    }

    // --- page view

    /// The browser on screen (behind the app, barely visible): WebKit draws only what is in a window.
    private func host() {
        made = true
        guard web.superview == nil,
              let win = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first
        else { return }
        win.insertSubview(web, at: 0)
    }

    private func showPage(play: Bool = false) async {
        guard canDraw else { return await locked() }
        host()
        guard let url = current else { return }
        if web.url != url {
            await note("Loading the page\u{2026}")
            committed = false
            web.load(URLRequest(url: url))
            await waitLoad()
        }
        if play {
            for _ in 0..<12 {
                if await js(BrowserProto.playScript) == "1" { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(2))
            if await playing() {
                // straight to its frames: the page's picture after it stops
                picGen += 1
                await video(picGen)
                return
            }
        }
        await snapshot()
    }

    /// The navigation under way has its new document (its text may still be coming).
    private var committed = true

    /// Till the page's text is in (its document parsed), not every image and ad: its picture in about a second.
    /// (Ends early when the Browser closes: `gen` moves on.)
    private func waitLoad() async {
        let g = gen
        try? await Task.sleep(for: .milliseconds(150))
        guard web.isLoading || !committed, g == gen else { return }
        // the new document, not the one before it
        for _ in 0..<100 where !committed && g == gen {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for _ in 0..<60 where g == gen {
            guard await js("document.readyState") == "loading" else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // (the pictures' capture waits for what is in view: images, fonts)
        try? await Task.sleep(for: .milliseconds(150))
    }

    nonisolated func webView(_ v: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
        Task { @MainActor in
            self.committed = false
            self.loading = true
            self.watching = v.url ?? self.watching
        }
    }

    nonisolated func webView(_ v: WKWebView, didCommit n: WKNavigation!) {
        Task { @MainActor in
            self.committed = true
            self.watching = v.url ?? self.watching
        }
    }

    private func loaded() {
        loading = false
        watching = web.url ?? watching
        let w = loadWaiters
        loadWaiters = []
        for c in w { c.resume() }
    }

    nonisolated func webView(_ v: WKWebView, didFinish n: WKNavigation!) {
        Task { @MainActor in self.loaded() }
    }

    nonisolated func webView(_ v: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        Task { @MainActor in self.loaded() }
    }

    nonisolated func webView(_ v: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        Task { @MainActor in self.committed = true; self.loaded() }
    }

    /// Page view's pictures (HubKit PagePictures): the real page a screen at a time, each screen sent as it is shot;
    /// pictures not in yet striped, sent once they are; the next part when the watch reaches the end of this one.
    @ObservationIgnored private lazy var pics = PagePictures(side: Double(Self.side),
                                                             js: { [unowned self] in await self.js($0) }) { [unowned self] rect, w in
        await self.capture(rect, width: w)
    }

    /// How the page's pictures are taken: the first way that gave a picture that isn't blank (iOS may not draw a
    /// web view it thinks is out of sight: its snapshot comes back empty, black on the watch).
    enum Capture: Int, CaseIterable { case snapshot, front, hierarchy, visible }
    private var capturing: Capture?
    /// what the Browser page shows of it
    private(set) var captureNote = ""

    /// Part of the page view (`rect`, page points) as RGB `w` px wide.
    private func capture(_ rect: CGRect, width w: Int) async -> (rgb: [UInt8], height: Int)? {
        let h = max(1, Int((Double(w) * rect.height / rect.width).rounded()))
        for way in capturing.map({ [$0] }) ?? Capture.allCases {
            guard let rgb = await shot(rect, width: w, height: h, way) else { continue }
            // never a blank one, even after a way worked once (locked, asleep: iOS stops drawing the page)
            if !Self.blank(rgb) {
                if capturing == nil {
                    capturing = way
                    captureNote = "Pictures: \(way)"
                }
                return (rgb, h)
            }
        }
        captureNote = "Pictures: every way came back blank"
        // the next page tries every way again (the phone may be awake by then)
        capturing = nil
        return nil
    }

    private func shot(_ rect: CGRect, width w: Int, height h: Int, _ way: Capture) async -> [UInt8]? {
        let up = web.superview
        defer {
            // back behind the app, all but invisible
            if way != .snapshot, let up { up.sendSubviewToBack(web) }
            web.alpha = 0.011
        }
        switch way {
        case .snapshot: break
        case .front: up?.bringSubviewToFront(web)
        case .hierarchy:
            up?.bringSubviewToFront(web)
            let r = UIGraphicsImageRenderer(bounds: rect, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true; return f }())
            let img = r.image { _ in
                web.alpha = 1
                web.drawHierarchy(in: web.bounds, afterScreenUpdates: true)
            }
            return img.cgImage.map { Self.rgb($0, width: w, height: h) }
        case .visible:
            up?.bringSubviewToFront(web)
            web.alpha = 1
        }
        if way != .snapshot { try? await Task.sleep(for: .milliseconds(120)) }
        let c = WKSnapshotConfiguration()
        c.rect = rect
        c.snapshotWidth = NSNumber(value: Double(w) / Double(UIScreen.main.scale))
        guard let img = await snap(c), let cg = img.cgImage else { return nil }
        return Self.rgb(cg, width: w, height: h)
    }

    /// One colour all over (a sample of it): nothing drawn.
    static func blank(_ rgb: [UInt8]) -> Bool {
        guard rgb.count >= 3 else { return true }
        let (r, g, b) = (rgb[0], rgb[1], rgb[2])
        var i = 0
        while i + 2 < rgb.count {
            if abs(Int(rgb[i]) - Int(r)) > 6 || abs(Int(rgb[i + 1]) - Int(g)) > 6 || abs(Int(rgb[i + 2]) - Int(b)) > 6 {
                return false
            }
            i += 3 * 37
        }
        return true
    }

    /// Page view: the whole page laid out tall (12 screens at most), its images in, sent once (the watch shows its
    /// first screen as soon as it came, the rest while it is read). Google, YouTube, Wikipedia and Fandom are drawn on
    /// the watch from their layout (sharp text in the watch's font, their look); every other site, and the mode
    /// button's picture view, as a picture of the page. When iOS won't draw the page (the phone locked or asleep: a
    /// snapshot comes back blank) nothing black goes out: the page is drawn from its layout, its images fetched from
    /// their addresses; the known sites' logos are the watch app's own copies (nothing is kept on the phone).
    private func snapshot() async {
        picGen += 1
        let g = picGen
        guard pageView, made else { return }
        guard canDraw else { return await locked() }
        outbox = []
        pics.reset()
        // the watch to page view (after a search it shows the text view)
        await send([BrowserProto.toPage])
        let full = Double(await js(BrowserProto.pageHeight) ?? "") ?? Double(Self.side)
        let tall = min(max(full, Double(Self.side)), Double(Self.side) * 12)
        web.frame = CGRect(x: 0, y: 0, width: Self.side, height: tall)
        _ = await js("window.scrollTo(0, 0)")
        try? await Task.sleep(for: .milliseconds(150))
        _ = await js(PagePictures.openFolds)
        _ = await js(PagePictures.hideBanners)
        // its images in (lazy ones told to load: all of the tall page is in view), 1.5 s at most
        for _ in 0..<15 where (Int(await js(BrowserProto.imagesPending(tall)) ?? "0") ?? 0) > 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let url = web.url ?? current
        let known = BrowserProto.known(url)
        let side = Double(Self.side)
        let layout = await js(Layout.script(width: side, height: tall))
        let rows = (await js(BrowserProto.pageBoxes)).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[Double]] } ?? []
        if let t = await js("document.title"), let url, url.scheme?.hasPrefix("http") == true {
            remember(t.isEmpty ? (url.host ?? "Page") : t, url)
        }
        let w = Self.picture
        let got = await capture(CGRect(x: 0, y: 0, width: Self.side, height: tall), width: w)
        web.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        guard g == picGen else { return }
        let h = got?.height ?? max(1, Int((Double(w) * tall / side).rounded()))
        let rgb: [UInt8]
        var drawn = known && mode == 1
        if let got {
            rgb = got.rgb
        } else if let layout {
            captureNote = "Phone locked: drawn from the page's layout"
            rgb = await compose(layout, url: url, width: w, height: h)
            drawn = true
        } else {
            // the phone won't run the page now (locked): its text, fetched without the browser
            captureNote = "Phone locked: the page's text instead"
            mode = 0
            if let u = url ?? current { await open(u, push: false) }
            return
        }
        guard g == picGen else { return }
        let locked = got == nil
        // the site's logo: the watch's own copy (built into the app), sharp and never black
        let logo = drawn ? BrowserProto.logo(url) : nil
        let (msgs, came) = await Task.detached(priority: .userInitiated) {
            if drawn, let layout,
               let m = Layout.messages(json: layout, rgb: rgb, pw: w, ph: h, cssWidth: side, cssHeight: tall, always: locked, logo: logo) {
                return m
            }
            return Rle.longPicture(rgb: rgb, width: w, height: h, scale: 2)
        }.value
        guard g == picGen else { return }
        let k = 466 / Self.side
        let boxes = rows.compactMap { r -> (x: Int, y: Int, w: Int, h: Int, kind: UInt8)? in
            guard r.count == 5, Int(r[1] * k) < came else { return nil }
            return (Int(r[0] * k), Int(r[1] * k), Int(r[2] * k), Int(r[3] * k), UInt8(r[4]))
        }
        // a site the watch doesn't draw: its mode button goes picture → text
        await send(msgs + [BrowserProto.pageInfo(more: known ? 0 : 4)] + BrowserProto.boxes(boxes))
        if let u = web.url { await send([BrowserProto.label(u)]) }
        if await playing() {
            await drained()
            if g == picGen { await video(g) }
        }
    }

    /// The page's picture made here when iOS won't draw it: its own colour, then its images fetched from their
    /// addresses (4 s at most, in memory only: no cache on disk), `w` × `h` RGB.
    private func compose(_ json: String, url: URL?, width w: Int, height h: Int) async -> [UInt8] {
        let k = Double(w) / Double(Self.side)
        let (_, sources) = Layout.images(json: json)
        let wanted = Array(sources.filter { $0.w >= 8 && $0.h >= 8 && $0.y * k < Double(h) }.prefix(40))
        var fetched: [Int: CGImage] = [:]
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (i, s) in wanted.enumerated() {
                guard let u = URL(string: s.url) else { continue }
                group.addTask {
                    var req = URLRequest(url: u)
                    req.timeoutInterval = 4
                    req.setValue(BrowserService.agent, forHTTPHeaderField: "User-Agent")
                    guard let (d, _) = try? await BrowserService.fetcher.data(for: req) else { return (i, nil) }
                    return (i, UIImage(data: d)?.cgImage)
                }
            }
            for await (i, img) in group { if let img { fetched[i] = img } }
        }
        let (r, g, b) = Layout.background(json: json)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let out = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { ctx in
            UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            for (i, s) in wanted.enumerated() {
                guard let img = fetched[i] else { continue }
                let rect = CGRect(x: s.x * k, y: s.y * k, width: s.w * k, height: s.h * k)
                // filled as the page's object-fit: cover does (the most common for pictures)
                let iw = Double(img.width), ih = Double(img.height)
                let f = max(rect.width / max(iw, 1), rect.height / max(ih, 1))
                let dw = iw * f, dh = ih * f
                ctx.cgContext.saveGState()
                ctx.cgContext.clip(to: rect)
                UIImage(cgImage: img).draw(in: CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh))
                ctx.cgContext.restoreGState()
            }
        }
        guard let cg = out.cgImage else { return [UInt8](repeating: 255, count: w * h * 3) }
        return Self.rgb(cg, width: w, height: h)
    }

    /// The next part of the page (`dir` 1 down, -1 up).
    private func more(_ dir: Int) async {
        picGen += 1
        let g = picGen
        guard pageView, made else { return }
        guard canDraw else {
            pictureLater = true
            await send([BrowserProto.unchanged])
            await note("iPhone locked: unlock it for more of the page")
            return
        }
        outbox = []
        if !(await pics.more(dir) { [unowned self] m in if g == picGen { await send(m) } }) {
            await send([BrowserProto.unchanged])
            return
        }
        await shown(g)
    }

    /// A part sent: the bar's words, then the pictures that come in late (20 s at most).
    private func shown(_ g: Int) async {
        guard g == picGen else { return }
        if let u = web.url { await send([BrowserProto.label(u)]) }
        Task { [weak self] in
            for _ in 0..<14 {
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, g == self.picGen else { return }
                let (m, left) = await self.pics.late()
                guard g == self.picGen else { return }
                if !m.isEmpty { await self.send(m) }
                if left == 0 { return }
            }
        }
    }

    /// A tall picture as `width` × `height` RGB.
    static func rgb(_ cg: CGImage, width: Int, height: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var out = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            out[3 * i] = px[4 * i]
            out[3 * i + 1] = px[4 * i + 1]
            out[3 * i + 2] = px[4 * i + 2]
        }
        return out
    }

    private func shot(width: Int) async -> UIImage? {
        let c = WKSnapshotConfiguration()
        c.rect = web.bounds
        c.snapshotWidth = NSNumber(value: Double(width) / Double(UIScreen.main.scale))
        return await snap(c)
    }

    /// A snapshot, nil after 5 s: WebKit may never answer once the phone locks mid-way (its page process suspended).
    private func snap(_ c: WKSnapshotConfiguration) async -> UIImage? {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return await withCheckedContinuation { (k: CheckedContinuation<UIImage?, Never>) in
            web.takeSnapshot(with: c) { img, _ in
                guard !once.done else { return }
                once.done = true
                k.resume(returning: img)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard !once.done else { return }
                once.done = true
                k.resume(returning: nil)
            }
        }
    }

    private func playing() async -> Bool {
        // (one that plays by itself, muted, is the page's: a feed's preview, not the player's)
        let r = await js("[...document.querySelectorAll('video')].some(v => !v.paused && !v.ended && v.readyState > 2 && !v.muted)")
        return r == "1" || r == "true"
    }

    /// One video frame as a JPEG data URL, drawn from the video itself (a page's own video; nil when the browser
    /// won't give its pixels: then a picture of the page).
    private static let grab = """
    (() => { const v = [...document.querySelectorAll('video')].find(v => !v.paused && !v.ended && v.readyState > 2);
      if (!v || !v.videoWidth) return null;
      const c = document.createElement('canvas'), w = 155, h = Math.round(155 * v.videoHeight / v.videoWidth);
      c.width = w; c.height = Math.min(h, 155);
      try { c.getContext('2d').drawImage(v, 0, 0, c.width, c.height); return c.toDataURL('image/jpeg', 0.6); }
      catch (e) { return null; } })()
    """

    /// Frames for as long as the video plays and page view is open (the sound stays on the phone).
    private func video(_ g: Int) async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        await send([BrowserProto.video(true)])
        var n = 0
        var paused = false
        while g == picGen, pageView {
            // the watch's player: its title and place every few frames; while paused, only that
            if n % 6 == 0 {
                guard let s = await js(BrowserProto.videoState),
                      let a = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [Any], a.count >= 6,
                      (a[2] as? Int) != 1 else { break }
                paused = (a[1] as? Int) == 1
                if n == 0 { await send([BrowserProto.videoTitle(a[5] as? String ?? "")]) }
                await send([BrowserProto.progress(cur: a[3] as? Double ?? 0, dur: a[4] as? Double ?? 0, paused: paused)])
            }
            if paused {
                try? await Task.sleep(for: .milliseconds(400))
                n = 6
                continue
            }
            var img: UIImage?
            if let s = await js(Self.grab), s.hasPrefix("data:"), let comma = s.firstIndex(of: ","),
               let d = Data(base64Encoded: String(s[s.index(after: comma)...])) {
                img = UIImage(data: d)
            }
            if img == nil { img = await shot(width: Self.frame) }
            guard let img, g == picGen else { break }
            let side = Self.frame
            let rgb = Self.rgb(img, side: side)
            let msgs = await Task.detached(priority: .userInitiated) {
                Rle.picture(rgb: rgb, width: side, height: side, scale: 3)
            }.value
            guard g == picGen else { break }
            await send(msgs)
            // a frame at a time: the next is grabbed once this one is out (the watch shows the newest)
            await drained()
            n += 1
        }
        guard g == picGen else { return }
        await send([BrowserProto.video(false)])
        // stopped: the page as it is
        await snapshot()
    }

    /// A tap at page px (the watch has the whole page): a field brings the keyboard; the page changed (a link, a
    /// section opened, a video started): all of it again; else the watch takes the tap's outline off.
    private func tap(_ x: Int, _ y: Int) async {
        guard pageView, made else { return }
        guard canDraw else {
            await send([BrowserProto.unchanged])
            await note("iPhone locked: unlock it to use the page")
            return
        }
        let before = await js(BrowserProto.pageState)
        let r = await js(BrowserProto.tapScript(x: x, y: y + pics.tapTop, side: Double(Self.side)))
        if r == "2" {
            await send([BrowserProto.field])
            return
        }
        // what the tap does may start late (a script's navigation, an app's own routing): watched for 4 s
        var changed = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(200))
            if web.isLoading || !committed { await waitLoad(); changed = true; break }
            if await js(BrowserProto.pageState) != before {
                try? await Task.sleep(for: .milliseconds(600))
                await waitLoad()
                changed = true
                break
            }
            if await playing() { break }
        }
        if await playing() {
            // a video started: the watch's player
            picGen += 1
            await video(picGen)
            return
        }
        let after = await js(BrowserProto.pageState)
        if !changed || after == before {
            await send([BrowserProto.unchanged])
            return
        }
        // the same page changed (a menu, a section opened): from where the watch is
        if pics.active, let s = before?.split(separator: "|").first, web.url?.absoluteString == String(s) {
            picGen += 1
            let g = picGen
            await pics.section(from: pics.top) { [unowned self] m in if g == picGen { await send(m) } }
            await shown(g)
            return
        }
        await snapshot()
    }

    private func type(_ text: String) async {
        guard made else { return }
        guard canDraw else { return await note("iPhone locked: unlock it to type on the page") }
        let s = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast()
        let script = """
        (() => { const f = document.activeElement; if (!f) return;
          if (f.isContentEditable) f.textContent = \(s); else f.value = \(s);
          f.dispatchEvent(new Event('input', { bubbles: true })); f.dispatchEvent(new Event('change', { bubbles: true }));
          const k = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true };
          f.dispatchEvent(new KeyboardEvent('keydown', k)); f.dispatchEvent(new KeyboardEvent('keyup', k));
          if (f.form) { f.form.requestSubmit ? f.form.requestSubmit() : f.form.submit(); } })()
        """
        _ = await js(script)
        try? await Task.sleep(for: .milliseconds(900))
        await waitLoad()
        await snapshot()
    }

    /// An image as `side` × `side` RGB, fitted in the middle on black.
    static func rgb(_ img: UIImage, side: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = img.cgImage else { return [UInt8](repeating: 0, count: side * side * 3) }
        let w = Double(cg.width), h = Double(cg.height)
        let k = min(Double(side) / w, Double(side) / h)
        let (dw, dh) = (w * k, h * k)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: (Double(side) - dw) / 2, y: (Double(side) - dh) / 2, width: dw, height: dh))
        }
        var out = [UInt8](repeating: 0, count: side * side * 3)
        for i in 0..<(side * side) {
            out[3 * i] = px[4 * i]
            out[3 * i + 1] = px[4 * i + 1]
            out[3 * i + 2] = px[4 * i + 2]
        }
        return out
    }
}

/// The Browser page: sign in to sites here (the watch's page view shares the cookies), and the recent pages.
struct BrowserPage: View {
    @State private var b = Hub.shared.browser
    @State private var address = ""
    @State private var url: URL?
    var body: some View {
        PageScroll(title: "Browser") {
            if let w = b.watching ?? b.current {
                // what the watch is showing, as it changes; opened again here each time this page opens
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        if b.loading || b.sending { ProgressView().controlSize(.small) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.loading ? "Loading on the watch" : b.sending ? "Sending to the watch" : "On the watch")
                                .font(.headline)
                            Text(w.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if !b.captureNote.isEmpty {
                                Text(b.captureNote).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    LiveWebView(url: w)
                        .frame(height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .glassCard()
            }
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "globe", color: .blue, title: "Sign in for the watch",
                           detail: "Open a site and sign in here: the watch's page view stays signed in.")
                HStack {
                    TextField("Address", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onSubmit { url = BrowserProto.url(for: address) }
                    Button("Go") { url = BrowserProto.url(for: address) }.buttonStyle(.bordered)
                }
                if let url {
                    WebView(url: url)
                        .frame(height: 480)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .glassCard()
            if !b.recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent on the watch").font(.headline)
                    ForEach(Array(b.recent.enumerated()), id: \.offset) { _, r in
                        Button { url = r.url; address = r.url.absoluteString } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).lineLimit(1).foregroundStyle(TDColor.text)
                                Text(r.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .glassCard()
            }
        }
    }
}

/// The watch's page on the phone: loaded fresh when it appears, and again whenever the watch moves to another
/// page (the same cookies: what the watch shows).
private struct LiveWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        c.allowsInlineMediaPlayback = true
        let w = WKWebView(frame: .zero, configuration: c)
        w.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        context.coordinator.asked = url
        return w
    }

    /// (the address asked for, not the view's own: a redirect here doesn't load it again)
    final class Asked { var asked: URL? }
    func makeCoordinator() -> Asked { Asked() }

    func updateUIView(_ w: WKWebView, context: Context) {
        guard context.coordinator.asked != url else { return }
        context.coordinator.asked = url
        w.load(URLRequest(url: url))
    }
}

/// A plain browser in the page (WebKit's default store: the same cookies as the watch's page view).
private struct WebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        c.allowsInlineMediaPlayback = true
        let w = WKWebView(frame: .zero, configuration: c)
        w.allowsBackForwardNavigationGestures = true
        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        if w.url?.host != url.host || w.url?.path != url.path, !w.isLoading { w.load(URLRequest(url: url)) }
    }
}
