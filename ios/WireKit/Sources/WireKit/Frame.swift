import CommonCrypto
import Foundation

// The stub's frames (src/wp2apps/link.py): header F5, length, c1, 1, 1, c2 (big endian); body sealed as
// plain ‖ crc32le, PKCS7, AES-128-CBC with a fixed IV. K is the pairing secret (docs/abi-1.4.md).

public let system: UInt16 = 0xFFFF
let iv = Data([0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x5A])
let plainReplies: Set<UInt16> = [0x0048] // watch→phone frames in the clear declare a length with the CRC but omit it

private let crcTable: [UInt32] = (0..<256).map { n in
    (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
}

/// zlib's CRC-32.
public func crc32(_ data: Data) -> UInt32 {
    ~data.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
}

extension Data {
    mutating func le<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func be<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    func le<T: FixedWidthInteger>(_: T.Type, at i: Int) -> T {
        (0..<MemoryLayout<T>.size).reduce(T(0)) { $0 | T(self[startIndex + i + $1]) << (8 * $1) }
    }
    func be16(at i: Int) -> UInt16 { UInt16(self[startIndex + i]) << 8 | UInt16(self[startIndex + i + 1]) }
}

private func aes(_ op: CCOperation, _ key: Data, _ input: Data) -> Data? {
    guard key.count == 16 else { return nil }
    var out = Data(count: input.count + 16)
    var n = 0
    let status = out.withUnsafeMutableBytes { o in
        input.withUnsafeBytes { i in
            key.withUnsafeBytes { k in
                iv.withUnsafeBytes { v in
                    CCCrypt(op, CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, 16, v.baseAddress, i.baseAddress, input.count, o.baseAddress, o.count, &n)
                }
            }
        }
    }
    return status == kCCSuccess ? out.prefix(n) : nil
}

/// `link.encrypt`.
public func seal(_ key: Data, _ plain: Data) -> Data {
    var body = plain
    body.le(crc32(plain))
    return aes(CCOperation(kCCEncrypt), key, body)!
}

/// `link.decrypt`: nil for a wrong key, bad padding or CRC.
public func open(_ key: Data, _ cipher: Data) -> Data? {
    guard !cipher.isEmpty, cipher.count % 16 == 0, let body = aes(CCOperation(kCCDecrypt), key, cipher),
          body.count >= 4 else { return nil }
    let plain = body.prefix(body.count - 4)
    return crc32(plain) == body.le(UInt32.self, at: body.count - 4) ? Data(plain) : nil
}

/// K from the 32 hex chars of `AT GETSECRET`.
public func channelKey(secretHex: String) -> Data? {
    let chars = Array(secretHex.utf8)
    guard chars.count == 32 else { return nil }
    var key = Data()
    for i in stride(from: 0, to: 32, by: 2) {
        guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
        key.append(b)
    }
    return key
}

/// A system frame (c1 0xFFFF), sealed with `key` (nil: plain with CRC).
public func frame(c2: UInt16, payload: Data, key: Data?) -> Data {
    var body: Data
    if let key {
        body = seal(key, payload)
    } else {
        body = payload
        body.le(crc32(payload))
    }
    var f = Data([0xF5])
    f.be(UInt16(body.count))
    f.be(system)
    f.be(UInt16(1))
    f.be(UInt16(1))
    f.be(c2)
    return f + body
}

/// Reassembles frames from notifications (`link.Parser`).
public struct FrameParser {
    var buf = Data()
    public init() {}

    public mutating func feed(_ data: Data) -> [(c1: UInt16, c2: UInt16, body: Data)] {
        buf.append(data)
        var out: [(c1: UInt16, c2: UInt16, body: Data)] = []
        while true {
            guard let start = buf.firstIndex(of: 0xF5) else {
                buf = Data()
                break
            }
            buf = Data(buf[start...])
            guard buf.count >= 11 else { break }
            let length = Int(buf.be16(at: 1)), c1 = buf.be16(at: 3), c2 = buf.be16(at: 9)
            let size = c1 == system && plainReplies.contains(c2) ? length - 4 : length
            guard buf.count >= 11 + size else { break }
            out.append((c1, c2, Data(buf[11..<11 + size])))
            buf = Data(buf[(11 + size)...])
        }
        return out
    }
}
