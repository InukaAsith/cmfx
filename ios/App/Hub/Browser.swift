import AVFoundation
import Foundation
import HubKit
import SwiftUI
import UIKit
import WebKit

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
    private var title = ""
    /// reader view's pages before this one (back)
    private var history: [URL] = []
    private var links: [URL] = []
    private var pageView = false
    private var gen = 0
    /// page view's last picture and the video frames: a newer ask drops an older one
    private var picGen = 0
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

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
            history = []
            Task { await open(BrowserProto.url(for: typed), push: true) }
        case .recent(let i):
            let r = recent
            guard r.indices.contains(i) else { return }
            history = []
            Task { await open(r[i].url, push: true) }
        case .link(let i):
            guard links.indices.contains(i) else { return }
            Task { await open(links[i], push: true) }
        case .back:
            Task { await back() }
        case .view(let page):
            pageView = page
            if page {
                Task { await showPage() }
            } else {
                stopMedia()
                // the page view may have gone somewhere else: its text
                let at = (made ? web.url : nil).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil } ?? current
                if let at { Task { await open(at, push: at != current) } }
            }
        case .tap(let x, let y):
            Task { await tap(x, y) }
        case .scroll:
            // the watch scrolls page view itself (it has the whole page): an older watch app's ask
            break
        case .type(let text):
            Task { await type(text) }
        case .leave:
            otherApp()
        case .toggle:
            Task { _ = await js(BrowserProto.toggleScript) }
        case .seek(let dt):
            Task { _ = await js(BrowserProto.seekScript(dt)) }
        }
    }

    /// Another watch app talks, or the Browser closed: the page's sound and pictures stop.
    func otherApp() {
        picGen += 1
        stopMedia()
        pageView = false
    }

    private func stopMedia() {
        picGen += 1
        guard made else { return }
        web.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(v => v.pause())", completionHandler: nil)
    }

    /// The browser exists (page view was used): nothing of it is made before.
    private var made = false

    /// A script's answer as text ("1" for true), nil for none (WebKit's async call traps on an empty answer).
    private func js(_ s: String) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            web.evaluateJavaScript(s) { r, _ in
                c.resume(returning: r.map { "\($0)" })
            }
        }
    }

    private func send(_ msgs: [Data]) async {
        do { try await Hub.shared.send(Self.app, msgs) } catch { status = error.localizedDescription }
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
        guard let (data, resp) = try? await URLSession.shared.data(for: req), g == gen else {
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
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
        let page = BrowserProto.results(rows, query: q)
        guard g == gen else { return }
        if page.blocks.isEmpty, let ddg = BrowserProto.fallback(for: url) {
            current = ddg
            await open(ddg, push: false)
            return
        }
        links = page.links
        title = page.title
        await send(Reader.messages(page))
    }

    private func back() async {
        if pageView, made, web.canGoBack {
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
    private func waitLoad() async {
        try? await Task.sleep(for: .milliseconds(150))
        guard web.isLoading || !committed else { return }
        // the new document, not the one before it
        for _ in 0..<100 where !committed {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for _ in 0..<60 where await js("document.readyState") == "loading" {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    nonisolated func webView(_ v: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
        Task { @MainActor in self.committed = false }
    }

    nonisolated func webView(_ v: WKWebView, didCommit n: WKNavigation!) {
        Task { @MainActor in self.committed = true }
    }

    private func loaded() {
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

    /// Page view's picture: the whole page (as much as the watch keeps, Rle.longPicture), laid out tall once, its
    /// folded sections opened, sent once; the watch scrolls it. Then, while a video plays, its frames.
    private func snapshot() async {
        picGen += 1
        let g = picGen
        guard pageView, made else { return }
        let full = Double(await js(BrowserProto.pageHeight) ?? "") ?? Double(Self.side)
        let tall = min(max(full, Double(Self.side)), Double(Self.side) * 12)
        web.frame = CGRect(x: 0, y: 0, width: Self.side, height: tall)
        _ = await js("window.scrollTo(0, 0)")
        try? await Task.sleep(for: .milliseconds(150))
        // its images in (lazy ones told to load: all of the tall page is in view), 1.5 s at most
        for _ in 0..<15 where (Int(await js(BrowserProto.imagesPending(tall)) ?? "0") ?? 0) > 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let layout = await js(Layout.script(width: Double(Self.side), height: tall))
        let rows = (await js(BrowserProto.pageBoxes)).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[Double]] } ?? []
        let img = await shot(width: Self.picture)
        web.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        guard g == picGen, let img, let cg = img.cgImage else { return }
        let w = Self.picture, h = max(1, Int(Double(w) * Double(cg.height) / Double(max(cg.width, 1))))
        let rgb = Self.rgb(cg, width: w, height: h)
        // drawn on the watch as it is laid out; a fancy page: its picture
        let side = Double(Self.side)
        let (msgs, came) = await Task.detached(priority: .userInitiated) {
            layout.flatMap { Layout.messages(json: $0, rgb: rgb, pw: w, ph: h, cssWidth: side, cssHeight: tall) }
                ?? Rle.longPicture(rgb: rgb, width: w, height: h, scale: 2)
        }.value
        guard g == picGen else { return }
        let k = 466 / Self.side
        let boxes = rows.compactMap { r -> (x: Int, y: Int, w: Int, h: Int, kind: UInt8)? in
            guard r.count == 5, Int(r[1] * k) < came else { return nil }
            return (Int(r[0] * k), Int(r[1] * k), Int(r[2] * k), Int(r[3] * k), UInt8(r[4]))
        }
        for m in msgs {
            guard g == picGen else { return }
            await send([m])
        }
        await send(BrowserProto.boxes(boxes))
        if await playing() { await video(g) }
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
        return try? await web.takeSnapshot(configuration: c)
    }

    private func playing() async -> Bool {
        let r = await js("[...document.querySelectorAll('video')].some(v => !v.paused && !v.ended && v.readyState > 2)")
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
                      let a = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [Any], a.count == 6,
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
        let before = await js(BrowserProto.pageState)
        let r = await js(BrowserProto.tapScript(x: x, y: y, side: Double(Self.side)))
        if r == "2" {
            await send([BrowserProto.field])
            return
        }
        try? await Task.sleep(for: .milliseconds(800))
        await waitLoad()
        if await js(BrowserProto.pageState) == before, !(await playing()) {
            await send([BrowserProto.unchanged])
            return
        }
        await snapshot()
    }

    private func type(_ text: String) async {
        guard made else { return }
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
