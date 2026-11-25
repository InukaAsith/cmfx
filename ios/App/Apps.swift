import MarkdownUI
import SwiftUI
import WireKit

// The apps on the watch and what each may use on the phone, laid out like iOS Settings: a list of apps, and per app
// "Allow <app> to access" with a switch per permission (docs/miniapp-rpc.md, "Permissions").

/// An app on the watch, or one that has answers on the phone but is not on the watch now.
struct WatchApp: Identifiable {
    var id: String { name }
    let name: String
    /// nil: not on the watch (or the watch was not read)
    let header: PackageHeader?
    let slot: Int?

    /// The store's name for it, else the package name.
    @MainActor var title: String { StoreApps.shared.listing(name)?.name ?? name }

    @MainActor var detail: String {
        guard let header, let slot else { return String(localized: "Not on the watch") }
        if let update { return String(localized: "Version \(versionText(header.version)) → \(versionText(update.version)) · slot \(slot)") }
        return String(localized: "Version \(versionText(header.version)) · slot \(slot)")
    }

    /// The store's build when it's newer than the one on the watch.
    @MainActor var update: PackageHeader? {
        guard let header, let latest = StoreApps.shared.latest(name), latest.version > header.version else { return nil }
        return latest
    }

    @MainActor static func all(_ loader: LoaderState?, _ perms: Permissions) -> [WatchApp] {
        let installed = (loader?.apps ?? [:]).sorted { $0.key < $1.key }
            .map { WatchApp(name: $0.value.name, header: $0.value, slot: $0.key) }
        let names = Set(installed.map(\.name))
        return installed + perms.packages.filter { !names.contains($0) }.map { WatchApp(name: $0, header: nil, slot: nil) }
    }

    /// Every app in the FMC store, the ones on the watch with their version and slot, then the installed and asked
    /// ones the store doesn't list.
    @MainActor static func store(_ loader: LoaderState?, _ perms: Permissions) -> [WatchApp] {
        let installed = (loader?.apps ?? [:]).map { (slot: $0.key, header: $0.value) }
        let store = StoreApps.shared
        let listed = store.all.map { l in
            if let on = installed.first(where: { store.listing($0.header.name)?.slug == l.slug }) {
                WatchApp(name: on.header.name, header: on.header, slot: on.slot)
            } else {
                WatchApp(name: l.slug, header: nil, slot: nil)
            }
        }
        return listed + all(loader, perms).filter { store.listing($0.name) == nil }
    }
}

/// The order of the apps on the watch, as package names, kept on the phone per watch; the Installed list shows it.
@MainActor @Observable final class AppOrder {
    static let shared = AppOrder()
    private static let key = "app-order"
    /// The last watch read (its BLE identifier); the order is kept per watch.
    var watch: String? = UserDefaults.standard.string(forKey: "watch") {
        didSet { UserDefaults.standard.set(watch, forKey: "watch") }
    }
    private var byWatch: [String: [String]] = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]

    /// The saved order first, then the apps it doesn't name, by slot.
    func sorted(_ apps: [WatchApp]) -> [WatchApp] {
        let names = byWatch[watch ?? ""] ?? []
        return apps.enumerated().sorted {
            (names.firstIndex(of: $0.element.name) ?? .max, $0.offset) < (names.firstIndex(of: $1.element.name) ?? .max, $1.offset)
        }.map(\.element)
    }

    /// The saved order of the watch read last.
    var names: [String] { byWatch[watch ?? ""] ?? [] }
    /// Changed on the phone and not on the watch yet: sent on Done, again after a Busy on the next read.
    private(set) var unsent = false
    private(set) var sending = false
    /// Why the last send didn't reach the watch.
    private(set) var status: String?

    func set(_ names: [String]) {
        byWatch[watch ?? ""] = names
        UserDefaults.standard.set(byWatch, forKey: Self.key)
        unsent = true
    }

    /// The loader package with this order in it (cmf-watch-sdk docs/app-order.md); as it is when it has no table.
    /// Every loader the phone installs goes through here, or an update would put the menu back in slot order.
    func patched(_ loader: Data) -> Data { (try? setOrder(loader, names: Array(names.prefix(16)))) ?? loader }

    /// The order goes inside the loader: the bundled loader with the table patched, installed to slot 0xFF.
    func send(_ watch: WatchModel) async {
        guard unsent, !sending, watch.loader?.loader != nil else { return }
        sending = true
        defer { sending = false }
        guard let loader = BundledLoader.package else {
            status = String(localized: "This build of CMFX has no App Loader in it, so the order can't be sent.")
            return
        }
        do {
            try await FirmwareModel.install(try setOrder(loader, names: Array(names.prefix(16)))) { _ in }
            DevLog.shared.log("app order sent: \(names.joined(separator: ", "))")
            unsent = false
            status = nil
            await watch.check()
        } catch InstallError.busy {
            // the menu holds the loader while it is open; tried again on the next read of the watch
            status = String(localized: "The Apps menu or an app is open on the watch. The order goes when you're back on the watch face and pull to refresh.")
        } catch OrderError.noTable {
            status = String(localized: "The App Loader in this build of CMFX is older than the app order. The order stays on this phone for now.")
        } catch {
            status = String(localized: "Couldn't send the order: \(error.localizedDescription)")
        }
    }
}

