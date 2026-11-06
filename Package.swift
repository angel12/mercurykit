// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MercuryKit",
    platforms: [.iOS(.v17), .macOS(.v14), .visionOS(.v2)],
    products: [
        .library(name: "MercuryKit", targets: ["MercuryKit"]),
        .library(name: "MercuryVoiceEngine", targets: ["MercuryVoiceEngine"]),
    ],
    targets: [.target(
                  name: "MercuryKit",
                  // Apple requires an SDK to ship its own required-reason
                  // API declarations; apps embed this resource bundle.
                  resources: [.copy("PrivacyInfo.xcprivacy")]),
              // Mercury Voice's audio + conversation engine, on MercuryKit.
              .target(
                  name: "MercuryVoiceEngine",
                  dependencies: ["MercuryKit"],
                  // The engine stores preferences in UserDefaults; its
                  // required-reason declaration ships with it.
                  resources: [.copy("PrivacyInfo.xcprivacy")]),
              .testTarget(name: "MercuryKitTests", dependencies: ["MercuryKit"]),
              .testTarget(
                  name: "MercuryVoiceEngineTests",
                  dependencies: ["MercuryVoiceEngine", "MercuryKit"])]
)
