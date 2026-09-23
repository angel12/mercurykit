import Foundation
import Testing

@testable import MercuryKit

/// Contract 7 (hermes-agent d3a44784b1): blocking prompts are JSON-RPC
/// requests the *server* sends, ids `srq-<12hex>`. What `GatewayClient`
/// does with each one is set per app by `ServerRequestPolicy`.
@Suite("Server request routing")
struct TransportUnionServerRequestRoutingTests {
    private static let approvalFrame =
        #"{"jsonrpc":"2.0","id":"srq-0123456789ab","method":"approval","params":{"session_id":"s1","request_id":"a1","command":"ls","choices":["once","deny"]}}"#
    private static let sudoFrame =
        #"{"jsonrpc":"2.0","id":"srq-aaaaaaaaaaaa","method":"sudo","params":{"session_id":"s1","command":"apt install x"}}"#
    private static let secretFrame =
        #"{"jsonrpc":"2.0","id":"srq-cccccccccccc","method":"secret","params":{"session_id":"s1","env_var":"API_KEY","prompt":"Paste the key"}}"#

    private func event(type: String, seq: Int) -> String {
        #"{"method":"event","params":{"type":"\#(type)","session_id":"s1","seq":\#(seq),"payload":{}}}"#
    }

    private func decode(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: Routed

    @Test func anApprovalRequestFrameIsSurfacedAsAnEvent() async throws {
        let (client, socket) = try await readyGatewayClient(serverRequestPolicy: .voice)
        let events = await client.events()
        socket.deliverText(Self.approvalFrame)
        var iterator = events.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.type == GatewayEvent.Kind.serverRequest)
        #expect(event.sessionID == "s1")
        #expect(event.seq == nil)
        let request = try #require(ServerRequest(event: event))
        #expect(request.id == "srq-0123456789ab")
        #expect(request.method == "approval")
        #expect(request.params["request_id"]?.stringValue == "a1")
        #expect(socket.sentFrames.isEmpty)  // answered later, by request.answer
        await client.close(reason: "test over")
    }

    /// Chat renders all four prompt kinds; its policy routes sudo and secret
    /// too, and each decodes into the typed prompt Chat's sheets take.
    @Test func chatsPolicyRoutesSudoAndSecret() async throws {
        let (client, socket) = try await readyGatewayClient(serverRequestPolicy: .chat)
        let events = await client.events()
        socket.deliverText(Self.sudoFrame)
        socket.deliverText(Self.secretFrame)
        var iterator = events.makeAsyncIterator()

        let sudoEvent = try #require(await iterator.next())
        let sudoRequest = try #require(ServerRequest(event: sudoEvent))
        let sudo = try #require(SudoRequest(serverRequest: sudoRequest))
        #expect(sudo.serverRequestID == "srq-aaaaaaaaaaaa")
        #expect(sudo.requestID == "srq-aaaaaaaaaaaa")
        #expect(sudo.command == "apt install x")

        let secretEvent = try #require(await iterator.next())
        let secretRequest = try #require(ServerRequest(event: secretEvent))
        let secret = try #require(SecretRequest(serverRequest: secretRequest))
        #expect(secret.serverRequestID == "srq-cccccccccccc")
        #expect(secret.envVar == "API_KEY")
        #expect(secret.prompt == "Paste the key")
        #expect(socket.sentFrames.isEmpty)
        await client.close(reason: "test over")
    }

    /// Routed requests keep their wire position among the events around
    /// them: an app's replay hold and ordering logic see one sequence.
    @Test func aRoutedRequestKeepsItsPlaceAmongEvents() async throws {
        let (client, socket) = try await readyGatewayClient(serverRequestPolicy: .chat)
        let events = await client.events()
        socket.deliverText(event(type: "message.delta", seq: 1))
        socket.deliverText(Self.approvalFrame)
        socket.deliverText(event(type: "message.delta", seq: 2))
        var iterator = events.makeAsyncIterator()
        var types: [String] = []
        for _ in 0..<3 {
            let next = try #require(await iterator.next())
            types.append(next.type)
        }
        #expect(types == ["message.delta", GatewayEvent.Kind.serverRequest, "message.delta"])
        await client.close(reason: "test over")
    }

