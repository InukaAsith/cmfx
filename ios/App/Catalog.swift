import Foundation
import Observation
import WireKit

// FMC catalog: PocketBase `watchfaces` at fmc.tools, as fmc_frontend modules/market/model/market.api.ts
// (loadMarketFx, loadMyFx, loadWatchfaceFx, toggleLikeFx). Publishing and the editor stay on the site.
//
// Light on the server and on the phone's data: a list comes in pages of `CatalogQuery.perPage`, filtered and
// sorted by PocketBase, the next page when the grid nears its end. Like counts come from the face's own
// `likes_count`, the heart from the signed-in user's likes alone. The first page of All waits on disk, so the tab
// shows at once and refreshes behind it. Cards show the 300×300 thumb, the face page the preview itself.

struct Watchface: Decodable, Identifiable, Hashable {
    struct Owner: Decodable, Hashable {
        var id: String
        var name: String
        var avatar: String?
        var avatarURL: URL? {
            avatar.flatMap { $0.isEmpty ? nil : Account.base.appending(path: "api/files/users/\(id)/\($0)").appending(queryItems: [.init(name: "thumb", value: "100x100")]) }
        }
    }
    struct Expand: Decodable, Hashable { var owner: Owner? }

    var id: String
    var collectionId: String
    var name: String
    var description: String
    var preview: String
    var bin: String
    var published: Bool
    var downloads: Int
    var created: String
    /// "Analog", "Digital", …; "" for most
    var type: String?
    /// "watch_pro_2", "watch_3_pro", …; "" for most, which count as Watch Pro 2 (the site's matchesDevice)
    var device: String?
    /// Kept by the server's hooks; nil from a server without the field (fmc_pocketbase 1755000000).
    var likesCount: Int?
    var expand: Expand?

    enum CodingKeys: String, CodingKey {
        case id, collectionId, name, description, preview, bin, published, downloads, created, type, device, expand
        case likesCount = "likes_count"
    }

    /// Made for another watch: the name to warn with, nil for the Watch Pro 2 and untagged faces.
    var otherDevice: String? {
        guard let d = device, !d.isEmpty, d != "watch_pro_2" else { return nil }
        return Self.devices[d] ?? d
    }
    /// fmc_frontend deviceLabel
    static let devices = ["watch_pro": "Watch Pro", "watch_3_pro": "Watch 3 Pro"]

    var author: String? { expand?.owner?.name }
    var authorAvatar: URL? { expand?.owner?.avatarURL }
    var ownerId: String? { expand?.owner?.id }
    var previewURL: URL? { file(preview) }
    /// For cards and tiles. A server without the thumb size sends the preview itself.
    var thumbURL: URL? { previewURL?.appending(queryItems: [.init(name: "thumb", value: CatalogQuery.thumb)]) }
    var binURL: URL? { file(bin) }
    var pageURL: URL { Account.base.appending(path: "market/\(id)") }

    private func file(_ name: String) -> URL? {
        name.isEmpty ? nil : Account.base.appending(path: "api/files/\(collectionId)/\(id)/\(name)")
    }
}

/// A face as the Watch tab needs it, to name a dial on the watch and show its picture.
struct DialFace: Codable, Hashable {
    var id, collectionId, name, preview: String
    var thumbURL: URL? {
        preview.isEmpty ? nil : Account.base.appending(path: "api/files/\(collectionId)/\(id)/\(preview)")
            .appending(queryItems: [.init(name: "thumb", value: CatalogQuery.thumb)])
    }
}

enum Shelf: Hashable { case all, liked, mine }
/// fmc_frontend market.svelte SORT_OPTIONS (Top creators, a shelf of rails, left out)
enum CatalogSort: String, CaseIterable { case new, popular, downloads }

/// One list of the catalog as PocketBase is asked for it. Same cases as android CatalogQuery.
struct CatalogQuery: Hashable {
    var shelf: Shelf = .all
    var sort: CatalogSort = .new
    var search = ""
    /// The signed-in user's record id: Liked and Mine need it.
    var user: String?

    static let perPage = 40
    /// fmc_pocketbase watchfaces.preview thumbs: 300x300 and 150x150
    static let thumb = "300x300"
    /// Only the owner's name, id and avatar of the expanded owner: a card shows no more.
    static let fields = "*,expand.owner.id,expand.owner.name,expand.owner.avatar"

