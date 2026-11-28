import AVFoundation
import Foundation

// The watch's YouTube Music app (cmf-watch-sdk sdk/examples/ytmusic; hosts/ytmhost.py is the reference host):
// search, a song's radio for up next, its audio stream, decoded and shaped for the watch's speaker (Speaker.swift).
// YouTube's own web API (InnerTube), as its apps use it; no account. Audio is fetched into memory for the song
// that plays and dropped after (a temporary file only while the decoder reads it).
//
// The client names and versions below are what YouTube's apps send; YouTube retires old ones now and then (the
// same upkeep yt-dlp has): when search or playback stops working, these are the first thing to update.

public struct YTSong: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let artist: String
    public let seconds: Int
    public init(id: String, title: String, artist: String, seconds: Int) {
        self.id = id; self.title = title; self.artist = artist; self.seconds = seconds
    }
}

public enum YTError: LocalizedError {
    case http(Int), unplayable(String), noAudio, decode(String)
    public var errorDescription: String? {
        switch self {
        case .http(let c): "YouTube answered \(c)"
        case .unplayable(let r): r
        case .noAudio: "No audio stream"
        case .decode(let s): "Decode: \(s)"
        }
    }
}

public enum YTMusic {
    // music.youtube.com's web client: search and radio
    nonisolated(unsafe) static let webRemix: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": "1.20250310.01.00", "hl": "en"]
    static let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
    /// A client asked for a song's streams (yt-dlp's INNERTUBE_CLIENTS, its 2026.10.26 release).
    struct Player {
        let client: [String: Any]
        let id: String
        /// its URLs are locked by the player JavaScript (YTSolver)
        let js: Bool
        /// takes the account's cookies
        let signedIn: Bool
        var ua: String { client["userAgent"] as! String }
    }

