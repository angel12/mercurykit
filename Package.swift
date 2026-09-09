// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MercuryKit",
    platforms: [.iOS(.v17), .macOS(.v14), .visionOS(.v2)],
    products: [.library(name: "MercuryKit", targets: ["MercuryKit"])],
    targets: [.target(name: "MercuryKit"),
              .testTarget(name: "MercuryKitTests", dependencies: ["MercuryKit"])]
)
