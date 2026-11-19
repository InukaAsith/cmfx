#if DEBUG
import SwiftUI
import UIKit
import WireKit

// Does a BLE notify wake this app in the background on the link Nothing X holds? (docs/miniapp-rpc.md,
// "Constraints"). The watch app `wake-probe` (cmf-watch-sdk sdk/examples) sends "R1P" ‖ seq:u16le every 20 s; this
// answers "R1p" ‖ seq and logs each one with the app state. Gaps of more than 20 s while "BG" = no wake.
// ponytail: DEBUG only, deleted once the question is answered.

@MainActor @Observable final class WakeProbe {
    static let shared = WakeProbe()
    private static let file = URL.documentsDirectory.appending(path: "wake-probe.log")

    private(set) var lines: [String] = []
    private var task: Task<Void, Never>?
    var running: Bool { task != nil }

    private init() {
        lines = ((try? String(contentsOf: Self.file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WakeProbe.shared.log("→ background") }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WakeProbe.shared.log("→ foreground") }
        }
    }

    func log(_ text: String) {
        let state = switch UIApplication.shared.applicationState {
        case .active: "fg"
        case .inactive: "inactive"
        case .background: "BG"
        @unknown default: "?"
        }
        let line = "\(Date.now.formatted(.dateTime.hour().minute().second())) \(state) \(text)"
        lines.append(line)
        // the file outlives a kill by the system: what happened then shows on the next launch
        if let h = try? FileHandle(forWritingTo: Self.file) {
            h.seekToEndOfFile()
            h.write(Data((line + "\n").utf8))
            try? h.close()
        } else {
            try? Data((line + "\n").utf8).write(to: Self.file)
        }
    }

    func clear() {
        lines = []
        try? FileManager.default.removeItem(at: Self.file)
    }

    func start() {
        guard task == nil else { return }
        task = Task {
            await listen()
            task = nil
        }
    }

    func stop() {
        task?.cancel()
    }

    private func listen() async {
        let link = BLELink()
        defer { link.disconnect() }
        link.onDisconnect = { Task { @MainActor in WakeProbe.shared.log("link dropped") } }
        do {
            try await link.connect()
            let account = "k-\(link.watchID?.uuidString ?? "")"
            let session: KSession
            do {
                (session, _) = try await KSession.open(link: link, secretHex: Keychain.get(account))
            } catch {
                // K changes with a factory reset: read it again once
                let (fresh, secret) = try await KSession.open(link: link)
                Keychain.set(account, secret)
                session = fresh
            }
            log("listening")
            while !Task.isCancelled {
                guard let m = try? await session.recv(timeout: .seconds(30)) else { continue }
                guard m.count == 5, m.prefix(3) == Data("R1P".utf8) else { continue }
                let seq = UInt16(m[m.startIndex + 3]) | UInt16(m[m.startIndex + 4]) << 8
                do {
                    try await session.send(Data("R1p".utf8) + m.suffix(2))
                    log("#\(seq) answered")
                } catch {
                    log("#\(seq) reply failed: \(error)")
                }
            }
            log("stopped")
        } catch {
            log("failed: \(error.localizedDescription)")
        }
    }
}

struct WakeProbeView: View {
    private var probe = WakeProbe.shared

    var body: some View {
        List {
            Section {
                Button(probe.running ? "Stop" : "Start") { probe.running ? probe.stop() : probe.start() }
                Button("Clear log", role: .destructive) { probe.clear() }
            } footer: {
                Text("Open wake-probe on the watch, start here, lock the phone. Each line is one request from the watch, every 20 s.")
            }
            Section("Log") {
                ForEach(Array(probe.lines.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("Wake probe")
    }
}
#endif
