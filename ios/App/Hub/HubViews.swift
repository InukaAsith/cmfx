import MapKit
import PhotosUI
import SwiftUI

// The Hub tab: the watch apps that need the phone, each with its own page.

struct HubTab: View {
    @State private var hub = Hub.shared
    var body: some View {
        NavigationStack {
            PageScroll(title: "Hub") {
                HStack(spacing: 10) {
                    Circle().fill(hub.linked ? TDColor.good : TDColor.muted).frame(width: 8, height: 8)
                    Text(hub.linked ? "Watch connected" : "Watch not connected").font(.subheadline.weight(.medium))
                    Spacer()
                    if let a = hub.lastApp { Pill(text: a, color: TDColor.accent) }
                }
                .glassCard(22)
                VStack(spacing: 0) {
                    row(SpotifyPage(), "music.note", .green, "Spotify", hub.spotify.signedIn ? "Signed in" : "Sign in", SpotifyService.app, first: true)
                    row(GeminiPage(), "sparkles", .blue, "Gemini", Secrets.geminiKey.isEmpty ? "Add API key" : "Ready", GeminiService.app)
                    row(MapsPage(), "map.fill", .orange, "Offline Maps", "Save a region to the watch", MapsService.app)
                    row(NavPage(), "location.north.line.fill", TDColor.accent, "Navigation",
                        hub.nav.active ? "Navigating" : "Turn by turn on the watch", NavService.app)
                    row(PhotosPage(), "photo.fill", .purple, "Photos", "Your gallery on the watch", PhotosService.app)
                    row(MailPage(), "envelope.fill", .red, "Mail", mailDetail, MailService.app)
                    row(NotesPage(), "note.text", .yellow, "Notes", "Your notes and reminders", NotesService.app)
                    row(WhatsAppPage(), "message.fill", Color(red: 0.15, green: 0.8, blue: 0.4), "WhatsApp",
                        hub.whatsapp.linked ? "Linked" : "Link with a pairing code", WhatsAppService.app)
                }
                .glassCard(22)
                Text("Each runs only while its app is open on the watch or while you use it here; Mail checks the inbox each minute while it is open.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
        }
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
                CardHeader(symbol: "sparkles", color: .blue, title: "Gemini on the watch", detail: "Model \(GeminiService.model)")
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
                Map(position: $camera)
                    .onMapCameraChange(frequency: .onEnd) { centre = $0.region.center }
                Circle().strokeBorder(TDColor.accent, lineWidth: 2).frame(width: 150, height: 150).allowsHitTesting(false)
                Circle().fill(TDColor.accent).frame(width: 8, height: 8)
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            if let picked { Text(picked).font(.footnote).foregroundStyle(TDColor.muted).padding(.horizontal, 6) }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Radius")
                    Slider(value: $m.radiusKm, in: 0.5...5, step: 0.5)
                    Text(String(format: "%.1f km", m.radiusKm)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                // zoom 10 shows a city, 18 single houses
                Stepper(value: Binding(get: { m.zooms.lowerBound },
                                       set: { m.zooms = $0...max($0, m.zooms.upperBound) }), in: 10...18) {
                    HStack { Text("Farthest zoom"); Spacer(); Text("\(m.zooms.lowerBound)").monospacedDigit() }
                }
                Stepper(value: Binding(get: { m.zooms.upperBound },
                                       set: { m.zooms = min($0, m.zooms.lowerBound)...$0 }), in: 10...18) {
                    HStack { Text("Closest zoom"); Spacer(); Text("\(m.zooms.upperBound)").monospacedDigit() }
                }
                let tiles = m.tileCount(centre)
                Text(tiles > 400 ? "\(tiles) tiles: too many (400 at most). Make the radius smaller or the closest zoom lower."
                     : "\(tiles) tiles. Open Offline Maps on the watch, then save.")
                    .font(.footnote).foregroundStyle(tiles > 400 ? TDColor.accent : TDColor.muted)
                if let p = m.progress {
                    if let s = m.status { Working(text: s) }
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    Button("Stop", role: .destructive) { m.cancel() }.secondaryButton()
                } else {
                    Button("Save to watch") { m.build(at: centre) }.primaryButton().disabled(tiles > 400)
                    Status(text: m.status)
                }
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
        withAnimation { camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 4000, longitudinalMeters: 4000)) }
        centre = c
        picked = p.detail.isEmpty ? p.name : "\(p.name), \(p.detail)"
        results = []
        query = ""
    }
}

struct NavPage: View {
    @State private var n = Hub.shared.nav
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false
    var body: some View {
        PageScroll(title: "Navigation") {
            if n.active {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(symbol: "location.north.line.fill", color: TDColor.accent, title: n.destination?.name ?? "Navigating",
                               detail: "Turns go to the watch. Location stops when you arrive.")
                    Button("Stop", role: .destructive) { n.stop() }.primaryButton()
                }
                .glassCard()
            }
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: $n.walking) {
                    Text("Walk").tag(true)
                    Text("Drive").tag(false)
                }
                .pickerStyle(.segmented)
                TextField("Where to? (or a Google Maps link)", text: $query).onSubmit(search)
                PasteButton(payloadType: String.self) { texts in
                    guard let t = texts.first else { return }
                    Task { @MainActor in
                        query = t
                        await go(link: t)
                    }
                }
                .buttonBorderShape(.capsule)
                Text("From Google Maps: drop a pin (or open a place) › Share › Copy, then Paste here.")
                    .font(.caption).foregroundStyle(.secondary)
                if searching { Working(text: "Searching…") }
                if let w = n.working { Working(text: w) }
                ForEach(results) { p in
                    Button { Task { await n.start(to: p.item) } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).foregroundStyle(TDColor.text)
                            Text(p.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(n.working != nil)
                }
                Status(text: n.status)
            }
            .glassCard()
        }
    }

    /// A Google Maps link or "lat, lng": straight to it.
    private func go(link: String) async {
        n.status = "Reading the link…"
        guard let p = await MapsLink.place(in: link) else {
            n.status = "No place found in that link"
            return
        }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: p.coordinate))
        item.name = p.name
        results = []
        await n.start(to: item)
    }

    private func search() {
        if MapsLink.parse(query) != nil || MapsLink.firstURL(query) != nil {
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

struct SettingsTab: View {
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    var body: some View {
        NavigationStack {
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
}
