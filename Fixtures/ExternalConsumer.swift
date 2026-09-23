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

// Chat's Bot Mode API (mercurychat #78/#79) an app uses without @testable.
func adoptBotMode(connection: HermesConnection, row: JSONValue) async throws {
    let bots: [BotSummary] = try await connection.listBots(timeout: 60)
    if let bot = bots.first ?? BotSummary(json: row) {
        _ = (bot.id, bot.name, bot.isDefault, bot.model, bot.provider, bot.profileDescription)
        _ = (bot.displayName, bot.skillCount, bot.hasAvatar, bot.metaTitle, bot.metaDescription)
        _ = (bot.shape, bot.colorHex, bot.hidden, bot.pinned, bot.workerLastActive)
        _ = (bot.title, bot.preview, bot.lastActivity, bot.uiMetaRaw, bot.uiMetaRevision)
        if let stub = bot.canonicalSession ?? bot.lastSession {
            _ = (stub.storedID, stub.resolvedID, stub.title, stub.preview, stub.lastActive, stub.messageCount)
        }
        let outcome = try await connection.configureBotMeta(
            name: bot.name, meta: bot.uiMetaRaw ?? [:], expectedRevision: bot.uiMetaRevision)
        switch outcome {
        case .persisted, .conflict, .failed: break
        }
        _ = HermesConnection.metaWriteOutcome(from: [:])
    }
    _ = BotSessionStub(json: row)
    let canonical: BotSessionStub? = try await connection.findCanonicalBotChat(profile: "p")
    _ = canonical
    _ = BotChatPolicy.isCanonicalRow(rootTitle: nil, title: BotChatPolicy.canonicalTitle)
    _ = BotChatPolicy.isCompactCommand("/new")
    let status: String = try await connection.compressSession(sessionID: "rt")
    _ = status

    if let asset = try await connection.profileAvatar(name: "p") ?? ProfileAsset(json: row) {
        _ = (asset.mime, asset.data)
    }
    try await connection.setProfileAvatar(name: "p", dataURL: nil)

    let list: CronJobList = try await connection.listCronJobs(profile: "p")
    for job in list.jobs where list.scopedToProfile || job.belongsToBot(named: "p") {
        _ = (job.id, job.jobID, job.name, job.displayName, job.schedule, job.prompt, job.enabled)
        _ = (job.state, job.lastStatus, job.lastRunAt, job.nextRunAt, job.lastFireError, job.deliver)
        try await connection.setCronJobEnabled(jobID: job.jobID, enabled: !job.enabled, profile: "p")
        try await connection.removeCronJob(jobID: job.jobID, profile: "p")
    }
    _ = CronJob(json: row)
    let failure = CronManageError(action: "pause", message: nil)
    _ = (failure.action, failure.message, failure.errorDescription)
    _ = GatewayEvent.Kind.cronChanged
}

// The composer rule the kit leaves to Chat: ChatCore re-adds it this way, so
// BotChatPolicy must stay a public enum an external module can extend.
extension BotChatPolicy {
    public static func isCompactCommand(_ text: String) -> Bool {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1).first.map(String.init)
        return ["/new", "/reset", "/compact"].contains(command?.lowercased() ?? "")
    }
}
