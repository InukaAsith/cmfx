import SwiftUI
import UIKit

// The Developer section: what the RPC listener did (link up and down, each request with its package, method and
// status), kept in Documents/rpc.log so a background wake shows up on the next launch.
// ponytail: whole file rewritten on clear only; trimmed to the last 500 lines in memory.

@MainActor @Observable final class DevLog {
    static let shared = DevLog()
    private static let file = URL.documentsDirectory.appending(path: "rpc.log")

    private(set) var lines: [String] = []

    private init() {
        lines = ((try? String(contentsOf: Self.file, encoding: .utf8)) ?? "").split(separator: "\n").suffix(500)
            .map(String.init)
    }

    func log(_ text: String) {
        let state = UIApplication.shared.applicationState == .background ? "BG" : "fg"
        let line = "\(Date.now.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())) \(state) \(text)"
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: Self.file) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: Self.file)
        }
    }

    func clear() {
        lines = []
        try? FileManager.default.removeItem(at: Self.file)
    }

    var fileURL: URL { Self.file }

    static let methods: [UInt8: String] = [0x01: "caps", 0x10: "calendar.events", 0x11: "reminders", 0x12: "reminders.complete", 0x20: "location", 0x30: "weather",
                                           0x40: "http.get", 0x41: "http.request", 0x60: "storage.get", 0x61: "storage.put", 0x62: "storage.delete", 0x70: "phone.battery", 0x51: "notify", 0x80: "media.now_playing", 0x81: "media.control", 0x90: "job.set", 0x91: "job.delete", 0x50: "notifications"]
    static let statuses = ["OK", "BAD_REQUEST", "DENIED", "UNAVAILABLE", "ASK", "TOO_LARGE"]
}

struct DeveloperView: View {
    private var log = DevLog.shared
    @State private var clearing = false

    var body: some View {
        List {
            #if DEBUG
            Section {
                NavigationLink("Wake probe", value: ContentView.Route.wakeProbe)
            }
            #endif
            Section {
                ForEach(Array(log.lines.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                }
                if log.lines.isEmpty {
                    Text("Nothing yet. Requests from watch apps and reading the faces show up here.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Log")
            } footer: {
                Text("BG: the app was in the background when it happened.")
            }
        }
        .navigationTitle("Developer")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: log.fileURL)
                    .disabled(log.lines.isEmpty)
                Button("Clear", role: .destructive) { clearing = true }
                    .disabled(log.lines.isEmpty)
            }
        }
        .confirmationDialog("Clear the RPC log?", isPresented: $clearing) {
            Button("Clear", role: .destructive) { log.clear() }
        }
    }
}
