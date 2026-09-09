import Foundation
import Testing
@testable import MercuryKit

struct VoiceAPICompletenessTests {
    @Test func voiceEventNamesArePublic() {
        #expect(GatewayEvent.Kind.sessionResumeProgress == "session.resume_progress")
        #expect(GatewayEvent.Kind.sessionReclaimed == "session.reclaimed")
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
