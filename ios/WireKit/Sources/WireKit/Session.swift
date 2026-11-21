import Foundation

// A session keyed with K (docs/abi-1.4.md) over a GATT link: no bind, no popup, next to Nothing X on the shared
// iOS connection. Mirrors link.Session.open_channel + channel.send/recv/ping of the Python host.

public enum Uuid {
    public static let shellWrite = "77D4FF01-2FE2-2334-0D35-9CCD078F529C"
    public static let shellNotify = "77D4FF02-2FE2-2334-0D35-9CCD078F529C"
    public static let cmdWrite = "0000FFF2-0000-1000-8000-00805F9B34FB"
    public static let cmdNotify = "0000FFF1-0000-1000-8000-00805F9B34FB"
}

/// GATT as the session needs it. BLE in the app; a fake stub in the tests.
public protocol Link: AnyObject, Sendable {
    /// Writes a characteristic (the BLE side picks write-with-response for frames over MTU-3).
    func write(_ uuid: String, _ data: Data) async throws
    /// Called for every notification: (characteristic uuid, value).
    func onNotify(_ handler: @escaping @Sendable (String, Data) -> Void)
}

enum Cmd {
    static let info: UInt16 = 0x90A0, begin: UInt16 = 0x90A1, data: UInt16 = 0x90A2, end: UInt16 = 0x90A3
    static let delete: UInt16 = 0x90A4, msg: UInt16 = 0x90A5, ping: UInt16 = 0x90A7, event: UInt16 = 0xB0A6
    static let push: UInt16 = 0x90A8
}

public enum Status: UInt8 {
    case ok = 0, badRequest, io, sequence, crc, busy, invalid, noApp, full, paused
}

