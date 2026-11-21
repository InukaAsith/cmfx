import HubKit
import SwiftUI
import WebKit
import WireKit

// The watch's YouTube Music app (cmf-watch-sdk sdk/examples/ytmusic; hosts/ytmhost.py is the reference host): the
// watch searches and picks, this finds the song on YouTube Music, decodes it, shapes it for the watch's speaker
// and streams it under the watch's credit. Up next is the picked song's radio. Only sound goes over BLE.
// Signed in (the sign-in page below keeps youtube.com's cookies), YouTube plays also where it asks to "confirm
// you're not a bot" (a VPN); yt-dlp's solver (ytsolver/, run in JavaScriptCore) unlocks those streams.

@MainActor @Observable class YouTubeMusicService: WatchService {
    class var app: String { "YouTube Music" }
    private static let cookieKey = "youtube-cookies"

    var status: String?
    private(set) var signedIn = false
    /// what the watch plays, for the page
    private(set) var playing: String?

    private var results: [YTSong] = []
    private var queue: [YTSong] = []
    private var index = 0
    /// the queue index of the watch's Up next row 0
    private var upFrom = 0
    private var stream: YTStream?
    private var feeder: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var line: Task<Void, Never>?

    init() {
        if let lib = Bundle.main.url(forResource: "lib.min", withExtension: "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }),
           let core = Bundle.main.url(forResource: "core.min", withExtension: "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
            YTMusic.solver = YTSolver(lib: lib, core: core)
        }
        YTMusic.log = { s in Task { @MainActor in DevLog.shared.log("YouTube: \(s)") } }
        loadAccount()
    }

    // MARK: account

    private func loadAccount() {
        let saved = Keychain.get(Self.cookieKey).flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        let a = saved.map(YTAccount.init)
        YTMusic.account = a?.valid == true ? a : nil
        signedIn = YTMusic.account != nil
    }

    /// youtube.com's cookies from the sign-in page; true when they are a signed-in session.
    @discardableResult func save(cookies: [String: String]) -> Bool {
        guard YTAccount(cookies: cookies).valid else {
            status = "Not signed in yet: finish signing in to Google."
            return false
        }
        Keychain.set(Self.cookieKey, String(decoding: try! JSONEncoder().encode(cookies), as: UTF8.self))
        loadAccount()
        status = "Signed in."
        return true
    }

    /// A pasted `Cookie:` header (name=value; …), for when Google's page refuses the in-app browser.
    func save(header: String) {
        var c: [String: String] = [:]
        for part in header.replacingOccurrences(of: "Cookie:", with: "").split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, !kv[0].isEmpty { c[kv[0]] = kv[1] }
        }
        save(cookies: c)
    }

