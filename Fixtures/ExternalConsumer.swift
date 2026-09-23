import Foundation
import MercuryKit

func loadVoiceResponse(_ request: URLRequest, session: URLSession) async throws -> Data {
    let (data, _) = try await HTTPErrorDetail.load(request, on: session)
    return data
}

func displayVoiceError(_ text: String) -> String {
    HTTPErrorDetail.displayed(text)
}

// Contract-7 API an app uses without @testable: every symbol below must be public.
func adoptContract7(endpoint: ServerEndpoint, authenticator: HermesAuthenticator) async throws {
    let connection = HermesConnection(
        endpoint: endpoint, authenticator: authenticator,
        reconnectPolicy: .chat, serverRequestPolicy: .chat)
    let custom = ServerRequestPolicy(answerableMethods: ["approval"], unanswerable: .refuse)
    _ = GatewayClient(endpoint: endpoint, authenticator: authenticator, serverRequestPolicy: custom)
    _ = await connection.serverRequestMethods

    let request = ServerRequest(id: "srq-1", method: ServerRequest.Method.approval, params: [:])
    let event = GatewayEvent(serverRequest: request)
    _ = ServerRequest(event: event)?.isDisplayable
    _ = ApprovalRequest(serverRequest: request)?.serverRequestID
    _ = ClarifyRequest(serverRequest: request)?.questions.first?.qid
    _ = ClarifyRequest.Question(qid: "q1", question: "Which?", choices: ["a"], multiSelect: false)
    _ = SudoRequest(serverRequest: request)?.command
    _ = SecretRequest(serverRequest: request)?.metadata
    _ = ServerRequestCancel(event: event)?.reason
    _ = ServerRequest.openRequests(in: [:])

    let status: PromptResponseStatus = try await connection.answerServerRequest(
        id: request.id, result: ServerRequestResult.approval(choice: "once"))
    switch status {
    case .accepted, .expired: break
    }
    _ = ServerRequestResult.clarify(answer: "")
    _ = ServerRequestResult.clarify(answers: ["q1": "a"])
    _ = ServerRequestResult.clarifyCancelAll
    _ = ServerRequestResult.value("")
    _ = try await connection.lockClarifyAnswer(requestID: request.id, questionID: "q1", answer: "a")

    let answer = ConnectionAnswer(targets: [.init(name: "github", status: .approved)])
    _ = try await connection.respondConnection(
        sessionID: "rt", opID: "op", answer: answer, desktopContract: 8)
    _ = ConnectionRequest(event: event)?.targets.first?.requiredEnv

    _ = DesktopContractRequirement.serverRequests.assess(8)
    let error = HermesError.rpcError(code: 5035, message: "retiring")
    _ = error.isBackendRetiring || error.isSessionNotLive || error.isInterruptSettling
        || error.isUnknownParameter || error.isProfileUnavailable
    await connection.rest.ttsLease(name: "mercury", active: true)
}
