import Foundation
import Testing
@testable import MercuryKit

@Suite("OAuth reconciliation", .serialized)
struct OAuthReconciliationTests {
    @Test func exchangeRetainsRequestedProviderWhenResponseOmitsIt() async throws {
        let server = try await ScriptedHTTPServer.start { request in
            #expect(request.path == "/auth/native/token")
            #expect(request.method == "POST")
            let body = try? JSONDecoder().decode(JSONValue.self, from: request.body)
            #expect(body?["code"]?.stringValue == "code-1")
            #expect(body?["code_verifier"]?.stringValue == "verifier-1")
            return ScriptedHTTPResponse(200, #"{"access_token":"at","refresh_token":"rt"}"#)
        }
        defer { server.stop() }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let session = try await HermesAuthenticator.exchangeNativeCode(
            endpoint: endpoint, code: "code-1", verifier: "verifier-1", provider: "nous")
        #expect(session.provider == "nous")
        #expect(session.accessToken == "at")
    }

    @Test func cancellationBeforeStartCannotReopenListener() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        await listener.cancel()
        await #expect(throws: LoopbackRedirectListener.ListenerError.failedToStart) {
            try await listener.start()
        }
        await #expect(throws: LoopbackRedirectListener.ListenerError.cancelled) {
            try await listener.waitForRedirect(timeout: 0.1)
        }
    }

    @Test func validatedEarlyRedirectSurvivesLateCancellation() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        let callbackURL = try await listener.start()
        var request = URLRequest(url: URL(string: "\(callbackURL)?code=early&state=s")!)
        request.timeoutInterval = 2
        _ = try await URLSession.shared.data(for: request)
        await listener.cancel()
        let redirect = try await listener.waitForRedirect(timeout: 0.1)
        #expect(redirect.code == "early")
        #expect(redirect.state == "s")
    }

    @Test func redirectBeforeWaitIsBuffered() async throws {
        let listener = LoopbackRedirectListener()
        let callbackURL = try await listener.start()
        var request = URLRequest(url: URL(string: "\(callbackURL)?code=early&state=s")!)
        request.timeoutInterval = 2
        _ = try await URLSession.shared.data(for: request)
        let redirect = try await listener.waitForRedirect(timeout: 0.1)
        #expect(redirect.code == "early")
        #expect(redirect.state == "s")
    }
}
