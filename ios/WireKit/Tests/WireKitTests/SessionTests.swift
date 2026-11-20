import Foundation
import Testing
@testable import WireKit

/// The stub as a K host sees it: answers AT GETSECRET, PING and MSG under K; notifications cut in 20-byte pieces
/// (MTU 23); `foreign` adds a stock-keyed frame before every reply, like Nothing X's traffic on the shared link.
final class FakeStub: Link, @unchecked Sendable {
    let secret = "00112233445566778899aabbccddeeff"
    var key: Data { channelKey(secretHex: secret)! }
    var handler: (@Sendable (String, Data) -> Void)?
    var inbox: [Data] = []
    var status: Status = .ok
    var foreign = false
    var pings = 0

    func onNotify(_ handler: @escaping @Sendable (String, Data) -> Void) { self.handler = handler }

    func notify(_ uuid: String, _ value: Data) {
        stride(from: 0, to: value.count, by: 20).forEach {
            handler?(uuid, Data(value[value.startIndex + $0..<value.startIndex + min($0 + 20, value.count)]))
        }
    }

    /// An app message sent unsolicited (docs/abi-1.4.md).
    func event(_ data: Data, seq: UInt8 = 0) {
        notify(Uuid.cmdNotify, frame(c2: Cmd.event, payload: Data([seq, 0]) + data, key: key))
    }

    func write(_ uuid: String, _ data: Data) async throws {
        if uuid == Uuid.shellWrite {
            notify(Uuid.shellNotify, Data("GETSECRET:\(secret),OK\r\n".utf8))
            return
        }
        var p = FrameParser()
        guard let f = p.feed(data).first, let plain = open(key, f.body) else { return }
        if foreign { notify(Uuid.cmdNotify, frame(c2: f.c2 | 0xA000, payload: Data([9, 9, 9]), key: Data(count: 16))) }
        switch f.c2 {
        case Cmd.ping:
            pings += 1
            notify(Uuid.cmdNotify, frame(c2: f.c2 | 0xA000, payload: Data([0, 2, 1]), key: key))
        case Cmd.msg:
            if status == .ok { inbox.append(Data(plain.dropFirst())) }
            notify(Uuid.cmdNotify, frame(c2: f.c2 | 0xA000, payload: Data([status.rawValue]), key: key))
        default: break
        }
    }
}

@Test func openReadsSecretAndRegisters() async throws {
    let stub = FakeStub()
    let (s, secret) = try await KSession.open(link: stub)
    #expect(secret == stub.secret)
    #expect(await s.key == stub.key)
    #expect(stub.pings == 1, "one PING registers the K host")
    let (slot, flags) = try await s.ping()
    #expect(slot == 2 && flags == 1)
}

@Test func sendAndUnsolicitedRecv() async throws {
    let stub = FakeStub()
    stub.foreign = true
    let (s, _) = try await KSession.open(link: stub, secretHex: stub.secret)
    try await s.send(Data("w1Q\0".utf8))
    #expect(stub.inbox == [Data("w1Q\0".utf8)])
    stub.notify(Uuid.cmdNotify, frame(c2: Cmd.event, payload: Data([0, 0, 1, 2, 3]), key: Data(count: 16)))
    stub.event(Data("w1R1234".utf8))
    #expect(try await s.recv(timeout: .seconds(2)) == Data("w1R1234".utf8))
    let pings = stub.pings
    await #expect(throws: WireError.timeout("no message")) { try await s.recv(timeout: .milliseconds(300)) }
    #expect(stub.pings == pings, "no polling unless asked")
}

@Test func noAppIsReported() async throws {
    let stub = FakeStub()
    stub.status = .noApp
    let (s, _) = try await KSession.open(link: stub, secretHex: stub.secret)
    await #expect(throws: WireError.noApp) { try await s.send(Data([1])) }
}

@Test func pollingPingsWhileWaiting() async throws {
    let stub = FakeStub()
    let (s, _) = try await KSession.open(link: stub, secretHex: stub.secret, poll: .milliseconds(50))
    _ = try? await s.recv(timeout: .milliseconds(300))
    #expect(stub.pings >= 3)
}

@Test func openWithoutRegisterSendsNoPing() async throws {
    let stub = FakeStub()
    _ = try await KSession.open(link: stub, register: false)
    #expect(stub.pings == 0, "a stock watch never answers PING")
}

@Test func recvFromKeepsTheSlot() async throws {
    let stub = FakeStub()
    let (s, _) = try await KSession.open(link: stub, secretHex: stub.secret)
    stub.notify(Uuid.cmdNotify, frame(c2: Cmd.event, payload: Data([5, 3]) + Data("R1Q".utf8), key: stub.key))
    let got = try await s.recvFrom(timeout: .seconds(2))
    #expect(got.slot == 3 && got.data == Data("R1Q".utf8))
}
