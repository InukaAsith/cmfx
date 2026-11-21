import AuthenticationServices
import CryptoKit
import Foundation
import HubKit
import UIKit

// The watch's Spotify app (cmf-watch-sdk sdk/examples/spotify, hosts/spotihost.py is the reference). Sign-in is
// PKCE with the user's own Spotify developer app (its client id typed in CMFX, redirect cmfx://spotify). Playback
// control needs Premium; without it the watch shows what plays and says "Premium needed" for the rest. Output
// devices are Spotify Connect's (iOS lets no app pick the system's audio route). Works only while the watch app
// asks: no timers, no polling.

@MainActor @Observable final class SpotifyService: NSObject, WatchService {
    static let app = "Spotify Control"
    static let redirect = "cmfx://spotify"
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing " +
        "user-library-read user-library-modify playlist-read-private playlist-read-collaborative " +
        "playlist-modify-private playlist-modify-public user-read-private user-read-recently-played"

    private(set) var user: String?
    private(set) var premium = false
    var status: String?

    private var token: String? { Keychain.get("spotify-access") }
    private var expires: Date {
        Date(timeIntervalSince1970: Double(Keychain.get("spotify-expires") ?? "0") ?? 0)
    }
    var signedIn: Bool { Keychain.get("spotify-refresh") != nil }

    // what the watch's list rows point at
    private var playlists: [[String: Any]] = []
    private var devices: [[String: Any]] = []
    private var view: [[String: Any]] = []
    private var context: String?
    /// What the watch's track list shows: songs to play, the queue (a tap skips ahead to it), or a playlist whose
    /// songs Spotify keeps from apps (one row: play it all).
    private enum Shown { case tracks, queue, whole }
    private var shown = Shown.tracks
    /// Library rows before the playlists: Up next, Liked Songs (0 in "add to")
    private var specials = 0
    private var track: [String: Any] = [:]
    private var playing = false
    private var lastArt: String?

    // MARK: watch

    /// The watch's asks, one at a time and in order: two at once (a double tap, a tap during a refresh) raced
    /// on the play state.
    private var line: Task<Void, Never>?

    func receive(_ m: Data) {
        guard let ask = SpotifyProto.parse(m) else { return }
        let before = line
        line = Task {
            await before?.value
            await handle(ask)
        }
    }

