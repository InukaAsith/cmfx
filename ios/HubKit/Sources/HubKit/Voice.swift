import Foundation

/// Voice typing and recordings from any watch app (cmf-watch-sdk sdk/cmf-wp2-ui/src/dictate.rs): 8 kHz mono IMA
/// ADPCM in blocks of 240 samples.
///   watch → phone: `~1` dictate, `~3` record, `~a seq:u16 block`, `~0` the end, `~2` cancel.
///   phone → watch: `~ kind text`: 0 the words so far, 1 the final words, 2 a problem.
public enum VoiceProto {
    public static let rate = 8000.0
    /// Bytes of text in a message to the watch.
    public static let textMax = 120

    public enum Ask: Equatable, Sendable {
        case start(record: Bool), audio(seq: UInt16, block: Data), end, cancel
    }

    public static func parse(_ m: Data) -> Ask? {
        let b = [UInt8](m)
        guard b.count >= 2, b[0] == UInt8(ascii: "~") else { return nil }
        switch (b[1], b.count) {
        case (UInt8(ascii: "1"), 2): return .start(record: false)
        case (UInt8(ascii: "3"), 2): return .start(record: true)
        case (UInt8(ascii: "0"), 2): return .end
        case (UInt8(ascii: "2"), 2): return .cancel
        case (UInt8(ascii: "a"), 7...): return .audio(seq: UInt16(b[2]) | UInt16(b[3]) << 8, block: Data(b[4...]))
        default: return nil
        }
    }

    public enum Kind: UInt8, Sendable { case partial = 0, final = 1, problem = 2 }

    /// The words for the watch: the newest ones when they are too long (it shows the end of what is said).
    public static func text(_ kind: Kind, _ s: String) -> Data {
        let full = Data(Emoji.watch(s).utf8)
        var d = full.count <= textMax ? full : full.suffix(textMax)
        while !d.isEmpty, String(data: d, encoding: .utf8) == nil { d.removeFirst() }
        return Data([UInt8(ascii: "~"), kind.rawValue]) + d
    }

    /// One block → its samples.
    public static func decode(_ block: Data) -> [Int16] {
        let b = [UInt8](block)
        guard b.count >= 3, b[2] <= 88 else { return [] }
        var p = Int(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8)), i = Int(b[2])
        var out: [Int16] = []
        out.reserveCapacity((b.count - 3) * 2)
        for byte in b[3...] {
            for code in [Int(byte & 0xF), Int(byte >> 4)] {
                (p, i) = ADPCMEncoder.step(p, i, code)
                out.append(Int16(p))
            }
        }
        return out
    }
}
