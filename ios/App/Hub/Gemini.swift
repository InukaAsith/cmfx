import Foundation
import HubKit
import UIKit

// The watch's Gemini app (the chats app in assistant mode; hosts/aihost.py is the reference). The user's own
// Gemini API key (aistudio.google.com), streamed answers word by word into the watch's bubbles.

@MainActor @Observable final class GeminiService: WatchService {
    static let app = "Gemini"
    static let model = "gemini-3.5-flash-lite"
    var status: String?
    private var answering: Task<Void, Never>?
    private var asking: String?

    /// A conversation kept on the phone (the last 3); its id is the watch's row id.
    struct Convo: Codable { var id: UInt8; var turns: [Turn] }
    struct Turn: Codable { var user: Bool; var text: String }
    private static let key = "gemini-convos", keep = 3, newChat: UInt8 = 1
    /// newest first
    private var convos: [Convo] = (UserDefaults.standard.data(forKey: key))
        .flatMap { try? JSONDecoder().decode([Convo].self, from: $0) } ?? []
    /// the conversation answers go to (nil: the watch's New chat, made on its first question)
    private var current: UInt8?

    func receive(_ m: Data) {
        guard let ask = ChatsProto.parse(m) else { return }
        switch ask {
        case .ready: send(list())
        case .open(let id):
            current = id == Self.newChat ? nil : id
            if let c = convos.first(where: { $0.id == id }) { send(chat(c)) }
            else { send([ChatsProto.open(Self.newChat, title: "Gemini")]) }
        case .send(let id, let text):
            // the watch asks again when it heard nothing for a while: the same question still being answered is kept
            if text == asking, answering != nil { return send(ChatsProto.quick(GeminiProto.prompts)) }
            if id != Self.newChat, convos.contains(where: { $0.id == id }) { current = id }
            answering?.cancel()
            asking = text
            answering = Task { await answer(text); self.answering = nil; self.asking = nil }
        case .tap: break
        }
    }

    /// The page's "Check the key": one tiny question.
    func check() async {
        status = nil
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model)")!)
        req.timeoutInterval = 15
        req.setValue(Secrets.geminiKey, forHTTPHeaderField: "x-goog-api-key")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { status = "The key works: \(Self.model) answers." }
            else {
                let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                status = "Gemini \(code): \(msg ?? "the key was refused")"
            }
        } catch { status = error.localizedDescription }
    }

    private func send(_ msgs: [Data]) { Task { try? await Hub.shared.send(Self.app, msgs) } }

    private func list() -> [Data] {
        var rows = [ChatsProto.Row(id: Self.newChat, name: "New chat", preview: "Ask anything")]
        for c in convos {
            rows.append(.init(id: c.id, name: c.turns.first { $0.user }?.text ?? "Chat",
                              preview: c.turns.last { !$0.user }?.text ?? ""))
        }
        return ChatsProto.list(rows) + ChatsProto.quick(GeminiProto.prompts)
    }

    /// `H` and the conversation's last 10 bubbles.
    private func chat(_ c: Convo) -> [Data] {
        let bubbles = c.turns.flatMap { t in ChatsProto.chunks(GeminiProto.clean(t.text), GeminiProto.bubble).map { (me: t.user, kind: ChatsProto.plain, text: $0) } }
        return ChatsProto.chat(c.id, title: "Gemini", Array(bubbles.suffix(10)))
    }

    private func save() {
        if let d = try? JSONEncoder().encode(convos) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    private func answer(_ prompt: String) async {
        // the answer may take a while; iOS gives a woken app a few seconds unless it asks for more
        let bg = UIApplication.shared.beginBackgroundTask(withName: "gemini")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        var s = GeminiProto.Streamer()
        // the conversation, moved to the front (a new one for New chat; the oldest beyond 3 goes)
        var c: Convo
        if let id = current, let i = convos.firstIndex(where: { $0.id == id }) {
            c = convos.remove(at: i)
        } else {
            let used = Set(convos.map(\.id))
            c = Convo(id: (2...250).map(UInt8.init).first { !used.contains($0) } ?? 2, turns: [])
        }
        let fresh = c.turns.isEmpty
        c.turns.append(Turn(user: true, text: prompt))
        convos.insert(c, at: 0)
        convos = Array(convos.prefix(Self.keep))
        current = c.id
        save()
        do {
            // the watch hears at once that the phone has it: a New chat takes its id, else a harmless Q
            if fresh { try await Hub.shared.send(Self.app, chat(c)) }
            else { try await Hub.shared.send(Self.app, ChatsProto.quick(GeminiProto.prompts)) }
            guard !Secrets.geminiKey.isEmpty else {
                try await Hub.shared.send(Self.app, s.feed("Add your Gemini API key in CMFX on the iPhone."))
                return
            }
            var full = ""
            for try await piece in stream(c.turns) {
                full += piece
                try await Hub.shared.send(Self.app, s.feed(piece))
            }
            try await Hub.shared.send(Self.app, s.finish())
            if let i = convos.firstIndex(where: { $0.id == c.id }) {
                convos[i].turns.append(Turn(user: false, text: full.isEmpty ? "(no answer)" : full))
                convos[i].turns = Array(convos[i].turns.suffix(20))
                save()
            }
            // the list on the watch: this conversation first
            try? await Hub.shared.send(Self.app, list())
        } catch is CancellationError {
        } catch {
            status = error.localizedDescription
            try? await Hub.shared.send(Self.app, s.feed(" (error: \(error.localizedDescription))"))
        }
    }

    private func request(_ turns: [Turn], quick: Bool) -> URLRequest {
        var body: [String: Any] = [
            "contents": turns.map { ["role": $0.user ? "user" : "model", "parts": [["text": $0.text]]] },
            "systemInstruction": ["parts": [["text":
                "You answer on a small round watch. Plain sentences, no markdown, no lists, no emoji. At most 60 words."]]],
        ]
        // quick answers: as little thinking first as the model allows
        if quick { body["generationConfig"] = ["thinkingConfig": ["thinkingLevel": "MINIMAL"]] }
        var req = URLRequest(url: URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model):streamGenerateContent?alt=sse")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Secrets.geminiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func stream(_ turns: [Turn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            let t = Task {
                do {
                    var (bytes, resp) = try await URLSession.shared.bytes(for: self.request(turns, quick: true))
                    var code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 400 {
                        // a model without that thinking setting: ask again without it
                        (bytes, resp) = try await URLSession.shared.bytes(for: self.request(turns, quick: false))
                        code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    }
                    guard code == 200 else { throw HubError.failed("Gemini \(code)") }
                    for try await line in bytes.lines where line.hasPrefix("data: ") {
                        guard let j = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
                        else { continue }
                        for cand in j["candidates"] as? [[String: Any]] ?? [] {
                            for p in ((cand["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? [] {
                                // thought summaries are not the answer
                                if p["thought"] as? Bool == true { continue }
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
