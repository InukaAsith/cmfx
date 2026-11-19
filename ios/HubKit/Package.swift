// swift-tools-version: 6.0
// CMFX's side of the watch apps (cmf-watch-sdk sdk/examples: spotify, assistant, maps, nav, pixview): message
// builders and the picture encoders, without UIKit, tested on a Mac with `swift test`.
import PackageDescription

let package = Package(
    name: "HubKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "HubKit", targets: ["HubKit"])],
    targets: [
        .target(name: "HubKit"),
        .testTarget(name: "HubKitTests", dependencies: ["HubKit"], resources: [.copy("vectors.json")]),
    ]
)
