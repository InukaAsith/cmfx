import Foundation
import Testing
@testable import WireKit

/// Byte-for-byte equal to the Python host (tests/ios_vectors.py). vectors.json is the shared file, unchanged:
/// it also holds the workout app's vectors, which this package does not read. Android runs the same file.
struct Vectors: Decodable {
    struct Seal: Decodable { let key: String; let plain: String; let cipher: String }
    struct Key: Decodable { let secret: String; let key: String }
    struct FrameV: Decodable { let c2: UInt16; let payload: String; let key: String; let hex: String }
    let seal: Seal
    let channel_key: Key
    let frame: FrameV
    struct Pkg: Decodable {
        let hex: String; let name: String; let version: UInt32; let kind: Int; let info_reply_hex: String
        let begin_hex: String; let data_hex: [String]; let end_hex: String
    }
    let package: Pkg

    static let shared: Vectors = {
        let url = Bundle.module.url(forResource: "vectors", withExtension: "json")!
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()
}

func hex(_ s: String) -> Data {
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        d.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return d
}

let v = Vectors.shared

@Test func sealOpen() {
    let key = hex(v.seal.key)
    #expect(seal(key, hex(v.seal.plain)) == hex(v.seal.cipher))
    #expect(open(key, hex(v.seal.cipher)) == hex(v.seal.plain))
    var bad = hex(v.seal.cipher)
    bad[0] ^= 1
    #expect(open(key, bad) == nil)
    #expect(open(Data(repeating: 1, count: 16), hex(v.seal.cipher)) == nil)
}

@Test func channelKeyFromSecret() {
    #expect(channelKey(secretHex: v.channel_key.secret) == hex(v.channel_key.key))
    #expect(channelKey(secretHex: "zz") == nil)
}

@Test func frameMatchesPython() {
    let f = frame(c2: v.frame.c2, payload: hex(v.frame.payload), key: hex(v.frame.key))
    #expect(f == hex(v.frame.hex))
    var p = FrameParser()
    let raw = hex(v.frame.hex)
    #expect(p.feed(raw.prefix(5)).isEmpty)
    let got = p.feed(raw.dropFirst(5))
    #expect(got.count == 1)
    #expect(got.first?.c1 == 0xFFFF && got.first?.c2 == v.frame.c2)
    #expect(got.first.flatMap { open(hex(v.frame.key), $0.body) } == hex(v.frame.payload))
}