    nonisolated(unsafe) static let tvSamsung: [String: Any] = [
        "clientName": "TVHTML5", "clientVersion": "5.20260707", "deviceMake": "Samsung", "deviceModel": "UKS9800",
        "userAgent": "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
        "osName": "Tizen", "osVersion": "2.4.0", "hl": "en"]
    nonisolated(unsafe) static let webEmbedded: [String: Any] = [
        "clientName": "WEB_EMBEDDED_PLAYER", "clientVersion": "2.20260708.00.00", "hl": "en",
        "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)"]
    nonisolated(unsafe) static let visionOS: [String: Any] = [
        "clientName": "VISIONOS", "clientVersion": "1.02", "deviceMake": "Apple", "deviceModel": "RealityDevice17,1",
        "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        "osName": "visionOS", "osVersion": "26.5.23O471", "hl": "en"]

    nonisolated(unsafe) static let androidVR: [String: Any] = [
        "clientName": "ANDROID_VR", "clientVersion": "1.65.10", "deviceMake": "Oculus", "deviceModel": "Quest 3",
        "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L", "hl": "en",
        "userAgent": "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"]

    /// Tried in turn, also when one answers but its stream is refused (the TV's URLs get 403 since late 2026:
    /// "OK" from the player isn't a song that plays). First the ones with plain URLs (visionOS, the Android VR
    /// app), then, signed in, the TV and the embedded web player with the cookies (yt-dlp's authed defaults: what
    /// still plays on a VPN, where the plain ones get "confirm you're not a bot"), then the TV without.
    nonisolated(unsafe) static let players: [Player] = [
        Player(client: visionOS, id: "101", js: false, signedIn: false),
        Player(client: androidVR, id: "28", js: false, signedIn: false),
        Player(client: tvSamsung, id: "7", js: true, signedIn: true),
        Player(client: webEmbedded, id: "56", js: true, signedIn: true),
        Player(client: tvSamsung, id: "7", js: true, signedIn: false),
    ]

    /// The YouTube account signed in on the phone (its cookies), and the player JavaScript's solver.
    nonisolated(unsafe) public static var account: YTAccount?
    nonisolated(unsafe) public static var solver: YTSolver?

    /// music.youtube.com's "Songs" filter
    static let songsOnly = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"

    /// YouTube's visitor id from its first answer, sent with the requests after it (a browser keeps it too).
    nonisolated(unsafe) static var visitor: String?

    static func post(_ url: String, _ body: [String: Any], ua: String, clientId: String, version: String,
                     origin: String? = nil, headers: [String: String] = [:], anonymous: Bool = true) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        var body = body
        // the visitor id is a signed-out session's: sent with the account's cookies, YouTube may answer as that
        // visitor (its home's mixes, not the account's)
        if anonymous, let v = visitor, var ctx = body["context"] as? [String: Any], var c = ctx["client"] as? [String: Any] {
            c["visitorData"] = v
            ctx["client"] = c
            body["context"] = ctx
            r.setValue(v, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        r.setValue(clientId, forHTTPHeaderField: "X-YouTube-Client-Name")
        r.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let origin { r.setValue(origin, forHTTPHeaderField: "Origin"); r.setValue(origin + "/", forHTTPHeaderField: "Referer") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw YTError.http(code) }
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if anonymous, visitor == nil, let v = (j["responseContext"] as? [String: Any])?["visitorData"] as? String { visitor = v }
        return j
    }

    /// `signedIn`: with the account's cookies when there is one (the home's mixes are the account's then).
    static func music(_ endpoint: String, _ body: [String: Any], signedIn: Bool = false) async throws -> [String: Any] {
        var b = body
        b["context"] = ["client": webRemix]
        var headers: [String: String] = [:]
        let asAccount = signedIn && account?.valid == true
        if asAccount, let a = account {
            headers["Cookie"] = a.header
            headers["Authorization"] = a.authorization(origin: "https://music.youtube.com")
            headers["X-Origin"] = "https://music.youtube.com"
            headers["X-Goog-AuthUser"] = "0"
        }
        return try await post("https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false", b, ua: webUA,
                              clientId: "67", version: webRemix["clientVersion"] as! String,
                              origin: "https://music.youtube.com", headers: headers, anonymous: !asAccount)
    }

    /// Whether YouTube took a request as the account's (`logged_in` in its tracking params); nil: it doesn't say.
    public static func loggedIn(_ j: [String: Any]) -> Bool? {
        var found: Bool?
        walk(j["responseContext"] ?? [:]) { d in
            if found == nil, d["key"] as? String == "logged_in", let v = d["value"] as? String { found = v == "1" }
        }
        return found
    }

    /// The account's listening history on YouTube Music (newest first), nil when not signed in or not taken as
    /// the account.
    public static func history() async throws -> [YTSong]? {
        guard account?.valid == true else { return nil }
        let j = try await music("browse", ["browseId": "FEmusic_history"], signedIn: true)
        guard loggedIn(j) != false else { return nil }
        let s = songs(inSearch: j)
        return s.isEmpty ? nil : Array(s.prefix(24))
    }

    /// Tells YouTube the account played song `id`, as its web player does when a song starts (the player's
    /// `videostatsPlaybackUrl` with `ver=2` and a fresh `cpn`, yt-dlp's --mark-watched): the song is then in the
    /// account's history, on YouTube Music too. The streams come from other players, which tell YouTube nothing.
    /// false when not signed in or YouTube refused.
    @discardableResult public static func markPlayed(_ id: String) async -> Bool {
        guard let a = account, a.valid else { return false }
        guard let j = try? await music("player", ["videoId": id, "contentCheckOk": true, "racyCheckOk": true], signedIn: true),
              let track = j["playbackTracking"] as? [String: Any],
              let base = (track["videostatsPlaybackUrl"] as? [String: Any])?["baseUrl"] as? String,
              var c = URLComponents(string: base) else {
            log("history: no playback URL for \(id)")
            return false
        }
        let abc = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cpn = String((0..<16).map { _ in abc.randomElement()! })
        var items = (c.queryItems ?? []).filter { $0.name != "ver" && $0.name != "cpn" }
        items += [URLQueryItem(name: "ver", value: "2"), URLQueryItem(name: "cpn", value: cpn)]
        c.queryItems = items
        guard let url = c.url else { return false }
        var r = URLRequest(url: url)
        r.timeoutInterval = 15
        r.setValue(webUA, forHTTPHeaderField: "User-Agent")
        r.setValue(a.header, forHTTPHeaderField: "Cookie")
        r.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        let code = ((try? await URLSession.shared.data(for: r))?.1 as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) { log("history: YouTube answered \(code) for \(id)") }
        return (200..<300).contains(code)
    }

    // MARK: mixes

    /// The mixes on YouTube Music's home (the account's when signed in: My Supermix, Discover Mix …), then its other
    /// playlists: (playlist id, name, what it is), 24 at most.
    public static func mixes() async throws -> [(id: String, name: String, sub: String)] {
        let j = try await music("browse", ["browseId": "FEmusic_home"], signedIn: true)
        if account?.valid == true, loggedIn(j) == false {
            log("home: signed in, but YouTube answered as signed out (the cookies may have expired)")
        }
        return lists(inHome: j)
    }

    static func lists(inHome j: Any) -> [(id: String, name: String, sub: String)] {
        var out: [(id: String, name: String, sub: String)] = []
        walk(j) { d in
            guard let r = d["musicTwoRowItemRenderer"] as? [String: Any] else { return }
            var id: String?
            walk(r["navigationEndpoint"] ?? [:]) { e in
                if id == nil, let w = e["watchPlaylistEndpoint"] as? [String: Any] ?? e["watchEndpoint"] as? [String: Any] {
                    id = w["playlistId"] as? String
                }
                if id == nil, let b = e["browseEndpoint"] as? [String: Any], let v = b["browseId"] as? String, v.hasPrefix("VL") {
                    id = String(v.dropFirst(2))
                }
            }
            if id == nil { walk(r) { if id == nil, let w = $0["watchPlaylistEndpoint"] as? [String: Any] { id = w["playlistId"] as? String } } }
            let name = text(r["title"])
            guard let id, !name.isEmpty else { return }
            out.append((id, name, text(r["subtitle"])))
        }
        var seen = Set<String>()
        let all = out.filter { seen.insert($0.id).inserted }
        let mix = all.filter { $0.name.localizedCaseInsensitiveContains("mix") || $0.id.hasPrefix("RDTMAK") }
        return Array((mix + all.filter { a in !mix.contains { $0.id == a.id } }).prefix(24))
    }

    /// A playlist's or mix's songs, in order (YouTube Music's queue for it).
    public static func playlist(_ id: String) async throws -> [YTSong] {
        let j = try await music("next", ["playlistId": id, "isAudioOnly": true], signedIn: true)
        return songs(inQueue: j)
    }

    // MARK: search and radio

    public static func search(_ query: String) async throws -> [YTSong] {
        let j = try await music("search", ["query": query, "params": songsOnly.removingPercentEncoding!])
        return songs(inSearch: j)
    }

    /// The songs of a search answer (musicResponsiveListItemRenderer rows), in order.
    public static func songs(inSearch j: Any) -> [YTSong] {
        var out: [YTSong] = []
        walk(j) { d in
            guard let r = d["musicResponsiveListItemRenderer"] as? [String: Any] else { return }
            let cols = (r["flexColumns"] as? [[String: Any]] ?? []).map { col -> [String] in
                let runs = ((col["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"]
                    as? [String: Any])?["runs"] as? [[String: Any]] ?? []
                return runs.compactMap { $0["text"] as? String }
            }
            var id = ((r["playlistItemData"] as? [String: Any])?["videoId"] as? String)
            if id == nil { walk(r) { if id == nil, let w = $0["watchEndpoint"] as? [String: Any] { id = w["videoId"] as? String } } }
            guard let id, let title = cols.first?.joined(), !title.isEmpty else { return }
            // second column: "Song", " • ", artist(s), " • ", album, " • ", "3:12" (the kind only in mixed results)
            let parts = (cols.count > 1 ? cols[1] : []).filter { $0 != " • " && $0 != " & " && $0 != ", " }
            let secs = parts.last.flatMap(seconds) ?? 0
            var names = parts.filter { seconds($0) == nil && $0 != "Song" && $0 != "Video" }
            if names.count > 1 { names.removeLast() } // the album
            out.append(YTSong(id: id, title: title, artist: names.joined(separator: ", "), seconds: secs))
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    /// The song's radio (YouTube Music's up next): the song first, then what it plays after.
    public static func radio(_ id: String) async throws -> [YTSong] {
        let j = try await music("next", ["videoId": id, "playlistId": "RDAMVM" + id, "isAudioOnly": true])
        return songs(inQueue: j)
    }

    public static func songs(inQueue j: Any) -> [YTSong] {
        var out: [YTSong] = []
        walk(j) { d in
            guard let r = d["playlistPanelVideoRenderer"] as? [String: Any], let id = r["videoId"] as? String else { return }
            let title = text(r["title"]), by = text(r["shortBylineText"])
            out.append(YTSong(id: id, title: title, artist: by, seconds: seconds(text(r["lengthText"])) ?? 0))
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    // MARK: audio

    /// An audio stream's URL: AAC in MP4 (itag 140) when there is one, which AVFoundation decodes.
    /// The song's AAC stream URL and its size in bytes.
    /// `skipping`: players (their index) whose stream was refused already; the answer says which one it is.
    public static func audioURL(_ id: String, skipping: Set<Int> = []) async throws -> (URL, Int, player: Int) {
        var why = "No player answered"
        let account = self.account?.valid == true ? self.account : nil
        for (k, p) in players.enumerated() where (!p.signedIn || account != nil) && !skipping.contains(k) {
            var body: [String: Any] = ["context": ["client": p.client], "videoId": id, "contentCheckOk": true,
                                       "racyCheckOk": true]
            var headers: [String: String] = [:]
            var sts: Int?
            if p.js {
                guard let solver else { continue }
                do { sts = try await solver.load().sts } catch {
                    why = "Player script: \(error.localizedDescription)"
                    continue
                }
                body["playbackContext"] = ["contentPlaybackContext": ["signatureTimestamp": sts!]]
            }
            if p.signedIn, let account {
                headers["Cookie"] = account.header
                headers["Authorization"] = account.authorization()
                headers["X-Origin"] = "https://www.youtube.com"
                headers["X-Youtube-Bootstrap-Logged-In"] = "true"
            }
            let j: [String: Any]
            do {
                j = try await post("https://www.youtube.com/youtubei/v1/player?prettyPrint=false", body, ua: p.ua,
                                   clientId: p.id, version: p.client["clientVersion"] as! String,
                                   origin: "https://www.youtube.com", headers: headers)
            } catch {
                why = error.localizedDescription
                continue
            }
            let play = j["playabilityStatus"] as? [String: Any]
            guard play?["status"] as? String == "OK" else {
                why = play?["reason"] as? String ?? "Not playable"
                log("player \(p.client["clientName"] ?? "?")\(p.signedIn ? " signed in" : ""): \(why)")
                continue
            }
            let secs = Int((j["videoDetails"] as? [String: Any])?["lengthSeconds"] as? String ?? "") ?? 0
            let formats = ((j["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]] ?? [])
                .filter { ($0["mimeType"] as? String ?? "").hasPrefix("audio/mp4") }
            guard let f = formats.first(where: { $0["itag"] as? Int == 140 })
                ?? formats.max(by: { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }) else {
                why = "No AAC audio"
                continue
            }
            do {
                // the byte size (for the download's progress); else ~16 KB a second of AAC
                return (try unlock(f), Int(f["contentLength"] as? String ?? "") ?? secs * 16_000, k)
            } catch {
                why = error.localizedDescription
                log("unlock \(p.client["clientName"] ?? "?"): \(why)")
            }
        }
        throw YTError.unplayable(why)
    }

    /// A format's URL: plain, or its `s` signature and `n` answered by the solver.
    static func unlock(_ f: [String: Any]) throws -> URL {
        var urlString: String
        var sig: (param: String, challenge: String)?
        if let u = f["url"] as? String {
            urlString = u
        } else if let c = f["signatureCipher"] as? String {
            var q: [String: String] = [:]
            for item in URLComponents(string: "?" + c)?.queryItems ?? [] { q[item.name] = item.value }
            guard let u = q["url"], let s = q["s"] else { throw YTError.decode("cipher") }
            urlString = u
            sig = (q["sp"] ?? "signature", s)
        } else {
            throw YTError.noAudio
        }
        guard var c = URLComponents(string: urlString) else { throw YTError.noAudio }
        let n = c.queryItems?.first { $0.name == "n" }?.value
        if sig != nil || n != nil {
            guard let solver else { throw YTError.decode("no solver") }
            let got = try solver.solve(n: n.map { [$0] } ?? [], sig: sig.map { [$0.challenge] } ?? [])
            var items = c.queryItems ?? []
            if let n, let nn = got.n[n] { items = items.map { $0.name == "n" ? URLQueryItem(name: "n", value: nn) : $0 } }
            if let sig, let ss = got.sig[sig.challenge] { items.append(URLQueryItem(name: sig.param, value: ss)) }
            c.queryItems = items
        }
        guard let url = c.url else { throw YTError.noAudio }
        return url
    }

    /// The stream's bytes, in 1 MiB ranges (one big request is throttled to playback speed).
    public static func fetch(_ url: URL, size: Int = 0, progress: @Sendable (Double) async -> Void = { _ in }) async throws -> Data {
        var data = Data()
        let chunk = 1 << 20
        while true {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.queryItems = (c.queryItems ?? []).filter { $0.name != "range" } +
                [URLQueryItem(name: "range", value: "\(data.count)-\(data.count + chunk - 1)")]
            var r = URLRequest(url: c.url!)
            r.timeoutInterval = 20
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 || code == 206 else { throw YTError.http(code) }
            data += d
            if size > 0 { await progress(min(1, Double(data.count) / Double(size))) }
            if d.count < chunk { return data }
        }
    }

    /// An audio file's sound from `from` seconds as mono i16 at `rate` (AVFoundation decodes and resamples).
    public static func decode(_ file: URL, from: Double = 0, rate: Int = SpeakerProto.rate) async throws -> [Int16] {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw YTError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        if from > 0 { reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 1000), duration: .positiveInfinity) }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        reader.add(out)
        guard reader.startReading() else { throw YTError.decode(reader.error?.localizedDescription ?? "start") }
        var pcm: [Int16] = []
        while let buf = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
            let n = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: n / 2)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
            pcm += chunk
        }
        if reader.status == .failed { throw YTError.decode(reader.error?.localizedDescription ?? "failed") }
        return pcm
    }

    /// A song from YouTube as the watch's tuned 10.67 kHz samples, from `from` seconds. The audio is held only for
    /// this: the temporary file goes as soon as it is decoded.
    /// `progress`: how far, 0...100 (the download most of it).
    public static func samples(_ id: String, from: Int = 0, level: Bool = false, smooth: Bool = true,
                               progress: @Sendable (Int) async -> Void = { _ in }) async throws -> [Int16] {
        await progress(3)
        // a player whose stream is refused (403): the next one
        var refused: Set<Int> = []
        var data = Data()
        while true {
            let (url, size, k) = try await audioURL(id, skipping: refused)
            await progress(8)
            do {
                data = try await fetch(url, size: size) { f in await progress(8 + Int(f * 72)) }
                break
            } catch YTError.http(let code) where code == 403 || code == 410 {
                log("stream of \(players[k].client["clientName"] ?? "?")\(players[k].signedIn ? " signed in" : ""): \(code)")
                refused.insert(k)
            }
        }
        await progress(82)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let pcm = try await decode(file, from: Double(from))
        await progress(88)
        return await Task.detached(priority: .userInitiated) { SpeakerTune.forSpeaker(pcm, rate: SpeakerProto.rate, level: level, smooth: smooth) }.value
    }

    /// Where the extractor's notes go (DevLog in the app).
    nonisolated(unsafe) public static var log: (String) -> Void = { _ in }

    // MARK: JSON

    static func walk(_ v: Any, _ f: ([String: Any]) -> Void) {
        if let d = v as? [String: Any] {
            f(d)
            for x in d.values { walk(x, f) }
        } else if let a = v as? [Any] {
            for x in a { walk(x, f) }
        }
    }

    static func text(_ v: Any?) -> String {
        let d = v as? [String: Any]
        if let s = d?["simpleText"] as? String { return s }
        return (d?["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }

    /// "3:12" / "1:02:03" → seconds
    static func seconds(_ s: String) -> Int? {
        let p = s.split(separator: ":")
        guard (2...3).contains(p.count), p.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return p.reduce(0) { $0 * 60 + Int($1)! }
    }
}

/// The watch's messages of YouTube Music (sdk/examples/ytmusic/src/model.rs).
public enum YTMusicProto {
    public enum Ask: Equatable {
        case ready, quit
        case search(String)
        case pick(gen: UInt8, kind: UInt8, index: Int)
        case next(gen: UInt8), previous(gen: UInt8)
        case seek(gen: UInt8, seconds: Int)
        case upNext
        /// the songs played before (`o H`), newest first
        case history
        /// the account's playlists (`o P`: the Spotify player)
        case library
        case credit(next: Int, room: Int, gen: UInt8, held: Int)
    }

    public static func parse(_ m: Data) -> Ask? {
        let b = [UInt8](m)
        switch (b.first, b.count) {
        case (UInt8(ascii: "R"), 1): return .ready
        case (UInt8(ascii: "q"), 1): return .quit
        case (UInt8(ascii: "s"), 2...): return .search(String(decoding: b[1...], as: UTF8.self))
        case (UInt8(ascii: "p"), 4): return .pick(gen: b[1], kind: b[2], index: Int(b[3]))
        case (UInt8(ascii: "n"), 2): return .next(gen: b[1])
        case (UInt8(ascii: "b"), 2): return .previous(gen: b[1])
        case (UInt8(ascii: "j"), 4): return .seek(gen: b[1], seconds: Int(b[2]) | Int(b[3]) << 8)
        case (UInt8(ascii: "o"), 2) where b[1] == UInt8(ascii: "Q"): return .upNext
        case (UInt8(ascii: "o"), 2) where b[1] == UInt8(ascii: "H"): return .history
        case (UInt8(ascii: "o"), 2) where b[1] == UInt8(ascii: "P"): return .library
        case (UInt8(ascii: "F"), 5): return .credit(next: Int(b[1]) | Int(b[2]) << 8, room: Int(b[3]), gen: b[4], held: 0)
        // with what the watch holds and has not played (its ~7 s buffer): the song at next - held is the one heard
        case (UInt8(ascii: "F"), 7): return .credit(next: Int(b[1]) | Int(b[2]) << 8, room: Int(b[3]), gen: b[4],
                                                    held: Int(b[5]) | Int(b[6]) << 8)
        default: return nil
        }
    }

    static func field(_ s: String, _ n: Int) -> Data {
        var b = Array(s.utf8.prefix(n))
        while !b.isEmpty, String(bytes: b, encoding: .utf8) == nil { b.removeLast() }
        return Data([UInt8(b.count)] + b)
    }

    public static func prep(gen: UInt8, _ pct: Int) -> Data { Data([UInt8(ascii: "r"), gen, UInt8(max(0, min(100, pct)))]) }
    public static func open(gen: UInt8) -> Data { Data([UInt8(ascii: "o"), SpeakerProto.outKhz, 1, gen]) }

    public static func song(_ s: YTSong, from: Int) -> Data {
        var m = Data([UInt8(ascii: "N"), UInt8(from & 0xFF), UInt8(from >> 8 & 0xFF),
                      UInt8(min(s.seconds, 0xFFFF) & 0xFF), UInt8(min(s.seconds, 0xFFFF) >> 8)])
        m += field(s.title, 48) + Data(s.artist.utf8.prefix(40))
        return m.prefix(128)
    }

    public static let end = Data("z".utf8)

    public static func list(kind: UInt8, rows: [(String, String, Bool)]) -> [Data] {
        var out = [Data([UInt8(ascii: "L"), kind, UInt8(min(rows.count, 24))])]
        for (i, r) in rows.prefix(24).enumerated() {
            out.append((Data([UInt8(ascii: "l"), UInt8(i), r.2 ? 1 : 0]) + field(r.0, 40) + Data(r.1.utf8)).prefix(128))
        }
        return out
    }

    public static func note(_ s: String) -> Data { (Data("X".utf8) + Data(s.utf8)).prefix(60) }

    public static func mmss(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}

/// One stream to the watch (a pick, a skip, a seek): its messages in order, numbered blocks, and how far the
/// watch's credit lets it go. The songs after the first are added while it plays.
public struct YTStream {
    public let gen: UInt8
    public private(set) var out: [Data] = []
    public private(set) var sent = 0
    var seq = 0
    /// each message's block number (full, not 16 bits), -1 for the others
    var blockSeq: [Int] = [-1, -1]
    /// (first block's seq, queue index) of each song in it
    var starts: [(Int, Int)] = []
    public var credit = (next: 0, room: 8)
    /// blocks the watch holds and has not played
    public var held = 0
    public private(set) var ended = false

    /// messages the watch refused or that got no reply: sent again first
    var retry: [Data] = []

    /// `excite`: the watch's shimmer above 5.5 kHz (the treble the link can't carry), 0...128.
    public init(gen: UInt8, excite: UInt8 = SpeakerProto.shimmer) {
        self.gen = gen
        out = [YTMusicProto.open(gen: gen), SpeakerProto.excite(excite)]
    }

    /// A song's tuned samples, after what is there.
    public mutating func add(_ song: YTSong, index: Int, from: Int, samples: [Int16]) {
        add(song, index: index, from: from, blocks: SpeakerProto.blocks(samples, pad: false))
    }

    /// A song already encoded (SpeakerProto.blocks, off the main actor: the trellis takes a moment).
    public mutating func add(_ song: YTSong, index: Int, from: Int, blocks: [Data]) {
        out.append(YTMusicProto.song(song, from: from))
        blockSeq.append(-1)
        starts.append((seq, index))
        for m in blocks {
            out.append(Data([UInt8(ascii: "a"), UInt8(seq & 0xFF), UInt8(seq >> 8 & 0xFF)]) + m.dropFirst(3))
            blockSeq.append(seq)
            seq += 1
        }
    }

    /// How far the first song's preparing got (`r gen pct`: the watch's yellow circle); nothing once a song is in.
    public mutating func preparing(_ pct: Int) {
        guard starts.isEmpty else { return }
        out.append(YTMusicProto.prep(gen: gen, pct))
        blockSeq.append(-1)
    }

    public mutating func end() {
        out.append(YTMusicProto.end)
        blockSeq.append(-1)
        ended = true
    }

    /// Blocks queued but not sent yet, in seconds: the next song is fetched when this gets low.
    public var secondsLeft: Double {
        Double(out[sent...].count) * Double(SpeakerProto.samplesPerBlock) / Double(SpeakerProto.rate)
    }

    /// The watch's `F next room` (next is 16 bits: unwrapped near the last one, so a long stream keeps counting).
    public mutating func setCredit(next: Int, room: Int, held: Int = 0) {
        self.held = held
        let base = credit.next & ~0xFFFF
        var n = base | next
        if n < credit.next - 0x8000 { n += 0x10000 } else if n > credit.next + 0x8000, n >= 0x10000 { n -= 0x10000 }
        credit = (n, room)
    }

    /// The song the watch plays: the last whose first block it has heard.
    public func playing(_ fallback: Int) -> Int {
        let heard = credit.next - held
        return starts.last { $0.0 <= heard }?.1 ?? starts.first?.1 ?? fallback
    }

    /// Up to `n` messages the credit allows.
    public mutating func take(_ n: Int) -> [Data] {
        var batch: [Data] = []
        while batch.count < n, !retry.isEmpty { batch.append(retry.removeFirst()) }
        let limit = credit.next + credit.room
        while batch.count < n, sent < out.count {
            let m = out[sent]
            if m.first == UInt8(ascii: "a"), blockSeq[sent] >= limit { break }
            batch.append(m)
            sent += 1
        }
        return batch
    }

    /// Messages to be sent again (refused or lost): first in line, in the order they went.
    /// (They may land after later blocks: the watch holds those until the gap is filled.)
    public mutating func requeue(_ msgs: [Data]) {
        retry += msgs
    }

    public var done: Bool { ended && sent == out.count && retry.isEmpty }
}
