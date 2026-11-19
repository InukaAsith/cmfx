import Foundation
import Network

// App-level messages to the running watch app: over BLE with key K (KSession) or to the host simulator over TCP
// (SimChannel, `scripts/sim <app> --tcp PORT`).

public enum WireError: Error, Equatable {
    case timeout(String)
    case noApp
    case refused(UInt8)
    case closed
}

public protocol Channel: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// The next message of the app; `WireError.timeout` when none comes in time.
    func recv(timeout: Duration) async throws -> Data
}

/// A queue one producer fills and `next` awaits, with a timeout (a continuation cannot be cancelled, so the
/// waiter itself is resumed with nil when time runs out).
actor Inbox<T: Sendable> {
    private var items: [T] = []
    private var waiters: [(id: Int, c: CheckedContinuation<T?, Never>)] = []
    private var ids = 0

    func put(_ item: T) {
        if waiters.isEmpty { items.append(item) } else { waiters.removeFirst().c.resume(returning: item) }
    }

    func next(timeout: Duration) async -> T? {
        if !items.isEmpty { return items.removeFirst() }
        ids += 1
        let id = ids
        return await withCheckedContinuation { c in
            waiters.append((id, c))
            Task {
                try? await Task.sleep(for: timeout)
                self.expire(id)
            }
        }
    }

    private func expire(_ id: Int) {
        if let i = waiters.firstIndex(where: { $0.id == id }) { waiters.remove(at: i).c.resume(returning: nil) }
    }

    func drain() { items.removeAll() }
}

/// Hex lines over TCP to `scripts/sim <app> --tcp PORT` (as `channel.SimChannel`). Debug builds and tests only.
public final class SimChannel: Channel, @unchecked Sendable {
    private let conn: NWConnection
    private let inbox = Inbox<Data>()
    private var partial = Data()

    public init(host: String = "127.0.0.1", port: UInt16) {
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        conn.start(queue: .global())
        read()
    }

    private func read() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data {
                partial += data
                while let nl = partial.firstIndex(of: 0x0A) {
                    let line = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self)
                    partial = Data(partial[(nl + 1)...])
                    if let bytes = Data(hexString: line.trimmingCharacters(in: .whitespaces)) {
                        Task { await self.inbox.put(bytes) }
                    }
                }
            }
            if !done && error == nil { read() }
        }
    }

    public func send(_ data: Data) async throws {
        let line = Data((data.map { String(format: "%02x", $0) }.joined() + "\n").utf8)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: line, completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    public func recv(timeout: Duration) async throws -> Data {
        guard let d = await inbox.next(timeout: timeout) else { throw WireError.timeout("no message") }
        return d
    }

    public func close() { conn.cancel() }
}

extension Data {
    init?(hexString s: String) {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var d = Data()
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            d.append(b)
        }
        self = d
    }
}
