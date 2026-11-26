import HubKit
import MapKit
import PhotosUI
import SwiftUI

// The Hub tab: the watch apps that need the phone, each with its own page.

/// More's pages pushed by value: Apps pushes its own pages by value (an app's page, the store's), and a value push
/// over a page pushed by view pops back to the list (SwiftUI): one path, values only, for those.
enum HubRoute: Hashable { case apps, settings }

struct HubTab: View {
    @State private var hub = Hub.shared
    @Environment(WatchModel.self) private var watch
    /// More's stack: the ask notification puts Apps on it (and Apps opens that app's page)
    @State private var path = NavigationPath()
    var body: some View {
        NavigationStack(path: $path) {
            PageScroll(title: "More") {
                HStack(spacing: 10) {
                    Circle().fill(hub.linked ? TDColor.good : TDColor.muted).frame(width: 8, height: 8)
                    Text(hub.linked ? "Watch connected" : "Watch not connected").font(.subheadline.weight(.medium))
                    Spacer()
                    if let a = hub.lastApp { Pill(text: a, color: TDColor.accent) }
                }
                .glassCard(22)
                // FMC Companion's watch tools: the apps on the watch (and the store's), firmware and the App Loader
                VStack(spacing: 0) {
                    tool(EmptyView(), "square.grid.3x3.fill", .blue, "Apps", appsDetail, badge: Permissions.shared.pending.count,
                         first: true, route: .apps)
                    tool(FirmwareView(), "cpu.fill", .gray, "Firmware & App Loader", firmwareDetail,
                         badge: FirmwareModel.shared.updates(watch.loader))
                }
                .glassCard(22)
                VStack(spacing: 0) {
                    row(SpotifyPage(), "music.note", .green, "Spotify", hub.spotify.signedIn ? "Signed in" : "Sign in", SpotifyService.app, first: true)
                    row(YouTubeMusicPage(), "play.circle.fill", .red, "YouTube Music",
                        hub.youtube.signedIn ? "Signed in: plays on the watch" : "Sign in to play on the watch", YouTubeMusicService.app)
                    row(SpotifyPlayerPage(), "music.note.list", .green, "Spotify player",
                        hub.spotify.signedIn && hub.youtube.signedIn ? "Spotify's songs, played from YouTube"
                            : "Sign in to Spotify and YouTube", SpotifyPlayerService.app)
                    row(GeminiPage(), "sparkles", .blue, "Gemini", Secrets.geminiKey.isEmpty ? "Add API key" : "Ready", GeminiService.app)
                    row(MapsPage(), "map.fill", .orange, "Offline Maps", "A map the watch draws, with GPS", MapsService.app)
                    row(AtlasPage(), "map", TDColor.accent, "Maps",
                        hub.atlas.nav.active ? "Navigating" : "Search, routes and turns on the watch", AtlasService.app)
                    row(NavPage(), "location.north.line.fill", TDColor.accent, "Navigation",
                        hub.nav.active ? "Navigating" : "Turn by turn on the watch", NavService.app)
                    row(PhotosPage(), "photo.fill", .purple, "Photos", "Your gallery on the watch", PhotosService.app)
                    row(BrowserPage(), "globe", .blue, "Browser", "The web on the watch; sign in to sites here", BrowserService.app)
                    row(MailPage(), "envelope.fill", .red, "Mail", mailDetail, MailService.app)
                    row(NotesPage(), "note.text", .yellow, "Notes", "Your notes and reminders", NotesService.app)
                    row(WhatsAppPage(), "message.fill", Color(red: 0.15, green: 0.8, blue: 0.4), "WhatsApp",
                        hub.whatsapp.linked ? "Linked" : "Link with a pairing code", WhatsAppService.app)
                }
                .glassCard(22)
                Text("Each runs only while its app is open on the watch or while you use it here; Mail checks the inbox each minute while it is open.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
                VStack(spacing: 0) {
                    tool(EmptyView(), "gearshape.fill", .gray, "Settings", String(localized: "Appearance, accent, about"),
                         badge: 0, first: true, route: .settings)
                }
                .glassCard(22)
            }
            .navigationDestination(for: HubRoute.self) { r in
                switch r {
                case .apps: AppsPage()
                case .settings: SettingsPage()
                }
            }
            // updates are checked once the watch is read: the Firmware row shows them
            .task(id: watch.phase) { if case .checked = watch.phase { await FirmwareModel.shared.refresh() } }
        }
        .onChange(of: Permissions.shared.open, initial: true) { if $1 != nil, path.isEmpty { path.append(HubRoute.apps) } }
    }

    private var appsDetail: String {
        guard let l = watch.listedLoader else { return String(localized: "Install, update and order the watch's apps") }
        return String(localized: "\(l.apps.count) on the watch")
    }

    private var firmwareDetail: String {
        guard let l = watch.loader else { return String(localized: "Bundled loader \(BundledLoader.label)") }
        return FirmwareModel.shared.loaderUpdate(l) ? String(localized: "App Loader update: \(BundledLoader.label)")
            : String(localized: "Stub \(l.stub.version) · loader up to date")
    }

    private func tool<D: View>(_ dest: D, _ symbol: String, _ color: Color, _ title: String, _ detail: String,
                               badge: Int, first: Bool = false, route: HubRoute? = nil) -> some View {
        VStack(spacing: 0) {
            if !first { Divider().overlay(TDColor.line).padding(.vertical, 8) }
            if let route {
                NavigationLink(value: route) { toolLabel(symbol, color, title, detail, badge) }.buttonStyle(.plain)
            } else {
                NavigationLink { dest } label: { toolLabel(symbol, color, title, detail, badge) }.buttonStyle(.plain)
            }
        }
    }

    private func toolLabel(_ symbol: String, _ color: Color, _ title: String, _ detail: String, _ badge: Int) -> some View {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: symbol, color: color, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).foregroundStyle(TDColor.text)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    CountBadge(count: badge)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
    }

