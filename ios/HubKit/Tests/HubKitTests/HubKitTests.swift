import Foundation
import Testing
import HubKit

@Test func matchesThePythonHosts() throws {
    let url = try #require(Bundle.module.url(forResource: "vectors", withExtension: "json"))
    let bad = try Checks.run(try Data(contentsOf: url))
    #expect(bad.isEmpty, "\(bad.joined(separator: "\n"))")
}

/// The bytes the watch's Compass parses (cmf-watch-sdk sdk/examples/compass/src/model.rs tests).
@Test func compassHeading() {
    #expect(CompassProto.heading(123.6, accuracy: 7, trueNorth: true, calibrate: true) == Data([0x48, 0xD4, 0x04, 7, 3]))
    #expect(CompassProto.heading(359.96, accuracy: nil, trueNorth: false, calibrate: false) == Data([0x48, 0, 0, 255, 0]))
    #expect(CompassProto.heading(-5, accuracy: -1, trueNorth: false, calibrate: false) == Data([0x48, 0xDE, 0x0D, 255, 0]))
    #expect(CompassProto.parse(Data("R".utf8)) == .ready)
    #expect(CompassProto.parse(Data("Z".utf8)) == .closed)
    #expect(CompassProto.parse(Data("Q".utf8)) == nil)
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
    #expect(AtlasProto.usingWatchGPS == Data("y".utf8))
}
