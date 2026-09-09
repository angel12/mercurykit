import Foundation
import Testing
@testable import MercuryKit

@Suite struct TransportUnionBoundaryTests {
    @Test(arguments: [0, 1])
    func exactUTF8MessageBound(extra: Int) async throws {
        let (client, socket) = try await readyGatewayClient()
        let prefix = #"{"method":"event","params":{"type":"bound","payload":""#
        let suffix = #""}}"#
        let text = prefix + String(repeating: "x", count: GatewayClient.maximumInboundMessageSize - prefix.utf8.count - suffix.utf8.count + extra) + suffix
        #expect(text.utf8.count == 8 * 1024 * 1024 + extra)
        var events = await client.events().makeAsyncIterator()
        socket.deliverText(text)
        if extra == 0 {
            #expect(await events.next()?.type == "bound")
            #expect(await client.state == .ready)
        } else {
            #expect(await transportEventually { await client.closeCause == .frameTooLarge })
        }
        await client.close()
    }

    @Test func oversizedErrorMappingsAreTyped() {
        for code in [URLSessionWebSocketTask.CloseCode.invalid, .messageTooBig] {
            let outcome = GatewayClient.closeOutcome(closeCode: code, upgradeStatus: nil,
                error: NSError(domain: NSPOSIXErrorDomain, code: Int(EMSGSIZE)))
            #expect(outcome.cause == .frameTooLarge)
        }
    }

    @Test func protocolCarriesReplayIdentityAndTypedClose() async throws {
        let (client, _) = try await readyGatewayClient()
        let dialer: any GatewayDialing = client
        #expect(await dialer.replayEpoch == "epoch-1")
        await client.close(reason: "no magic strings", cause: .forbidden)
        #expect(await dialer.closeCause == .forbidden)
    }
}
