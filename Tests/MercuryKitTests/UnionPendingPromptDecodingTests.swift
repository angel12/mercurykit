import Foundation
import Testing

@testable import MercuryKit

/// The `pending_approval` / `pending_clarify` replay fields of
/// `session.resume` carry the same payloads as the `approval.request` /
/// `clarify.request` events (tui_gateway/server.py `_pending_*_payload`),
/// so the payload initializers must decode exactly like the event path.
@Suite("Pending prompt replay decoding")
struct UnionPendingPromptDecodingTests {
    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    // MARK: pending_approval

    @Test func approvalWithExplicitChoices() throws {
        let payload = try json(
            """
            {"command": "rm -rf build", "description": "Delete the build dir",
             "choices": ["once", "deny"]}
            """)
        let request = ApprovalRequest(payload: payload, sessionID: "sid-1")

        #expect(request?.sessionID == "sid-1")
        #expect(request?.command == "rm -rf build")
        #expect(request?.description == "Delete the build dir")
        #expect(request?.choices == ["once", "deny"])
    }

    /// The gateway stamps `request_id` on every approval entry
    /// (`_ApprovalEntry.__init__`) and `_approval_request_payload` copies the
    /// entry's dict through, so both the event and the `pending_approval`
    /// snapshot field carry it. It is decoded to recognise the same approval
    /// arriving twice; `id` stays the session id because `approval.respond`
    /// is answered session-keyed.
    @Test func approvalCarriesTheRequestIDWhenTheBackendStampsOne() throws {
        let stamped = ApprovalRequest(
            payload: try json(#"{"command": "ls", "request_id": "a1"}"#), sessionID: "sid-1")
        #expect(stamped?.requestID == "a1")
        #expect(stamped?.id == "a1")

        // A backend that does not stamp one leaves it nil, and two such
        // approvals must not be assumed to be the same approval.
        let unstamped = ApprovalRequest(payload: try json(#"{"command": "ls"}"#), sessionID: "s")
        #expect(unstamped?.requestID == nil)
    }

    @Test func approvalDerivesChoicesLikeTheServer() throws {
        // allow_* absent means allowed; the full ladder is offered.
        let full = ApprovalRequest(payload: try json(#"{"command": "ls"}"#), sessionID: "s")
        #expect(full?.choices == ["once", "session", "always", "deny"])

        // Explicit denials trim the ladder.
        let trimmed = ApprovalRequest(
            payload: try json(#"{"command": "ls", "allow_permanent": false}"#),
            sessionID: "s")
        #expect(trimmed?.choices == ["once", "session", "deny"])

        // smart_denied collapses to once/deny.
        let denied = ApprovalRequest(
            payload: try json(#"{"command": "curl evil", "smart_denied": true}"#),
            sessionID: "s")
        #expect(denied?.choices == ["once", "deny"])
    }

    @Test func approvalRequiresASessionID() throws {
        #expect(ApprovalRequest(payload: try json(#"{"command": "ls"}"#), sessionID: nil) == nil)
    }

    @Test func approvalEventPathStillDecodes() throws {
        let event = GatewayEvent(
            type: GatewayEvent.Kind.approvalRequest,
            sessionID: "sid-9",
            payload: try json(#"{"command": "make", "choices": ["once", "deny"]}"#))
        let request = ApprovalRequest(event: event)
        #expect(request?.sessionID == "sid-9")
        #expect(request?.choices == ["once", "deny"])
        // Wrong event type still refuses.
        #expect(
            ApprovalRequest(
                event: GatewayEvent(
                    type: GatewayEvent.Kind.clarifyRequest, sessionID: "sid-9",
                    payload: .object([:]))) == nil)
    }

    // MARK: pending_clarify

    @Test func clarifyDecodesFromReplayPayload() throws {
        let payload = try json(
            """
            {"request_id": "req-42", "question": "Which env?",
             "choices": ["dev", "prod"], "multi_select": false}
            """)
        let request = ClarifyRequest(payload: payload, sessionID: "sid-1")

        #expect(request?.requestID == "req-42")
        #expect(request?.sessionID == "sid-1")
        #expect(request?.question == "Which env?")
        #expect(request?.choices == ["dev", "prod"])
        #expect(request?.multiSelect == false)
    }

    @Test func clarifyRequiresARequestID() throws {
        #expect(ClarifyRequest(payload: try json(#"{"question": "?"}"#), sessionID: "s") == nil)
    }

    @Test func clarifyFiltersUnspeakableChoices() throws {
        let payload = try json(
            """
            {"request_id": "req-1", "question": "Pick",
             "choices": ["ok", "", "has\\nnewline"], "multi_select": true}
            """)
        let request = ClarifyRequest(payload: payload, sessionID: nil)
        #expect(request?.choices == ["ok"])
        #expect(request?.multiSelect == true)
        #expect(request?.sessionID == nil)
    }

    // MARK: Server requests (contract ≥ 7)

    private func request(_ method: String, _ params: String) throws -> ServerRequest {
        ServerRequest(id: "srq-0123456789ab", method: method, params: try json(params))
    }

    @Test func approvalDecodesFromAServerRequest() throws {
        let approval = try #require(
            ApprovalRequest(
                serverRequest: try request(
                    "approval",
                    #"{"session_id": "s1", "request_id": "a1", "command": "ls", "choices": ["once", "deny"]}"#)))
        #expect(approval.serverRequestID == "srq-0123456789ab")
        #expect(approval.sessionID == "s1")
        #expect(approval.requestID == "a1")
        // The kit's identity rule is unchanged: the queue's request id.
        #expect(approval.id == "a1")
        #expect(approval.command == "ls")
        #expect(approval.choices == ["once", "deny"])
    }

    @Test func approvalWithoutChoicesDerivesThemLikeTheContract6Path() throws {
        let approval = try #require(
            ApprovalRequest(
                serverRequest: try request(
                    "approval",
                    #"{"session_id": "s1", "request_id": "a1", "allow_permanent": false}"#)))
        #expect(approval.choices == ["once", "session", "deny"])
    }

    @Test(arguments: [
        #"{"request_id": "a1"}"#,  // no session_id
        #"{"session_id": "", "request_id": "a1"}"#,
        #"{"session_id": "s1"}"#,  // no request_id (the contract requires it)
        #"{"session_id": "s1", "request_id": "a1", "command": 3}"#,
        #"{"session_id": "s1", "request_id": "a1", "choices": "once"}"#,
        #"{"session_id": "s1", "request_id": "a1", "choices": ["once", 2]}"#,
    ])
    func approvalServerRequestFailsClosed(params: String) throws {
        #expect(ApprovalRequest(serverRequest: try request("approval", params)) == nil)
    }

    @Test func approvalRefusesANonApprovalServerRequest() throws {
        #expect(ApprovalRequest(serverRequest: try request("clarify", #"{"session_id": "s1"}"#)) == nil)
    }

    /// The legacy event path never carries a server request id.
    @Test func contract6PromptsHaveNoServerRequestID() throws {
        let approval = ApprovalRequest(payload: try json(#"{"request_id": "a1"}"#), sessionID: "s1")
        #expect(approval?.serverRequestID == nil)
        let clarify = ClarifyRequest(payload: try json(#"{"request_id": "c1", "question": "?"}"#), sessionID: "s1")
        #expect(clarify?.serverRequestID == nil)
    }

    @Test func clarifyDecodesASingleQuestionServerRequest() throws {
        let clarify = try #require(
            ClarifyRequest(
                serverRequest: try request(
                    "clarify",
                    """
                    {"session_id": "s1", "question": "Which env?",
                     "choices": ["dev", "prod"], "multi_select": false}
                    """)))
        #expect(clarify.requestID == "srq-0123456789ab")
        #expect(clarify.serverRequestID == "srq-0123456789ab")
        #expect(clarify.sessionID == "s1")
        #expect(clarify.question == "Which env?")
        #expect(clarify.choices == ["dev", "prod"])
        #expect(clarify.multiSelect == false)
        #expect(!clarify.isBatch)
        #expect(clarify.lockedAnswers.isEmpty)
    }

    @Test func clarifyDecodesABatchServerRequestIntoTheExistingQuestionType() throws {
        let clarify = try #require(
            ClarifyRequest(
                serverRequest: try request(
                    "clarify",
                    """
                    {"session_id": "s1",
                     "questions": [
                       {"qid": "q1", "question": "Which env?", "choices": ["dev", "prod"]},
                       {"qid": "q2", "question": "Which branch?", "multi_select": true}
                     ],
                     "answers": {"q1": "dev"}}
                    """)))
        #expect(clarify.isBatch)
        // A batch's own question/choices are not "the first question".
        #expect(clarify.question == "")
        #expect(clarify.choices == [])
        #expect(
            clarify.questions == [
                ClarifyRequest.Question(qid: "q1", question: "Which env?", choices: ["dev", "prod"]),
                ClarifyRequest.Question(qid: "q2", question: "Which branch?", multiSelect: true),
            ])
        #expect(clarify.lockedAnswers == ["q1": "dev"])
    }

    /// `null` is how the contract's optional fields read when unset.
    @Test func clarifyTreatsNullOptionalFieldsAsAbsent() throws {
        let clarify = try #require(
            ClarifyRequest(
                serverRequest: try request(
                    "clarify",
                    #"{"session_id": "s1", "question": "Why?", "choices": null, "questions": null, "answers": null, "multi_select": null}"#)))
        #expect(clarify.question == "Why?")
        #expect(!clarify.isBatch)
    }

    /// A dropped question would still let the caller submit `{answers}` for
    /// the ones it did see — a batch that looks complete to the backend
    /// while one question was never asked. So anything the contract does
    /// not allow refuses the whole request.
    @Test(arguments: [
        #"{"session_id": "s1", "questions": [{"qid": "q1", "question": "a"}, {"question": "no qid"}]}"#,
        #"{"session_id": "s1", "questions": [{"qid": "", "question": "empty qid"}]}"#,
        #"{"session_id": "s1", "questions": [{"qid": "q1"}]}"#,
        #"{"session_id": "s1", "questions": [{"qid": "q1", "question": "a"}, {"qid": "q1", "question": "b"}]}"#,
        #"{"session_id": "s1", "questions": [{"qid": "q1", "question": "a", "choices": "x"}]}"#,
        #"{"session_id": "s1", "questions": [{"qid": "q1", "question": "a", "multi_select": "yes"}]}"#,
        #"{"session_id": "s1", "questions": []}"#,
        #"{"session_id": "s1", "questions": {}}"#,
        #"{"session_id": "s1", "questions": [{"qid": "q1", "question": "a"}], "answers": {"q1": 3}}"#,
        #"{"session_id": "s1", "questions": [{"qid": "q1", "question": "a"}], "answers": ["q1"]}"#,
        #"{"session_id": "s1"}"#,  // single without a question
        #"{"session_id": "s1", "question": "a", "choices": ["x", 1]}"#,
        #"{"question": "no session"}"#,
    ])
    func clarifyServerRequestFailsClosed(params: String) throws {
        #expect(ClarifyRequest(serverRequest: try request("clarify", params)) == nil)
    }

    @Test func clarifyRefusesANonClarifyServerRequest() throws {
        #expect(ClarifyRequest(serverRequest: try request("approval", #"{"session_id": "s1"}"#)) == nil)
    }

    @Test func sudoDecodesFromAServerRequest() throws {
        let sudo = try #require(
            SudoRequest(serverRequest: try request("sudo", #"{"session_id": "s1", "command": "apt ***"}"#)))
        #expect(sudo.requestID == "srq-0123456789ab")
        #expect(sudo.serverRequestID == "srq-0123456789ab")
        #expect(sudo.sessionID == "s1")
        #expect(sudo.command == "apt ***")
        let bare = try #require(SudoRequest(serverRequest: try request("sudo", #"{"session_id": "s1"}"#)))
        #expect(bare.command == nil)
        #expect(SudoRequest(serverRequest: try request("sudo", #"{}"#)) == nil)
        #expect(SudoRequest(serverRequest: try request("sudo", #"{"session_id": "s1", "command": 1}"#)) == nil)
        #expect(SudoRequest(serverRequest: try request("secret", #"{"session_id": "s1"}"#)) == nil)
    }

    @Test func secretDecodesFromAServerRequest() throws {
        let secret = try #require(
            SecretRequest(
                serverRequest: try request(
                    "secret",
                    #"{"session_id": "s1", "env_var": "TOKEN", "prompt": "Paste it", "metadata": {"skill": "x"}}"#)))
        #expect(secret.requestID == "srq-0123456789ab")
        #expect(secret.serverRequestID == "srq-0123456789ab")
        #expect(secret.envVar == "TOKEN")
        #expect(secret.prompt == "Paste it")
        #expect(secret.metadata?["skill"]?.stringValue == "x")
    }

    @Test(arguments: [
        #"{"session_id": "s1", "prompt": "p"}"#,
        #"{"session_id": "s1", "env_var": "", "prompt": "p"}"#,
        #"{"session_id": "s1", "env_var": "T"}"#,
        #"{"session_id": "s1", "env_var": "T", "prompt": "p", "metadata": "x"}"#,
        #"{"env_var": "T", "prompt": "p"}"#,
    ])
    func secretServerRequestFailsClosed(params: String) throws {
        #expect(SecretRequest(serverRequest: try request("secret", params)) == nil)
    }
}
