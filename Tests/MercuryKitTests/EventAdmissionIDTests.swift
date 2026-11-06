import Foundation
import Testing

@testable import MercuryKit

/// A session authority stamps the claimed admission's id beside `seq` at the
/// top level of every event frame's `params` (`gateway/session_events.py`
/// `SessionEvents.publish`), and `session.events.since` returns those same
/// `params` objects (`CanonicalReplayEvent.admission_id`).
@Suite("event admission_id")
struct EventAdmissionIDTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func decodesTheEnvelopeAdmissionID() throws {
        let params = try json(
            #"{"type":"message.delta","session_id":"s","seq":9,"authority_epoch":7,"execution_generation":3,"admission_id":"a1","payload":{"text":"hi"}}"#
        )
        let event = try #require(GatewayEvent(eventParams: params))
        #expect(event.admissionID == "a1")
        #expect(event.executionGeneration == 3)
        #expect(event.seq == 9)
        #expect(event.payload["text"]?.stringValue == "hi")
    }

    @Test func absentOnLegacyAndIdleFrames() throws {
        let params = try json(#"{"type":"message.delta","session_id":"s","seq":9,"payload":{}}"#)
        let event = try #require(GatewayEvent(eventParams: params))
        #expect(event.admissionID == nil)
        #expect(event.executionGeneration == nil)
    }

    @Test func emptyOrNonStringReadsAsAbsent() throws {
        for value in [#""""#, "null", "4"] {
            let params = try json(#"{"type":"x","payload":{},"admission_id":\#(value)}"#)
            #expect(GatewayEvent(eventParams: params)?.admissionID == nil)
        }
    }

    @Test func payloadAdmissionIDIsNotTheEnvelope() throws {
        // The cancelled-queued completion also names the admission in its
        // payload; only the envelope field is the attribution.
        let params = try json(#"{"type":"message.complete","payload":{"admission_id":"p"}}"#)
        #expect(GatewayEvent(eventParams: params)?.admissionID == nil)
    }

    @Test func memberwiseInitKeepsItsOldShape() {
        let event = GatewayEvent(type: "x", sessionID: nil, payload: .null, seq: 1, executionGeneration: 2)
        #expect(event.admissionID == nil)
        #expect(event != GatewayEvent(type: "x", sessionID: nil, payload: .null, seq: 1,
                                      executionGeneration: 2, admissionID: "a"))
    }

    @Test func replayBatchKeepsEachFramesAdmission() throws {
        // Two admissions in one batch: a running turn's frames, then a queued
        // one cancelled while it ran (own id, no generation), then an idle frame.
        let batch = EventReplayBatch(result: try json(#"""
            {"events":[
              {"type":"message.start","session_id":"s","payload":{},"replay_epoch":"e","seq":1,"authority_epoch":7,"execution_generation":2,"admission_id":"a1"},
              {"type":"message.complete","session_id":"s","payload":{"admission_id":"a2","outcome":"cancelled"},"replay_epoch":"e","seq":2,"authority_epoch":7,"admission_id":"a2"},
              {"type":"message.complete","session_id":"s","payload":{},"replay_epoch":"e","seq":3,"authority_epoch":7,"execution_generation":2,"admission_id":"a1"},
              {"type":"session.info","session_id":"s","payload":{"pending":[]},"replay_epoch":"e","seq":4}
            ],"latest_seq":4,"last_sequence":4,"epoch":"e","replay_epoch":"e","truncated":false,
             "snapshot_required":false,"count":4,"open_requests":[]}
            """#))
        #expect(!batch.malformed)
        #expect(batch.events.map(\.admissionID) == ["a1", "a2", "a1", nil])
        #expect(batch.events.map(\.executionGeneration) == [2, nil, 2, nil])
    }

    @Test func liveSocketFrameKeepsIt() async throws {
        let server = try await TransportUnionLoopbackGatewayServer.start(
            onOpen: { server in
                server.sendEvent(type: "gateway.ready", payload: #"{"session_authority":true}"#)
            },
            onRequest: { frame in
                #"{"jsonrpc":"2.0","id":\#(frame["id"]?.intValue ?? 0),"result":{}}"#
            })
        defer { server.stop() }
        let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let connection = HermesConnection(endpoint: endpoint, token: nil, adoptsSessionAuthority: true)
        let updates = await connection.updates()
        await connection.start()
        #expect(await transportEventually { await connection.phase == .ready(isReconnect: false) })

        server.send(
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"s","seq":4,"authority_epoch":7,"execution_generation":5,"admission_id":"a9","payload":{}}}"#
        )
        var seen: GatewayEvent?
        for await update in updates {
            if case .event(let event) = update, event.type == "message.start" {
                seen = event
                break
            }
        }
        #expect(seen?.admissionID == "a9")
        #expect(seen?.executionGeneration == 5)
        await connection.stop()
    }
}
