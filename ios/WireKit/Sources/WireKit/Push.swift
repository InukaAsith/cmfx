import Foundation

// PUSH (stub 8, cmf-watch-sdk docs/widget-push.md): the phone writes a watch app's widget card or start blob while
// the app doesn't run. Used for its background jobs (docs/miniapp-rpc.md, job.set).

/// What a PUSH writes: the widget card's 64-byte record, or the blob the app gets as its first message at start.
public enum PushKind: Int, Codable, Sendable { case widget = 0, blob = 1 }

public enum PushResult: Equatable, Sendable {
    case ok
    /// Written less than 60 s ago; nothing written, retry after `ms`.
    case later(ms: UInt32)
    /// NoApp (7), BadRequest (1, also every stub before 8), Io (2); 0xFF for an empty reply.
    case refused(UInt8)
}

/// From stub 8 on; older stubs answer BadRequest.
public func canPush(stub: UInt32) -> Bool { stub >= 8 }

/// title ≤ 23 bytes at 0, value ≤ 39 bytes at 24 (0A starts a second line), NUL-padded to 64.
public func widgetRecord(title: String, value: String) -> Data {
    func field(_ s: String, _ size: Int) -> Data {
        let d = utf8Cut(s, size - 1)
        return d + Data(count: size - d.count)
    }
    return field(title, 24) + field(value, 40)
}

public func pushPayload(slot: Int, kind: PushKind, data: Data) -> Data { Data([UInt8(slot), UInt8(kind.rawValue)]) + data }

public func parsePushReply(_ r: Data) -> PushResult {
    guard let s = r.first else { return .refused(0xFF) }
    if s == Status.ok.rawValue { return .ok }
    if s == 0x0A, r.count >= 5 { return .later(ms: r.le(UInt32.self, at: 1)) }
    return .refused(s)
}

/// PUSH on a session; empty `data` removes the record.
public func push(_ s: Requester, slot: Int, kind: PushKind, data: Data) async throws -> PushResult {
    parsePushReply(try await s.call(Cmd.push, pushPayload(slot: slot, kind: kind, data: data)))
}

/// A job's start blob: each record as `len:u8 ‖ record`, whole records while they fit 128 bytes; nil when none does.
public func jobBlob(_ records: [Data]) -> Data? {
    var out = Data()
    for r in records {
        guard out.count + 1 + r.count <= 128 else { break }
        out += [UInt8(r.count)] + r
    }
    return out.isEmpty ? nil : out
}

/// A web job's widget: a 2xx body as UTF-8, its first line the title, the rest the value; nil for anything else.
public func jobWidget(_ records: [Data]) -> Data? {
    guard let head = records.first, head.count >= 4, (200..<300).contains(Int(head.le(UInt16.self, at: 0))),
          let text = String(data: records.dropFirst().reduce(Data(), +), encoding: .utf8) else { return nil }
    let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    return widgetRecord(title: String(lines[0]), value: lines.count > 1 ? String(lines[1]) : "")
}
