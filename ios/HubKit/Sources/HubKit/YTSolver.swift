import CryptoKit
import Foundation
import JavaScriptCore

// Signed-in YouTube (with the cookies of the sign-in page in CMFX): the clients that take an account give stream
// URLs locked by YouTube's player JavaScript (the `s` signature and the `n` parameter). yt-dlp's solver
// (yt-dlp-ejs: lib.min.js + core.min.js, Unlicense / MIT / ISC, bundled in the app) finds those functions in the
// player and runs them, here in JavaScriptCore, the way yt-dlp runs it in deno or node.

/// The signed-in session: youtube.com's cookies.
public struct YTAccount: Sendable {
    public let cookies: [String: String]
    public init(cookies: [String: String]) { self.cookies = cookies }

    public var header: String { cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ") }

    /// Signed in: one of the SAPISID cookies is there.
    public var valid: Bool { sapisid != nil }

    var sapisid: String? { cookies["SAPISID"] ?? cookies["__Secure-3PAPISID"] }

    /// `SAPISIDHASH ts_sha1(ts sid origin)` and the 1P / 3P ones, as YouTube's web player signs its requests.
    public func authorization(origin: String = "https://www.youtube.com", now: Date = .now) -> String? {
        let ts = String(Int(now.timeIntervalSince1970.rounded()))
        var out: [String] = []
        for (scheme, sid) in [("SAPISIDHASH", sapisid), ("SAPISID1PHASH", cookies["__Secure-1PAPISID"]),
                              ("SAPISID3PHASH", cookies["__Secure-3PAPISID"])] {
            guard let sid else { continue }
            let hash = Insecure.SHA1.hash(data: Data("\(ts) \(sid) \(origin)".utf8)).map { String(format: "%02x", $0) }.joined()
            out.append("\(scheme) \(ts)_\(hash)")
        }
        return out.isEmpty ? nil : out.joined(separator: " ")
    }
}

/// yt-dlp-ejs in JavaScriptCore. One player at a time (its preprocessed form is kept for the next songs).
public final class YTSolver: @unchecked Sendable {
    private let lib: String
    private let core: String
    private var player: (id: String, sts: Int, preprocessed: String)?
    private let lock = NSLock()

    public init(lib: String, core: String) {
        self.lib = lib
        self.core = core
    }

    /// The current player's id (from the embed API, as yt-dlp finds it) and its signature timestamp.
    public func load() async throws -> (id: String, sts: Int) {
        var r = URLRequest(url: URL(string: "https://www.youtube.com/iframe_api")!)
        r.timeoutInterval = 20
        let api = String(decoding: try await URLSession.shared.data(for: r).0, as: UTF8.self)
        guard let m = api.firstMatch(of: /player\\?\/([0-9a-fA-F]{8})\\?\//) else { throw YTError.decode("no player id") }
        let id = String(m.1)
        if let p = lock.withLock({ player }), p.id == id { return (p.id, p.sts) }
        let js = String(decoding: try await URLSession.shared.data(
            from: URL(string: "https://www.youtube.com/s/player/\(id)/player_ias.vflset/en_US/base.js")!).0, as: UTF8.self)
        guard let s = js.firstMatch(of: /(?:signatureTimestamp|sts)\s*:\s*(\d{5})/), let sts = Int(s.1) else {
            throw YTError.decode("no signature timestamp")
        }
        let out = try run(["type": "player", "player": js, "output_preprocessed": true, "requests": [] as [Any]])
        guard let pre = out["preprocessed_player"] as? String else { throw YTError.decode("player not solved") }
        lock.withLock { player = (id, sts, pre) }
        return (id, sts)
    }

    /// Answers to the `n` and `sig` challenges of one song's URLs, with the loaded player.
    public func solve(n: [String], sig: [String]) throws -> (n: [String: String], sig: [String: String]) {
        guard let pre = lock.withLock({ player?.preprocessed }) else { throw YTError.decode("no player") }
        var reqs: [[String: Any]] = []
        if !n.isEmpty { reqs.append(["type": "n", "challenges": n]) }
        if !sig.isEmpty { reqs.append(["type": "sig", "challenges": sig]) }
        let out = try run(["type": "preprocessed", "preprocessed_player": pre, "requests": reqs])
        var got: (n: [String: String], sig: [String: String]) = ([:], [:])
        for (req, resp) in zip(reqs, out["responses"] as? [[String: Any]] ?? []) {
            guard resp["type"] as? String == "result", let data = resp["data"] as? [String: String] else {
                throw YTError.decode(resp["error"] as? String ?? "challenge")
            }
            if req["type"] as? String == "n" { got.n = data } else { got.sig = data }
        }
        return got
    }

    func run(_ input: [String: Any]) throws -> [String: Any] {
        guard let ctx = JSContext() else { throw YTError.decode("no JavaScript") }
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        ctx.evaluateScript(lib)
        ctx.evaluateScript("Object.assign(globalThis, lib);")
        ctx.evaluateScript(core)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let r = ctx.evaluateScript("JSON.stringify(jsc(\(json)))")
        if let thrown { throw YTError.decode(thrown) }
        guard let s = r?.toString(), let out = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
            throw YTError.decode("no answer")
        }
        if out["type"] as? String == "error" { throw YTError.decode(out["error"] as? String ?? "solver") }
        return out
    }
}