    /// A method an app opts into beyond the kit-typed four is routed with
    /// only the session and object params checked.
    @Test func anOptedInUntypedMethodIsRouted() async throws {
        let policy = ServerRequestPolicy(answerableMethods: ["vault.code"])
        let (client, socket) = try await readyGatewayClient(serverRequestPolicy: policy)
        let events = await client.events()
        socket.deliverText(
            #"{"jsonrpc":"2.0","id":"srq-dddddddddddd","method":"vault.code","params":{"session_id":"s1","site":"x"}}"#)
        var iterator = events.makeAsyncIterator()
        let routed = try #require(await iterator.next())
        let request = try #require(ServerRequest(event: routed))
        #expect(request.method == "vault.code")
        #expect(socket.sentFrames.isEmpty)
        await client.close(reason: "test over")
    }

    // MARK: Switched off (the default)

    /// `.disabled` must behave exactly like a contract-6 client: a request
    /// frame produces no event and no reply (a co-attached client that does
    /// answer requests must not be pre-empted). Proved with more than
    /// silence: an event delivered *after* the request is the first thing
    /// out, and the socket has still seen no write.
    @Test func theDisabledPolicyIgnoresRequestFramesAsBefore() async throws {
        let (client, socket) = try await readyGatewayClient()
        #expect(client.serverRequestPolicy == .disabled)
        let events = await client.events()
        socket.deliverText(Self.approvalFrame)
        socket.deliverText(Self.sudoFrame)
        socket.deliverText(event(type: "message.delta", seq: 1))
        var iterator = events.makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.type == "message.delta")
        #expect(socket.sentFrames.isEmpty)
        await client.close(reason: "test over")
    }

    // MARK: Unanswerable methods

    /// Default: left unanswered for another client. The first response
    /// settles a request for every attached client (upstream
    /// `resolve_response`), so a refusal would take it from a co-attached
    /// desktop that can render it.
    @Test func anUnanswerableRequestIsLeftForAnotherClientByDefault() async throws {
        let (client, socket) = try await readyGatewayClient(serverRequestPolicy: .voice)
        let events = await client.events()
        socket.deliverText(Self.sudoFrame)
        socket.deliverText(Self.approvalFrame)
        var iterator = events.makeAsyncIterator()
        let routed = try #require(await iterator.next())
        let request = try #require(ServerRequest(event: routed))
        #expect(request.id == "srq-0123456789ab")
        #expect(socket.sentFrames.isEmpty)
        await client.close(reason: "test over")
    }