/// The coloured rounded square of an iOS Settings row.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var side: CGFloat = 29

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: side * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.gradient, in: .rect(cornerRadius: side * 0.225, style: .continuous))
    }
}

/// The red count before a row's chevron, as on Settings' rows.
struct CountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(minWidth: 22, minHeight: 22)
                .background(.red, in: .capsule)
        }
    }
}

/// The header's u32 version as the store's MAJOR.MINOR.PATCH (apps/scripts/store build_number), else the number.
func versionText(_ v: UInt32) -> String { v >= 1024 ? "\(v >> 20).\(v >> 10 & 1023).\(v & 1023)" : "\(v)" }

/// The FMC store's listing of watch apps (fmc.tools `apps`): their names and icons, matched to a package by slug or
/// name. Loaded once per launch.
@MainActor @Observable final class StoreApps {
    static let shared = StoreApps()
    struct Listing {
        let id, slug, name: String
        let icon, package: URL?
        var summary = "", description = "", author = "", version = "", abi = "", source = "", updated = ""
        var downloads = 0
        var screenshots: [URL] = []
        var page: URL { Account.base.appending(path: "apps/\(id)") }
        /// The download hook: counts the install as a download and redirects to the package.
        var download: URL { Account.base.appending(path: "api/apps/\(id)/download") }
    }
    private(set) var byKey: [String: Listing] = [:]
    /// slug → the store package's header. Its u32 version, not the listing's text: SDK examples don't encode it.
    private(set) var headers: [String: PackageHeader] = [:]
    /// By name, for the All segment.
    private(set) var all: [Listing] = []
    private(set) var loaded = false

    func listing(_ package: String) -> Listing? { byKey[package.lowercased()] }
    func latest(_ package: String) -> PackageHeader? { listing(package).flatMap { headers[$0.slug] } }

    /// The store's apps, once; `force` (pull to refresh) reads them again.
    func load(force: Bool = false) async {
        guard force || !loaded else { return }
        struct Page: Decodable { var items: [Record] }
        struct Record: Decodable {
            var id, collectionId, slug, name, icon: String
            var package, summary, description, author, version, abi, source, updated: String?
            var downloads: Int?
            var screenshots: [String]?
        }
        var url = Account.base.appending(path: "api/collections/apps/records")
        url.append(queryItems: [.init(name: "filter", value: "published = true"), .init(name: "perPage", value: "200"),
                                .init(name: "fields", value: "id,collectionId,slug,name,icon,package,summary,description,author,version,abi,source,updated,downloads,screenshots")])
        // past URLCache: an app hidden or shown in the store shows here on the next refresh
        guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)),
              let page = try? JSONDecoder().decode(Page.self, from: data) else { return }
        loaded = true
        var byKey: [String: Listing] = [:], all: [Listing] = []
        for r in page.items {
            // ponytail: SVG icons have no image decoder here, those apps keep the letter tile
            let files = Account.base.appending(path: "api/files/\(r.collectionId)/\(r.id)")
            let icon = r.icon.isEmpty || r.icon.hasSuffix(".svg") ? nil : files.appending(path: r.icon)
            let package = r.package.flatMap { $0.isEmpty ? nil : files.appending(path: $0) }
            let l = Listing(id: r.id, slug: r.slug, name: r.name, icon: icon, package: package, summary: r.summary ?? "",
                            description: r.description ?? "", author: r.author ?? "", version: r.version ?? "",
                            abi: r.abi ?? "", source: r.source ?? "", updated: r.updated ?? "", downloads: r.downloads ?? 0,
                            screenshots: (r.screenshots ?? []).map { files.appending(path: $0) })
            byKey[r.slug.lowercased()] = l
            byKey[r.name.lowercased()] = l
            all.append(l)
        }
        all.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        (self.byKey, self.all) = (byKey, all)
        // ponytail: one 64-byte request per store app, a few dozen at most; a field with the header's u32 on the
        // store record would make this one request
        headers = await withTaskGroup(of: (String, PackageHeader)?.self) { group in
            for l in all {
                guard let url = l.package else { continue }
                group.addTask {
                    var req = URLRequest(url: url)
                    req.setValue("bytes=0-63", forHTTPHeaderField: "Range")
                    guard let (data, _) = try? await URLSession.shared.data(for: req), let h = parseHeader(data) else { return nil }
                    return (l.slug, h)
                }
            }
            var out: [String: PackageHeader] = [:]
            for await case let (slug, h)? in group { out[slug] = h }
            return out
        }
    }
}

