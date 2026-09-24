// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MercuryKit",
    platforms: [.iOS(.v17), .macOS(.v14), .visionOS(.v2)],
    products: [.library(name: "MercuryKit", targets: ["MercuryKit"])],
    targets: [.target(
                  name: "MercuryKit",
                  // Apple requires an SDK to ship its own required-reason
                  // API declarations; apps embed this resource bundle.
                  resources: [.copy("PrivacyInfo.xcprivacy")]),
              .testTarget(name: "MercuryKitTests", dependencies: ["MercuryKit"])]
)
