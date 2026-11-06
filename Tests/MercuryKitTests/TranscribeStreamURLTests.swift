import Foundation
import Testing

@testable import MercuryKit

/// Upstream 00adf69d92: live transcription streams PCM over
/// `/api/audio/transcribe-stream`, authenticated like speak-stream.
@Suite("transcribe-stream URL")
struct TranscribeStreamURLTests {
    private func client(token: String? = "session-token") -> HermesRESTClient {
        HermesRESTClient(
            endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:8642")!),
            token: token)
    }

    @Test func usesTheTranscribeStreamPathOnTheWebSocketScheme() async throws {
        let url = try await client().transcribeStreamURL(profile: nil)
        #expect(url.scheme == "ws")
        #expect(url.path == "/api/audio/transcribe-stream")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!items.contains { $0.name == "profile" })
    }

    @Test func carriesTheProfileAndTheSameAuthAsSpeakStream() async throws {
        let rest = client()
        let transcribe = try await rest.transcribeStreamURL(profile: "work")
        let speak = try await rest.speakStreamURL(profile: "work")
        let tItems = URLComponents(url: transcribe, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let sItems = URLComponents(url: speak, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(tItems.first { $0.name == "profile" }?.value == "work")
        #expect(Set(tItems.map(\.name)) == Set(sItems.map(\.name)))
    }
}