    private func handle(_ ask: SpotifyProto.Ask) async {
        do {
            guard signedIn else {
                try await Hub.shared.send(Self.app, [idle(), SpotifyProto.note("Sign in on the iPhone")])
                return
            }
            switch ask {
            case .ready: try await push(art: true)
            case .playPause:
                // what plays now, from Spotify (the watch's idea may be old): "play" while playing is refused
                // nothing active (an empty answer): paused, so the tap plays (the remembered state could say playing)
                let now = try? await call("GET", "/me/player") as? [String: Any]
                let isPlaying = now?["is_playing"] as? Bool ?? false
                var want = !isPlaying
                do {
                    try await call("PUT", isPlaying ? "/me/player/pause" : "/me/player/play")
                } catch SpotifyError.restricted {
                    want = isPlaying
                    try await call("PUT", isPlaying ? "/me/player/play" : "/me/player/pause")
                } catch SpotifyError.noDevice {
                    want = true
                    try await playOnADevice()
                }
                await settle(playing: want)
                try await push()
            case .next, .previous:
                do {
                    try await call("POST", ask == .next ? "/me/player/next" : "/me/player/previous")
                } catch SpotifyError.noDevice {
                    try await playOnADevice()
                }
                try await Task.sleep(for: .milliseconds(500))
                try await push()
            case .seek(let sec):
                try await call("PUT", "/me/player/seek", query: ["position_ms": "\(sec * 1000)"])
                try await push()
            case .volume(let v):
                // the iPhone's system volume (the hardware buttons' volume), not Spotify's: a phone's Spotify takes
                // no volume from apps, and this follows whatever plays
                SystemVolume.set(v)
            case .like:
                guard let id = track["id"] as? String else { return try await note("Nothing playing") }
                // Feb 2026: one library for everything, by URI
                let liked = (try await call("GET", "/me/library/contains", query: ["uris": "spotify:track:\(id)"]) as? [Bool]) == [true]
                try await call(liked ? "DELETE" : "PUT", "/me/library", query: ["uris": "spotify:track:\(id)"])
                try await note(liked ? "Removed from Liked" : "Liked")
                try await push()
            case .open(let kind): try await rows(kind)
            case .search(let q):
                context = nil
                let r = try await call("GET", "/search", query: ["q": q, "type": "track", "limit": "10"]) as? [String: Any]
                view = ((r?["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
                shown = .tracks
                try await send(list: "S", view.map { ($0.str("name"), artists($0), false) })
            case .pick(let kind, let i): try await pick(kind, i)
            }
        } catch SpotifyError.noDevice {
            try? await note("Open Spotify on a device")
        } catch SpotifyError.premium {
            status = "Spotify says this account needs Premium to control playback"
            try? await note("Premium needed")
        } catch {
            status = error.localizedDescription
            let m = error.localizedDescription.lowercased()
            try? await note(m.contains("not registered") || m.contains("user may not") ? "Add you in User Management"
                : m.contains("404") || m.contains("no active device") ? "Open Spotify on a device"
                : error is URLError ? "No connection to Spotify" : "Spotify error")
            // the watch changed its button at once: back to what really plays
            try? await push()
        }
    }

    private func rows(_ kind: Character) async throws {
        switch kind {
        case "P", "A":
            let me = try await call("GET", "/me") as? [String: Any] ?? [:]
            var items = ((try await call("GET", "/me/playlists", query: ["limit": "24"]) as? [String: Any])?["items"]
                as? [[String: Any]]) ?? []
            if kind == "A" {
                items = items.filter {
                    (($0["owner"] as? [String: Any])?["id"] as? String) == me.str("id") || ($0["collaborative"] as? Bool ?? false)
                }
            }
            playlists = items
            specials = kind == "P" ? 2 : 0
            let lead: [(String, String, Bool)] = kind == "P" ? [("Up next", "Your queue", false), ("Liked Songs", "Your saved songs", false)] : []
            try await send(list: kind, lead + items.map {
                let total = (($0["items"] ?? $0["tracks"]) as? [String: Any])?["total"] as? Int
                let owner = ($0["owner"] as? [String: Any])?["display_name"] as? String ?? ""
                return ($0.str("name"), total.map { "\($0) songs" } ?? (owner.isEmpty ? "Playlist" : "by \(owner)"), false)
            })
        case "D":
            devices = ((try await call("GET", "/me/player/devices") as? [String: Any])?["devices"] as? [[String: Any]]) ?? []
            try await send(list: "D", devices.map {
                ($0.str("name"), $0.str("type").capitalized, $0["is_active"] as? Bool ?? false)
            })
        default: break
        }
    }

    private func pick(_ kind: Character, _ i: Int) async throws {
        switch kind {
        case "P" where i == 0 && specials == 2:
            // Up next: what Spotify plays after this one
            let q = try await call("GET", "/me/player/queue") as? [String: Any] ?? [:]
            view = Array((q["queue"] as? [[String: Any]] ?? []).prefix(24))
            context = nil
            shown = .queue
            try await send(list: "T", view.map { ($0.str("name"), artists($0), false) })
        case "P" where i == 1 && specials == 2:
            let me = try await call("GET", "/me") as? [String: Any] ?? [:]
            let items = ((try await call("GET", "/me/tracks", query: ["limit": "24"]) as? [String: Any])?["items"]
                as? [[String: Any]]) ?? []
            view = items.compactMap { ($0["item"] ?? $0["track"]) as? [String: Any] }
            context = me.str("id").isEmpty ? nil : "spotify:user:\(me.str("id")):collection"
            shown = .tracks
            let now = track.str("id")
            try await send(list: "T", view.map { ($0.str("name"), artists($0), $0.str("id") == now) })
        case "P":
            let i = i - specials
            guard i >= 0, i < playlists.count else { return }
            context = playlists[i].str("uri")
            let id = playlists[i].str("id")
            // Feb 2026: only the user's own playlists show their songs to an app; another's is played whole
            let items: [[String: Any]]
            do {
                items = ((try await call("GET", "/playlists/\(id)/items", query: ["limit": "24"]) as? [String: Any])?["items"]
                    as? [[String: Any]]) ?? []
            } catch {
                // not the user's: Spotify shows apps its name only; one row plays it all
                view = []
                shown = .whole
                let owner = (playlists[i]["owner"] as? [String: Any])?["display_name"] as? String ?? ""
                return try await send(list: "T", [("Play all", owner.isEmpty ? "Songs hidden by Spotify" : "by \(owner)", false)])
            }
            shown = .tracks
            view = items.compactMap { ($0["item"] ?? $0["track"]) as? [String: Any] }
            let now = track.str("id")
            try await send(list: "T", view.map { ($0.str("name"), artists($0), $0.str("id") == now) })
        case "T" where shown == .whole:
            guard let ctx = context else { return }
            do { try await call("PUT", "/me/player/play", body: ["context_uri": ctx]) }
            catch SpotifyError.noDevice { try await playOnADevice(["context_uri": ctx]) }
            try await Task.sleep(for: .milliseconds(500))
            try await push()
        case "T" where shown == .queue:
            // the API cannot jump in the queue: skip forward to it
            guard i < view.count else { return }
            for _ in 0...i {
                try await call("POST", "/me/player/next")
                try await Task.sleep(for: .milliseconds(250))
            }
            try await Task.sleep(for: .milliseconds(400))
            try await push()
        case "T", "S":
            guard i < view.count else { return }
            let uri = view[i].str("uri")
            let body: [String: Any] = context.map { ["context_uri": $0, "offset": ["uri": uri]] } ?? ["uris": [uri]]
            do {
                try await call("PUT", "/me/player/play", body: body)
            } catch SpotifyError.noDevice {
                try await playOnADevice(body)
            }
            await settle(playing: true)
            try await push()
        case "D":
            guard i < devices.count else { return }
            try await call("PUT", "/me/player", body: ["device_ids": [devices[i].str("id")], "play": true])
            try await Task.sleep(for: .milliseconds(800))
            try await push()
        case "A":
            guard i < playlists.count else { return }
            guard let uri = track["uri"] as? String else { return try await note("Nothing playing") }
            try await call("POST", "/playlists/\(playlists[i].str("id"))/items", body: ["uris": [uri]])
            try await note("Added to \(playlists[i].str("name"))")
        default: break
        }
    }

    /// Now playing, and the art when the track changed.
    private func push(art: Bool = false) async throws {
        let me = try await call("GET", "/me") as? [String: Any] ?? [:]
        premium = Self.premium(me)
        user = me["display_name"] as? String
        let p = try await call("GET", "/me/player") as? [String: Any] ?? [:]
        track = p["item"] as? [String: Any] ?? [:]
        playing = p["is_playing"] as? Bool ?? false
        if track.isEmpty {
            // nothing active (Spotify answers empty after a while paused): the last song played, paused, so the
            // watch shows it at once and play picks it up again
            let r = try? await call("GET", "/me/player/recently-played", query: ["limit": "1"]) as? [String: Any]
            track = ((r?["items"] as? [[String: Any]])?.first?["track"] as? [String: Any]) ?? [:]
            playing = false
        }
        var flags: UInt8 = (playing ? SpotifyProto.playing : 0) | (premium ? SpotifyProto.premium : 0)
        if p["shuffle_state"] as? Bool ?? false { flags |= SpotifyProto.shuffle }
        if track.isEmpty { flags |= SpotifyProto.idle }
        if let id = track["id"] as? String,
           (try? await call("GET", "/me/library/contains", query: ["uris": "spotify:track:\(id)"]) as? [Bool]) == [true] {
            flags |= SpotifyProto.liked
        }
        let dev = p["device"] as? [String: Any] ?? [:]
        let now = SpotifyProto.now(flags: flags, pos: (p["progress_ms"] as? Int ?? 0) / 1000,
                                   dur: (track["duration_ms"] as? Int ?? 0) / 1000, vol: SystemVolume.percent,
                                   title: track.str("name"), artist: artists(track), device: dev.str("name"))
        try await Hub.shared.send(Self.app, now)
        let imgs = (track["album"] as? [String: Any])?["images"] as? [[String: Any]] ?? []
        let url = (imgs.count > 1 ? imgs[imgs.count - 2] : imgs.first)?.str("url")
        if let url, art || url != lastArt {
            lastArt = url
            if let u = URL(string: url), let (d, _) = try? await URLSession.shared.data(from: u), let img = UIImage(data: d) {
                let side = SpotifyProto.artSize
                let rgb = Pixels.rgb(img, side: side, corner: 18)
                try await Hub.shared.send(Self.app, Rle.picture(rgb: rgb, width: side, height: side))
            }
        }
    }

    /// Spotify's player state trails a command by up to about a second: read until it shows the change (2 s at
    /// most), so the watch is not sent the old state and its button does not flip back.
    private func settle(playing want: Bool) async {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(250))
            if let p = try? await call("GET", "/me/player") as? [String: Any], (p["is_playing"] as? Bool) == want { return }
        }
    }

    private func idle() -> Data {
        SpotifyProto.now(flags: SpotifyProto.idle, pos: 0, dur: 0, vol: 0, title: "", artist: "", device: "")
    }

    private func note(_ s: String) async throws { try await Hub.shared.send(Self.app, SpotifyProto.note(s)) }

    private func send(list kind: Character, _ rows: [(String, String, Bool)]) async throws {
        try await Hub.shared.send(Self.app, SpotifyProto.list(kind: kind, rows: rows.map { (title: $0.0, sub: $0.1, active: $0.2) }))
    }

    private func artists(_ t: [String: Any]) -> String {
        ((t["artists"] as? [[String: Any]]) ?? []).map { $0.str("name") }.joined(separator: ", ")
    }

    // MARK: Web API

    @discardableResult
    private func call(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> Any? {
        let token = try await fresh()
        var c = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method == "PUT" || method == "POST" {
            req.httpBody = Data()
        }
        let (data, resp) = try await Self.send(req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404, String(decoding: data, as: UTF8.self).contains("NO_ACTIVE_DEVICE") { throw SpotifyError.noDevice }
        if code == 403 {
            // 403 is not only Premium: an account missing from the developer app's User Management, or a
            // development-mode app whose owner has no Premium, answer it too; Spotify's own words say which
            let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let reason = err?["reason"] as? String ?? "", message = err?["message"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self)
            DevLog.shared.log("spotify 403 \(method) \(path): \(reason) \(message)")
            if reason == "PREMIUM_REQUIRED" { premium = false; throw SpotifyError.premium }
            let low = message.lowercased()
            if low.contains("restriction violated") || low.contains("cannot control device volume") { throw SpotifyError.restricted }
            throw HubError.failed("Spotify: \(message.isEmpty ? "access refused (403)" : message)")
        }
        if code == 401 { Keychain.set("spotify-expires", "0") }
        guard (200..<300).contains(code) else { throw HubError.failed("Spotify \(code)") }
        // a command's answer may be empty, or not JSON at all (next, previous): fine, it worked
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? [:]
    }

    /// Nothing is playing anywhere: start on a device (this iPhone's Spotify first, else the first one listed).
    private func playOnADevice(_ body: [String: Any]? = nil) async throws {
        let list = ((try await call("GET", "/me/player/devices") as? [String: Any])?["devices"] as? [[String: Any]]) ?? []
        guard let d = list.first(where: { $0.str("type") == "Smartphone" }) ?? list.first else {
            try await note("Open Spotify on a device")
            return
        }
        try await call("PUT", "/me/player/play", query: ["device_id": d.str("id")], body: body)
    }

    /// The access token, refreshed when it is near its end.
    private func fresh() async throws -> String {
        if let token, expires.timeIntervalSinceNow > 60 { return token }
        guard let refresh = Keychain.get("spotify-refresh") else { throw HubError.notSignedIn }
        try await tokens(["grant_type": "refresh_token", "refresh_token": refresh])
        guard let token else { throw HubError.notSignedIn }
        return token
    }

    private func tokens(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var f = form
        f["client_id"] = Secrets.spotifyClient
        req.httpBody = f.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], let access = j["access_token"] as? String
        else { throw HubError.failed("Spotify sign-in failed") }
        Keychain.set("spotify-access", access)
        Keychain.set("spotify-expires", "\(Date.now.timeIntervalSince1970 + Double(j["expires_in"] as? Int ?? 3600))")
        if let r = j["refresh_token"] as? String { Keychain.set("spotify-refresh", r) }
    }

    // MARK: sign-in (PKCE)

    private var authSession: ASWebAuthenticationSession?

    func signIn() async {
        status = nil
        guard !Secrets.spotifyClient.isEmpty else { status = "Enter your Spotify app's client ID first."; return }
        let verifier = Data((0..<48).map { _ in UInt8.random(in: 0...255) }).base64url
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64url
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: Secrets.spotifyClient), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
        ]
        do {
            let url: URL = try await withCheckedThrowingContinuation { k in
                let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "cmfx") { url, err in
                    if let url { k.resume(returning: url) } else { k.resume(throwing: err ?? HubError.notSignedIn) }
                }
                s.presentationContextProvider = self
                authSession = s
                s.start()
            }
            guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "code" })?.value else { throw HubError.notSignedIn }
            try await tokens(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                              "code_verifier": verifier])
            let me = try await call("GET", "/me") as? [String: Any] ?? [:]
            user = me["display_name"] as? String
            premium = Self.premium(me)
        } catch {
            status = error.localizedDescription
        }
    }

    func signOut() {
        for k in ["spotify-access", "spotify-refresh", "spotify-expires"] { Keychain.set(k, nil) }
        user = nil
        premium = false
    }
}

