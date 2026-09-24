import Foundation
import Testing

/// Apple requires an SDK to declare its own required-reason API use in a
/// privacy manifest it ships; the consuming app's manifest doesn't cover it
/// (angel12/mercurychat#100). MercuryKit's only such use is
/// `ProcessInfo.systemUptime`, the default clock `HermesConnection` measures
/// failure durations with — reason 35F9.1, elapsed time between in-app
/// events. Add a category here when the kit starts using another listed API.
@Suite("Privacy manifest")
struct PrivacyManifestTests {
    private final class Marker {}

    private static let sourceManifest = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/MercuryKit/PrivacyInfo.xcprivacy")

    private static func plist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }

    @Test func declaresSystemBootTimeForElapsedTimeOnly() throws {
        let manifest = try Self.plist(at: Self.sourceManifest)
        let accessed = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let declared = Dictionary(
            uniqueKeysWithValues: accessed.map {
                ($0["NSPrivacyAccessedAPIType"] as? String ?? "",
                 $0["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
            })
        #expect(declared == ["NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]])
    }

    @Test func declaresNoTrackingAndNoCollectedData() throws {
        let manifest = try Self.plist(at: Self.sourceManifest)
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
    }

    /// The manifest only counts if it ships: SwiftPM must copy it into the
    /// package's resource bundle, which apps embed.
    @Test func shipsInThePackageResourceBundle() throws {
        let products = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
        let candidates = [
            products.appending(path: "MercuryKit_MercuryKit.bundle/PrivacyInfo.xcprivacy"),
            products.appending(path: "MercuryKit_MercuryKit.bundle/Contents/Resources/PrivacyInfo.xcprivacy"),
        ]
        let shipped = try #require(
            candidates.first { FileManager.default.fileExists(atPath: $0.path) },
            "no PrivacyInfo.xcprivacy in the MercuryKit resource bundle under \(products.path)")
        #expect(try Self.plist(at: shipped) as NSDictionary == Self.plist(at: Self.sourceManifest) as NSDictionary)
    }
}
