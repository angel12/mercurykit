import Testing
@testable import MercuryKit

struct EndpointPolicyTests {
    @Test(arguments: ["192.168.1.5:8080", "8.8.8.8", "server.local", "server", "[2001:db8::1]:8080"])
    func consumerDefaults(input: String) throws {
        #expect(try ServerEndpoint.parse(input).endpoint.isSecure)
        #expect(try !ServerEndpoint.parse(input, schemePolicy: .voiceLANDefaults).endpoint.isSecure)
    }

    @Test(arguments: ["localhost:8080", "127.0.0.1:8080", "[::1]:8080"])
    func loopback(input: String) throws {
        #expect(try !ServerEndpoint.parse(input).endpoint.isSecure)
        #expect(try !ServerEndpoint.parse(input, schemePolicy: .voiceLANDefaults).endpoint.isSecure)
    }

    @Test func explicitSchemesAndDNS() throws {
        for policy in [EndpointSchemePolicy.httpsExceptLoopback, .voiceLANDefaults] {
            #expect(try ServerEndpoint.parse("server.example.com", schemePolicy: policy).endpoint.isSecure)
            #expect(try ServerEndpoint.parse("https://server.local", schemePolicy: policy).endpoint.isSecure)
            let parsed = try ServerEndpoint.parse("http://server.example.com/?token=sample", schemePolicy: policy)
            #expect(!parsed.endpoint.isSecure)
            #expect(parsed.embeddedToken == "sample")
            #expect(parsed.endpoint.isPlaintextNonLoopback)
            #expect(parsed.endpoint.restURL("/api/a%2Fb%25").absoluteString == "http://server.example.com/api/a%2Fb%25")
        }
    }
}
