import AuthenticationServices
import Foundation
import Observation
import UIKit

// FMC login: PocketBase `users` at fmc.tools, as fmc_frontend modules/auth/model/auth.api.ts.
// Email and password, plus the OAuth2 providers the server has on (Google, Apple).
// Sign-up stays on the site, but OAuth2 creates an account on first use, so the app offers
// account deletion (App Store 5.1.1(v)).

struct User: Decodable, Equatable {
    var id: String
    var email: String
    var name: String
    var avatar: String?

    var avatarURL: URL? {
        avatar.flatMap { $0.isEmpty ? nil : URL(string: "https://fmc.tools/api/files/users/\(id)/\($0)?thumb=100x100") }
    }
}

struct OAuthProvider: Decodable, Identifiable {
    var name: String
    var displayName: String
    var authURL: String
    var codeVerifier: String
    var id: String { name }

    /// The provider's page with PocketBase's redirect and our realtime client as `state`,
    /// as the JS SDK's authWithOAuth2 does.
    func url(state: String) -> URL? {
        guard var c = URLComponents(string: authURL) else { return nil }
        var items = (c.queryItems ?? []).filter { $0.name != "state" && $0.name != "redirect_uri" }
        items += [URLQueryItem(name: "state", value: state),
                  URLQueryItem(name: "redirect_uri", value: Account.redirect.absoluteString)]
        c.queryItems = items
        return c.url
    }
}

@MainActor @Observable final class Account {
    nonisolated static let base = URL(string: "https://fmc.tools")!
    static let signUp = URL(string: "https://fmc.tools/register")!
    nonisolated static let redirect = URL(string: "https://fmc.tools/api/oauth2-redirect")!

    private(set) var user: User?
    private(set) var providers: [OAuthProvider] = []
    private var token: String? {
        didSet { Keychain.set("token", token) }
    }

    init() {
        token = Keychain.get("token")
    }

    /// Checks the stored token and renews it; a rejected one signs out.
    func restore() async {
        guard token != nil else { return }
        do {
            try await auth("auth-refresh", body: nil)
        } catch AccountError.server(let status, _) where status == 401 || status == 403 || status == 404 {
            signOut()
        } catch {
            // offline: keep the token, try again on the next launch
        }
    }

    /// OAuth2 providers on the server. App Store 4.8: no third-party login without Sign in with Apple,
    /// so release builds hide them all until `apple` is on.
    func loadProviders() async {
        struct Methods: Decodable { struct O: Decodable { var providers: [OAuthProvider] }; var oauth2: O }
        guard let (data, _) = try? await URLSession.shared.data(from: api("auth-methods")),
              let all = try? JSONDecoder().decode(Methods.self, from: data).oauth2.providers else { return }
        #if DEBUG
        providers = all
        #else
        providers = all.contains { $0.name == "apple" } ? all : []
        #endif
    }

    func signIn(email: String, password: String) async throws {
        try await auth("auth-with-password", body: ["identity": email, "password": password])
    }

    /// PocketBase's own OAuth2 flow, as the JS SDK: the provider redirects to fmc.tools, which hands
    /// the code to our realtime connection; no URL scheme or provider client of our own.
    /// Throws CancellationError when the user closes the sheet.
    func signIn(with provider: OAuthProvider) async throws {
        var sse = URLRequest(url: Self.base.appending(path: "api/realtime"))
        sse.timeoutInterval = 600
        let (bytes, _) = try await URLSession.shared.bytes(for: sse)
        let stream = bytes.task
        var web: ASWebAuthenticationSession?
        defer { web?.cancel(); stream.cancel() }
        var event = "", clientId = ""
        do {
            for try await line in bytes.lines {
                if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
                guard line.hasPrefix("data:") else { continue }
                let data = Data(line.dropFirst(5).utf8)
                switch event {
                case "PB_CONNECT":
                    struct Connect: Decodable { var clientId: String }
                    clientId = try JSONDecoder().decode(Connect.self, from: data).clientId
                    try await subscribe(clientId)
                    guard let url = provider.url(state: clientId) else { throw AccountError.server(0, String(localized: "Bad provider URL")) }
                    let s = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, error in
                        if error != nil { stream.cancel() } // closed by the user
                    }
                    s.presentationContextProvider = WindowAnchor.shared
                    web = s
                    s.start()
                case "@oauth2":
                    struct Reply: Decodable { var state: String; var code: String?; var error: String? }
                    let r = try JSONDecoder().decode(Reply.self, from: data)
                    guard r.state == clientId else { continue }
                    guard let code = r.code, !code.isEmpty else {
                        throw AccountError.server(0, r.error.map { "\(provider.displayName): \($0)" } ?? String(localized: "Sign-in failed"))
                    }
                    web?.cancel()
                    try await auth("auth-with-oauth2", body: ["provider": provider.name, "code": code,
                                                              "codeVerifier": provider.codeVerifier,
                                                              "redirectURL": Self.redirect.absoluteString])
                    return
                default: continue
                }
            }
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        }
        throw CancellationError()
    }

    /// Deletes the FMC account (PocketBase users.deleteRule lets a user delete themselves).
    func deleteAccount() async throws {
        guard let user, let token else { return }
        var r = URLRequest(url: Self.base.appending(path: "api/collections/users/records/\(user.id)"))
        r.httpMethod = "DELETE"
        r.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: r)
        try check(response, data)
        signOut()
    }

    /// Adds the FMC token to a request for the user's own records.
    func authorize(_ r: inout URLRequest) {
        if let token { r.setValue(token, forHTTPHeaderField: "Authorization") }
    }

    func signOut() {
        token = nil
        user = nil
    }

    private func api(_ path: String) -> URL {
        Self.base.appending(path: "api/collections/users/\(path)")
    }

    private func subscribe(_ clientId: String) async throws {
        var r = URLRequest(url: Self.base.appending(path: "api/realtime"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["clientId": clientId, "subscriptions": ["@oauth2"]])
        let (data, response) = try await URLSession.shared.data(for: r)
        try check(response, data)
    }

    private func auth(_ path: String, body: [String: String]?) async throws {
        var r = URLRequest(url: api(path))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { r.setValue(token, forHTTPHeaderField: "Authorization") }
        r.httpBody = try JSONEncoder().encode(body ?? [:])
        let (data, response) = try await URLSession.shared.data(for: r)
        try check(response, data)
        let reply = try JSONDecoder().decode(AuthReply.self, from: data)
        token = reply.token
        user = reply.record
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200..<300).contains(status) else { return }
        let message = (try? JSONDecoder().decode(PBError.self, from: data))?.message
        throw AccountError.server(status, message ?? String(localized: "Request failed (\(status))"))
    }
}

enum AccountError: LocalizedError {
    case server(Int, String)
    var errorDescription: String? {
        switch self { case .server(_, let m): m }
    }
}

private final class WindowAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WindowAnchor()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}

private struct AuthReply: Decodable {
    var token: String
    var record: User
}

private struct PBError: Decodable {
    var message: String
}
