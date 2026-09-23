import Foundation

/// The lowest backend `desktop_contract` an app needs, supplied by the app.
/// The backend reports its contract in session-info shapes
/// (`SessionHandle.desktopContract`, `probeDesktopContract()`); an app
/// compares it against its own requirement to decide whether to warn.
///
/// Each app picks its own minimum, because what an app needs depends on the
/// protocol paths it has adopted. An app answering prompts only through the
/// contract-6 events still works against a newer backend as long as it has
/// not switched on `ServerRequestPolicy`, and an app that has switched it on
/// needs contract 7.
public struct DesktopContractRequirement: Sendable, Equatable {
    public var minimum: Int

    public init(minimum: Int) {
        self.minimum = minimum
    }

    /// Contract 6: `plugins.manage` canonical keys; prompts arrive as
    /// `<kind>.request` events. The baseline MercuryKit was reconciled at.
    public static let promptEvents = Self(minimum: 6)
    /// Contract 7: prompts are server→client requests (`ServerRequest`),
    /// withdrawn by `request.cancel` and replayed as `open_requests`.
    public static let serverRequests = Self(minimum: 7)

    public enum Assessment: Sendable, Equatable {
        /// The backend did not report a contract (it predates the field).
        case unknown
        /// Older than `minimum`: expect missing protocol features.
        case older(Int)
        /// At or above `minimum`. A newer backend is not a warning: its
        /// additions are opt-in (contract 8 is connector RPCs only).
        case satisfied(Int)
    }

    public func assess(_ reported: Int?) -> Assessment {
        guard let reported else { return .unknown }
        return reported < minimum ? .older(reported) : .satisfied(reported)
    }
}
