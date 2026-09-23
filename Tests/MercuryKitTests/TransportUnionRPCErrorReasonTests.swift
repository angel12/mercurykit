import Foundation
import Testing

@testable import MercuryKit

/// prompt.submit refusals carry a machine-readable `error.data.reason`
/// (hermes_cli/active_sessions.py: "the reason is the contract; the message
/// is for people"). The app must branch on the reason, never the prose —
/// and the voice notice must be speakable: no pids, paths, or timestamps.
@Suite("RPC refusal reasons")
struct TransportUnionRPCErrorReasonTests {
    /// The raw server prose these errors replace — asserting it stays OUT
    /// of the friendly copy.
    private static let serverProse =
        "Session abc123 already has a live owner (gui, pid 4821, running 3m)."

    private func refusal(_ reason: String) -> HermesError {
        .rpcError(
            code: HermesError.RPCCode.sessionSlotRefused,
            message: Self.serverProse,
            data: .object(["reason": .string(reason)]))
    }

    @Test func reasonIsExtractedFromData() {
        let error = refusal(HermesError.RefusalReason.sessionNotOwned)
        #expect(error.rpcReason == "SESSION_NOT_OWNED")
    }

    @Test func reasonIsNilWithoutData() {
        let error = HermesError.rpcError(code: 4090, message: "busy", data: nil)
        #expect(error.rpcReason == nil)
    }

    @Test func reasonIsNilForOtherCases() {
        #expect(HermesError.notConnected.rpcReason == nil)
    }

    @Test func sessionNotOwnedSpeaksCloseTheOtherApp() {
        let text = refusal(HermesError.RefusalReason.sessionNotOwned)
            .errorDescription ?? ""
        #expect(text.contains("Another app"))
        #expect(!text.contains("pid"))
        #expect(!text.contains("abc123"))
    }

    @Test func maxConcurrentSpeaksTryAgain() {
        let text = refusal(HermesError.RefusalReason.maxConcurrentSessions)
            .errorDescription ?? ""
        #expect(text.contains("session limit"))
        #expect(!text.contains("pid"))
    }

    @Test func coordinationUnavailableNamesTheRegistry() {
        let text = refusal(HermesError.RefusalReason.coordinationUnavailable)
            .errorDescription ?? ""
        #expect(text.contains("registry"))
        // Server prose for this reason names a filesystem path; the spoken
        // notice must not.
        #expect(!text.contains("/"))
    }

    @Test func storageUnavailableByCodeAlone() {
        // 5072 carries no data.reason — mapped by code.
        let error = HermesError.rpcError(
            code: HermesError.RPCCode.sessionStorageUnavailable,
            message: "session storage unavailable: state.db could not be opened — repair state.db",
            data: nil)
        let text = error.errorDescription ?? ""
        #expect(text.contains("storage"))
        #expect(!text.contains("state.db"))
    }

    @Test func unknownReasonFallsBackToGeneric() {
        let error = refusal("SOME_FUTURE_REASON")
        #expect(error.errorDescription == "Hermes error 4090: \(Self.serverProse)")
    }

    @Test func unknownCodeWithoutReasonStaysGeneric() {
        let error = HermesError.rpcError(code: 4007, message: "session not found", data: .null)
        #expect(error.errorDescription == "Hermes error 4007: session not found")
    }

    // Reattach refusals (tui_gateway session_lifecycle `_reattach_refusal`):
    // issued before prompt.submit accepts anything, so one resubmit is safe.

    @Test func sessionNotLiveIsClassifiedByCode() {
        let error = HermesError.rpcError(
            code: 4007, message: "session no longer live; retry resume", data: nil)
        #expect(error.isSessionNotLive)
        #expect(!error.isInterruptSettling)
    }

    @Test func interruptSettlingIsClassifiedByCode() {
        let error = HermesError.rpcError(
            code: 4009, message: "session disconnect interrupt settling", data: nil)
        #expect(error.isInterruptSettling)
        #expect(!error.isSessionNotLive)
    }

    // Contract-wire codes added upstream since the contract-6 baseline.

    @Test func unknownParameterIsClassifiedAndExplained() {
        let error = HermesError.rpcError(
            code: 4000,
            message: "invalid params for session.resume: lazy: extra inputs are not permitted — the client and the Hermes backend are out of sync",
            data: nil)
        #expect(error.isUnknownParameter)
        let text = error.errorDescription ?? ""
        #expect(text.contains("out of sync"))
        #expect(!text.contains("session.resume"))
    }

    @Test func profileUnavailableIsClassifiedAndExplained() {
        let error = HermesError.rpcError(code: 4064, message: "profile 'x/../y' is unavailable", data: nil)
        #expect(error.isProfileUnavailable)
        #expect(error.errorDescription == "That profile isn't available on this server.")
    }

    @Test func backendRetiringIsClassifiedAndExplained() {
        let error = HermesError.rpcError(
            code: 5035, message: "backend is retiring; reconnect to continue", data: nil)
        #expect(error.isBackendRetiring)
        #expect(error.errorDescription == "The Hermes server is restarting. Try again in a moment.")
    }

    @Test func classifiersIgnoreOtherErrors() {
        let others: [HermesError] = [
            .notConnected,
            .rpcError(code: 4090, message: "refused", data: nil),
            .rpcError(code: -32601, message: "unknown method", data: nil),
            .connectionClosed(nil),
            .timeout("x"),
        ]
        for error in others {
            #expect(!error.isSessionNotLive)
            #expect(!error.isInterruptSettling)
            #expect(!error.isUnknownParameter)
            #expect(!error.isProfileUnavailable)
            #expect(!error.isBackendRetiring)
        }
    }
}
