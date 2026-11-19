import Foundation

// storage (docs/miniapp-rpc.md, 0x60–0x62): a watch app's key/value store on the phone, past the watch's 4 KiB.
// One file per key under <root>/<package as hex>/; the app gives a root kept out of backups.

/// A key: 1–16 bytes of `A–Z a–z 0–9 . _ -` (safe as a file name); BAD_REQUEST otherwise.
public func storageKey(_ d: Data) throws -> String {
    let ok = (1...16).contains(d.count) && d.allSatisfy { b in
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || [0x2E, 0x5F, 0x2D].contains(b)
    }
    guard ok, let s = String(data: d, encoding: .ascii) else { throw RPCStatus.badRequest }
    return s
}

/// `length:u16`, then the value in 121-byte chunks.
public func valueRecords(_ value: Data) -> [Data] {
    var head = Data()
    head.le(UInt16(clamping: value.count))
    return [head] + stride(from: 0, to: value.count, by: 121).map {
        Data(value[value.startIndex + $0..<value.startIndex + min($0 + 121, value.count)])
    }
}

public final class KeyValueStore: @unchecked Sendable {
    /// Keys and values together, per package.
    public static let quota = 64 * 1024
    let root: URL

    public init(root: URL) { self.root = root }

    func dir(_ package: String) -> URL {
        root.appendingPathComponent(Data(package.utf8).map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }

    public func get(_ package: String, _ key: String) -> Data? {
        try? Data(contentsOf: dir(package).appendingPathComponent(key))
    }

    /// TOO_LARGE when the package would go over its quota.
    public func put(_ package: String, _ key: String, _ value: Data) throws {
        let others = used(package) - (get(package, key).map { $0.count + key.utf8.count } ?? 0)
        guard others + key.utf8.count + value.count <= Self.quota else { throw RPCStatus.tooLarge }
        try FileManager.default.createDirectory(at: dir(package), withIntermediateDirectories: true)
        try value.write(to: dir(package).appendingPathComponent(key), options: .atomic)
    }

    public func delete(_ package: String, _ key: String) {
        try? FileManager.default.removeItem(at: dir(package).appendingPathComponent(key))
    }

    /// Delete from the Watch.
    public func clear(_ package: String) { try? FileManager.default.removeItem(at: dir(package)) }

    /// Bytes of keys and values the package holds.
    public func used(_ package: String) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir(package), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + $1.lastPathComponent.utf8.count + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
