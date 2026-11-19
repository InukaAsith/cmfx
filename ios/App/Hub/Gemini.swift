import Foundation
import HubKit

// The watch's Gemini app (the chats app in assistant mode; hosts/aihost.py is the reference). The user's own
// Gemini API key (aistudio.google.com), streamed answers word by word into the watch's bubbles.

@MainActor @Observable final class GeminiService: WatchService {
    static let app = "Gemini"
    static let model = "gemini-3.5-flash"
    private var history: [[String: Any]] = []
    var status: String?
    private var answering: Task<Void, Never>?

    func receive(_ m: Data) {
        if m == Data("R".utf8) {
            history.removeAll()
            Task { try? await Hub.shared.send(Self.app, GeminiProto.hello()) }
        } else if let prompt = GeminiProto.prompt(m) {
            answering?.cancel()
            answering = Task { await answer(prompt) }
        }
    }

    private func answer(_ prompt: String) async {
        history.append(["role": "user", "parts": [["text": prompt]]])
        var s = GeminiProto.Streamer()
        var full = ""
        do {
            guard !Secrets.geminiKey.isEmpty else {
                try await Hub.shared.send(Self.app, s.feed("Add your Gemini API key in CMFX on the iPhone."))
                return
            }
            for try await piece in stream() {
                full += piece
                try await Hub.shared.send(Self.app, s.feed(piece))
            }
            try await Hub.shared.send(Self.app, s.finish())
            history.append(["role": "model", "parts": [["text": full]]])
        } catch {
            status = error.localizedDescription
            try? await Hub.shared.send(Self.app, s.feed(" (error: \(error.localizedDescription))"))
        }
    }

    private func stream() -> AsyncThrowingStream<String, Error> {
        let body: [String: Any] = [
            "contents": history,
            "systemInstruction": ["parts": [["text":
                "You answer on a small round watch. Plain sentences, no markdown, no lists, no emoji. At most 60 words."]]],
        ]
        var req = URLRequest(url: URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model):streamGenerateContent?alt=sse")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Secrets.geminiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return AsyncThrowingStream { c in
            let t = Task {
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else { throw HubError.failed("Gemini \(code)") }
                    for try await line in bytes.lines where line.hasPrefix("data: ") {
                        guard let j = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
                        else { continue }
                        for cand in j["candidates"] as? [[String: Any]] ?? [] {
                            for p in ((cand["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? [] {
                                if let t = p["text"] as? String { c.yield(t) }
                            }
                        }
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}
