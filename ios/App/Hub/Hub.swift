import Foundation
import UIKit
import WireKit

// CMFX's phone side of the watch apps (cmf-watch-sdk sdk/examples): each app's messages go to its service here,
// by the app's name in the loader. RPCListener's link wakes the app (BLE notify) when a watch app talks, and a
// service only works while its app is open on the watch, or while the user does something here (Mail alone checks
// the inbox each minute, and only while Mail is open on the watch).

/// A watch app's phone half.
@MainActor protocol WatchService: AnyObject {
    /// The app's name in the loader ("Spotify").
    static var app: String { get }
    /// One message from the app. Return fast: long work goes in a Task.
    func receive(_ m: Data)
}

@MainActor @Observable final class Hub {
    static let shared = Hub()

    let spotify = SpotifyService()
    let gemini = GeminiService()
    let maps = MapsService()
    let nav = NavService()
    let photos = PhotosService()
    let mail = MailService()
    let notes = NotesService()
    let whatsapp = WhatsAppService()
    let youtube = YouTubeMusicService()
    let spotifyPlayer = SpotifyPlayerService()
    let recorder = RecorderService()
    let atlas = AtlasService()
    let browser = BrowserService()

    /// slot → app name, from the loader (RPCListener).
    private(set) var apps: [Int: String] = [:]
    private var session: KSession?
    /// The app last heard from, and when.
    private(set) var lastApp: String?
    private(set) var lastHeard: Date?

    var linked: Bool { session != nil }

    private var services: [String: WatchService] {
        [SpotifyService.app: spotify, GeminiService.app: gemini, MapsService.app: maps, NavService.app: nav,
         PhotosService.app: photos, MailService.app: mail, NotesService.app: notes, WhatsAppService.app: whatsapp,
         YouTubeMusicService.app: youtube, SpotifyPlayerService.app: spotifyPlayer, RecorderService.app: recorder,
         AtlasService.app: atlas, BrowserService.app: browser]
    }

    func attach(_ s: KSession?, apps: [Int: String]) {
        session = s
        self.apps = apps
    }

    func setApps(_ a: [Int: String]) { apps = a }

    /// Spotify Control was called Spotify before; the name is the on-watch player's now (SpotifyPlayerService).
    func slot(of app: String) -> Int? {
        apps.first { $0.value == app }?.key
    }
    func installed(_ app: String) -> Bool { slot(of: app) != nil }

    /// From RPCListener: a message that is not a service request.
    func receive(_ m: Data, slot: Int) {
        guard let name = apps[slot] else { return }
        // voice typing and recordings, from any app (`~`, HubKit VoiceProto)
        if m.first == UInt8(ascii: "~") {
            lastApp = name
            lastHeard = .now
            return Dictation.shared.receive(m, app: name)
        }
        guard let service = services[name] else { return }
        lastApp = name
        lastHeard = .now
        // YouTube Music's credit comes 10 times a second while it plays: straight through
        if name == YouTubeMusicService.app || name == SpotifyPlayerService.app || name == RecorderService.app, m.first == UInt8(ascii: "F") {
            return service.receive(m)
        }
        // the watch runs one app at a time: WhatsApp goes offline when another talks
        if name != WhatsAppService.app {
            whatsapp.otherApp()
            // awake for another watch app: a WhatsApp catch-up if it's on and due
            Task { await whatsapp.catchUp() }
        }
        // and music stops when its app is closed: YouTube Music, Spotify
        if name != YouTubeMusicService.app { youtube.otherApp() }
        if name != SpotifyPlayerService.app { spotifyPlayer.otherApp() }
        if name != RecorderService.app { recorder.otherApp() }
        if name != BrowserService.app { browser.otherApp() }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "hub")
        service.receive(m)
        Task { try? await Task.sleep(for: .seconds(8)); UIApplication.shared.endBackgroundTask(bg) }
    }

    /// Messages to `app`, in order; only while it is the app running (the stub refuses another slot's).
    func send(_ app: String, _ msgs: [Data]) async throws {
        guard let session else { throw HubError.noWatch }
        guard let slot = slot(of: app) else { throw HubError.notInstalled(app) }
        try await KLock.shared.run {
            for m in msgs { try await session.send(m, slot: UInt8(slot)) }
        }
    }

    func send(_ app: String, _ m: Data) async throws { try await send(app, [m]) }

    /// Several messages to `app` in flight at once (WireKit sendWindow): a status each, nil when lost.
    func sendWindow(_ app: String, _ msgs: [Data]) async throws -> [UInt8?] {
        guard let session else { throw HubError.noWatch }
        guard let slot = slot(of: app) else { throw HubError.notInstalled(app) }
        return try await KLock.shared.run { try await session.sendWindow(msgs, slot: UInt8(slot)) }
    }

    /// The sliding window (WireKit stream): 4 frames in flight, refilled as replies come; the ones refused or lost
    /// come back to be sent again.
    func stream(_ app: String, pull: @escaping @Sendable () async -> Data?) async throws -> [Data] {
        guard let session else { throw HubError.noWatch }
        guard let slot = slot(of: app) else { throw HubError.notInstalled(app) }
        return try await KLock.shared.run { try await session.stream(slot: UInt8(slot), pull: pull) }
    }

    /// A PING: the watch sends its apps' messages after a frame from the phone, so a stream waiting for credit
    /// asks with this.
    func ping() async throws {
        guard let session else { throw HubError.noWatch }
        _ = try await KLock.shared.run { try await session.ping() }
    }
}

