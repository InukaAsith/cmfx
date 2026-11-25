import SwiftUI

// CMFX's start: the watch, Navigation and recent notes as cards, the other apps as icons. The bar holds Overview,
// Navigation, Notes, Watch and Watch faces (FMC Companion's catalog, the one part of it kept).

/// A feature: its page, look and one line of state.
private struct Feature: Identifiable {
    let id: String
    let symbol: String
    let color: Color
    let app: String
    let detail: String
}

@MainActor private func features(_ hub: Hub) -> [Feature] {
    let mail: String = switch hub.mail.kind {
    case .gmail: hub.mail.gmail.signedIn ? "Gmail" : "Sign in"
    case .imap: hub.mail.imap.configured ? "IMAP" : "Add account"
    }
    return [
        Feature(id: "WhatsApp", symbol: "message.fill", color: Color(red: 0.15, green: 0.8, blue: 0.4),
                app: WhatsAppService.app, detail: hub.whatsapp.linked ? "Linked" : "Link"),
        Feature(id: "Mail", symbol: "envelope.fill", color: .red, app: MailService.app, detail: mail),
        Feature(id: "Notes", symbol: "note.text", color: .yellow, app: NotesService.app, detail: "Notes, reminders"),
        Feature(id: "Photos", symbol: "photo.fill", color: .purple, app: PhotosService.app, detail: "Gallery"),
        Feature(id: "Spotify", symbol: "music.note", color: .green, app: SpotifyService.app,
                detail: hub.spotify.signedIn ? "Signed in" : "Sign in"),
        Feature(id: "Gemini", symbol: "sparkles", color: .blue, app: GeminiService.app,
                detail: Secrets.geminiKey.isEmpty ? "Add key" : "Ready"),
        Feature(id: "Offline Maps", symbol: "map.fill", color: .orange, app: MapsService.app, detail: "Save a region"),
        Feature(id: "Maps", symbol: "map", color: TDColor.accent, app: AtlasService.app,
                detail: hub.atlas.nav.active ? "Navigating" : "Search, routes"),
        Feature(id: "Navigation", symbol: "location.north.line.fill", color: TDColor.accent, app: NavService.app,
                detail: hub.nav.active ? "Navigating" : "Turn by turn"),
        Feature(id: "Compass", symbol: "safari.fill", color: .red, app: CompassService.app,
                detail: hub.compass.running ? "On" : "iPhone heading"),
    ]
}

@MainActor @ViewBuilder private func page(_ id: String) -> some View {
    switch id {
    case "WhatsApp": WhatsAppPage()
    case "Mail": MailPage()
    case "Notes": NotesPage()
    case "Photos": PhotosPage()
    case "Spotify": SpotifyPage()
    case "Gemini": GeminiPage()
    case "Offline Maps": MapsPage()
    case "Maps": AtlasPage()
    case "Compass": CompassPage()
    default: NavPage()
    }
}

struct OverviewTab: View {
    @Binding var tab: RootTab
    @Binding var faces: Bool
    @Environment(WatchModel.self) private var watch
    @State private var hub = Hub.shared
    @State private var settings = false

    /// The apps not in the bar, as icons at the bottom.
    private var apps: [Feature] { features(hub).filter { !["Navigation", "Notes"].contains($0.id) } }

    var body: some View {
        NavigationStack {
            PageScroll(title: "Overview") {
                Button { tab = .watch } label: { watchCard }.buttonStyle(PressScale())
                Button { tab = .navigation } label: { navCard }.buttonStyle(PressScale())
                NavigationLink { NotesPage() } label: { notesCard }.buttonStyle(PressScale())
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 16) {
                    ForEach(apps) { f in
                        NavigationLink { page(f.id) } label: { icon(f) }.buttonStyle(PressScale())
                    }
                    Button { settings = true } label: {
                        icon(Feature(id: "Settings", symbol: "gearshape.fill", color: .gray, app: "", detail: ""))
                    }
                    .buttonStyle(PressScale())
                }
                .padding(.vertical, 6)
                .glassCard(22)
                Text("Each feature runs only while its app is open on the watch, or while you use it here.")
                    .font(.caption).foregroundStyle(TDColor.muted).padding(.horizontal, 6)
            }
            // the watch is usually there: read it on opening
            .task { if watch.phase == .idle { await watch.check() } }
        }
        .fullScreenCover(isPresented: $settings) { Closable { SettingsTab() } }
    }

    private var connected: Bool { if case .checked = watch.phase { true } else { false } }

    private var watchCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "applewatch")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(TDColor.accent.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("CMF Watch Pro 2").font(.headline).foregroundStyle(TDColor.text)
                HStack(spacing: 6) {
                    Circle().fill(hub.linked || connected ? TDColor.good : TDColor.muted).frame(width: 8, height: 8)
                    Text(hub.linked || connected ? "Connected" : "Not connected").font(.subheadline).foregroundStyle(TDColor.muted)
                }
            }
            Spacer()
            if let a = hub.lastApp { Pill(text: a, color: TDColor.accent) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(TDColor.muted)
        }
        .glassCard(22)
    }

    /// Navigation, one tap from the start: where it is going, or a search to start.
    private var navCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FeatureIcon(symbol: "location.north.line.fill", color: TDColor.accent, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hub.nav.active ? "Navigating" : "Navigate").font(.headline).foregroundStyle(TDColor.text)
                    Text(hub.nav.active ? (hub.nav.destination?.name ?? "Turns on the watch") : "Turn by turn on the watch")
                        .font(.caption).foregroundStyle(TDColor.muted).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(TDColor.muted)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(TDColor.muted)
                Text(hub.nav.active ? "Change destination" : "Where to?").foregroundStyle(TDColor.muted)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(TDColor.muted.opacity(0.12), in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }

    /// The three notes changed last.
    private var notesCard: some View {
        let recent = Array(hub.notes.store.notes.sorted { $0.modified > $1.modified }.prefix(3))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                FeatureIcon(symbol: "note.text", color: .yellow, size: 34)
                Text("Recent notes").font(.headline).foregroundStyle(TDColor.text)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(TDColor.muted)
            }
            if recent.isEmpty {
                Text("No notes yet. Write one here or on the watch.").font(.footnote).foregroundStyle(TDColor.muted)
            }
            ForEach(recent) { n in
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.title.isEmpty ? "Untitled" : n.title).font(.subheadline.weight(.semibold))
                        .foregroundStyle(TDColor.text).lineLimit(1)
                    if let first = n.lines.first(where: { !$0.isEmpty }) {
                        Text(first).font(.caption).foregroundStyle(TDColor.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(22)
    }

    private func icon(_ f: Feature) -> some View {
        VStack(spacing: 6) {
            FeatureIcon(symbol: f.symbol, color: f.color, size: 52)
            Text(f.id == "Offline Maps" ? "Offline" : f.id).font(.caption2.weight(.medium)).foregroundStyle(TDColor.text)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A full-screen sheet's content with a close button over its top corner.
struct Closable<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(.regularMaterial, in: Circle())
                }
                .tint(.primary)
                .padding(.trailing, 16)
                .padding(.top, 6)
                .accessibilityLabel("Close")
            }
    }
}
