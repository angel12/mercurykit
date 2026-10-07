import Foundation
import Testing

@testable import MercuryKit

@Suite("PushDevicesAPI", .timeLimit(.minutes(1)))
struct PushDevicesAPITests {
    static let base = "/api/plugins/mercury_push/devices"
    static let device = #"{"device_id":"dev_1","device_name":"iPhone","preferences":{"approval":true,"response_ready":false,"turn_failed":true,"task_done":true,"cron":true,"future":false},"paired_at":"2026-09-21T14:13:20.123456Z","last_delivery_at":null,"last_error":null,"active":true,"extra":1}"#

    private func client(_ server: RoutedHTTPServer) throws -> HermesRESTClient {
        HermesRESTClient(endpoint: try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint, token: "tok")
    }

    @Test func pairSendsProfileQueryAuthAndBody() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(201, #"{"device_id":"dev_1","profile":"coder"}"#) }
        defer { server.stop() }

        let pairing = try await client(server).pairPushDevice(
            profile: "coder", installationID: "inst_1", pairingCode: "ABCDE-FGHJK", deviceName: "iPhone",
            preferences: PushPreferences(cron: false))

        #expect(pairing == PushDevicePairing(deviceID: "dev_1", profile: "coder"))
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "\(Self.base)?profile=coder")
        #expect(request.headers["x-hermes-session-token"] == "tok")  // session-token mode (HermesAuthenticator.authHeaders)
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body)
        #expect(body["installation_id"] == .string("inst_1"))
        #expect(body["pairing_code"] == .string("ABCDE-FGHJK"))
        #expect(body["device_name"] == .string("iPhone"))
        #expect(body["preferences"]?["cron"] == .bool(false))
        #expect(body["preferences"]?["response_ready"] == .bool(true))
    }

    @Test func nilOrEmptyProfileOmitsQuery() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(200, "[]") }
        defer { server.stop() }
        _ = try await client(server).pushDevices(profile: nil)
        _ = try await client(server).pushDevices(profile: "")
        #expect(server.requests.map(\.path) == [Self.base, Self.base])
    }

    @Test func listDecodesDevicesAndIgnoresUnknownFields() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(200, "[\(Self.device)]") }
        defer { server.stop() }
        let devices = try await client(server).pushDevices(profile: "coder")
        #expect(devices == [PushDevice(
            deviceID: "dev_1", deviceName: "iPhone",
            preferences: PushPreferences(responseReady: false),
            pairedAt: PushDate.parse("2026-09-21T14:13:20.123456Z"), lastDeliveryAt: nil, lastError: nil,
            active: true)])
    }

    @Test func updateTestAndUnpairUseDevicePath() async throws {
        let server = try await RoutedHTTPServer.start { request in
            switch request.method {
            case "PATCH": return .init(200, Self.device)
            case "POST": return .init(202, #"{"event_id":"e-1"}"#)
            default: return .init(204, "")
            }
        }
        defer { server.stop() }
        let rest = try client(server)
        _ = try await rest.updatePushPreferences(profile: "coder", deviceID: "dev_1", PushPreferences(cron: false))
        #expect(try await rest.sendTestPush(profile: "coder", deviceID: "dev_1") == "e-1")
        try await rest.unpairPushDevice(profile: "coder", deviceID: "dev_1")
        let device = "\(Self.base)/dev_1"
        #expect(server.requests.map(\.path) == ["\(device)?profile=coder", "\(device)/test?profile=coder", "\(device)?profile=coder"])
        #expect(server.requests.map(\.method) == ["PATCH", "POST", "DELETE"])
    }

    @Test(arguments: [
        (502, #"{"error":"relay_error","relay_error":"pairing_code_invalid"}"#, PushDevicesError.relayError(code: "pairing_code_invalid")),
        (503, #"{"error":"relay_url_invalid"}"#, .relayURLInvalid),
        (404, #"{"error":"device_not_found"}"#, .deviceNotFound),
        (404, #"{"error":"profile_not_found"}"#, .profileNotFound),
        (404, #"{"detail":"Not Found"}"#, .pluginUnavailable),
        (405, #"{"detail":"Method Not Allowed"}"#, .pluginUnavailable),  // SPA catch-all when the plugin isn't mounted
        (404, "", .pluginUnavailable),
        (400, #"{"error":"invalid_profile"}"#, .invalidProfile),
        (409, #"{"error":"plugin_not_enabled","profile":"off"}"#, .pluginNotEnabled(profile: "off")),
        (500, #"{"detail":"boom"}"#, .http(status: 500, code: nil)),
    ])
    func mapsPluginErrors(status: Int, body: String, expected: PushDevicesError) async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(status, body) }
        defer { server.stop() }
        let rest = try client(server)
        await #expect(throws: expected) { _ = try await rest.pushDevices(profile: "coder") }
    }

    @Test func unauthorizedAfterRefreshIsUnauthorized() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(401, #"{"detail":"no"}"#) }
        defer { server.stop() }
        let rest = try client(server)  // session-token mode: no refresh possible
        await #expect(throws: PushDevicesError.unauthorized) { _ = try await rest.pushDevices(profile: nil) }
    }

    @Test func malformedSuccessIsMalformedResponse() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(201, #"{"profile":"coder"}"#) }
        defer { server.stop() }
        let rest = try client(server)
        await #expect(throws: PushDevicesError.malformedResponse) {
            _ = try await rest.pairPushDevice(
                profile: nil, installationID: "i", pairingCode: "c", deviceName: "d", preferences: nil)
        }
    }

    @Test func preferencesDefaultToTrueAndDropUnknownKeys() {
        #expect(PushPreferences() == PushPreferences(
            approval: true, responseReady: true, turnFailed: true, taskDone: true, cron: true))
        let decoded = PushPreferences(json: .object(["cron": .bool(false), "surprise": .bool(false)]))
        #expect(decoded == PushPreferences(cron: false))
    }

    @Test(arguments: [
        (#""session_scope":"owned","#, PushSessionScope?.some(.owned)),
        (#""session_scope":"all","#, PushSessionScope?.some(.all)),
        (#""session_scope":"mine","#, nil),
        ("", nil),
    ])
    func decodesSessionScope(field: String, expected: PushSessionScope?) throws {
        let text = #"{"device_id":"dev_1","device_name":"iPhone",\#(field)"preferences":{},"active":true}"#
        let device = try #require(PushDevice(json: try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))))
        #expect(device.sessionScope == expected)
    }

    @Test func featureUnsupportedDescription() {
        #expect(PushDevicesError.featureUnsupported.errorDescription
            == "Mercury Push on this server doesn't support this yet.")
    }

    // MARK: Password-mode refresh

    private func passwordClient(_ server: RoutedHTTPServer) throws -> HermesRESTClient {
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let authenticator = HermesAuthenticator(
            endpoint: endpoint,
            credentials: .password(PasswordSession(
                provider: "basic", username: "spencer", accessToken: "old-at", refreshToken: "old-rt", expiresAt: 0)))
        return HermesRESTClient(endpoint: endpoint, authenticator: authenticator)
    }

    private static let refreshed = #"{"access_token":"new-at","refresh_token":"new-rt","expires_at":99}"#

    @Test func passwordModeRefreshesOn401AndRetriesWithRotatedToken() async throws {
        let server = try await RoutedHTTPServer.start { request in
            if request.path == "/auth/native/refresh" { return .init(200, Self.refreshed) }
            return request.headers["authorization"] == "Bearer new-at" ? .init(200, "[]") : .init(401, #"{"detail":"expired"}"#)
        }
        defer { server.stop() }

        let devices = try await passwordClient(server).pushDevices(profile: "coder")

        #expect(devices.isEmpty)
        #expect(server.requests.map(\.path) == ["\(Self.base)?profile=coder", "/auth/native/refresh", "\(Self.base)?profile=coder"])
        #expect(server.requests.map { $0.headers["authorization"] } == ["Bearer old-at", nil, "Bearer new-at"])
    }

    @Test func passwordModeSecond401AfterRefreshIsUnauthorized() async throws {
        let server = try await RoutedHTTPServer.start { request in
            request.path == "/auth/native/refresh" ? .init(200, Self.refreshed) : .init(401, #"{"detail":"no"}"#)
        }
        defer { server.stop() }
        let rest = try passwordClient(server)

        await #expect(throws: PushDevicesError.unauthorized) { _ = try await rest.pushDevices(profile: nil) }
        #expect(server.requests.map(\.path) == [Self.base, "/auth/native/refresh", Self.base])
        #expect(server.requests.last?.headers["authorization"] == "Bearer new-at")
    }

    @Test func updateSessionScopeSendsOnlyTheScope() async throws {
        let owned = Self.device.replacingOccurrences(of: #""active":true"#, with: #""active":true,"session_scope":"owned""#)
        let server = try await RoutedHTTPServer.start { _ in .init(200, owned) }
        defer { server.stop() }
        let device = try await client(server).updatePushSessionScope(profile: "coder", deviceID: "dev_1", .owned)
        #expect(device.sessionScope == .owned)
        let request = try #require(server.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.path == "\(Self.base)/dev_1?profile=coder")
        #expect(try JSONDecoder().decode(JSONValue.self, from: request.body) == .object(["session_scope": .string("owned")]))
    }

    @Test(arguments: [
        (422, #"{"detail":[{"type":"missing","loc":["body","preferences"]}]}"#),  // older DevicePatch requires preferences
        (200, PushDevicesAPITests.device),  // older plugin ignored the field
    ])
    func updateSessionScopeOnOlderPluginIsUnsupported(status: Int, body: String) async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(status, body) }
        defer { server.stop() }
        let rest = try client(server)
        await #expect(throws: PushDevicesError.featureUnsupported) {
            _ = try await rest.updatePushSessionScope(profile: nil, deviceID: "dev_1", .owned)
        }
    }

    @Test func claimSessionPutsPercentEncodedPath() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(204, "") }
        defer { server.stop() }
        try await client(server).claimPushSession(profile: "coder", deviceID: "dev_1", sessionID: "20261007_a/b c")
        let request = try #require(server.requests.first)
        #expect(request.method == "PUT")
        #expect(request.path == "\(Self.base)/dev_1/sessions/20261007_a%2Fb%20c?profile=coder")
        #expect(request.body.isEmpty)
    }

    @Test func claimSessionMapsDeviceNotFound() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(404, #"{"error":"device_not_found"}"#) }
        defer { server.stop() }
        let rest = try client(server)
        await #expect(throws: PushDevicesError.deviceNotFound) {
            try await rest.claimPushSession(profile: nil, deviceID: "dev_1", sessionID: "s1")
        }
    }

    @Test func pairSendsSessionScopeOnlyWhenGiven() async throws {
        let server = try await RoutedHTTPServer.start { _ in .init(201, #"{"device_id":"dev_1","profile":"default"}"#) }
        defer { server.stop() }
        let rest = try client(server)
        _ = try await rest.pairPushDevice(
            profile: nil, installationID: "i", pairingCode: "c", deviceName: "n", preferences: nil, sessionScope: .owned)
        _ = try await rest.pairPushDevice(
            profile: nil, installationID: "i", pairingCode: "c", deviceName: "n", preferences: nil)
        let bodies = try server.requests.map { try JSONDecoder().decode(JSONValue.self, from: $0.body) }
        #expect(bodies.map { $0["session_scope"] } == [.string("owned"), nil])
    }
}
