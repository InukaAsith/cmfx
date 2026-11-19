import Foundation
import Testing
@testable import WireKit

/// Made by tools/ota-vectors.ts from fmc_frontend's own inspectOtaImage and Watch.flashFirmware.
struct OtaVectors: Decodable {
    struct Image: Decodable { let name, hex: String; let refuse: String?; let board: String?; let version_code: Int? }
    struct Flash: Decodable { let key, image: String; let notifications, writes: [[String]]; let progress: [Int] }
    let images: [Image]
    let flash: Flash

    static let shared: OtaVectors = {
        let url = Bundle.module.url(forResource: "ota-vectors", withExtension: "json")!
        return try! JSONDecoder().decode(OtaVectors.self, from: Data(contentsOf: url))
    }()
}

let ov = OtaVectors.shared

@Test func otaGateMatchesSite() {
    for i in ov.images {
        do {
            let info = try inspectOtaImage(hex(i.hex))
            #expect(i.refuse == nil, "\(i.name): the site refuses it (\(i.refuse ?? ""))")
            #expect(info.board == i.board && info.versionCode == i.version_code, "\(i.name)")
        } catch OtaError.notFlashable(let why) {
            #expect(i.refuse == "not a flashable image: \(why)", "\(i.name)")
        } catch {
            Issue.record("\(i.name): \(error)")
        }
    }
}

@Test func otaTargetIsWatchPro2Only() throws {
    let ok = try inspectOtaImage(hex(ov.images.first { $0.name == "ok" }!.hex))
    let pro3 = try inspectOtaImage(hex(ov.images.first { $0.name == "watch_3_pro" }!.hex))
    try checkOtaTarget(ok, watchName: "CMF Watch Pro 2-1A2B")
    #expect(throws: OtaError.self) { try checkOtaTarget(ok, watchName: "CMF Watch 3 Pro-9A9D") }
    #expect(throws: OtaError.self) { try checkOtaTarget(ok, watchName: nil) }
    #expect(throws: OtaError.self) { try checkOtaTarget(pro3, watchName: "CMF Watch Pro 2-1A2B") }
}

/// The site's watch, replayed: A052 after 0x9052, everything else after 0x9040.
final class OtaWatch: Link, @unchecked Sendable {
    var handler: (@Sendable (String, Data) -> Void)?
    var writes: [[String]] = []
    let names = [Uuid.cmdWrite: "fff2", OtaUuid.write: "ff01"]
    let uuids = ["fff1": Uuid.cmdNotify, "ff02": OtaUuid.notify]
    var notes = ov.flash.notifications

    func onNotify(_ handler: @escaping @Sendable (String, Data) -> Void) { self.handler = handler }

    func write(_ uuid: String, _ f: Data) async throws {
        writes.append([names[uuid] ?? uuid, f.hexString])
        let cmd = UInt32(f.be16(at: 3)) << 16 | UInt32(f.be16(at: 9))
        let upTo = cmd == StockCmd.otaBeginReq ? 1 : cmd == StockCmd.otaStartReq ? notes.count : 0
        for n in notes.prefix(upTo) { handler?(uuids[n[0]]!, hex(n[1])) }
        notes.removeFirst(upTo)
    }
}

@Test func flashWritesWhatTheSiteWrites() async throws {
    let w = OtaWatch()
    let s = StockSession(link: w, key: hex(ov.flash.key))
    nonisolated(unsafe) var seen: [Int] = []
    try await s.flashFirmware(hex(ov.flash.image)) { seen.append($0) }
    #expect(w.writes == ov.flash.writes)
    #expect(seen == ov.flash.progress)
}

@Test func flashStopsOnRefusal() async throws {
    let w = OtaWatch()
    let key = hex(ov.flash.key)
    w.notes = [["fff1", stockFrames(StockCmd.otaBeginRep, Data([0]), key: key)[0].hexString]]
    let s = StockSession(link: w, key: key)
    await #expect(throws: OtaError.refused("The watch refused the update (00).")) {
        try await s.flashFirmware(hex(ov.flash.image)) { _ in }
    }
    #expect(w.writes.count == 1, "nothing after the refusal, 0x9040 least of all")
}

/// A real image through the gate: OTA_IMAGE=path swift test --filter realImage
@Test(.enabled(if: ProcessInfo.processInfo.environment["OTA_IMAGE"] != nil)) func realImage() throws {
    let d = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["OTA_IMAGE"]!))
    let info = try inspectOtaImage(d)
    try checkOtaTarget(info, watchName: "CMF Watch Pro 2-0000")
    print("OTA_IMAGE:", info)
}
