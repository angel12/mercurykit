import Foundation
import Testing

@testable import MercuryKit

/// Fixtures are verbatim `apns_request()` payloads from angel12/mercury-push (envelope v1).
@Suite("PushPayload")
struct PushPayloadTests {
    static let approval = #"{"aps":{"alert":{"title":"Hermes","body":"x"},"sound":"default","mutable-content":1,"interruption-level":"time-sensitive","thread-id":"20260929_101500_abc"},"mercury":{"v":1,"kind":"approval","event_id":"3f2b1c9e-8d7a-4b6c-9e5f-1a2b3c4d5e6f","profile":"default","session_id":"20260929_101500_abc","session_key":"agent:main:tui:dm:x","request_id":"req-1"}}"#
    static let responseReady = #"{"aps":{"alert":{"title":"Hermes","body":"x"},"sound":"default","mutable-content":1,"interruption-level":"active","thread-id":"20260929_101500_abc"},"mercury":{"v":1,"kind":"response_ready","event_id":"3f2b1c9e-8d7a-4b6c-9e5f-1a2b3c4d5e6f","profile":"coder","session_id":"20260929_101500_abc"}}"#
    static let cron = #"{"aps":{"alert":{"title":"Hermes","body":"x"},"sound":"default","mutable-content":1,"interruption-level":"active","thread-id":"cron-job123"},"mercury":{"v":1,"kind":"cron","event_id":"3f2b1c9e-8d7a-4b6c-9e5f-1a2b3c4d5e6f","profile":"default","cron_job":"Morning brief"}}"#
    static let test = #"{"aps":{"alert":{"title":"Hermes","body":"x"},"sound":"default","mutable-content":1,"interruption-level":"active"},"mercury":{"v":1,"kind":"test","event_id":"3f2b1c9e-8d7a-4b6c-9e5f-1a2b3c4d5e6f","profile":"default"}}"#
    static let stampedApproval = #"{"aps":{"alert":{"title":"Hermes","body":"x"},"sound":"default","mutable-content":1,"interruption-level":"time-sensitive","thread-id":"20260929_101500_abc"},"mercury":{"v":1,"kind":"approval","event_id":"3f2b1c9e-8d7a-4b6c-9e5f-1a2b3c4d5e6f","profile":"coder","session_id":"20260929_101500_abc","request_id":"req-1","device_id":"dev_ab12cd34ef56ab78"}}"#

    /// What UNNotificationContent.userInfo looks like: JSONSerialization output.
    static func userInfo(_ json: String) -> [AnyHashable: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [AnyHashable: Any] ?? [:]
    }

    @Test func decodesApproval() throws {
        let payload = try #require(PushPayload(userInfo: Self.userInfo(Self.approval)))
        #expect(payload.version == 1)
        #expect(payload.kind == .approval)
        #expect(payload.eventID == "3f2b1c9e-8d7a-4b6c-9e5f-1a2b3c4d5e6f")
        #expect(payload.profile == "default")
        #expect(payload.sessionID == "20260929_101500_abc")
        #expect(payload.sessionKey == "agent:main:tui:dm:x")
        #expect(payload.requestID == "req-1")
        #expect(payload.cronJob == nil)
        #expect(payload.route == .session(id: "20260929_101500_abc", profile: "default"))
    }

    @Test func decodesEveryKind() throws {
        #expect(try #require(PushPayload(userInfo: Self.userInfo(Self.responseReady))).kind == .responseReady)
        let cron = try #require(PushPayload(userInfo: Self.userInfo(Self.cron)))
        #expect(cron.kind == .cron)
        #expect(cron.cronJob == "Morning brief")
        #expect(cron.route == .none)
        #expect(try #require(PushPayload(userInfo: Self.userInfo(Self.test))).kind == .test)
        for (wire, kind) in [("turn_failed", PushPayload.Kind.turnFailed), ("task_done", .taskDone)] {
            let info: [AnyHashable: Any] = ["mercury": ["v": 1, "kind": wire, "event_id": "e", "profile": "p"]]
            #expect(PushPayload(userInfo: info)?.kind == kind)
        }
    }

    @Test func routesBySessionKeyWhenNoSessionID() {
        let info: [AnyHashable: Any] = [
            "mercury": ["v": 1, "kind": "approval", "event_id": "e", "profile": "coder", "session_key": "k"]
        ]
        #expect(PushPayload(userInfo: info)?.route == .sessionKey("k", profile: "coder"))
    }

    @Test func emptyStringsAreAbsent() {
        let info: [AnyHashable: Any] = [
            "mercury": ["v": 1, "kind": "approval", "event_id": "e", "profile": "p", "session_id": ""]
        ]
        #expect(PushPayload(userInfo: info)?.sessionID == nil)
    }

    @Test func toleratesFutureVersionsAndKinds() throws {
        let info: [AnyHashable: Any] = [
            "mercury": ["v": 2, "kind": "live_update", "event_id": "e", "profile": "p", "ciphertext": "abc", "session_id": "s"]
        ]
        let payload = try #require(PushPayload(userInfo: info))
        #expect(payload.version == 2)
        #expect(payload.kind == .unknown("live_update"))
        #expect(payload.sessionID == "s")
    }

    @Test func rejectsMissingOrMalformedBlock() {
        #expect(PushPayload(userInfo: [:]) == nil)
        #expect(PushPayload(userInfo: ["mercury": "nope"]) == nil)
        #expect(PushPayload(userInfo: ["mercury": ["kind": "approval", "profile": "p"]]) == nil)  // no event_id
        #expect(PushPayload(userInfo: ["mercury": ["event_id": "e", "profile": "p"]]) == nil)  // no kind
        #expect(PushPayload(userInfo: ["mercury": ["kind": "test", "event_id": "e"]]) == nil)  // no profile
    }

    @Test func decodesDeviceID() throws {
        let payload = try #require(PushPayload(userInfo: Self.userInfo(Self.stampedApproval)))
        #expect(payload.deviceID == "dev_ab12cd34ef56ab78")
        #expect(payload.profile == "coder")
    }

    @Test func deviceIDIsOptional() throws {
        #expect(try #require(PushPayload(userInfo: Self.userInfo(Self.approval))).deviceID == nil)
        let info: [AnyHashable: Any] = ["mercury": ["v": 1, "kind": "test", "event_id": "e", "profile": "p", "device_id": ""]]
        #expect(PushPayload(userInfo: info)?.deviceID == nil)
    }
}