    private var mailDetail: String {
        let m = hub.mail
        switch m.kind {
        case .gmail: return m.gmail.signedIn ? "Gmail, signed in" : "Sign in with Google"
        case .imap: return m.imap.configured ? (m.imap.address ?? "IMAP account") : "Add an IMAP account"
        }
    }

    private func row<D: View>(_ dest: D, _ symbol: String, _ color: Color, _ title: String, _ detail: String,
                              _ app: String, first: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !first { Divider().overlay(TDColor.line).padding(.vertical, 8) }
            NavigationLink { dest } label: {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: symbol, color: color, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).foregroundStyle(TDColor.text)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !hub.installed(app) && !hub.apps.isEmpty { Pill(text: "Not on watch", color: TDColor.muted) }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// A spinner and what is going on.
struct Working: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A button for slow work: a spinner and `busy` in its place until the work is done.
struct BusyButton: View {
    let title: String
    let busy: String
    var primary = true
    let action: () async -> Void
    @State private var running = false
    var body: some View {
        let b = Button {
            running = true
            Task { await action(); running = false }
        } label: {
            HStack(spacing: 8) {
                if running { ProgressView() }
                Text(running ? busy : title)
            }
        }
        .disabled(running)
        if primary { b.primaryButton() } else { b.secondaryButton() }
    }
}

private struct Status: View {
    let text: String?
    var body: some View {
        if let text { Text(text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
    }
}

struct SpotifyPage: View {
    @State private var s = Hub.shared.spotify
    @State private var client = Secrets.spotifyBuilt ? "" : Secrets.spotifyClient
    var body: some View {
        PageScroll(title: "Spotify") {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(symbol: "music.note", color: .green, title: s.signedIn ? (s.user ?? "Signed in") : "Not signed in",
                           detail: s.signedIn ? (s.premium ? "Premium: full control from the watch" : "Free or unknown: playback control needs Premium") : nil)
                if s.signedIn {
                    Button("Sign out", role: .destructive) { s.signOut() }.secondaryButton()
                } else {
                    TextField(Secrets.spotifyBuilt ? "Built in (type to replace)" : "Spotify app client ID", text: $client)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                        .onChange(of: client) { Secrets.spotifyClient = $1.trimmingCharacters(in: .whitespaces) }
                    BusyButton(title: "Sign in with Spotify", busy: "Signing in…") { await s.signIn() }
                        .disabled(Secrets.spotifyClient.isEmpty && client.isEmpty)
                }
                Status(text: s.status)
            }
            .glassCard()
            YouTubeAccountCard()
            VStack(alignment: .leading, spacing: 8) {
                Text("Setup, once").font(.headline)
                Text("1. developer.spotify.com › Dashboard › Create app.\n2. Redirect URI: cmfx://spotify, API: Web API.\n3. Paste its Client ID here and sign in.\n\nOn the watch: play, pause, skip, volume with the crown, like, your playlists, search and play, add to a playlist, and the Spotify Connect device to play on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .glassCard()
        }
    }
}

struct GeminiPage: View {
    @State private var key = Secrets.geminiBuilt ? "" : Secrets.geminiKey
    @State private var g = Hub.shared.gemini
    var body: some View {
        PageScroll(title: "Gemini") {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(symbol: "sparkles", color: .blue, title: "Gemini on the watch", detail: "Model \(g.model)")
                SecureField(Secrets.geminiBuilt ? "Built in (type to replace)" : "Gemini API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: key) { Secrets.geminiKey = $1.trimmingCharacters(in: .whitespaces) }
                Text("Get a free key at aistudio.google.com › Get API key. It stays in this iPhone's keychain.")
                    .font(.footnote).foregroundStyle(.secondary)
                BusyButton(title: "Check the key", busy: "Asking Gemini…", primary: false) { await g.check() }
                    .disabled(Secrets.geminiKey.isEmpty)
                Status(text: g.status)
            }
            .glassCard()
            VStack(alignment: .leading, spacing: 10) {
                Picker("Model", selection: $g.model) {
                    ForEach(Array(Set(g.models + [g.model, GeminiService.defaultModel])).sorted {
                        $0.localizedStandardCompare($1) == .orderedDescending
                    }, id: \.self) { m in
                        Text(m == GeminiService.defaultModel ? "\(m) (default)" : m).tag(m)
                    }
                }
                .pickerStyle(.navigationLink)
                Divider().overlay(TDColor.line)
                Picker("Thinking", selection: $g.effort) {
                    ForEach(GeminiService.Effort.allCases) { e in
                        Text(e == GeminiService.defaultEffort ? "\(e.title) (default)" : e.title).tag(e)
                    }
                }
                Text("More thinking answers harder questions, but the first words take longer to reach the watch. Models without a thinking setting ignore it.")
                    .font(.footnote).foregroundStyle(.secondary)
                if g.model != GeminiService.defaultModel || g.effort != GeminiService.defaultEffort {
                    Button("Back to the defaults") {
                        g.model = GeminiService.defaultModel
                        g.effort = GeminiService.defaultEffort
                    }
                    .font(.subheadline)
                }
            }
            .glassCard()
            .task(id: key) { await g.loadModels() }
        }
    }
}

struct MapsPage: View {
    @State private var m = Hub.shared.maps
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var centre = CLLocationCoordinate2D(latitude: 51.508, longitude: -0.128)
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false
    @State private var picked: String?
    @State private var confirmClean = false

    var body: some View {
        PageScroll(title: "Offline Maps") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(TDColor.muted)
                    TextField("Search a place", text: $query).onSubmit(search).submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(TDColor.muted)
                    }
                }
                if searching { Working(text: "Searching…") }
                ForEach(results) { p in
                    Button { show(p) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).foregroundStyle(TDColor.text)
                            Text(p.detail).font(.caption).foregroundStyle(TDColor.muted).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassCard()
            ZStack {
                Map(position: $camera) {
                    // what is saved: the whole area, and the streets round the centre
                    MapCircle(center: centre, radius: m.radiusKm * 1000)
                        .foregroundStyle(TDColor.accent.opacity(0.08)).stroke(TDColor.accent, lineWidth: 2)
                    MapCircle(center: centre, radius: min(m.detailKm, m.radiusKm) * 1000)
                        .foregroundStyle(TDColor.accent.opacity(0.12)).stroke(TDColor.accent.opacity(0.7), lineWidth: 1)
                }
                .onMapCameraChange(frequency: .continuous) { centre = $0.region.center }
                Circle().fill(TDColor.accent).frame(width: 8, height: 8).allowsHitTesting(false)
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            if let picked { Text(picked).font(.footnote).foregroundStyle(TDColor.muted).padding(.horizontal, 6) }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Area")
                    Slider(value: $m.radiusKm, in: 1...VectorPack.maxRadiusKm, step: 1)
                    Text("\(Int(m.radiusKm)) km").monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                HStack {
                    Text("Streets")
                    Slider(value: $m.detailKm, in: 1...VectorPack.maxDetailKm, step: 0.5)
                    Text(String(format: "%.1f km", min(m.detailKm, m.radiusKm))).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                Text("Main roads, water and towns reach \(Int(m.radiusKm)) km round the centre; streets and paths \(String(format: "%.1f", min(m.detailKm, m.radiusKm))) km. The watch draws the map itself, so it stays sharp at every zoom. \(m.cellCount) parts (empty ones are skipped). Open Offline Maps on the watch, then save.")
                    .font(.footnote).foregroundStyle(TDColor.muted)
                if let p = m.progress {
                    if let s = m.status { Working(text: s) }
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    Button("Stop", role: .destructive) { m.cancel() }.secondaryButton()
                } else {
                    Button("Save to watch") { m.build(at: centre) }.primaryButton()
                    Button("Clean storage on the watch", role: .destructive) { confirmClean = true }
                        .secondaryButton().disabled(m.cleaning)
                        .confirmationDialog("Delete everything Offline Maps keeps on the watch: the map, leftovers of older versions and the pins?",
                                            isPresented: $confirmClean, titleVisibility: .visible) {
                            Button("Clean storage", role: .destructive) { m.cleanWatch() }
                        }
                    if m.cleaning, let s = m.status { Working(text: s) } else { Status(text: m.status) }
                }
                Text("On the watch: the GPS is on while Offline Maps is open. Mark drops a pin where you are, Track records your path, Back leads you along it to the start, all with no phone. Hold the map or tap a pin for Walk or Drive route: the phone finds it once, then the watch follows it alone. Map data © OpenStreetMap contributors, OpenFreeMap.")
                    .font(.footnote).foregroundStyle(TDColor.muted)
            }
            .glassCard()
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task {
            defer { searching = false }
            results = await Place.search(q)
        }
    }

    private func show(_ p: Place) {
        let c = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
        let span = m.radiusKm * 2400
        withAnimation { camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: span, longitudinalMeters: span)) }
        centre = c
        picked = p.detail.isEmpty ? p.name : "\(p.name), \(p.detail)"
        results = []
        query = ""
    }
}

struct AtlasPage: View {
    @State private var a = Hub.shared.atlas
    var body: some View {
        PageScroll(title: "Maps") {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "map", color: TDColor.accent,
                           title: a.nav.active ? (a.nav.destination?.name ?? "Navigating") : "Maps on the watch",
                           detail: "Open Maps on the watch. It works like Google Maps: search or pick a kind of place (food, fuel, hotels …) and the places come as pins with a sheet at the bottom (pull it up for the list); tap a pin for its card, hold the map to drop one; Directions shows car, bike and on foot and the routes to pick from; then Start, turn by turn. Search an area to move the map there. The watch draws the map itself from OpenStreetMap data sent from here (© OpenStreetMap contributors, OpenFreeMap).")
                if a.nav.active {
                    Button("Stop", role: .destructive) { a.nav.stop() }.primaryButton()
                }
                if let w = a.nav.working { Working(text: w) }
                Status(text: a.status ?? a.nav.status)
            }
            .glassCard()
        }
    }
}

struct NavPage: View {
    @State private var n = Hub.shared.nav
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false
    /// the next place searched for or pinned goes in as a stop
    @State private var addingStop = false
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    /// a place tapped on the map
    @State private var pin: CLLocationCoordinate2D?