    func signOut() {
        Keychain.set(Self.cookieKey, nil)
        loadAccount()
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                             for: records.filter { $0.displayName.contains("youtube") || $0.displayName.contains("google") }) {}
        }
        status = nil
    }

    // MARK: watch

    func receive(_ m: Data) {
        guard let ask = YTMusicProto.parse(m) else { return }
        if case let .credit(next, room, gen, held) = ask {
            if stream?.gen == gen { stream?.setCredit(next: next, room: room, held: held) }
            return
        }
        // in order, one at a time (a pick while a search answers)
        let before = line
        line = Task {
            await before?.value
            await handle(ask)
        }
    }

    private var current: Int { stream?.playing(index) ?? index }

    private func handle(_ ask: YTMusicProto.Ask) async {
        do {
            switch ask {
            case .ready, .quit:
                stop()
            case .search(let q):
                results = try await find(q)
                try await rows(Character("S"), results.map { ($0.title, sub($0), false) })
            case .pick(let gen, let kind, let i):
                if kind == UInt8(ascii: "S"), i < results.count {
                    queue = [results[i]]
                    index = 0
                    start(gen)
                    radio(after: results[i])
                } else {
                    index = upFrom + i
                    start(gen)
                }
            case .next(let gen):
                index = current + 1
                start(gen)
            case .previous(let gen):
                index = max(current - 1, 0)
                start(gen)
            case .seek(let gen, let s):
                index = current
                start(gen, from: s)
            case .upNext:
                upFrom = current
                let shown = queue.indices.contains(upFrom) ? Array(queue[upFrom...]) : []
                try await rows(Character("Q"), shown.enumerated().map { ($0.element.title, sub($0.element), $0.offset == 0) })
            case .credit:
                break
            }
        } catch {
            DevLog.shared.log("YouTube: \(error.localizedDescription)")
            try? await Hub.shared.send(Self.app, YTMusicProto.note(error.localizedDescription))
        }
    }

    private func sub(_ s: YTSong) -> String {
        [s.artist, s.seconds > 0 ? YTMusicProto.mmss(s.seconds) : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func rows(_ kind: Character, _ r: [(String, String, Bool)]) async throws {
        try await Hub.shared.send(Self.app, YTMusicProto.list(kind: kind.asciiValue!, rows: r))
    }

    /// Songs for the watch's search (SpotifyPlayerService: Spotify's catalog).
    func find(_ q: String) async throws -> [YTSong] { try await YTMusic.search(q) }

    /// The song on YouTube (a result of `find` that is not one yet: SpotifyPlayerService).
    func resolve(_ song: YTSong) async throws -> YTSong { song }

    /// Up next: the song's radio after it.
    private func radio(after song: YTSong) {
        Task {
            guard let yt = try? await resolve(song), let r = try? await YTMusic.radio(yt.id),
                  queue.first == song else { return }
            queue = [song] + r.filter { $0.id != yt.id }
        }
    }

    private func stop() {
        feeder?.cancel()
        sender?.cancel()
        stream = nil
        playing = nil
    }

    /// A new stream for the watch's `gen`: the song at `index` from `from` s, then the rest of the queue.
    private func start(_ gen: UInt8, from: Int = 0) {
        stop()
        stream = YTStream(gen: gen)
        feeder = Task { await feed(gen, from: from) }
        sender = Task { await send(gen) }
    }

    private func feed(_ gen: UInt8, from: Int) async {
        var i = index, from = from
        var failed = 0
        while i < queue.count, failed < 3 {
            var song = queue[i]
            playing = song.title
            do {
                song = try await resolve(song)
                guard !Task.isCancelled, stream?.gen == gen else { return }
                var told = -100
                let samples = try await YTMusic.samples(song.id, from: from) { @MainActor [weak self] pct in
                    // the watch's yellow circle while it waits for the first song; every 4 % at most
                    guard let self, pct - told >= 4 || pct >= 100, self.stream?.gen == gen else { return }
                    told = pct
                    self.stream?.preparing(pct)
                }
                guard !Task.isCancelled, stream?.gen == gen else { return }
                let blocks = await Task.detached(priority: .userInitiated) { SpeakerProto.blocks(samples, pad: false) }.value
                guard !Task.isCancelled, stream?.gen == gen else { return }
                stream?.preparing(100)
                let secs = max(song.seconds, from + samples.count / SpeakerProto.rate)
                stream?.add(YTSong(id: song.id, title: song.title, artist: song.artist, seconds: secs), index: i,
                            from: from, blocks: blocks)
                failed = 0
            } catch {
                guard !Task.isCancelled else { return }
                failed += 1
                DevLog.shared.log("YouTube: \(song.title): \(error.localizedDescription)")
                status = "\(song.title): \(error.localizedDescription)"
                try? await Hub.shared.send(Self.app, YTMusicProto.note(error.localizedDescription))
            }
            from = 0
            i += 1
            // the next song is fetched while this one plays, when ~25 s of it are left to send
            while let s = stream, s.gen == gen, s.secondsLeft > 25 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
        }
        if stream?.gen == gen { stream?.end() }
    }

    /// The stream's messages as the watch's credit allows, 4 in flight all the time (a sliding window: a new one
    /// goes out as each reply comes, never waiting for a batch).
    private func send(_ gen: UInt8) async {
        while !Task.isCancelled, let s = stream, s.gen == gen, !s.done {
            do {
                let before = s.sent
                let again = try await Hub.shared.stream(Self.app) { @MainActor [weak self] in
                    guard let self, self.stream?.gen == gen else { return nil }
                    return self.stream?.take(1).first
                }
                if stream?.gen == gen { stream?.requeue(again) }
                if (stream?.sent ?? 0) <= before {
                    // waiting for credit or the next song: the watch's messages come after a frame from here
                    try? await Hub.shared.ping()
                    try? await Task.sleep(for: .milliseconds(30))
                }
            } catch WireError.noApp {
                return stop()
            } catch {
                DevLog.shared.log("YouTube stream: \(error.localizedDescription)")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

// MARK: page

struct YouTubeMusicPage: View {
    @State private var s = Hub.shared.youtube
    @State private var signingIn = false
    @State private var pasted = ""
    var body: some View {
        PageScroll(title: "YouTube Music") {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(symbol: "play.circle.fill", color: .red, title: s.signedIn ? "Signed in" : "Not signed in",
                           detail: s.signedIn ? "Songs play on the watch's speaker, also on a VPN"
                               : "Without signing in it works only where YouTube doesn't ask to confirm you're not a bot (not on a VPN)")
                if s.signedIn {
                    Button("Sign out", role: .destructive) { s.signOut() }.secondaryButton()
                } else {
                    Button("Sign in to YouTube") { signingIn = true }.primaryButton()
                }
                if let p = s.playing { Text("Now: \(p)").font(.footnote).foregroundStyle(.secondary) }
                if let t = s.status { Text(t).font(.footnote).foregroundStyle(.secondary) }
            }
            .glassCard()
            if !s.signedIn {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If Google refuses the sign-in page").font(.headline)
                    Text("Sign in at music.youtube.com in a browser, copy the request's Cookie header (developer tools › Network) and paste it here.")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("SAPISID=…; __Secure-3PAPISID=…; …", text: $pasted, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                    Button("Use these cookies") { s.save(header: pasted); pasted = "" }
                        .secondaryButton().disabled(pasted.isEmpty)
                }
                .glassCard()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("On the watch").font(.headline)
                Text("Search with the keyboard or the dial, tap a song: it plays on the watch, then its radio. Play and pause, previous and next, tap the ring to seek, the crown for the volume, Up next to jump ahead. The phone fetches each song and streams only its sound; keep CMFX running.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .glassCard()
        }
        .sheet(isPresented: $signingIn) {
            NavigationStack {
                YouTubeSignIn { cookies in
                    if s.save(cookies: cookies) { signingIn = false }
                }
                .navigationTitle("Sign in").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { signingIn = false } } }
            }
        }
    }
}

/// Google's sign-in for YouTube Music in a web view; youtube.com's cookies once it lands on YouTube.
struct YouTubeSignIn: UIViewRepresentable {
    let done: ([String: String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIView(context: Context) -> WKWebView {
        let v = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Google refuses sign-in in web views that name themselves; Safari's own agent
        v.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        v.navigationDelegate = context.coordinator
        v.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F")!))
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let done: ([String: String]) -> Void
        init(done: @escaping ([String: String]) -> Void) { self.done = done }

        func webView(_ v: WKWebView, didFinish navigation: WKNavigation!) {
            guard let host = v.url?.host, host.hasSuffix("youtube.com") else { return }
            v.configuration.websiteDataStore.httpCookieStore.getAllCookies { all in
                var c: [String: String] = [:]
                for k in all where k.domain.hasSuffix("youtube.com") { c[k.name] = k.value }
                Task { @MainActor in self.done(c) }
            }
        }
    }
}

// MARK: Spotify player

/// The watch's Spotify app (cmf-watch-sdk sdk/examples/spplayer: YouTube Music's app under Spotify's name). Spotify
/// withholds the audio of its streams from third-party players (librespot: "audio key error" for this account), so
/// the watch searches Spotify's catalog (Spotify Control's sign-in) and each song plays from YouTube: the YouTube
/// Music song with the same title and artist, the one closest in length.
@MainActor final class SpotifyPlayerService: YouTubeMusicService {
    override class var app: String { "Spotify" }

    override func find(_ q: String) async throws -> [YTSong] {
        try await Hub.shared.spotify.tracks(q)
    }

    override func resolve(_ song: YTSong) async throws -> YTSong {
        guard song.id.hasPrefix("spotify:") else { return song }
        let found = try await YTMusic.search("\(song.title) \(song.artist)")
        let near = found.prefix(5).min { abs($0.seconds - song.seconds) < abs($1.seconds - song.seconds) }
        guard let yt = (song.seconds > 0 ? near : nil) ?? found.first else { throw HubError.failed("Not on YouTube: \(song.title)") }
        return YTSong(id: yt.id, title: song.title, artist: song.artist, seconds: yt.seconds)
    }
}
