import Foundation
import Testing
@testable import MercuryKit

struct VoiceAPICompletenessTests {
    @Test func voiceEventNamesArePublic() {
        #expect(GatewayEvent.Kind.sessionResumeProgress == "session.resume_progress")
        #expect(GatewayEvent.Kind.sessionReclaimed == "session.reclaimed")
    }

    /// Names mercury-voice #126 added to its kit (and Chat needs too).
    @Test func contract7EventNamesArePublic() {
        #expect(GatewayEvent.Kind.serverRequest == "mercury.server_request")
        #expect(GatewayEvent.Kind.requestCancel == "request.cancel")
        #expect(GatewayEvent.Kind.notificationClear == "notification.clear")
        #expect(GatewayEvent.Kind.subagentStart == "subagent.start")
        #expect(GatewayEvent.Kind.subagentComplete == "subagent.complete")
        #expect(GatewayEvent.Kind.connectionRequest == "connection.request")
        #expect(GatewayEvent.Kind.connectionUpdate == "connection.update")
        #expect(GatewayEvent.StatusKind.compacting == "compacting")
        #expect(GatewayEvent.StatusKind.compacted == "compacted")
    }

    /// Voice answers approval and clarify; Chat adds sudo and secret. Both
    /// default off until each app's adoption PR.
    @Test func serverRequestPoliciesPerApp() {
        #expect(ServerRequestPolicy.voice.answerableMethods == ["approval", "clarify"])
        #expect(ServerRequestPolicy.chat.answerableMethods == ["approval", "clarify", "sudo", "secret"])
        #expect(ServerRequestPolicy.voice.unanswerable == .leaveForOtherClients)
        #expect(!ServerRequestPolicy.disabled.isEnabled)
    }

    @Test(arguments: [nil, "work"] as [String?])
    func voiceConfigUsesProfileScopedGET(profile: String?) async throws {
        let server = try await ScriptedHTTPServer.start { _ in
            ScriptedHTTPResponse(200, "{}")
        }
        defer { server.stop() }
        let client = HermesRESTClient(
            endpoint: try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint,
            token: "test-token")
        _ = try await client.voiceConfig(profile: profile)
        #expect(server.requests.map(\.method) == ["GET"])
        #expect(server.requests.map(\.path) == [profile == nil ? "/api/audio/voice-config" : "/api/audio/voice-config?profile=work"])
    }
}
