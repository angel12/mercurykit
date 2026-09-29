import Foundation
import Testing

@testable import MercuryKit

@Suite("PushRelayClient", .timeLimit(.minutes(1)))
struct PushRelayClientTests {
    static let token = String(repeating: "ab", count: 32)

    @Test func dateParserAcceptsRelayTimestamps() {
        let whole = PushDate.parse("2026-09-21T14:13:20Z")
        #expect(whole == Date(timeIntervalSince1970: 1_790_000_000))
        let fractional = PushDate.parse("2026-09-21T14:13:20.123456Z")
        #expect(abs((fractional?.timeIntervalSince1970 ?? 0) - 1_790_000_000.123456) < 0.000_01)
        #expect(PushDate.parse("2026-09-21 14:13:20") == nil)
        #expect(PushDate.parse("") == nil)
    }

    @Test func registerSendsBodyAndDecodesRegistration() async throws {
        let server = try await RoutedHTTPServer.start { _ in
            .init(201, #"{"installation_id":"inst_1","installation_secret":"s3cret","pairing_code":"ABCDE-FGHJK","pairing_expires_at":"2026-09-21T14:13:20Z"}"#)
        }
        defer { server.stop() }
        let relay = PushRelayClient(baseURL: pushTestURL(port: server.port))

        let registration = try await relay.register(
            bundleID: "com.spencermcguire.mercurychat", deviceToken: Self.token, environment: .sandbox)

        #expect(registration.installationID == "inst_1")
        #expect(registration.installationSecret == "s3cret")
        #expect(registration.pairingCode == PushPairingCode(
            code: "ABCDE-FGHJK", expiresAt: Date(timeIntervalSince1970: 1_790_000_000)))
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/installations")
        #expect(request.headers["authorization"] == nil)
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body)
        #expect(body == .object([
            "bundle_id": .string("com.spencermcguire.mercurychat"),
            "device_token": .string(Self.token), "environment": .string("sandbox"),
        ]))
        #expect(!String(describing: registration).contains("s3cret"))
        #expect(!String(reflecting: registration).contains("s3cret"))
    }

    @Test func authenticatedCallsUseBearerSecret() async throws {
        let server = try await RoutedHTTPServer.start { request in
            switch (request.method, request.path) {
            case ("PUT", "/v1/installations/inst_1"): return .init(200, #"{"ok":true}"#)
            case ("POST", "/v1/installations/inst_1/pairing-codes"):
                return .init(201, #"{"pairing_code":"ZZZZZ-ZZZZZ","pairing_expires_at":"2026-09-21T14:13:20.5Z"}"#)
            case ("DELETE", "/v1/installations/inst_1"): return .init(204, "")
            default: return .init(404, #"{"error":"not_found"}"#)
            }
        }
        defer { server.stop() }
        let relay = PushRelayClient(baseURL: pushTestURL(port: server.port))

        try await relay.update(installationID: "inst_1", secret: "s3cret", deviceToken: Self.token, environment: nil)
        let code = try await relay.newPairingCode(installationID: "inst_1", secret: "s3cret")
        try await relay.delete(installationID: "inst_1", secret: "s3cret")

        #expect(code.code == "ZZZZZ-ZZZZZ")
        #expect(server.requests.map(\.headers["authorization"]) == Array(repeating: "Bearer s3cret", count: 3))
        let put = try JSONDecoder().decode(JSONValue.self, from: server.requests[0].body)
        #expect(put == .object(["device_token": .string(Self.token)]))  // nil environment omitted
    }

    @Test(arguments: [
        (401, #"{"error":"credential_invalid","message":"x"}"#, [String: String](), PushRelayError.credentialInvalid),
        (400, #"{"error":"bundle_not_allowed","message":"x"}"#, [:], .bundleNotAllowed),
        (422, #"{"error":"invalid_request","message":"x"}"#, [:], .invalidRequest),
        (429, #"{"error":"rate_limited","message":"x"}"#, ["Retry-After": "42"], .rateLimited(retryAfter: 42)),
        (429, #"{"error":"rate_limited","message":"x"}"#, [:], .rateLimited(retryAfter: nil)),
        (429, "", ["Retry-After": "nan"], .rateLimited(retryAfter: nil)),
        (429, "", ["Retry-After": "inf"], .rateLimited(retryAfter: nil)),
        (429, "", ["Retry-After": "-5"], .rateLimited(retryAfter: nil)),
        (429, "", ["Retry-After": "0"], .rateLimited(retryAfter: 0)),
        (503, #"{"error":"apns_unavailable","message":"x"}"#, [:], .http(status: 503, code: "apns_unavailable")),
        (502, "<html>bad gateway</html>", [:], .http(status: 502, code: nil)),
    ])
    func mapsErrors(status: Int, body: String, headers: [String: String], expected: PushRelayError) async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(status, body, headers: headers) }
        defer { server.stop() }
        let relay = PushRelayClient(baseURL: pushTestURL(port: server.port))
        await #expect(throws: expected) {
            try await relay.update(installationID: "inst_1", secret: "s3cret", deviceToken: nil, environment: nil)
        }
    }

    @Test func malformedSuccessBodyIsMalformedResponse() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(201, #"{"installation_id":"inst_1"}"#) }
        defer { server.stop() }
        let relay = PushRelayClient(baseURL: pushTestURL(port: server.port))
        await #expect(throws: PushRelayError.malformedResponse) {
            _ = try await relay.register(bundleID: "b", deviceToken: Self.token, environment: .production)
        }
    }

    @Test func connectionFailureIsTransportWithoutURL() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(200) }
        let port = server.port
        server.stop()
        let relay = PushRelayClient(baseURL: pushTestURL(port: port))
        do {
            try await relay.update(installationID: "inst_1", secret: "s3cret", deviceToken: nil, environment: nil)
            Issue.record("expected a transport error")
        } catch let error as PushRelayError {
            guard case .transport(let detail) = error else { Issue.record("got \(error)"); return }
            #expect(!detail.contains("127.0.0.1"))
            #expect(!detail.contains("s3cret"))
            #expect(!(error.errorDescription ?? "").contains("s3cret"))
        }
    }

    @Test func defaultBaseURLIsProductionRelay() {
        #expect(PushRelayClient.defaultBaseURL.absoluteString == "https://mpns.angelsolutionsnm.com")
        #expect(PushRelayClient().baseURL == PushRelayClient.defaultBaseURL)
    }

    @Test(arguments: ["/mpns", "/mpns/"])
    func baseURLPathPrefixIsPreserved(prefix: String) async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(200, #"{"ok":true}"#) }
        defer { server.stop() }
        let relay = PushRelayClient(baseURL: URL(string: "http://127.0.0.1:\(server.port)\(prefix)")!)
        try await relay.update(installationID: "inst_1", secret: "s3cret", deviceToken: nil, environment: nil)
        #expect(server.requests.map(\.path) == ["/mpns/v1/installations/inst_1"])
    }
}
