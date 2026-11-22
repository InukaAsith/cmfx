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
        case .scroll(let dy):
            Task {
                guard self.made else { return }
                _ = await js("window.scrollBy(0, \(Double(dy) * Self.side / 466))")
                await snapshot()
            }
        case .type(let text):
            Task { await type(text) }
        case .leave:
            otherApp()
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
        if pageView {
            await showPage()
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
        if p.blocks.isEmpty { p.blocks = [.init(kind: Reader.para, link: nil, text: "No text here: try page view.")] }
        remember(title, final)
        await send(Reader.messages(p))
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

    private func showPage() async {
        host()
        guard let url = current else { return }
        if web.url != url {
            await note("Loading the page\u{2026}")
            web.load(URLRequest(url: url))
            await waitLoad()
        }
        await snapshot()
    }

    private func waitLoad() async {
        guard web.isLoading else { return }
        await withCheckedContinuation { c in
            loadWaiters.append(c)
            // a page that never says it is done still gets its picture
            Task { try? await Task.sleep(for: .seconds(12)); self.loaded() }
        }
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
        Task { @MainActor in self.loaded() }
    }

    /// Page view's picture: the page as it is now, 8 bands of 16 colours; then, while a video plays, its frames.
    private func snapshot() async {
        picGen += 1
        let g = picGen
        guard pageView, let img = await shot(width: Self.picture) else { return }
        let side = Self.picture
        let rgb = Self.rgb(img, side: side)
        let msgs = await Task.detached(priority: .userInitiated) {
            Rle.bandedPicture(rgb: rgb, width: side, height: side, scale: 2)
        }.value
        guard g == picGen else { return }
        for m in msgs {
            guard g == picGen else { return }
            await send([m])
        }
        if await playing() { await video(g) }
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
        while g == picGen, pageView {
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
            if n % 8 == 0, !(await playing()) { break }
        }
        guard g == picGen else { return }
        await send([BrowserProto.video(false)])
        // stopped: the page as it is
        await snapshot()
    }

    private func tap(_ x: Int, _ y: Int) async {
        guard pageView, made else { return }
        let k = Self.side / 466
        let px = Double(x) * k, py = Double(y) * k
        let script = """
        (() => { const e = document.elementFromPoint(\(px), \(py)); if (!e) return 0;
          const f = e.closest('input,textarea,[contenteditable="true"]');
          if (f && !['button','submit','checkbox','radio','image','reset'].includes((f.type||'').toLowerCase())) { f.focus(); return 2; }
          const o = { bubbles: true, cancelable: true, clientX: \(px), clientY: \(py), view: window };
          e.dispatchEvent(new PointerEvent('pointerdown', o)); e.dispatchEvent(new MouseEvent('mousedown', o));
          e.dispatchEvent(new PointerEvent('pointerup', o)); e.dispatchEvent(new MouseEvent('mouseup', o));
          e.click(); return 1; })()
        """
        let r = await js(script)
        if r == "2" {
            await send([BrowserProto.field])
            return
        }
        // a link may be loading: its picture once it has, else the page as the tap left it
        try? await Task.sleep(for: .milliseconds(700))
        await waitLoad()
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
