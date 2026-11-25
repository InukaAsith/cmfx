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
