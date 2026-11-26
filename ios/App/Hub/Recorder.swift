import AVFoundation
import Foundation
import HubKit
import SwiftUI

// The watch's Recorder (cmf-watch-sdk sdk/examples/recorder: YouTube Music's app as a voice recorder). A recording
// is voice typing that keeps the sound (Dictation: Files › On My iPhone › CMFX › Recordings, an .m4a and its words);
// History lists them here, newest first, and one plays on the watch's speaker as a song does: the same stream, the
// same ~7 s buffer on the watch, previous and next, seeking on the ring.

@MainActor final class RecorderService: YouTubeMusicService {
    override class var app: String { "Recorder" }

    /// The recordings, newest first: the file's name as the id, its date as the title, its first words under it.
    override func accountHistory() async throws -> [YTSong]? {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Dictation.folder.path)) ?? []
        let files = names.filter { $0.hasPrefix("Recording ") && $0.hasSuffix(".m4a") }.sorted(by: >).prefix(24)
        var out: [YTSong] = []
        for name in files {
            let url = Dictation.folder.appending(path: name)
            let secs = (try? await AVURLAsset(url: url).load(.duration)).map { Int($0.seconds.rounded()) } ?? 0
            let words = (try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            out.append(YTSong(id: name, title: Self.title(name), artist: String(words.prefix(40)), seconds: secs))
        }
        return out
    }

    /// "Recording 2026-11-26 17.12.05.m4a" → "26 Nov 17:12".
    static func title(_ name: String) -> String {
        let stem = name.dropFirst("Recording ".count).dropLast(".m4a".count)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        guard let d = f.date(from: String(stem)) else { return String(stem) }
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: d)
    }

    /// The recording, decoded here and shaped for the speaker, levelled (a voice recorded quietly is heard).
    override func samples(_ song: YTSong, from: Int, level: Bool, smooth: Bool,
                          progress: @Sendable (Int) async -> Void) async throws -> [Int16] {
        let url = Dictation.folder.appending(path: song.id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw HubError.failed("Recording deleted") }
        await progress(20)
        let pcm = try await YTMusic.decode(url, from: Double(from))
        await progress(80)
        return await Task.detached(priority: .userInitiated) {
            SpeakerTune.forSpeaker(pcm, rate: SpeakerProto.rate, level: true, smooth: smooth)
        }.value
    }

    /// Up next: the older recordings after it.
    override func radio(after song: YTSong) {
        guard let i = historyShown.firstIndex(of: song) else { return }
        queue = Array(historyShown[i...])
    }

    override func played(_ song: YTSong) {}

    override func find(_ q: String) async throws -> [YTSong] {
        let q = q.lowercased()
        let all: [YTSong] = (try? await accountHistory()) ?? []
        return all.filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
    }

    override func library() async throws -> [(id: String, name: String, sub: String)] { [] }
}

// MARK: page

struct RecorderPage: View {
    var body: some View {
        PageScroll(title: "Recorder") {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(symbol: "waveform.circle.fill", color: .red, title: "Recordings on this iPhone",
                           detail: "Files › On My iPhone › CMFX › Recordings: each an .m4a, with its words beside it")
            }
            .glassCard()
            VStack(alignment: .leading, spacing: 8) {
                Text("On the watch").font(.headline)
                Text("Tap the red button to record; the words appear as you speak, and the recording is saved here. History lists them, newest first: tap one to hear it on the watch's speaker, with previous and next, the ring to seek and the crown for the volume. Keep CMFX running.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .glassCard()
        }
    }
}