    /// nil: a shelf that needs a user, signed out.
    var filter: String? {
        var f: String
        switch shelf {
        case .all: f = "published = true"
        case .liked, .mine:
            guard let user, FaceLink.isRecordID(user) else { return nil }
            f = shelf == .mine ? "owner = '\(user)'" : "published = true && likes_via_watchface.user ?= '\(user)'"
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { f += " && (name ~ \(Self.quote(q)) || owner.name ~ \(Self.quote(q)))" }
        return f
    }

    /// `likesCount`: the server has watchfaces.likes_count. Without it Popular falls back to downloads.
    /// The id breaks ties, so a face can't show on two pages or on none.
    func order(likesCount: Bool = true) -> String {
        switch sort {
        case .new: "-created,id"
        case .popular where likesCount: "-likes_count,-downloads,id"
        case .popular, .downloads: "-downloads,-created,id"
        }
    }

    /// The disk file the first page waits in: All only, unsearched, one per sort.
    var cacheName: String? {
        shelf == .all && search.trimmingCharacters(in: .whitespaces).isEmpty ? "catalog-\(sort.rawValue)" : nil
    }

    /// A PocketBase filter string literal (the JS SDK's pb.filter): backslashes and quotes escaped.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// The grid is near its end: the cell at `index` of `count` loaded is in the last few.
    static func nearEnd(_ index: Int, of count: Int) -> Bool { index >= count - 8 }
}

@MainActor @Observable final class Catalog {
    /// The list on screen, as `query` asked for it.
    private(set) var query = CatalogQuery()
    private(set) var faces: [Watchface] = []
    private(set) var loading = false
    /// The last page came short: nothing more to ask for.
    private(set) var end = false
    private(set) var error: String?
    /// Like counts: from each face's likes_count, then moved by the user's own taps.
    private(set) var counts: [String: Int] = [:]
    /// The signed-in user's likes: face id → like id ("" while the create is in flight).
    private(set) var myLikes: [String: String] = [:]
    /// Faces of the Watch tab's dials, by dial id: from the lists loaded and from the slim index.
    private(set) var dials: [UInt32: DialFace] = [:]

    private var page = 0
    /// Bumped by each new query: a page that comes back for an older one is dropped.
    private var generation = 0
    /// Whether the server has watchfaces.likes_count; nil until a list says.
    private var hasLikesCount: Bool?
    private var known: [String: Watchface] = [:]

    func likeCount(_ face: Watchface) -> Int { counts[face.id] ?? face.likesCount ?? 0 }
    func liked(_ face: Watchface) -> Bool { myLikes[face.id] != nil }

    /// Shows `q`: from its first page again when it changed, else as it is.
    func show(_ q: CatalogQuery, account: Account) async {
        guard q != query || (faces.isEmpty && !loading) else { return }
        query = q
        generation += 1
        page = 0
        end = false
        error = nil
        faces = q.cacheName.flatMap(Self.cached) ?? []
        faces.forEach(remember)
        await load(account: account)
    }

    /// Pull to refresh: the first page again, the list on screen until it comes.
    func refresh(account: Account) async {
        generation += 1
        page = 0
        end = false
        async let mine: Void = loadMyLikes(account)
        await load(account: account)
        await mine
    }

    /// The next page, unless one is coming or the last one came.
    func more(account: Account) async {
        guard !loading, !end, page > 0 else { return }
        await load(account: account)
    }

    private func load(account: Account) async {
        let q = query, gen = generation, next = page + 1
        guard let filter = q.filter else { faces = []; end = true; return }
        loading = true
        defer { if gen == generation { loading = false } }
        do {
            let (items, data) = try await list(filter: filter, q: q, page: next, account: account)
            guard gen == generation else { return }
            if next == 1, let name = q.cacheName { Self.store(data, as: name) }
            faces = next == 1 ? items : faces + items.filter { f in !faces.contains { $0.id == f.id } }
            page = next
            end = items.count < CatalogQuery.perPage
            error = nil
            items.forEach(remember)
            if hasLikesCount == false { await fallbackCounts(items) }
        } catch {
            if gen == generation, !Self.cancelled(error) { self.error = error.localizedDescription }
        }
    }