extension SpotifyService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

extension SpotifyService {
    /// Some networks drop a TLS connection now and then (seen on the owner's Wi-Fi with Spotify and OSRM): tried
    /// again twice. A command that may have reached Spotify (the answer was lost) is only tried again when it is
    /// safe to repeat (GET, PUT, DELETE); next/previous (POST) only when the connection never opened.
    nonisolated static func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do { return try await URLSession.shared.data(for: req) }
            catch let e as URLError {
                let never: Set<URLError.Code> = [.secureConnectionFailed, .cannotConnectToHost, .cannotFindHost,
                                                 .dnsLookupFailed]
                let maybe: Set<URLError.Code> = [.networkConnectionLost, .timedOut]
                let again = never.contains(e.code) || (maybe.contains(e.code) && req.httpMethod != "POST")
                attempt += 1
                guard again, attempt <= 2 else { throw e }
                try await Task.sleep(for: .milliseconds(300 * attempt))
            }
        }
    }

    /// Feb 2026: Spotify stops sending `product` to development-mode apps. No word: taken as Premium (a Free
    /// account is told so by its first refused command, PREMIUM_REQUIRED).
    static func premium(_ me: [String: Any]) -> Bool {
        guard let p = me["product"] as? String else { return true }
        return p != "free" && p != "open"
    }
}

enum SpotifyError: Error { case premium, restricted, noDevice }

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String { self[k] as? String ?? "" }
}

extension Data {
    var base64url: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: the Spotify player's search (SpotifyPlayerService)

extension SpotifyService {
    /// Songs from Spotify's catalog for the watch's search, as YTSongs with the Spotify URI as id (resolved to
    /// YouTube when one plays).
    func tracks(_ q: String) async throws -> [YTSong] {
        let r = try await call("GET", "/search", query: ["q": q, "type": "track", "limit": "12"]) as? [String: Any]
        let items = ((r?["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return items.map { t in
            YTSong(id: t.str("uri"), title: t.str("name"), artist: artists(t), seconds: (t["duration_ms"] as? Int ?? 0) / 1000)
        }
    }
}
