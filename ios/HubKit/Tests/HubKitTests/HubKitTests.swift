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
