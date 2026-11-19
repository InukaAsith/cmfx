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
                    row(MailPage(), "envelope.fill", .red, "Mail", hub.mail.signedIn ? "Gmail, signed in" : "Sign in with Google", MailService.app)
                    row(NotesPage(), "note.text", .yellow, "Notes", "Your notes and reminders", NotesService.app)
                    row(WhatsAppPage(), "message.fill", Color(red: 0.15, green: 0.8, blue: 0.4), "WhatsApp", "Not linked yet", "WhatsApp")
                }
                .glassCard(22)
                Text("Each runs only while its app is open on the watch or while you use it here; Mail checks the inbox each minute while it is open.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
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
                    Button("Sign in with Spotify") { Task { await s.signIn() } }.primaryButton().disabled(Secrets.spotifyClient.isEmpty && client.isEmpty)
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
    var body: some View {
        PageScroll(title: "Offline Maps") {
            ZStack {
                Map(position: $camera)
                    .onMapCameraChange(frequency: .onEnd) { centre = $0.region.center }
                Circle().strokeBorder(TDColor.accent, lineWidth: 2).frame(width: 150, height: 150).allowsHitTesting(false)
                Circle().fill(TDColor.accent).frame(width: 8, height: 8)
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Radius")
                    Slider(value: $m.radiusKm, in: 0.5...5, step: 0.5)
                    Text(String(format: "%.1f km", m.radiusKm)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                Text("\(m.tileCount(centre)) tiles, zoom \(m.zooms.lowerBound)–\(m.zooms.upperBound). Open Offline Maps on the watch, then save.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let p = m.progress {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    Button("Stop", role: .destructive) { m.cancel() }.secondaryButton()
                } else {
                    Button("Save to watch") { m.build(at: centre) }.primaryButton()
                }
                Status(text: m.status)
                Text("Map data © OpenStreetMap contributors").font(.caption2).foregroundStyle(.tertiary)
            }
            .glassCard()
        }
    }
}

struct NavPage: View {
    @State private var n = Hub.shared.nav
    @State private var query = ""
    @State private var results: [MKMapItem] = []
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
                TextField("Where to?", text: $query).onSubmit(search)
                ForEach(results, id: \.self) { item in
                    Button { Task { await n.start(to: item) } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "").foregroundStyle(TDColor.text)
                            Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                Status(text: n.status)
            }
            .glassCard()
        }
    }

    private func search() {
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = query
        Task { results = (try? await MKLocalSearch(request: r).start().mapItems.prefix(8).map { $0 }) ?? [] }
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
    @State private var client = Secrets.googleBuilt ? "" : Secrets.googleClient
    var body: some View {
        PageScroll(title: "Mail") {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(symbol: "envelope.fill", color: .red, title: m.signedIn ? (m.email ?? "Signed in") : "Not signed in",
                           detail: m.signedIn ? "Gmail: your newest inbox threads on the watch" : nil)
                if m.signedIn {
                    Button("Sign out", role: .destructive) { m.signOut() }.secondaryButton()
                } else {
                    TextField(Secrets.googleBuilt ? "Built in (type to replace)" : "Google OAuth client ID (iOS)", text: $client)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                        .onChange(of: client) { Secrets.googleClient = $1.trimmingCharacters(in: .whitespaces) }
                    Button("Sign in with Google") { Task { await m.signIn() } }.primaryButton().disabled(Secrets.googleClient.isEmpty && client.isEmpty)
                }
                Status(text: m.status)
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
    var body: some View {
        PageScroll(title: "WhatsApp") {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "message.fill", color: .green, title: "Not linked yet")
                Text("iOS gives no app your WhatsApp chats. The watch app works with a linked-device bridge (WhatsApp Web) running on a computer; linking from the iPhone comes later.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .glassCard()
        }
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