    /// One page. A server without likes_count refuses that sort: Popular asks again by downloads.
    private func list(filter: String, q: CatalogQuery, page: Int, account: Account) async throws -> ([Watchface], Data) {
        var r = URLRequest(url: Self.records.appending(queryItems: [
            .init(name: "page", value: "\(page)"), .init(name: "perPage", value: "\(CatalogQuery.perPage)"),
            .init(name: "skipTotal", value: "1"), .init(name: "filter", value: filter),
            .init(name: "sort", value: q.order(likesCount: hasLikesCount != false)),
            .init(name: "expand", value: "owner"), .init(name: "fields", value: CatalogQuery.fields),
        ]))
        account.authorize(&r)
        do {
            let data = try await Self.data(r)
            let items = try JSONDecoder().decode(Page<Watchface>.self, from: data).items
            if let first = items.first { hasLikesCount = first.likesCount != nil }
            return (items, data)
        } catch AccountError.server(400, _) where q.sort == .popular && hasLikesCount != false {
            hasLikesCount = false
            return try await list(filter: filter, q: q, page: page, account: account)
        }
    }

    private func remember(_ face: Watchface) {
        known[face.id] = face
        if let n = face.likesCount { counts[face.id] = n }
        dials[dialId(face.id)] = DialFace(id: face.id, collectionId: face.collectionId, name: face.name, preview: face.preview)
    }

    /// A server without likes_count: the counts of these faces from their likes.
    private func fallbackCounts(_ faces: [Watchface]) async {
        guard !faces.isEmpty else { return }
        let filter = faces.map { "watchface = '\($0.id)'" }.joined(separator: " || ")
        guard let likes: [Like] = try? await Self.all(Self.likesURL, filter: filter, fields: "id,watchface") else { return }
        var n = Dictionary(faces.map { ($0.id, 0) }, uniquingKeysWith: +)
        for l in likes { n[l.watchface, default: 0] += 1 }
        counts.merge(n) { _, new in new }
    }

    struct Like: Decodable { var id, watchface: String }

    /// The signed-in user's own likes, for the hearts; nothing signed out.
    func loadMyLikes(_ account: Account) async {
        guard let id = account.user?.id, FaceLink.isRecordID(id) else { myLikes = [:]; return }
        guard let l: [Like] = try? await Self.all(Self.likesURL, filter: "user = '\(id)'", fields: "id,watchface", account: account)
        else { return }
        myLikes = Dictionary(l.map { ($0.watchface, $0.id) }, uniquingKeysWith: { a, _ in a })
    }

    /// Likes or unlikes as the signed-in user; the count moves at once and back if the server says no.
    func toggleLike(_ face: Watchface, account: Account) async {
        guard let user = account.user else { return }
        let before = (myLikes[face.id], likeCount(face))
        var r: URLRequest
        if let mine = before.0 {
            guard !mine.isEmpty else { return } // its create is still in flight
            r = URLRequest(url: Self.likesURL.appending(path: mine))
            r.httpMethod = "DELETE"
            myLikes[face.id] = nil
            counts[face.id] = max(0, before.1 - 1)
        } else {
            r = URLRequest(url: Self.likesURL)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONEncoder().encode(["user": user.id, "watchface": face.id])
            myLikes[face.id] = ""
            counts[face.id] = before.1 + 1
        }
        account.authorize(&r)
        do {
            let data = try await Self.data(r)
            if before.0 == nil { myLikes[face.id] = (try? JSONDecoder().decode(Like.self, from: data))?.id ?? "" }
        } catch {
            myLikes[face.id] = before.0
            counts[face.id] = before.1
        }
    }

    /// A face from a list loaded, else from the server: a deep link can name one before any list.
    func face(_ id: String, account: Account) async throws -> Watchface {
        if let f = known[id] { return f }
        var r = URLRequest(url: Self.records.appending(path: id).appending(queryItems: [.init(name: "expand", value: "owner")]))
        account.authorize(&r)
        let f: Watchface = try JSONDecoder().decode(Watchface.self, from: await Self.data(r))
        remember(f)
        if f.likesCount == nil { await fallbackCounts([f]) }
        return f
    }

    /// An author's published faces, all of them: their page adds up downloads and likes.
    func author(_ id: String, account: Account) async throws -> [Watchface] {
        guard FaceLink.isRecordID(id) else { return [] }
        let faces: [Watchface] = try await Self.all(Self.records, filter: "published = true && owner = '\(id)'",
                                                   fields: CatalogQuery.fields, sort: "-created,id", expand: "owner", account: account)
        faces.forEach(remember)
        if faces.first?.likesCount == nil { await fallbackCounts(faces) }
        return faces
    }