    private var planned: Bool { !n.active && n.destination != nil && !n.coords.isEmpty }

    var body: some View {
        PageScroll(title: "Navigation") {
            if n.active { navigating }
            VStack(alignment: .leading, spacing: 12) {
                if !n.active {
                    Picker("Mode", selection: Binding(get: { n.walking }, set: { w in
                        n.walking = w
                        replan()
                    })) {
                        Text("Walk").tag(true)
                        Text("Drive").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                HStack {
                    TextField(addingStop ? "Add a stop…" : "Where to? (or a Google Maps link)", text: $query)
                        .onSubmit(search)
                    if addingStop {
                        Button("Cancel") { addingStop = false; results = [] }.font(.footnote)
                    }
                }
                if !addingStop && !planned {
                    PasteButton(payloadType: String.self) { texts in
                        guard let t = texts.first else { return }
                        Task { @MainActor in
                            query = t
                            await go(link: t)
                        }
                    }
                    .buttonBorderShape(.capsule)
                }
                if searching { Working(text: "Searching…") }
                if let w = n.working { Working(text: w) }
                ForEach(results) { p in
                    HStack {
                        // the row: the ways there to look at (or the stop added); ▶: off at once
                        Button { Task { await pick(p.item) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundStyle(TDColor.text)
                                Text(p.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if !addingStop && !n.active {
                            Button {
                                results = []
                                Task { await n.start(to: p.item) }
                            } label: {
                                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(TDColor.accent)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Start now")
                        }
                    }
                    .disabled(n.working != nil)
                }
                Status(text: n.status)
            }
            .glassCard()
            map
            if planned { plan }
        }
    }

    // --- the map: the ways there, the stops, a pin where it is tapped

    private var map: some View {
        VStack(spacing: 8) {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    if !n.active {
                        ForEach(Array(n.alternativeLines.enumerated()), id: \.offset) { k, line in
                            if k != n.chosen { MapPolyline(coordinates: line).stroke(.gray.opacity(0.7), lineWidth: 5) }
                        }
                    }
                    if !n.coords.isEmpty { MapPolyline(coordinates: n.coords).stroke(TDColor.accent, lineWidth: 6) }
                    ForEach(Array(n.stops.enumerated()), id: \.offset) { k, s in
                        Marker(s.name ?? "Stop \(k + 1)", systemImage: "\(k + 1).circle", coordinate: s.placemark.coordinate)
                            .tint(.orange)
                    }
                    if let d = n.destination { Marker(d.name ?? "There", coordinate: d.placemark.coordinate).tint(.red) }
                    if let pin { Marker("Pin", systemImage: "mappin", coordinate: pin).tint(.purple) }
                }
                .onTapGesture { p in
                    guard !n.active, let c = proxy.convert(p, from: .local) else { return }
                    pin = c
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            if let pin, !n.active {
                HStack {
                    Button("Route here") {
                        self.pin = nil
                        Task { await pick(pinned(pin), asStop: false) }
                    }
                    .buttonStyle(.borderedProminent)
                    if n.destination != nil {
                        Button("Add stop here") {
                            self.pin = nil
                            Task { await pick(pinned(pin), asStop: true) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(n.stops.count >= 3)
                    }
                    Spacer()
                    Button { self.pin = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            } else if !n.active && !planned {
                Text("Tap the map to drop a pin.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // --- the plan: the ways (pick one), the stops, Start

    private var plan: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(n.destination?.name ?? "There").font(.headline)
                Spacer()
                Button { n.clearPlan(); camera = .userLocation(fallback: .automatic) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            let rows = n.alternativeRows
            if rows.count >= 2 {
                ForEach(Array(rows.enumerated()), id: \.offset) { k, r in
                    Button { n.choose(k) } label: {
                        way(secs: r.secs, metres: r.metres, via: r.via, on: k == n.chosen)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                way(secs: n.expected, metres: n.length, via: nil, on: true)
            }
            ForEach(Array(n.stops.enumerated()), id: \.offset) { k, s in
                HStack {
                    Image(systemName: "\(k + 1).circle.fill").foregroundStyle(.orange)
                    Text(s.name ?? "Stop").lineLimit(1)
                    Spacer()
                    Button { removeStop(k) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.red)
                }
            }
            HStack {
                Button { addingStop = true; results = []; query = "" } label: { Label("Add stop", systemImage: "plus") }
                    .buttonStyle(.bordered)
                    .disabled(n.stops.count >= 3 || n.working != nil)
                Button { Task { await n.startPlanned() } } label: {
                    Label("Start", systemImage: "location.north.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(n.working != nil)
            }
        }
        .glassCard()
    }

    private func way(secs: Double, metres: Double, via: String?, on: Bool) -> some View {
        HStack {
            Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? TDColor.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.time(secs)) · \(Self.km(metres))").foregroundStyle(TDColor.text)
                Text("Arrive \(Date.now.addingTimeInterval(secs).formatted(date: .omitted, time: .shortened))"
                     + (via.map { " · via \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    static func time(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m < 60 ? "\(max(m, 1)) min" : "\(m / 60) hr \(m % 60) min"
    }

    static func km(_ m: Double) -> String {
        m < 1000 ? "\(Int(m / 10) * 10) m" : String(format: "%.1f km", m / 1000)
    }

    private var navigating: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbol: "location.north.line.fill", color: TDColor.accent, title: n.destination?.name ?? "Navigating",
                       detail: "Turns go to the watch. Location stops when you arrive.")
            Button("Stop", role: .destructive) { n.end() }.primaryButton()
        }
        .glassCard()
    }

    // --- picking

    private func pinned(_ c: CLLocationCoordinate2D) -> MKMapItem {
        let i = MKMapItem(placemark: MKPlacemark(coordinate: c))
        i.name = "Dropped pin"
        return i
    }

    /// A place: a stop on the plan (adding one), else the ways there to look at (a new plan, no stops).
    private func pick(_ item: MKMapItem, asStop: Bool? = nil) async {
        results = []
        query = ""
        if asStop ?? addingStop, let d = n.destination {
            addingStop = false
            n.stops.append(item)
            if await n.plan(to: d) { camera = .automatic }
            return
        }
        addingStop = false
        n.stops = []
        if await n.plan(to: item) { camera = .automatic }
    }

    private func removeStop(_ k: Int) {
        guard n.stops.indices.contains(k) else { return }
        n.stops.remove(at: k)
        replan()
    }

    /// The plan again (a stop gone, walk or drive changed).
    private func replan() {
        guard planned, let d = n.destination else { return }
        Task { _ = await n.plan(to: d) }
    }

    /// A Google Maps link or "lat, lng": the ways there.
    private func go(link: String) async {
        n.status = "Reading the link…"
        guard let p = await MapsLink.place(in: link) else {
            n.status = "No place found in that link"
            return
        }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: p.coordinate))
        item.name = p.name
        n.status = nil
        await pick(item)
    }

    private func search() {
        if !addingStop, MapsLink.parse(query) != nil || MapsLink.firstURL(query) != nil {
            Task { await go(link: query) }
            return
        }
        let q = query
        searching = true
        Task {
            defer { searching = false }
            results = await Place.search(q)
            if results.isEmpty { n.status = "Nothing found for “\(q)”" } else { n.status = nil }
        }
    }
}

struct PhotosPage: View {
    @State private var p = Hub.shared.photos
    var body: some View {
        PageScroll(title: "Photos") {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(symbol: "photo.on.rectangle", color: .purple, title: "Gallery on the watch",
                           detail: p.allowed ? "Your newest \(PhotosService.max) photos" : "Needs access to your photos")
                if p.access == .notDetermined {
                    Button("Allow access to all photos") { Task { await p.requestAccess() } }.primaryButton()
                } else if !p.allowed {
                    Text("Photo access is off. Turn on Full Access in Settings › CMFX › Photos.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }.secondaryButton()
                } else if p.access == .limited {
                    Text("Limited access: only the photos you allowed show. Choose Full Access in Settings › CMFX › Photos for all of them.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Open Photos on the watch: a grid of thumbnails or a list of names (tap the heading). Tap one to open it; the crown goes to the next, a double tap zooms. Thumbnails are sent only as you scroll to them and stay on the watch.")
                    .font(.footnote).foregroundStyle(.secondary)
                Status(text: p.status)
            }
            .glassCard()
        }
    }
}

struct MailPage: View {
    @State private var m = Hub.shared.mail
    var body: some View {
        PageScroll(title: "Mail") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Account", selection: $m.kind) {
                    ForEach(MailKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(m.kind == .gmail ? "Gmail through Google sign-in and your own OAuth client."
                     : "Any IMAP mailbox (Gmail, iCloud, Yahoo, Zoho, Fastmail, …) with an app password.")
                    .font(.footnote).foregroundStyle(.secondary)
                Status(text: m.status)
            }
            .glassCard()
            if m.kind == .gmail { GmailSettings() } else { ImapSettings() }
        }
    }
}

private struct GmailSettings: View {
    @State private var g = Hub.shared.mail.gmail
    @State private var client = Secrets.googleBuilt ? "" : Secrets.googleClient
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(symbol: "envelope.fill", color: .red, title: g.signedIn ? (g.email ?? "Signed in") : "Not signed in",
                       detail: g.signedIn ? "Gmail: your newest inbox threads on the watch" : nil)
            if g.signedIn {
                Button("Sign out", role: .destructive) { g.signOut() }.secondaryButton()
            } else {
                TextField(Secrets.googleBuilt ? "Built in (type to replace)" : "Google OAuth client ID (iOS)", text: $client)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    .onChange(of: client) { Secrets.googleClient = $1.trimmingCharacters(in: .whitespaces) }
                BusyButton(title: "Sign in with Google", busy: "Signing in…") { await g.signIn() }
                    .disabled(Secrets.googleClient.isEmpty && client.isEmpty)
            }
            Status(text: g.status)
        }
        .glassCard()
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup, once").font(.headline)
            Text("1. console.cloud.google.com › a project › enable the Gmail API.\n2. OAuth consent screen: add yourself as a test user.\n3. Credentials › Create OAuth client ID › iOS, bundle ID app.cmfx.ios.\n4. Paste its Client ID here and sign in.\n\nOn the watch: your 11 newest inbox threads, the latest email of one as text (it is marked read), quick or typed replies, • Archive and • Mark unread. A new email buzzes the watch while Mail is open.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .glassCard()
    }
}

private struct ImapSettings: View {
    @State private var b = Hub.shared.mail.imap
    @State private var a = ImapAccount.saved ?? ImapAccount()
    @State private var password = ""
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    private var hasPassword: Bool { !password.isEmpty || (b.account != nil && ImapAccount.password != nil) }
    private var pw: String { password.isEmpty ? (ImapAccount.password ?? "") : password }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbol: "envelope.fill", color: .red, title: b.configured ? (b.address ?? "IMAP account") : "No account yet",
                       detail: b.configured ? "IMAP: your newest inbox emails on the watch" : nil)
            TextField("Email address", text: $a.email)
                .keyboardType(.emailAddress).textContentType(.username)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: a.email) { old, new in fill(old, new) }
            SecureField(b.account != nil && ImapAccount.password != nil ? "Password saved (type to replace)" : "App password", text: $password)
                .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
            server("IMAP server", $a.imapHost, $a.imapPort)
            server("SMTP server", $a.smtpHost, $a.smtpPort)
            if ImapAccount.unsupported(a.email) {
                Text("Outlook and Hotmail are not supported: Microsoft turned off password sign-in for IMAP.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Button("Save account") {
                b.save(a, password: password.isEmpty ? nil : password)
                password = ""
                result = nil
            }
            .primaryButton().disabled(!a.complete || !hasPassword)
            Button(testing ? "Testing…" : "Test connection") {
                testing = true
                result = nil
                let account = a, p = pw
                Task {
                    let err = await ImapBackend.test(account, password: p)
                    result = err.map { (false, $0) } ?? (true, "Signed in to IMAP and SMTP.")
                    testing = false
                }
            }
            .secondaryButton().disabled(testing || !a.complete || !hasPassword)
            if let result {
                Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(result.ok ? TDColor.good : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if b.account != nil {
                Button("Remove account", role: .destructive) {
                    b.remove()
                    a = ImapAccount()
                    password = ""
                    result = nil
                }
                .secondaryButton()
            }
        }
        .glassCard()
        VStack(alignment: .leading, spacing: 8) {
            Text("Use an app password").font(.headline)
            Text("Your mail provider wants an app password here, not your account password.\n\nGmail: turn on 2-Step Verification, then make one at myaccount.google.com/apppasswords.\niCloud: appleid.apple.com › Sign-In and Security › App-Specific Passwords.\nYahoo: Account Info › Account Security › Generate app password.\nZoho and Fastmail: an app password from the account's security settings.\n\nOutlook and Hotmail are not supported (Microsoft turned off password sign-in).\n\nThe password stays in this iPhone's keychain. Ports: 993 for IMAP; 465 (TLS) or 587 (STARTTLS) for SMTP.\n\nOn the watch: your 11 newest inbox emails, one as text (it is marked read), quick or typed replies, • Archive and • Mark unread. A new email buzzes the watch while Mail is open.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .glassCard()
    }

    private func server(_ title: String, _ host: Binding<String>, _ port: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            TextField(title, text: host)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Port", value: port, format: .number.grouping(.never))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 64)
        }
    }

    /// A known domain fills its servers (when the domain changed, so a server typed by hand stays).
    private func fill(_ old: String, _ new: String) {
        func domain(_ e: String) -> Substring? { e.contains("@") ? e.split(separator: "@").last : nil }
        guard domain(old)?.lowercased() != domain(new)?.lowercased(), let p = ImapAccount.preset(new) else { return }
        a.imapHost = p.imap
        a.imapPort = p.imapPort
        a.smtpHost = p.smtp
        a.smtpPort = p.smtpPort
    }
}

struct NotesPage: View {
    @State private var n = Hub.shared.notes
    var body: some View {
        PageScroll(title: "Notes") {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(symbol: "note.text", color: .yellow, title: "Notes and Reminders",
                           detail: n.allowed ? "Your reminder lists show on the watch too" : "Reminders need access")
                if n.access == .notDetermined {
                    Button("Allow access to Reminders") { Task { await n.requestAccess() } }.secondaryButton()
                } else if !n.allowed {
                    Text("Reminders access is off. Turn on Full Access in Settings › CMFX › Reminders.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("On the watch: New note (what you type first is its title), your notes, then your reminder lists. Tap a reminder to tick it; type to add a line or a reminder.")
                    .font(.footnote).foregroundStyle(.secondary)
                Status(text: n.status)
            }
            .glassCard()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Notes").font(.headline)
                    Spacer()
                    NavigationLink { NoteEditor(note: nil) } label: { Image(systemName: "plus").font(.headline) }
                }
                if n.store.notes.isEmpty {
                    Text("No notes yet.").font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                }
                ForEach(n.store.notes) { note in
                    Divider().overlay(TDColor.line).padding(.vertical, 8)
                    NavigationLink { NoteEditor(note: note) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title.isEmpty ? "Untitled" : note.title).font(.subheadline.weight(.medium)).foregroundStyle(TDColor.text)
                                Text(note.lines.first { !$0.isEmpty } ?? "No text yet").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(note.modified, style: .date).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassCard()
        }
    }
}

/// A note: its title and its lines (one a line on the watch). Saved when you leave.
struct NoteEditor: View {
    let note: Note?
    @State private var title = ""
    @State private var text = ""
    @State private var deleted = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PageScroll(title: note == nil ? "New note" : "Note") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: $title).font(.headline)
                Divider().overlay(TDColor.line)
                TextEditor(text: $text).frame(minHeight: 240).scrollContentBackground(.hidden)
                if note != nil {
                    Button("Delete note", role: .destructive) {
                        deleted = true
                        if let note { Hub.shared.notes.store.delete(note.id) }
                        dismiss()
                    }.secondaryButton()
                }
            }
            .glassCard()
        }
        .onAppear {
            title = note?.title ?? ""
            text = note?.lines.joined(separator: "\n") ?? ""
        }
        .onDisappear(perform: save)
    }

    private func save() {
        guard !deleted else { return }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let t = title.trimmingCharacters(in: .whitespaces)
        let store = Hub.shared.notes.store
        if var n = note.flatMap({ store.note($0.id) }) {
            n.title = t
            n.lines = lines
            store.update(n)
        } else if note == nil, !t.isEmpty || !lines.isEmpty {
            store.add(title: t.isEmpty ? String(lines[0].prefix(40)) : t, lines: t.isEmpty ? Array(lines.dropFirst()) : lines)
        }
    }
}

struct WhatsAppPage: View {
    @State private var w = Hub.shared.whatsapp
    @State private var phone = ""
    @State private var copied = false

    private var connectionText: String {
        switch w.connection {
        case "synced", "connected": "Online now"
        case "unlinked": "Not linked"
        default: "Offline: online only while the watch app is open"
        }
    }

    var body: some View {
        PageScroll(title: "WhatsApp") {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(symbol: "message.fill", color: .green, title: w.linked ? "Linked as \(w.me.isEmpty ? "your account" : w.me)" : "Not linked",
                           detail: w.linked ? connectionText : "CMFX becomes a linked device, like WhatsApp Web")
                if w.linked {
                    Button("Unlink", role: .destructive) { Task { await w.unlink() } }.secondaryButton()
                } else if let code = w.code {
                    Text(code)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                    Button(copied ? "Copied" : "Copy code") {
                        UIPasteboard.general.string = code.replacingOccurrences(of: "-", with: "")
                        copied = true
                    }.secondaryButton().frame(maxWidth: .infinity)
                    Text("On the phone with your WhatsApp: WhatsApp › Settings › Linked devices › Link a device › Link with phone number instead, then type this code. It works for about 2 minutes; keep CMFX open until it says linked.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Cancel") { w.cancelPairing() }.secondaryButton()
                } else {
                    TextField("Your WhatsApp number, with country code (+…)", text: $phone)
                        .keyboardType(.phonePad).textContentType(.telephoneNumber).autocorrectionDisabled()
                    Button(w.pairing ? "Asking WhatsApp…" : "Get pairing code") {
                        copied = false
                        Task { await w.pair(phone) }
                    }
                    .primaryButton()
                    .disabled(w.pairing || phone.filter(\.isNumber).count < 7)
                    Text("International format (E.164): + then the country code and number, no leading 0.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Status(text: w.status)
            }
            .glassCard()
            if w.linked {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Keep chats up to date", isOn: $w.keepSynced)
                    Text("So WhatsApp on the watch opens on your new messages instead of fetching them first (slow after a long time offline). CMFX catches up now and then, at most every 15 minutes: when it is awake for the watch anyway, or when iOS allows a background refresh. Each time it goes online for a few seconds and straight back offline. Never in Low Power Mode, no timers, nothing kept running.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if w.keepSynced, let t = w.lastSync {
                        Text("Last caught up \(t.formatted(.relative(presentation: .named)))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .glassCard()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("On the watch").font(.headline)
                Text("Open WhatsApp on the watch: your 12 newest chats and the last 12 messages of each. Reply with a quick reply or by typing; a new message buzzes the watch while the app is open. CMFX goes online only while the watch app is open and offline a minute after, so it costs no battery in between; the session and chats stay on this iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("CMFX is an unofficial WhatsApp client (whatsmeow). That is against WhatsApp's terms; bans of linked devices are rare but possible. Use it at your own risk.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .glassCard()
        }
        .onAppear { w.pageAppeared(true) }
        .onDisappear { w.pageAppeared(false) }
    }
}

/// Settings in its own stack (Overview's sheet).
struct SettingsTab: View {
    var body: some View { NavigationStack { SettingsPage() } }
}

/// Settings: Overview's sheet, and More › Settings.
struct SettingsPage: View {
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    var body: some View {
        PageScroll(title: "Settings") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Appearance").font(.headline)
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Text("Accent").font(.headline)
                    AccentPicker()
                }
                .glassCard()
                PermissionsCard()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        AppMark(size: 44)
                        VStack(alignment: .leading) {
                            Text("CMFX").font(.headline)
                            Text("For the CMF Watch Pro 2, next to Nothing X").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Built on FMC Companion (MIT) and TwinDesk's look. No analytics.").font(.caption).foregroundStyle(.secondary)
                }
                .glassCard()
            }
    }
}