enum HubError: LocalizedError {
    case noWatch, notInstalled(String), notSignedIn, failed(String)
    var errorDescription: String? {
        switch self {
        case .noWatch: "The watch is not connected."
        case .notInstalled(let a): "\(a) is not on the watch."
        case .notSignedIn: "Not signed in."
        case .failed(let s): s
        }
    }
}

/// Keys: one typed in the app (Keychain) wins; else the one built in (Info.plist from the build's secrets).
enum Secrets {
    private static func built(_ k: String) -> String {
        let v = (Bundle.main.object(forInfoDictionaryKey: k) as? String ?? "").trimmingCharacters(in: .whitespaces)
        return v.hasPrefix("$(") ? "" : v
    }
    static var spotifyBuilt: Bool { !built("CMFXSpotifyClientID").isEmpty }
    static var geminiBuilt: Bool { !built("CMFXGeminiKey").isEmpty }
    static var googleBuilt: Bool { !built("CMFXGoogleClientID").isEmpty }

    static var spotifyClient: String {
        get { (Keychain.get("spotify-client")).flatMap { $0.isEmpty ? nil : $0 } ?? built("CMFXSpotifyClientID") }
        set { Keychain.set("spotify-client", newValue.isEmpty ? nil : newValue) }
    }
    static var geminiKey: String {
        get { (Keychain.get("gemini-key")).flatMap { $0.isEmpty ? nil : $0 } ?? built("CMFXGeminiKey") }
        set { Keychain.set("gemini-key", newValue.isEmpty ? nil : newValue) }
    }
    /// A Google Cloud OAuth client of type iOS (Gmail).
    static var googleClient: String {
        get { (Keychain.get("google-client")).flatMap { $0.isEmpty ? nil : $0 } ?? built("CMFXGoogleClientID") }
        set { Keychain.set("google-client", newValue.isEmpty ? nil : newValue) }
    }
}

/// Pictures → RGB bytes for HubKit's encoders.
enum Pixels {
    /// `img` drawn into side × side (filled, centred), with `mask` (rounded square radius, or a circle when nil
    /// and `round`), black outside.
    static func rgb(_ img: UIImage, side: Int, corner: CGFloat = 0, round: Bool = false) -> [UInt8] {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let r = CGRect(x: 0, y: 0, width: side, height: side)
        let out = UIGraphicsImageRenderer(size: r.size, format: fmt).image { ctx in
            UIColor.black.setFill()
            ctx.fill(r)
            let clip = round ? UIBezierPath(ovalIn: r) : UIBezierPath(roundedRect: r, cornerRadius: corner)
            clip.addClip()
            let s = img.size
            let k = max(r.width / max(s.width, 1), r.height / max(s.height, 1))
            let w = s.width * k, h = s.height * k
            img.draw(in: CGRect(x: (r.width - w) / 2, y: (r.height - h) / 2, width: w, height: h))
        }
        return bytes(out.cgImage!, side: side)
    }

    /// A CGImage's RGB, side × side.
    static func bytes(_ cg: CGImage, side: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let ctx = CGContext(data: &rgba, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var rgb = [UInt8](repeating: 0, count: side * side * 3)
        for i in 0..<(side * side) {
            rgb[3 * i] = rgba[4 * i]; rgb[3 * i + 1] = rgba[4 * i + 1]; rgb[3 * i + 2] = rgba[4 * i + 2]
        }
        return rgb
    }
}
