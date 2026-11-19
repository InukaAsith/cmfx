import SwiftUI
import UserNotifications
import WireKit

// The user's answers per watch app (docs/miniapp-rpc.md, "Permissions"): grants keyed by package name, pending asks,
// "Show text on the watch". A local notification asks, at most once a day per package and cap.
// ponytail: UserDefaults, a handful of packages; move to a file if this grows past that.

@MainActor @Observable final class Permissions {
    static let shared = Permissions()
    private static let key = "rpc-permissions"

    struct Store: Codable {
        /// package → cap → allowed
        var grants: [String: [String: Bool]] = [:]
        /// package → cap → last notified
        var asked: [String: [String: Date]] = [:]
        var showText: Set<String> = []
    }

    private(set) var store: Store
    /// The package whose ask notification was tapped: the Watch tab opens its page.
    var open: String?

    private init() {
        store = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
            ?? Store()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(store), forKey: Self.key)
    }

    var packages: [String] { Set(store.grants.keys).union(store.asked.keys).sorted() }

    struct Ask: Hashable { let package: String, cap: String }

    /// Asked and not answered.
    var pending: [Ask] {
        store.asked.flatMap { p, caps in caps.keys.filter { store.grants[p]?[$0] == nil }.map { Ask(package: p, cap: $0) } }
            .sorted { ($0.package, $0.cap) < ($1.package, $1.cap) }
    }

    func grants(_ package: String) -> [String: Bool] { store.grants[package] ?? [:] }

    /// Every cap the package asked for or has an answer for.
    func caps(_ package: String) -> [String] {
        Set(grants(package).keys).union(store.asked[package].map { Array($0.keys) } ?? []).sorted()
    }

    func isPending(_ package: String, _ cap: String) -> Bool {
        store.asked[package]?[cap] != nil && store.grants[package]?[cap] == nil
    }

    func pendingCount(_ package: String) -> Int { caps(package).filter { isPending(package, $0) }.count }

    /// Forgets every answer, the headers and the cookies: the next calls ask again.
    func reset(_ package: String) {
        for cap in caps(package) where cap.hasPrefix("http:") { setHeaders(package, String(cap.dropFirst(5)), []) }
        PhoneServices.shared.clearCookies(package)
        Jobs.shared.clear(package)
        store.grants[package] = nil
        store.asked[package] = nil
        store.showText.remove(package)
        save()
    }

    /// `write`: http.request, which can change data on the host.
    func ask(_ package: String, _ cap: String, write: Bool = false, now: Date = .now) {
        if let last = store.asked[package]?[cap], now.timeIntervalSince(last) < 86_400 { return }
        store.asked[package, default: [:]][cap] = now
        save()
        let n = UNMutableNotificationContent()
        n.title = write ? String(localized: "\(package) wants to read and change data on \(String(cap.dropFirst(5)))")
            : String(localized: "\(package) wants \(Self.label(cap))")
        n.body = String(localized: "Allow or deny it in CMFX.")
        n.userInfo = ["package": package]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ask-\(package)-\(cap)", content: n,
                                                                    trigger: nil))
    }

    /// Allow also asks for the OS permission the cap needs.
    func set(_ package: String, _ cap: String, _ allowed: Bool) {
        store.grants[package, default: [:]][cap] = allowed
        save()
        if allowed { Task { await PhoneServices.shared.requestOS(cap) } }
    }

    /// The headers the user set for the app's requests to `host`: in the Keychain, never logged or sent to the watch.
    func headers(_ package: String, _ host: String) -> [HTTPHeader] {
        Keychain.get("h|\(package)|\(host)").flatMap { try? JSONDecoder().decode([HTTPHeader].self, from: Data($0.utf8)) } ?? []
    }

    func setHeaders(_ package: String, _ host: String, _ list: [HTTPHeader]) {
        let json = try? JSONEncoder().encode(list)
        Keychain.set("h|\(package)|\(host)", list.isEmpty ? nil : json.flatMap { String(data: $0, encoding: .utf8) })
    }

    func showText(_ package: String) -> Bool { store.showText.contains(package) }

    func setShowText(_ package: String, _ on: Bool) {
        if on { store.showText.insert(package) } else { store.showText.remove(package) }
        save()
    }

    static func label(_ cap: String) -> String {
        switch cap {
        case "calendar": String(localized: "your calendar")
        case "reminders": String(localized: "your reminders")
        case "location": String(localized: "your approximate location")
        case "weather": String(localized: "the weather where you are")
        case "notifications": String(localized: "your notifications")
        case "notify": String(localized: "to send you notifications")
        default: cap.hasPrefix("http:") ? String(localized: "the web: \(String(cap.dropFirst(5)))") : cap
        }
    }
}

/// Watch apps' background jobs (job.set), per package, in UserDefaults. Not secret: an http job's URL and body are
/// what the app sent; the headers stay in the Keychain.
@MainActor @Observable final class Jobs {
    static let shared = Jobs()
    private static let key = "rpc-jobs"
    private(set) var all: [String: [RefreshJob]]

    private init() {
        all = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: [RefreshJob]].self, from: $0) } ?? [:]
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: Self.key) }

    func of(_ package: String) -> [RefreshJob] { (all[package] ?? []).sorted { $0.id < $1.id } }

    /// A new job with that id replaces the old one and runs soon; the user's switch stays as it was.
    func set(_ package: String, _ job: RefreshJob) {
        var j = job
        j.on = all[package]?.first { $0.id == job.id }?.on ?? true
        j.last = nil
        all[package] = (all[package] ?? []).filter { $0.id != job.id } + [j]
        save()
    }

    func delete(_ package: String, _ id: Int) { all[package]?.removeAll { $0.id == id }; save() }
    func clear(_ package: String) { all[package] = nil; save() }

    func setOn(_ package: String, _ id: Int, _ on: Bool) {
        guard let i = all[package]?.firstIndex(where: { $0.id == id }) else { return }
        all[package]![i].on = on
        save()
    }

    func ran(_ package: String, _ id: Int, at: Date) {
        guard let i = all[package]?.firstIndex(where: { $0.id == id }) else { return }
        all[package]![i].last = at
        save()
    }

    /// "Every 30 min: GET api.example.com/rate"
    static func label(_ j: RefreshJob) -> String {
        let what = switch j.kind {
        case .http: parseHTTPCall(j.spec).map { "\($0.method) \($0.url.absoluteString.replacingOccurrences(of: "https://", with: ""))" } ?? String(localized: "Web request")
        case .weather: String(localized: "Weather")
        case .calendar: String(localized: "Calendar")
        }
        let into = j.target == .widget ? String(localized: " → widget") : ""
        let every = j.minutes % 60 == 0 ? String(localized: "\(j.minutes / 60) h") : String(localized: "\(j.minutes) min")
        return String(localized: "Every \(every): \(what)\(into)")
    }
}