public actor KSession: Channel {
    let link: Link
    public let key: Data
    /// PING while recv waits (foreground); off when the stub sends app messages unsolicited.
    public var poll: Duration?
    private let frames = Inbox<(UInt16, Data)>()
    private let events = Inbox<Data>()
    private var parser = FrameParser()
    /// When another host (Nothing X) last talked on the link: its bind changes the stock session, and the stub
    /// stops sending us the apps' messages until a K frame comes again (cmf-watch-sdk wp2-core chan.rs `listening`).
    private var foreignAt: ContinuousClock.Instant?

    init(link: Link, key: Data, poll: Duration?) {
        (self.link, self.key, self.poll) = (link, key, poll)
    }

    /// Reads the pairing secret (or takes the cached one), subscribes and registers with one PING, so the stub
    /// sends this host the app's messages. `register: false` skips the PING: a stock watch never answers it, and
    /// `readLoader` tells stock firmware apart faster with INFO.
    public static func open(link: Link, secretHex: String? = nil, poll: Duration? = nil,
                            register: Bool = true) async throws
        -> (session: KSession, secretHex: String) {
        let shell = Inbox<Data>()
        let box = SessionBox()
        // one consumer keeps the notifications in order: a frame may span several
        let (stream, sink) = AsyncStream<(String, Data)>.makeStream()
        link.onNotify { uuid, value in sink.yield((uuid.uppercased(), value)) }
        Task {
            for await (uuid, value) in stream {
                if uuid == Uuid.shellNotify { await shell.put(value) }
                if uuid == Uuid.cmdNotify { await box.session?.feed(value) }
            }
        }
        var secret = secretHex
        var tries = 0
        while secret == nil {
            tries += 1
            try await link.write(Uuid.shellWrite, Data("AT GETSECRET\r\n".utf8))
            var reply = ""
            while !["OK", "ERROR", "FAIL"].contains(where: reply.contains) {
                guard let d = await shell.next(timeout: .seconds(6)) else { break }
                reply += String(decoding: d, as: UTF8.self)
            }
            let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("GETSECRET:"), t.hasSuffix(",OK") {
                secret = String(t.dropFirst("GETSECRET:".count).dropLast(",OK".count))
            } else if tries == 3 {
                throw WireError.timeout("no pairing secret from the watch shell")
            }
        }
        guard let secret, let key = channelKey(secretHex: secret) else { throw WireError.refused(0xFF) }
        let s = KSession(link: link, key: key, poll: poll)
        await box.set(s)
        if register { _ = try await s.ping() }
        return (s, secret)
    }

    func feed(_ value: Data) async {
        for f in parser.feed(value) {
            guard f.c1 == system, WireKit.open(key, f.body) != nil else {
                foreignAt = .now
                continue
            }
            // another host's frames (Nothing X, the stock session) do not open with K: dropped where they are read
            if f.c2 == Cmd.event { await events.put(f.body) } else { await frames.put((f.c2, f.body)) }
        }
    }

    public func setPoll(_ p: Duration?) { poll = p }

    /// true once, when another host talked and has been quiet for `quiet`: time to register again (one PING).
    public func takeForeign(quiet: Duration = .seconds(2)) -> Bool {
        guard let t = foreignAt, ContinuousClock.now - t >= quiet else { return false }
        foreignAt = nil
        return true
    }

    /// One system request; the reply that opens with K.
    func request(_ c2: UInt16, _ payload: Data, timeout: Duration = .seconds(6)) async throws -> Data {
        await frames.drain()
        try await link.write(Uuid.cmdWrite, frame(c2: c2, payload: payload, key: key))
        let deadline = ContinuousClock.now + timeout
        while true {
            let left = deadline - ContinuousClock.now
            guard left > .zero, let (got, body) = await frames.next(timeout: left) else {
                throw WireError.timeout(String(format: "no reply to %04X", c2))
            }
            if got == c2 | 0xA000, let plain = WireKit.open(key, body) { return plain }
        }
    }

    /// (running slot, flags): bit 0 ABI 1.1 app, bit 1 paused.
    public func ping() async throws -> (slot: UInt8, flags: UInt8) {
        let r = try await request(Cmd.ping, Data([0]))
        guard r.count == 3, r[r.startIndex] == Status.ok.rawValue else { throw WireError.refused(r.first ?? 0xFF) }
        return (r[r.startIndex + 1], r[r.startIndex + 2])
    }

    /// One message to the running app; FULL and PAUSED are retried for `wait`.
    public func send(_ data: Data) async throws {
        try await send(data, slot: 0xFF)
    }

    /// One message to the app in `slot` only (CMFX): `WireError.noApp` when another app runs, so a phone service
    /// never feeds an app that is not its own. 0xFF: whichever app runs.
    public func send(_ data: Data, slot: UInt8) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        var delay = Duration.milliseconds(20)
        while true {
            let r = try await request(Cmd.msg, Data([slot]) + data)
            switch Status(rawValue: r.first ?? 0xFF) {
            case .ok?: return
            case .noApp?: throw WireError.noApp
            case .full?, .paused?:
                guard ContinuousClock.now + delay < deadline else { throw WireError.refused(r[r.startIndex]) }
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .milliseconds(500))
            default: throw WireError.refused(r.first ?? 0xFF)
            }
        }
    }

    /// Several messages in flight at once (the Python hosts' Pipe): all written, then their replies in order. A
    /// status per message, nil when its reply was lost; the caller sends refused and lost ones again. For streams
    /// (YouTube Music's audio): one at a time a round trip each is slower than the speaker plays.
    public func sendWindow(_ msgs: [Data], slot: UInt8) async throws -> [UInt8?] {
        await frames.drain()
        for m in msgs { try await link.write(Uuid.cmdWrite, frame(c2: Cmd.msg, payload: Data([slot]) + m, key: key)) }
        var got: [UInt8?] = []
        let deadline = ContinuousClock.now + .seconds(3)
        while got.count < msgs.count {
            let left = deadline - ContinuousClock.now
            guard left > .zero, let (c2, body) = await frames.next(timeout: left) else { break }
            if c2 == Cmd.msg | 0xA000, let plain = WireKit.open(key, body) { got.append(plain.first) }
        }
        if got.contains(Status.noApp.rawValue) { throw WireError.noApp }
        return got + Array(repeating: nil, count: msgs.count - got.count)
    }

    /// A sliding window: up to `window` frames in flight, a new one written as each reply comes back (replies come
    /// in frame order), so the link never idles waiting for a whole batch. `pull` gives the next message (nil: none
    /// ready now). Ends when nothing is ready and all are answered, or after `budget` (other requests take turns).
    /// Returns the messages not taken (FULL, PAUSED, or no reply), in order, to be sent again.
    public func stream(slot: UInt8, window: Int = 4, budget: Duration = .milliseconds(400),
                       pull: @Sendable () async -> Data?) async throws -> [Data] {
        await frames.drain()
        var flight: [Data] = []
        var again: [Data] = []
        let end = ContinuousClock.now + budget
        var more = true
        while true {
            while more, flight.count < window, ContinuousClock.now < end {
                guard let m = await pull() else { more = false; break }
                try await link.write(Uuid.cmdWrite, frame(c2: Cmd.msg, payload: Data([slot]) + m, key: key))
                flight.append(m)
            }
            if flight.isEmpty { return again }
            guard let (c2, body) = await frames.next(timeout: .seconds(3)) else {
                return again + flight // lost: all in flight again
            }
            guard c2 == Cmd.msg | 0xA000, let plain = WireKit.open(key, body) else { continue }
            let m = flight.removeFirst()
            if plain.first == Status.noApp.rawValue { throw WireError.noApp }
            if plain.first != Status.ok.rawValue { again.append(m) }
            if ContinuousClock.now >= end { more = false }
        }
    }

    public func recv(timeout: Duration) async throws -> Data {
        try await recvFrom(timeout: timeout).data
    }

    /// The next app message and the slot of the app that sent it (EVENT plain = seq ‖ slot ‖ data). Android:
    /// `recvFrom(timeoutMs): Pair<Int, ByteArray>`.
    public func recvFrom(timeout: Duration) async throws -> (slot: UInt8, data: Data) {
        let deadline = ContinuousClock.now + timeout
        while true {
            let left = deadline - ContinuousClock.now
            guard left > .zero else { throw WireError.timeout("no message") }
            if let body = await events.next(timeout: poll.map { min($0, left) } ?? left) {
                if let plain = WireKit.open(key, body), plain.count >= 3 {
                    return (plain[plain.startIndex + 1], Data(plain.dropFirst(2)))
                }
                continue
            }
            if poll != nil { _ = try? await ping() }
        }
    }

    /// Raw request for install (INFO, BEGIN, DATA, END, DELETE).
    public func call(_ c2: UInt16, _ payload: Data, timeout: Duration) async throws -> Data {
        try await request(c2, payload, timeout: timeout)
    }
}

actor SessionBox {
    var session: KSession?
    func set(_ s: KSession) { session = s }
}
