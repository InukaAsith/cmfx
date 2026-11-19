import SwiftUI

// CMFX's start: the watch at a glance and every feature as a tile. The bar holds Overview, WhatsApp, Navigation
// and Mail; More has the rest, the watch (connection, faces on it) and Settings. FMC Companion's watch faces catalog,
// the one part of it kept, opens as a sheet.

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
        Feature(id: "Navigation", symbol: "location.north.line.fill", color: TDColor.accent, app: NavService.app,
                detail: hub.nav.active ? "Navigating" : "Turn by turn"),
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
    default: NavPage()
    }
}

struct OverviewTab: View {
    @Binding var tab: RootTab
    @Binding var faces: Bool
    @Environment(WatchModel.self) private var watch
    @State private var hub = Hub.shared
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable { case watch, settings; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            PageScroll(title: "Overview") {
                Button { sheet = .watch } label: { watchCard }.buttonStyle(PressScale())
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(features(hub)) { f in
                        NavigationLink { page(f.id) } label: { tile(f) }.buttonStyle(PressScale())
                    }
                    Button { faces = true } label: {
                        tile(Feature(id: "Watch faces", symbol: "square.grid.2x2.fill", color: .gray, app: "",
                                     detail: "From fmc.tools"))
                    }
                    .buttonStyle(PressScale())
                    Button { sheet = .settings } label: {
                        tile(Feature(id: "Settings", symbol: "gearshape.fill", color: .gray, app: "", detail: "Look, accent"))
                    }
                    .buttonStyle(PressScale())
                }
                Text("Each feature runs only while its app is open on the watch, or while you use it here.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            // the watch is usually there: read it on opening
            .task { if watch.phase == .idle { await watch.check() } }
        }
        .fullScreenCover(item: $sheet) { s in
            Closable { if s == .watch { ContentView() } else { SettingsTab() } }
        }
    }

    private var connected: Bool { if case .checked = watch.phase { true } else { false } }

    private var watchCard: some View {
        HStack(spacing: 14) {
            AppMark(size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("CMF Watch Pro 2").font(.headline).foregroundStyle(TDColor.text)
                HStack(spacing: 6) {
                    Circle().fill(hub.linked || connected ? TDColor.good : TDColor.muted).frame(width: 8, height: 8)
                    Text(hub.linked || connected ? "Connected" : "Not connected").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let a = hub.lastApp { Pill(text: a, color: TDColor.accent) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .glassCard(22)
    }

    private func tile(_ f: Feature) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FeatureIcon(symbol: f.symbol, color: f.color, size: 34)
                Spacer()
                if !f.app.isEmpty, !hub.apps.isEmpty, !hub.installed(f.app) {
                    Image(systemName: "applewatch.slash").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Text(f.id).font(.headline).foregroundStyle(TDColor.text).lineLimit(1)
            Text(f.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(20)
    }
}

/// More: the features not in the bar, the watch and Settings; watch faces as a sheet.
struct MoreTab: View {
    @Binding var faces: Bool
    @State private var hub = Hub.shared
    @State private var sheet: OverviewTab.Sheet?

    var body: some View {
        NavigationStack {
            PageScroll(title: "More") {
                VStack(spacing: 0) {
                    ForEach(Array(features(hub).filter { !["WhatsApp", "Mail", "Navigation"].contains($0.id) }.enumerated()), id: \.element.id) { i, f in
                        if i > 0 { Divider().overlay(TDColor.line).padding(.vertical, 8) }
                        NavigationLink { page(f.id) } label: { row(f.symbol, f.color, f.id, f.detail) }
                    }
                }
                .glassCard(22)
                VStack(spacing: 0) {
                    Button { faces = true } label: { row("square.grid.2x2.fill", .gray, "Watch faces", "From fmc.tools") }
                    Divider().overlay(TDColor.line).padding(.vertical, 8)
                    Button { sheet = .watch } label: { row("applewatch", .gray, "Watch", "Connection, faces on the watch") }
                    Divider().overlay(TDColor.line).padding(.vertical, 8)
                    Button { sheet = .settings } label: { row("gearshape.fill", .gray, "Settings", "Look, accent") }
                }
                .glassCard(22)
            }
        }
        .fullScreenCover(item: $sheet) { s in
            Closable { if s == .watch { ContentView() } else { SettingsTab() } }
        }
    }

    private func row(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            FeatureIcon(symbol: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(TDColor.text)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// FMC Companion's watch faces catalog in a sheet (it keeps its own navigation).
struct FacesSheet: View {
    @Binding var path: [String]
    var body: some View { Closable { CatalogView(path: $path) } }
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