    /// Names and pictures for the dials on the watch. Only when one isn't known yet: then the slim index of every
    /// face the user may see (id, name, preview), from disk, and from the server again if a dial is still unknown
    /// and the copy is over ten minutes old (a face installed from the site since).
    func resolve(_ ids: [UInt32], account: Account) async {
        let missing = { ids.filter { self.dials[$0] == nil && DialSlot.stock[$0] == nil } }
        guard !missing().isEmpty else { return }
        let name = "dial-index"
        if let c = Self.cachedData(name), let index = try? JSONDecoder().decode([DialFace].self, from: c.data) {
            index.forEach { dials[dialId($0.id)] = $0 }
            if missing().isEmpty || c.age < 600 { return }
        }
        guard let index: [DialFace] = try? await Self.all(Self.records, filter: nil, fields: "id,collectionId,name,preview",
                                                           perPage: 500, account: account) else { return }
        index.forEach { dials[dialId($0.id)] = $0 }
        if let data = try? JSONEncoder().encode(index) { Self.store(data, as: name) }
    }

    /// A list that left the screen mid-load: not an error to show.
    private static func cancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static let records = Account.base.appending(path: "api/collections/watchfaces/records")
    private static let likesURL = Account.base.appending(path: "api/collections/likes/records")

    private struct Page<T: Decodable>: Decodable { var items: [T] }

    /// Every record a filter matches, page after page until a short one. For short lists: a user's likes, an
    /// author's faces, the dial index.
    private static func all<T: Decodable>(_ url: URL, filter: String?, fields: String, sort: String? = nil,
                                          expand: String? = nil, perPage: Int = 200, account: Account? = nil) async throws -> [T] {
        var out: [T] = []
        var page = 1
        while true {
            var items: [URLQueryItem] = [
                .init(name: "page", value: "\(page)"), .init(name: "perPage", value: "\(perPage)"),
                .init(name: "skipTotal", value: "1"), .init(name: "fields", value: fields),
            ]
            if let filter { items.append(.init(name: "filter", value: filter)) }
            if let sort { items.append(.init(name: "sort", value: sort)) }
            if let expand { items.append(.init(name: "expand", value: expand)) }
            var r = URLRequest(url: url.appending(queryItems: items))
            account?.authorize(&r)
            let p = try JSONDecoder().decode(Page<T>.self, from: await data(r))
            out += p.items
            guard p.items.count == perPage else { return out }
            page += 1
        }
    }

    private static func data(_ r: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AccountError.server(status, String(localized: "Catalog request failed (\(status))")) }
        return data
    }

    // the first page of each sort and the dial index, in Caches: the system may clear it, the next launch refills it
    private static let dir = URL.cachesDirectory.appending(path: "catalog", directoryHint: .isDirectory)

    private static func store(_ data: Data, as name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appending(path: "\(name).json"), options: .atomic)
    }

    private static func cachedData(_ name: String) -> (data: Data, age: TimeInterval)? {
        let url = dir.appending(path: "\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return (data, -date.timeIntervalSinceNow)
    }

    private static func cached(_ name: String) -> [Watchface]? {
        cachedData(name).flatMap { try? JSONDecoder().decode(Page<Watchface>.self, from: $0.data).items }
    }
}

/// Links that open a face in the app: `fmc://install?url=…` from the Install button on fmc.tools,
/// `fmc://install?id=…`, and the site's own `https://fmc.tools/market/<id>` (a universal link once the
/// site serves apple-app-site-association).
///
/// A link only ever names a catalog record. The file to install is always that record's own `bin`
/// from fmc.tools, never a URL from the link: a web page can't make the app fetch and flash a file.
enum FaceLink {
    static func watchface(_ url: URL) -> String? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = { (name: String) in c.queryItems?.first { $0.name == name }?.value }
        let parts = c.path.split(separator: "/").map(String.init)
        switch c.scheme?.lowercased() {
        case "fmc" where c.host == "install":
            if let id = query("id") { return isRecordID(id) ? id : nil }
            return query("url").flatMap(URL.init(string:)).flatMap(fileRecord)
        case "https" where isFMC(c.host):
            return parts.count == 2 && parts[0] == "market" && isRecordID(parts[1]) ? parts[1] : nil
        default:
            return nil
        }
    }

    /// `https://fmc.tools/api/files/<collection>/<record>/<file>` → the record.
    private static func fileRecord(_ url: URL) -> String? {
        let p = url.pathComponents
        guard url.scheme == "https", isFMC(url.host), p.count == 6, p[1] == "api", p[2] == "files",
              isRecordID(p[4]) else { return nil }
        return p[4]
    }

    private static func isFMC(_ host: String?) -> Bool {
        host?.lowercased() == Account.base.host
    }

    /// PocketBase ids: 15 lowercase letters and digits. Also what makes a filter safe to build from one.
    static func isRecordID(_ s: String) -> Bool {
        s.count == 15 && s.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }
}
