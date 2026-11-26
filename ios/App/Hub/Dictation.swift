import AVFoundation
import Foundation
import HubKit
import Speech
import UIKit

/// Voice typing and recordings from any watch app (HubKit VoiceProto): the watch's mic comes as ADPCM, iOS speech
/// recognition writes it down (on this iPhone when it can), and the words go back as they come. A recording is also
/// kept: Files › On My iPhone › CMFX › Recordings, an .m4a and the words beside it.
@MainActor final class Dictation {
    static let shared = Dictation()

    private var app: String?
    private var record = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var samples = 0
    private var heard = ""
    private var sentAt = Date.distantPast
    private var sent = ""
    private var ended = false
    private var finished = false
    private var gen = 0
    private var bg: UIBackgroundTaskIdentifier = .invalid
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceProto.rate, channels: 1,
                                       interleaved: false)!

    /// Asks for speech recognition once (from the foreground: the watch can't show the question).
    static func askPermission() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
    }

    func receive(_ m: Data, app name: String) {
        guard let ask = VoiceProto.parse(m) else { return }
        switch ask {
        case .start(let rec): start(name, record: rec)
        case .audio(_, let block): audio(block)
        case .end: end()
        case .cancel: stop(keepFile: false)
        }
    }

    private func start(_ name: String, record rec: Bool) {
        stop(keepFile: false)
        gen += 1
        app = name
        record = rec
        heard = ""; sent = ""; samples = 0
        ended = false; finished = false
        bg = UIApplication.shared.beginBackgroundTask(withName: "dictation")
        if rec { openFile() }
        // the watch sends its messages after a frame from the phone: ask often while it talks
        let g = gen
        Task {
            while self.gen == g, !self.finished {
                try? await Hub.shared.ping()
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        // an answer even if the recognizer never gives one
        Task {
            try? await Task.sleep(for: .seconds(40))
            if self.gen == g, !self.finished { self.finish() }
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            Self.askPermission()
            if !rec { return problem("Open CMFX once to allow speech recognition") }
            return
        default:
            if !rec { return problem("Speech recognition is off for CMFX in Settings") }
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            if !rec { problem("Speech recognition is not available now") }
            return
        }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }
        request = r
        task = recognizer.recognitionTask(with: r) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in self?.result(g, text, final: final, failed: failed) }
        }
    }

    private func audio(_ block: Data) {
        guard app != nil, !ended else { return }
        let pcm = VoiceProto.decode(block)
        guard !pcm.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(pcm.count)
        let ch = buf.floatChannelData![0]
        for (i, v) in pcm.enumerated() { ch[i] = Float(v) / 32768 }
        request?.append(buf)
        if let file { try? file.write(from: buf) }
        samples += pcm.count
    }

    private func end() {
        guard app != nil, !ended else { return }
        ended = true
        if request == nil { return finish() }
        request?.endAudio()
    }

    private func result(_ g: Int, _ text: String?, final: Bool, failed: Bool) {
        guard g == gen, !finished else { return }
        if let text, !text.isEmpty { heard = text }
        if final || (failed && ended) { return finish() }
        if failed {
            // the recognizer stopped early (silence, no network): what it has is shown, the end finishes it
            return
        }
        // the words so far, 4 times a second at most
        if heard != sent, Date.now.timeIntervalSince(sentAt) > 0.25 {
            sent = heard
            sentAt = .now
            send(VoiceProto.text(.partial, heard))
        }
    }

    private func finish() {
        guard !finished, app != nil else { return }
        finished = true
        if record {
            let secs = samples / Int(VoiceProto.rate)
            let name = saveFile()
            send(VoiceProto.text(.final, name.map { "Saved \($0) (\(secs / 60):\(String(format: "%02d", secs % 60)))" }
                                 ?? "Not saved"))
        } else if heard.isEmpty {
            send(VoiceProto.text(.problem, "Didn't catch that"))
        } else {
            send(VoiceProto.text(.final, heard))
        }
        stop(keepFile: true)
    }

    private func problem(_ why: String) {
        send(VoiceProto.text(.problem, why))
        finished = true
        stop(keepFile: false)
    }

    private func send(_ m: Data) {
        guard let app else { return }
        Task { try? await Hub.shared.send(app, m) }
    }

    private func stop(keepFile: Bool) {
        task?.cancel()
        task = nil
        request = nil
        file = nil
        if !keepFile, let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        finished = true
        app = nil
        if bg != .invalid {
            let b = bg
            bg = .invalid
            // the last words still have to reach the watch
            Task { try? await Task.sleep(for: .seconds(3)); UIApplication.shared.endBackgroundTask(b) }
        }
    }

    // MARK: recordings

    static var folder: URL {
        URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    private func openFile() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let url = Self.folder.appending(path: ".recording-\(gen).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: VoiceProto.rate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24000]
        file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        fileURL = file == nil ? nil : url
    }

    /// The recording under its date, with the words beside it; its name, nil if nothing was kept.
    private func saveFile() -> String? {
        file = nil // closes it
        guard let fileURL, samples > 0 else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Recording \(f.string(from: .now))"
        let dest = Self.folder.appending(path: name + ".m4a")
        do { try FileManager.default.moveItem(at: fileURL, to: dest) } catch { return nil }
        self.fileURL = nil
        if !heard.isEmpty {
            try? heard.write(to: Self.folder.appending(path: name + ".txt"), atomically: true, encoding: .utf8)
        }
        return name.replacingOccurrences(of: "Recording ", with: "")
    }
}