/// A watch app's icon: round, as on the watch. Its store icon, or its first letter on grey.
struct AppIcon: View {
    let name: String
    var side: CGFloat = 29

    var body: some View {
        let shape = Circle()
        Group {
            if let url = StoreApps.shared.listing(name)?.icon {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { letter }
            } else {
                letter
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }

    private var letter: some View {
        Text(name.prefix(1).uppercased())
            .font(.system(size: side * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(Color(.systemGray2).gradient)
    }
}

/// The Apps page under More: the list, and an app's page over it.
struct AppsPage: View {
    /// The ask notification's app: its page over the list.
    @State private var asked: String?

    var body: some View {
        @Bindable var perms = Permissions.shared
        AppsView()
            .navigationDestination(for: String.self) { value in
                // "store:<name>" from All: the store page; a bare name: the app's settings
                // "headers:<name>|<host>": the headers its requests to that host carry
                if value.hasPrefix("store:") { AppView(name: String(value.dropFirst(6)), store: true) }
                else if value.hasPrefix("headers:") {
                    let p = value.dropFirst(8).split(separator: "|", maxSplits: 1).map(String.init)
                    HeadersView(package: p[0], host: p.count > 1 ? p[1] : "")
                } else { AppView(name: value) }
            }
            .navigationDestination(item: $asked) { AppView(name: $0) }
            .alert("Couldn't update", isPresented: Binding { AppUpdates.shared.error != nil } set: { if !$0 { AppUpdates.shared.error = nil } }) {
                Button("OK") {}
            } message: { Text(AppUpdates.shared.error ?? "") }
            .onChange(of: perms.open, initial: true) { _, name in
                guard let name else { return }
                asked = name
                perms.open = nil
            }
    }
}

/// Store installs and updates: the package over K into the app's own slot, else the first free one.
@MainActor @Observable final class AppUpdates {
    static let shared = AppUpdates()
    /// name → 0…1 while installing
    private(set) var progress: [String: Double] = [:]
    var error: String?

    func update(_ name: String, _ watch: WatchModel) async {
        guard progress[name] == nil, let listing = StoreApps.shared.listing(name), listing.package != nil else { return }
        progress[name] = 0
        defer { progress[name] = nil }
        do {
            let (pkg, _) = try await URLSession.shared.data(from: listing.download)
            try await FirmwareModel.install(pkg) { p in Task { @MainActor in self.progress[name] = p } }
            DevLog.shared.log("\(name) installed")
            Analytics.track("app_installed", ["app": listing.slug])
            await watch.check()
        } catch InstallError.busy {
            error = String(localized: "\(listing.name) or the Apps menu is open on the watch. Go back to the watch face, then try again.")
        } catch InstallError.noFreeSlot(let slots) {
            error = String(localized: "All \(slots) app slots on the watch are taken.")
        } catch {
            self.error = String(localized: "Couldn't install \(listing.name): \(error.localizedDescription)")
        }
    }
}

extension AppUpdates {
    func remove(_ name: String, slot: Int, _ watch: WatchModel) async {
        guard progress[name] == nil else { return }
        let title = StoreApps.shared.listing(name)?.name ?? name
        progress[name] = 0
        defer { progress[name] = nil }
        do {
            try await FirmwareModel.remove(slot: slot)
            DevLog.shared.log("\(name) removed from slot \(slot)")
            Analytics.track("app_removed", ["app": name])
            // as iOS does on uninstall: a reinstall asks again
            Permissions.shared.reset(name)
            PhoneServices.storage.clear(name) // its data on the phone goes with it; Reset permissions keeps it
            await watch.check()
        } catch InstallError.busy {
            // the stub answers BUSY to removing a page's app even behind the face (cmf-watch-sdk docs/app-guide.md)
            error = String(localized: "\(title) is running on the watch. If it is a page next to the watch face, remove the page first: on the watch, long press \(title) in Apps → Remove page. Else go back to the watch face. Then try again.")
        } catch {
            self.error = String(localized: "Couldn't delete \(title): \(error.localizedDescription)")
        }
    }
}

/// The App Store's button: Get, Update or Installed, and the progress while it installs.
struct GetButton: View {
    @Environment(WatchModel.self) private var watch
    let app: WatchApp
    var large = false

    var body: some View {
        let width: CGFloat = large ? 84 : 72
        if let p = AppUpdates.shared.progress[app.name] {
            ProgressView(value: p).frame(width: width)
        } else if app.slot != nil, app.update == nil {
            Text("Installed").font(large ? .subheadline.weight(.semibold) : .footnote.weight(.semibold))
                .foregroundStyle(.secondary).frame(minWidth: width)
        } else {
            Button { Task { await AppUpdates.shared.update(app.name, watch) } } label: {
                Text(app.slot == nil ? "Get" : "Update").fontWeight(.bold).frame(minWidth: width - 24)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(large ? .regular : .small)
            .disabled(watch.loader == nil || StoreApps.shared.listing(app.name)?.package == nil)
        }
    }
}

struct AppsView: View {
    @Environment(WatchModel.self) private var watch
    private var perms = Permissions.shared
    @State private var showAll = false
    @State private var editMode = EditMode.inactive

    var body: some View {
        // Installed is the watch's list: nothing until it is read, not the apps that only asked for something
        let loader = watch.listedLoader
        let apps = showAll ? WatchApp.store(loader, perms) : loader == nil ? [] : WatchApp.all(loader, perms).filter { $0.slot != nil }
        // first load: placeholder rows; a refresh keeps the rows it has
        let loading = apps.isEmpty && (showAll ? !StoreApps.shared.loaded : watch.isChecking)
        List {
            Section {
                Picker("Show", selection: $showAll) {
                    Text("Installed").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            // the apps made for CMFX, in the IPA itself: no store needed
            if !editMode.isEditing { BundledAppsSection() }
            if loading {
                Section {
                    ForEach(0..<6, id: \.self) { _ in
                        HStack(spacing: 12) {
                            Circle().fill(Color(.systemGray5)).frame(width: 29, height: 29)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Placeholder name")
                                Text("Version 1.0 · slot 0").font(.footnote)
                            }
                        }
                        .redacted(reason: .placeholder)
                    }
                }
            } else if showAll {
                Section { ForEach(apps) { row($0) } } footer: {
                    Text(watch.listedLoader == nil ? "Apps in the FMC store. Connect on the Watch tab to install them." : "Apps in the FMC store.")
                }
            } else {
                installed(apps)
            }
        }
        .overlay {
            if apps.isEmpty, !loading {
                if showAll {
                    ContentUnavailableView("No apps", systemImage: "square.grid.2x2",
                                           description: Text("Couldn't load the FMC store."))
                } else {
                    ContentUnavailableView("No apps", systemImage: "square.grid.2x2",
                                           description: Text("Connect on the Watch tab to see the apps on the watch."))
                }
            }
        }
        .navigationTitle("Apps")
        .toolbar { if !showAll, !apps.isEmpty { EditButton() } }
        .environment(\.editMode, $editMode)
        .onChange(of: showAll) { editMode = .inactive }
        .onChange(of: editMode.isEditing) { _, editing in
            if !editing { Task { await AppOrder.shared.send(watch) } }
        }
        .task { await StoreApps.shared.load() }
        // the list of installed apps is the watch's: read it here too, not only from Connect on the Watch tab
        .task { if watch.phase == .idle { await watch.check() } }
        .refreshable {
            async let store: () = StoreApps.shared.load(force: true)
            await watch.check()
            await store
        }
    }

    @ViewBuilder private func installed(_ apps: [WatchApp]) -> some View {
        let on = AppOrder.shared.sorted(apps.filter { $0.slot != nil })
        let updates = on.filter { $0.update != nil }, current = on.filter { $0.update == nil }
        if editMode.isEditing {
            // one list while editing: the order is of every app on the watch
            Section {
                ForEach(on) { row($0) }
                    .onMove { from, to in
                        var names = on.map(\.name)
                        names.move(fromOffsets: from, toOffset: to)
                        AppOrder.shared.set(names)
                    }
            } footer: {
                Text("Drag to set the order of the Apps menu on the watch. It goes to the watch inside the App Loader (about 54 KB) when you tap Done.")
            }
        } else if !updates.isEmpty {
            Section {
                ForEach(updates) { row($0) }
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates install over Bluetooth. Keep the app closed on the watch meanwhile.")
            }
        }
        if !editMode.isEditing, !current.isEmpty {
            Section {
                ForEach(current) { row($0) }
            } header: {
                Text("On the watch")
            } footer: {
                if AppOrder.shared.sending { Text("Sending the order to the watch…") }
                else if let s = AppOrder.shared.status { Text(s) }
            }
        }
    }

    private func row(_ app: WatchApp) -> some View {
        NavigationLink(value: showAll ? "store:\(app.name)" : app.name) {
            HStack(spacing: 12) {
                AppIcon(name: app.name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.title)
                    Text(app.detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                CountBadge(count: perms.pendingCount(app.name))
                if app.update != nil || (app.slot == nil && StoreApps.shared.listing(app.name)?.package != nil) {
                    GetButton(app: app)
                } else if showAll, app.slot != nil {
                    Text("Installed").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AppView: View {
    @Environment(WatchModel.self) private var watch
    let name: String
    private var perms = Permissions.shared
    private let services = PhoneServices.shared
    @State private var resetting = false
    @State private var deleting = false
    /// The store page (from All): description, screenshots, Get. Else the app's settings: permissions, Update, Delete.
    let store: Bool

    init(name: String, store: Bool = false) { self.name = name; self.store = store }

    var body: some View {
        let app = WatchApp.all(watch.listedLoader, perms).first { $0.name == name } ?? WatchApp(name: name, header: nil, slot: nil)
        // asked ones first; an app on the watch also offers the phone's own services ahead of its first ask (the
        // spec's pre-filled grants), so Calendar or Reminders apps can be allowed before they need it
        let asked = perms.caps(name)
        let caps = app.slot == nil ? asked : asked + Permissions.offered.filter { !asked.contains($0) }
        let listing = StoreApps.shared.listing(name)
        List {
            if store, let listing { storeSections(app, listing) } else { settingsSections(app, caps, listing) }
        }
        .navigationTitle(app.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store, let listing {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: listing.page) { Image(systemName: "safari") }.accessibilityLabel("Open on fmc.tools")
                }
            }
        }
        .task { await StoreApps.shared.load() }
        .confirmationDialog("Reset permissions for \(name)?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { perms.reset(name) }
        }
        .confirmationDialog("Delete \(app.title) from the watch?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let slot = app.slot { Task { await AppUpdates.shared.remove(name, slot: slot, watch) } }
            }
        } message: { Text("Its data on the watch goes too.") }
    }

    @ViewBuilder private func storeSections(_ app: WatchApp, _ listing: StoreApps.Listing) -> some View {
            // the App Store's header: icon, name, summary, the button, the facts. A section header, not a row: rows
            // clip to the section's rounded corners, a header spans the screen
            Section {} header: {
                VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    AppIcon(name: name, side: 108)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.title).font(.title2.weight(.bold)).lineLimit(2)
                        if !listing.summary.isEmpty {
                            Text(listing.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer(minLength: 8)
                        GetButton(app: app, large: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                }
                if listing.package != nil, watch.listedLoader == nil {
                    Text("Connect on the Watch tab to install.").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                InfoStrip(app: app, listing: listing).padding(.horizontal, -20)
                }
                .textCase(nil)
                .foregroundStyle(.primary)
                .padding(.top, 8)
            }
                if !listing.screenshots.isEmpty {
                    Section {} header: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Preview").font(.title3.weight(.bold)).foregroundStyle(.primary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(listing.screenshots, id: \.self) { url in
                                        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color(.systemGray5) }
                                            .frame(width: 180, height: 180).clipShape(.circle)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                            .padding(.horizontal, -20)
                        }
                        .textCase(nil)
                    }
                }
                if !listing.description.isEmpty {
                    Section("Description") {
                        Markdown(listing.description).textSelection(.enabled).padding(.vertical, 4)
                    }
                }
                Section("Information") {
                    if !listing.author.isEmpty { LabeledContent("Developer", value: listing.author) }
                    if !listing.version.isEmpty { LabeledContent("Version", value: listing.version) }
                    if let h = app.header, let slot = app.slot {
                        LabeledContent("On the watch", value: "\(versionText(h.version)) · slot \(slot)")
                    }
                    if !listing.abi.isEmpty { LabeledContent("Loader ABI", value: listing.abi) }
                    if let url = URL(string: listing.source), !listing.source.isEmpty {
                        Link(destination: url) { LabeledContent("Source code") { Image(systemName: "arrow.up.right.square") } }
                    }
                }
    }

    @ViewBuilder private func settingsSections(_ app: WatchApp, _ caps: [String], _ listing: StoreApps.Listing?) -> some View {
            Section {
                VStack(spacing: 8) {
                    AppIcon(name: name, side: 60)
                    Text(app.title).font(.title3.weight(.semibold))
                    Text(app.detail).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            if app.update != nil || listing != nil {
                Section {
                    if let new = app.update {
                        HStack {
                            Text("Version \(versionText(new.version)) is out").fontWeight(.semibold)
                            Spacer()
                            GetButton(app: app)
                        }
                    }
                    if listing != nil { NavigationLink("View in the Store", value: "store:\(name)") }
                }
            }
            if app.slot != nil {
                Section {
                    Button("Delete from the Watch", role: .destructive) { deleting = true }
                        .disabled(AppUpdates.shared.progress[name] != nil)
                } footer: {
                    Text("Removes \(app.title) and its data from the watch, and forgets its permissions.")
                }
            }
            let jobs = Jobs.shared.of(name)
            if !jobs.isEmpty {
                Section {
                    ForEach(jobs, id: \.id) { j in
                        Toggle(Jobs.label(j), isOn: Binding(get: { j.on }, set: { Jobs.shared.setOn(name, j.id, $0) }))
                    }
                } header: {
                    Text("Background refresh")
                } footer: {
                    Text("\(app.title) asked the phone to fetch these on its own, for its widget or page on the watch. They run while the phone is connected to the watch.")
                }
            }
            if caps.isEmpty {
                Section {
                    Text("\(app.title) hasn't asked for anything on your phone.").foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(caps, id: \.self) { cap in
                        Toggle(isOn: Binding(get: { perms.grants(name)[cap] == true },
                                             set: { perms.set(name, cap, $0) })) {
                            HStack(spacing: 12) {
                                SettingsIcon(symbol: Self.symbol(cap), color: Self.color(cap))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Self.title(cap))
                                    if let note = note(cap) {
                                        Text(note).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if cap.hasPrefix("http:") {
                            let host = String(cap.dropFirst(5))
                            NavigationLink(value: "headers:\(name)|\(host)") {
                                LabeledContent("Headers") {
                                    let n = perms.headers(name, host).count
                                    Text(n == 0 ? String(localized: "None") : "\(n)")
                                }
                                .padding(.leading, 41)
                            }
                        }
                    }
                    Toggle(isOn: Binding(get: { perms.showText(name) }, set: { perms.setShowText(name, $0) })) {
                        HStack(spacing: 12) {
                            SettingsIcon(symbol: "text.bubble.fill", color: .gray)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Show text on the watch")
                                Text("Calendar titles and notification text").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Allow \(app.title) to access")
                } footer: {
                    if caps.contains(where: { perms.grants(name)[$0] == true && !services.osAllowed($0) }) {
                        Text("Some of these are off for CMFX in iOS Settings. [Open Settings](app-settings:)\n")
                    }
                    Text("Anyone nearby with a Bluetooth scanner could read what goes to the watch, location included (rounded to about 10 km).")
                }
                Section {
                    Button("Reset permissions", role: .destructive) { resetting = true }
                } footer: {
                    Text("\(app.title) asks again the next time it needs something.")
                }
            }
    }

    private func note(_ cap: String) -> String? {
        if perms.isPending(name, cap) { return String(localized: "Waiting for your answer") }
        if cap == "notifications", !services.notificationsAvailable { return String(localized: "Not available on iPhone") }
        if perms.grants(name)[cap] == true, !services.osAllowed(cap) { return String(localized: "Off in iOS Settings") }
        return nil
    }

    static func title(_ cap: String) -> String {
        switch cap {
        case "calendar": String(localized: "Calendars")
        case "reminders": String(localized: "Reminders")
        case "location": String(localized: "Location")
        case "weather": String(localized: "Weather")
        case "notifications": String(localized: "Notifications")
        case "notify": String(localized: "Send Notifications")
        default: cap.hasPrefix("http:") ? String(cap.dropFirst(5)) : cap
        }
    }

    static func symbol(_ cap: String) -> String {
        switch cap {
        case "calendar": "calendar"
        case "reminders": "checklist"
        case "location": "location.fill"
        case "weather": "cloud.sun.fill"
        case "notifications": "bell.badge.fill"
        case "notify": "app.badge.fill"
        default: "globe"
        }
    }

    static func color(_ cap: String) -> Color {
        switch cap {
        case "calendar", "notifications": .red
        case "notify": .orange
        case "location", "reminders": .blue
        case "weather": .cyan
        default: .gray
        }
    }
}

/// The App Store's row of facts under the header.
private struct InfoStrip: View {
    let app: WatchApp
    let listing: StoreApps.Listing

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                cell("DOWNLOADS", listing.downloads.formatted(.number.notation(.compactName)), "arrow.down.circle")
                if !listing.version.isEmpty { cell("VERSION", listing.version, nil) }
                if !listing.author.isEmpty { cell("DEVELOPER", nil, "person.crop.square", caption: listing.author) }
                if let slot = app.slot { cell("SLOT", "\(slot)", nil, caption: String(localized: "on the watch")) }
                if let date = updated { cell("UPDATED", nil, "calendar", caption: date.formatted(.relative(presentation: .named))) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .overlay(alignment: .top) { Divider().padding(.horizontal, 20) }
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 20) }
    }

    private var updated: Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
        return f.date(from: listing.updated)
    }

    private func cell(_ title: LocalizedStringKey, _ value: String?, _ symbol: String?, caption: String? = nil) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Group {
                if let value { Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6) }
                else if let symbol { Image(systemName: symbol).font(.title3) }
            }
            .foregroundStyle(.secondary).frame(height: 26)
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(width: 104, alignment: .top)
        .overlay(alignment: .trailing) { Divider().frame(height: 36).frame(maxHeight: .infinity) }
    }
}

/// Name/value pairs an app's requests to one host carry (an API key, `Authorization: Bearer …`). In the Keychain,
/// never sent to the watch; saved as typed.
struct HeadersView: View {
    let package: String, host: String
    private struct Row: Identifiable, Equatable { let id = UUID(); var name = "", value = "" }
    @State private var rows: [Row] = []

    var body: some View {
        List {
            Section {
                ForEach($rows) { $row in
                    VStack(spacing: 8) {
                        TextField("Name", text: $row.name)
                        Divider()
                        TextField("Value", text: $row.value)
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                .onDelete { rows.remove(atOffsets: $0) }
                Button("Add Header") { rows.append(Row()) }
            } header: {
                Text(host)
            } footer: {
                Text("Sent with every request \(package) makes to \(host). They stay on this iPhone, in the Keychain, and never go to the watch.")
            }
        }
        .navigationTitle("Headers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !rows.isEmpty { EditButton() } }
        .onAppear {
            rows = Permissions.shared.headers(package, host).map { Row(name: $0.name, value: $0.value) }
        }
        .onChange(of: rows) {
            Permissions.shared.setHeaders(package, host, rows.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { HTTPHeader(name: $0.name, value: $0.value) })
        }
    }
}

/// The watch apps that came with this build of CMFX: CI puts the newest cmf-watch-sdk apps release in the app
/// (ios/fetch-apps.sh), App/WatchApps/<crate>.wp2app with apps.json listing them. Installed from the Apps page
/// without fmc.tools.
@MainActor @Observable final class BundledApps {
    static let shared = BundledApps()
    struct App: Identifiable {
        var id: String { name }
        let name: String
        let package: Data
        let header: PackageHeader
    }
    let all: [App]
    /// name → 0…1 while installing
    private(set) var progress: [String: Double] = [:]
    private(set) var installingAll = false
    var error: String?

    private init() {
        struct Entry: Decodable { var file: String; var name: String }
        let dir = Bundle.main.resourceURL
        let list = Bundle.main.url(forResource: "apps", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        all = list.compactMap { e in
            guard let url = dir?.appending(path: e.file), let pkg = try? Data(contentsOf: url), let h = parseHeader(pkg) else { return nil }
            return App(name: h.name, package: pkg, header: h)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    enum State { case missing, older, current }

    func state(_ app: App, _ loader: LoaderState?) -> State {
        guard let on = loader?.apps.values.first(where: { $0.name == app.name }) else { return .missing }
        return on.version < app.header.version ? .older : .current
    }

    func install(_ app: App, _ watch: WatchModel) async {
        guard progress[app.name] == nil else { return }
        progress[app.name] = 0
        defer { progress[app.name] = nil }
        do {
            try await FirmwareModel.install(app.package) { p in Task { @MainActor in self.progress[app.name] = p } }
            DevLog.shared.log("\(app.name) installed (bundled v\(app.header.version))")
        } catch InstallError.busy {
            error = String(localized: "\(app.name) or the Apps menu is open on the watch. Go back to the watch face, then try again.")
        } catch InstallError.noFreeSlot(let slots) {
            error = String(localized: "All \(slots) app slots on the watch are taken. Delete an app first.")
        } catch {
            self.error = String(localized: "Couldn't install \(app.name): \(error.localizedDescription)")
        }
    }

    /// Every bundled app the watch doesn't have, or has older, one after the other; stops at the first error.
    func installAll(_ watch: WatchModel) async {
        guard !installingAll else { return }
        installingAll = true
        defer { installingAll = false }
        for app in all where state(app, watch.loader) != .current {
            await install(app, watch)
            if error != nil { break }
        }
        await watch.check()
    }
}

/// The Apps page's section of the apps bundled with CMFX: Install, Update or Installed each, and Install all.
struct BundledAppsSection: View {
    @Environment(WatchModel.self) private var watch
    private var bundled = BundledApps.shared

    var body: some View {
        if !bundled.all.isEmpty {
            let loader = watch.listedLoader
            let todo = bundled.all.filter { bundled.state($0, loader) != .current }.count
            Section {
                ForEach(bundled.all) { app in
                    HStack(spacing: 12) {
                        AppIcon(name: app.name, side: 29)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                            Text("Version \(versionText(app.header.version))").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let p = bundled.progress[app.name] {
                            ProgressView(value: p).frame(width: 72)
                        } else {
                            switch bundled.state(app, loader) {
                            case .current:
                                Text("Installed").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            case let s:
                                Button { Task { await bundled.install(app, watch); await watch.check() } } label: {
                                    Text(s == .missing ? "Install" : "Update").fontWeight(.bold)
                                }
                                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
                                .disabled(loader?.loader == nil || bundled.installingAll)
                            }
                        }
                    }
                }
                if todo > 1 {
                    Button {
                        Task { await bundled.installAll(watch) }
                    } label: {
                        HStack {
                            Text(bundled.installingAll ? "Installing…" : "Install all (\(todo))")
                            Spacer()
                            if bundled.installingAll { ProgressView() }
                        }
                    }
                    .disabled(loader?.loader == nil || bundled.installingAll)
                }
            } header: {
                Text("Bundled with CMFX")
            } footer: {
                if loader == nil {
                    Text("Connect on the Watch tab to install them.")
                } else if loader?.loader == nil {
                    Text("Install the App Loader first: Watch tab › Firmware & App Loader.")
                } else {
                    Text("The watch apps made for CMFX, in this build. The watch should be on its watch face while they install; each takes up to a minute.")
                }
            }
            .alert("Couldn't install", isPresented: Binding { bundled.error != nil } set: { if !$0 { bundled.error = nil } }) {
                Button("OK") {}
            } message: { Text(bundled.error ?? "") }
        }
    }
}
