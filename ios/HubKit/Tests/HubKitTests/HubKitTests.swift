import Foundation
import Testing
import HubKit

@Test func matchesThePythonHosts() throws {
    let url = try #require(Bundle.module.url(forResource: "vectors", withExtension: "json"))
    let bad = try Checks.run(try Data(contentsOf: url))
    #expect(bad.isEmpty, "\(bad.joined(separator: "\n"))")
}

@Test func browserViewsAndRemove() {
    #expect(BrowserProto.parse(Data([0x56, 0])) == .view(mode: 0))
    #expect(BrowserProto.parse(Data([0x56, 1])) == .view(mode: 1))
    #expect(BrowserProto.parse(Data([0x56, 2])) == .view(mode: 2))
    #expect(BrowserProto.parse(Data([0x44, 3])) == .remove(3))
    #expect(BrowserProto.pageInfo(more: 4) == Data([0x79, 0, 0, 4]))
    #expect(BrowserProto.known(URL(string: "https://en.m.wikipedia.org/wiki/Colombo")))
    #expect(BrowserProto.known(URL(string: "https://www.google.com/search?q=x")))
    #expect(BrowserProto.known(URL(string: "https://starwars.fandom.com/wiki/Yoda")))
    #expect(BrowserProto.known(URL(string: "https://m.youtube.com/")))
    #expect(!BrowserProto.known(URL(string: "https://example.com/")))
}

@Test func layoutImageSources() {
    let json = #"{"bg":[1,2,3],"boxes":[],"frames":[],"texts":[],"imgs":[[0,0,10,10]],"srcs":[[0,0,10,10,"https://a/b.png"]],"canvas":0,"img":100,"video":0,"chars":0}"#
    let r = Layout.images(json: json)
    #expect(r.boxes.count == 1 && r.sources.count == 1 && r.sources[0].url == "https://a/b.png")
    #expect(Layout.background(json: json) == (1, 2, 3))
}

@Test func atlasWatchFix() {
    // Y lat_e7 lon_e7 alt_dm sats: 6.9271, 79.8612, 10 m, 8 satellites (the watch sim's bytes)
    let m = Data([0x59, 0xd8, 0xfd, 0x20, 0x04, 0x20, 0xda, 0x99, 0x2f, 0x64, 0, 0, 0, 8])
    guard case .watchFix(let lat, let lon, let alt, let sats) = AtlasProto.parse(m) else { Issue.record("no fix"); return }
    #expect(abs(lat - 6.9271) < 1e-7 && abs(lon - 79.8612) < 1e-7 && alt == 10 && sats == 8)
    #expect(AtlasProto.parse(Data("y".utf8)) == .watchGPSOff)
    #expect(AtlasProto.parse(Data("Y".utf8)) == .watchLooking)
    #expect(AtlasProto.usingWatchGPS(phone: true) == Data([0x79, 1]))
    #expect(AtlasProto.usingWatchGPS(phone: false) == Data([0x79, 0]))
}

@Test func offlineMapsPack() {
    // three levels, the frame's grid matching the watch's pack.rs (side x0 y0 cols rows min_k)
    let ls = VectorPack.levels(radiusKm: 10, detailKm: 3)
    #expect(ls.map(\.side) == [8000, 3000, 1500])
    #expect(ls.map(\.n) == [4, 8, 4])
    #expect(ls[2].x0 == -3000)
    let idx = VectorPack.index(ls, lat: 6.9271, lon: 79.8612)
    #expect(idx.count == 17 + 9 * 3)
    #expect(Array(idx.prefix(4)) == Array("WMV1".utf8))
    #expect(Array(idx[4..<8]) == [0xd8, 0xfd, 0x20, 0x04])
    #expect(VectorPack.cellName(level: 1, col: 12, row: 7) == "v1_12_7")
    // a line through a cell with no point in it is kept, cut at the sides
    let cut = VectorPack.clipLine([(-100, 50), (300, 50)], (0, 0), (100, 100))
    #expect(cut.count == 1 && cut[0].first! == (0, 50) && cut[0].last! == (100, 50))
    // out and back in: two pieces
    #expect(VectorPack.clipLine([(10, 10), (200, 10), (200, 90), (10, 90)], (0, 0), (100, 100)).count == 2)
    // a ring over a corner becomes the part inside
    let ring = VectorPack.clipRing([(-50, -50), (50, -50), (50, 50), (-50, 50)], (0, 0), (100, 100))
    #expect(Set(ring.map { "\(Int($0.0)),\(Int($0.1))" }) == ["0,0", "50,0", "50,50", "0,50"])
}

@Test func offlineMapsRoute() {
    // the watch sim's ask: D walk, 6.9271 79.8612, from (0, 0) to (202, 193)
    let m = Data([0x44, 0x02, 0xd8, 0xfd, 0x20, 0x04, 0x20, 0xda, 0x99, 0x2f, 0, 0, 0, 0, 0xca, 0, 0xc1, 0])
    guard let a = VectorPack.parseAsk(m) else { Issue.record("no ask"); return }
    #expect(a.walk && a.from! == (0, 0) && a.to == (202, 193))
    #expect(abs(a.origin.lat - 6.9271) < 1e-7)
    var far = m; far[10] = 0; far[11] = 0x80
    #expect(VectorPack.parseAsk(far)!.from == nil)  // i16.min: from where the phone is
    // G n metres secs, then g seq points (30 a message)
    let pts = (0..<70).map { (Double($0) * 10, Double($0 % 2) * 50) }
    let msgs = VectorPack.route(pts, metres: 700, secs: 500)
    #expect(msgs[0] == Data([0x47, 70, 0, 0xbc, 0x02, 0, 0, 0xf4, 0x01, 0, 0]))
    #expect(msgs.count == 4 && msgs[1][1] == 0 && msgs[3][1] == 2 && msgs[3].count == 2 + 10 * 4)
}