    @Test func theRefuseOptionAnswersUnanswerableRequestsWithMethodNotFound() async throws {
        let policy = ServerRequestPolicy(
            answerableMethods: ServerRequestPolicy.voice.answerableMethods, unanswerable: .refuse)
        let (client, socket) = try await readyGatewayClient(serverRequestPolicy: policy)
        let events = await client.events()
        socket.deliverText(Self.sudoFrame)
        await socket.awaitSend(count: 1)
        let reply = try decode(socket.sentFrames[0])
        #expect(reply["id"]?.stringValue == "srq-aaaaaaaaaaaa")
        #expect(reply["error"]?["code"]?.intValue == -32601)
        // A response frame: upstream reads only method-less frames as one.
        #expect(reply["method"] == nil)
        #expect(reply["result"] == nil)
        let message = try #require(reply["error"]?["message"]?.stringValue)
        #expect(message.contains("sudo"))
        for name in ["Mercury", "Voice", "Chat"] { #expect(!message.contains(name)) }

        // Nothing was surfaced for it.
        socket.deliverText(event(type: "message.delta", seq: 1))
        var iterator = events.makeAsyncIterator()
        let next = try #require(await iterator.next())
        #expect(next.type == "message.delta")
        await client.close(reason: "test over")
    }

    // MARK: Malformed routed requests

    /// An answerable request that cannot become a prompt on screen must be
    /// refused, never silently dropped: the client advertised, so the agent
    /// would otherwise wait out its deadline for a card nobody shows.
    @Test(arguments: [
        // approval without session_id
        #"{"jsonrpc":"2.0","id":"srq-eeeeeeeeeeee","method":"approval","params":{"request_id":"a1","command":"ls"}}"#,
        // approval without request_id
        #"{"jsonrpc":"2.0","id":"srq-eeeeeeeeeeee","method":"approval","params":{"session_id":"s1","command":"ls"}}"#,
        // batch clarify with an undecodable question
        #"{"jsonrpc":"2.0","id":"srq-eeeeeeeeeeee","method":"clarify","params":{"session_id":"s1","questions":[{"qid":"q1","question":"a"},{"question":"no qid"}]}}"#,
        // params not an object
        #"{"jsonrpc":"2.0","id":"srq-eeeeeeeeeeee","method":"clarify","params":["s1"]}"#,
        // secret without env_var
        #"{"jsonrpc":"2.0","id":"srq-eeeeeeeeeeee","method":"secret","params":{"session_id":"s1","prompt":"p"}}"#,
    ])
    func aMalformedRoutedRequestIsRefused(frame: String) async throws {
        let (client, socket) = try await readyGatewayClient(serverRequestPolicy: .chat)
        let events = await client.events()
        socket.deliverText(frame)
        await socket.awaitSend(count: 1)
        let reply = try decode(socket.sentFrames[0])
        #expect(reply["id"]?.stringValue == "srq-eeeeeeeeeeee")
        #expect(reply["error"]?["code"]?.intValue == -32602)
        #expect(reply["method"] == nil)
        let message = try #require(reply["error"]?["message"]?.stringValue)
        for name in ["Mercury", "Voice", "Chat"] { #expect(!message.contains(name)) }

        socket.deliverText(event(type: "message.delta", seq: 1))
        var iterator = events.makeAsyncIterator()
        let next = try #require(await iterator.next())
        #expect(next.type == "message.delta")
        await client.close(reason: "test over")
    }

    /// With the switch off even a malformed request is ignored, not refused.
    @Test func theDisabledPolicyDoesNotRefuseMalformedRequests() async throws {
        let (client, socket) = try await readyGatewayClient()
        let events = await client.events()
        socket.deliverText(
            #"{"jsonrpc":"2.0","id":"srq-eeeeeeeeeeee","method":"approval","params":{}}"#)
        socket.deliverText(event(type: "message.delta", seq: 1))
        var iterator = events.makeAsyncIterator()
        let next = try #require(await iterator.next())
        #expect(next.type == "message.delta")
        #expect(socket.sentFrames.isEmpty)
        await client.close(reason: "test over")
    }

    // MARK: Frames that are not requests

    /// A response frame (no `method`) with a string id is not ours to route:
    /// it must be silently ignored, not refused. A *pending* int-id request
    /// sent before it still resolves afterwards, so the string-id frame
    /// never touched `pending` or produced a wire reply.
    @Test func aStringIDResponseIsNotMistakenForARequest() async throws {
        let (client, socket) = try await readyGatewayClient(serverRequestPolicy: .chat)
        let call = Task<RPCOutcome, Never> {
            await rpcOutcome { try await client.request("gateway.ping") }
        }
        await socket.awaitSend(count: 1)
        let pingID = try #require(socket.sentRequestID(at: 0))

        socket.deliverText(#"{"jsonrpc":"2.0","id":"srq-bbbbbbbbbbbb","result":{}}"#)
        #expect(socket.sentFrames.count == 1)

        socket.deliverReply(id: pingID, result: #"{"pong":true}"#)
        #expect(await settled(call) == .value(.object(["pong": .bool(true)])))
        #expect(await client.pendingRequestCount == 0)
        #expect(socket.sentFrames.count == 1)
        await client.close(reason: "test over")
    }

    @Test func anOpenRequestsSnapshotEntryDecodesLikeAFrame() throws {
        let entry = try decode(
            #"{"id":"srq-cccccccccccc","method":"clarify","params":{"session_id":"s1","question":"Which?"}}"#)
        let request = try #require(ServerRequest(snapshot: entry))
        #expect(request.method == "clarify")
        #expect(request.sessionID == "s1")
        #expect(request.isDisplayable)
        #expect(ServerRequest(snapshot: try decode(#"{"method":"clarify"}"#)) == nil)
        #expect(ServerRequest(snapshot: try decode(#"{"id":"srq-1","method":""}"#)) == nil)
    }

    @Test func requestCancelDecodes() throws {
        let event = GatewayEvent(
            type: GatewayEvent.Kind.requestCancel, sessionID: "s1",
            payload: try decode(#"{"id":"srq-0123456789ab","method":"approval","reason":"timeout"}"#))
        let cancel = try #require(ServerRequestCancel(event: event))
        #expect(cancel.id == "srq-0123456789ab")
        #expect(cancel.method == "approval")
        #expect(cancel.reason == "timeout")
        #expect(cancel.sessionID == "s1")
        #expect(
            ServerRequestCancel(
                event: GatewayEvent(
                    type: GatewayEvent.Kind.requestCancel, sessionID: "s1",
                    payload: try decode(#"{"method":"approval"}"#))) == nil)
    }
}
