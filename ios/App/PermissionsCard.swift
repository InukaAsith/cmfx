import CoreBluetooth
import CoreLocation
import EventKit
import Photos
import SwiftUI
import UIKit
import UserNotifications
import WireKit

/// Settings › Permissions: each iOS permission CMFX asks for, what it is for, how it stands (Allow, or iOS
/// Settings once refused), and the watch apps that use it: one not on the watch says so, with Install.
@MainActor @Observable final class PhonePermissions: NSObject, CLLocationManagerDelegate {
    static let shared = PhonePermissions()

    enum Kind: CaseIterable, Identifiable {
        case bluetooth, location, photos, reminders, calendar, notifications
        var id: Self { self }

        var title: String {
            switch self {
            case .bluetooth: "Bluetooth"
            case .location: "Location"
            case .photos: "Photos"
            case .reminders: "Reminders"
            case .calendar: "Calendar"
            case .notifications: "Notifications"
            }
        }

        var icon: (String, Color) {
            switch self {
            case .bluetooth: ("dot.radiowaves.left.and.right", .blue)
            case .location: ("location.fill", .blue)
            case .photos: ("photo.on.rectangle", .orange)
            case .reminders: ("checklist", .orange)
            case .calendar: ("calendar", .red)
            case .notifications: ("bell.badge.fill", .red)
            }
        }

        var why: String {
            switch self {
            case .bluetooth: "Talks to the watch."
            case .location: "Where you are: Maps, Navigation, Offline Maps and the weather."
            case .photos: "Your newest photos as a gallery on the watch."
            case .reminders: "Your reminders in Notes on the watch."
            case .calendar: "Upcoming events for watch apps you allow."
            case .notifications: "Asks from watch apps (a permission they want)."
            }
        }

        /// The watch apps (their names on the watch) that need it.
        var apps: [String] {
            switch self {
            case .location: ["Maps", "Navigation", "Offline Maps"]
            case .photos: ["Photos"]
            case .reminders: ["Notes"]
            default: []
            }
        }
    }

    enum State {
        case allowed, limited, denied, notAsked
        var text: String {
            switch self {
            case .allowed: "Allowed"
            case .limited: "Limited"
            case .denied: "Not allowed"
            case .notAsked: "Not asked yet"
            }
        }
        var color: Color {
            switch self {
            case .allowed: .green
            case .limited: .orange
            case .denied: .red
            case .notAsked: .secondary
            }
        }
    }

    private(set) var states: [Kind: State] = [:]
    private let location = CLLocationManager()

    override private init() {
        super.init()
        location.delegate = self
    }

    func refresh() async {
        var s: [Kind: State] = [:]
        s[.bluetooth] = switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        s[.location] = switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        s[.photos] = switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: .allowed
        case .limited: .limited
        case .notDetermined: .notAsked
        default: .denied
        }
        for (k, type) in [(Kind.reminders, EKEntityType.reminder), (.calendar, .event)] {
            s[k] = switch EKEventStore.authorizationStatus(for: type) {
            case .fullAccess: .allowed
            case .writeOnly: .limited
            case .notDetermined: .notAsked
            default: .denied
            }
        }
        s[.notifications] = switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        states = s
    }

    /// The iOS prompt (only while not asked yet: after that iOS shows it no more, the Settings app changes it).
    func ask(_ k: Kind) async {
        switch k {
        case .bluetooth: break // asked when CMFX first looks for the watch
        case .location: location.requestWhenInUseAuthorization()
        case .photos: await Hub.shared.photos.requestAccess()
        case .reminders: await Hub.shared.notes.requestAccess()
        case .calendar: await PhoneServices.shared.requestOS("calendar")
        case .notifications: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        await refresh()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in await self.refresh() }
    }
}

struct PermissionsCard: View {
    @Environment(WatchModel.self) private var watch
    @Environment(\.scenePhase) private var phase
    private var perms = PhonePermissions.shared
    private var bundled = BundledApps.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.headline)
            ForEach(PhonePermissions.Kind.allCases) { k in
                row(k)
                if k != PhonePermissions.Kind.allCases.last { Divider() }
            }
        }
        .glassCard()
        .task { await perms.refresh() }
        // back from the Settings app
        .onChange(of: phase) { _, p in if p == .active { Task { await perms.refresh() } } }
        .alert("Couldn't install", isPresented: Binding { bundled.error != nil } set: { if !$0 { bundled.error = nil } }) {
            Button("OK") {}
        } message: { Text(bundled.error ?? "") }
    }

    @ViewBuilder private func row(_ k: PhonePermissions.Kind) -> some View {
        let state = perms.states[k]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: k.icon.0)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(k.icon.1.gradient, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(k.title).font(.subheadline.weight(.semibold))
                    Text(k.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let state {
                    switch state {
                    case .notAsked where k != .bluetooth:
                        Button("Allow") { Task { await perms.ask(k) } }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
                    case .denied, .limited:
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(state.text).font(.caption.weight(.semibold)).foregroundStyle(state.color)
                            Button("Settings") { openSettings() }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        }
                    default:
                        Text(state.text).font(.caption.weight(.semibold)).foregroundStyle(state.color)
                    }
                }
            }
            ForEach(k.apps, id: \.self) { name in appLine(name) }
        }
    }

    /// A watch app that uses the permission: on the watch, or not (Install, when this build of CMFX has it).
    @ViewBuilder private func appLine(_ name: String) -> some View {
        let loader = watch.listedLoader
        let on = loader?.apps.values.contains { $0.name == name } ?? false
        HStack(spacing: 8) {
            AppIcon(name: name, side: 20)
            Text(name).font(.caption)
            Spacer()
            if loader == nil {
                Text("Watch not connected").font(.caption2).foregroundStyle(.secondary)
            } else if on {
                Text("On the watch").font(.caption2).foregroundStyle(.secondary)
            } else if let p = bundled.progress[name] {
                ProgressView(value: p).frame(width: 64)
            } else {
                Text("App not installed on watch").font(.caption2.weight(.medium)).foregroundStyle(.orange)
                if let app = bundled.all.first(where: { $0.name == name }) {
                    Button("Install") { Task { await bundled.install(app, watch); await watch.check() } }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.mini)
                        .disabled(loader?.loader == nil || bundled.installingAll)
                }
            }
        }
        .padding(.leading, 42)
    }

    private func openSettings() {
        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
    }
}
