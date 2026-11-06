import Foundation
import Testing

@testable import MercuryKit

/// Session controls, slash commands and `/btw` (SessionControlsAPI.swift),
/// plus the owner-forwarded `prompt.submit` receipt. Every request shape was
/// checked with `tui_gateway.contracts.registry.validate_params` at upstream
/// v0.23.0 (`2bd378ed1b`); see VERIFICATION.md.
@Suite("Session controls and slash commands", .timeLimit(.minutes(1)))
struct SessionControlsAPITests {
    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [JSONValue] = []
        func append(_ frame: JSONValue) { lock.withLock { values.append(frame) } }
        var all: [JSONValue] { lock.withLock { values } }
        var last: JSONValue? { all.last }
    }

    /// Answers each request with the raw reply for its method: a result
    /// object, or an `{"code":…}` error body when the string starts with `!`.
    private func withGateway<T>(
        _ replies: [String: String], _ body: (HermesConnection, Frames) async throws -> T
    ) async throws -> T {
        let frames = Frames()
        let server = try await LocalGatewayServer.start(onText: { text, server in
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                let id = frame["id"]?.intValue, let method = frame["method"]?.stringValue
            else { return }
            frames.append(frame)
            let reply = replies[method] ?? "{}"
            if reply.hasPrefix("!") {
                server.send(#"{"jsonrpc": "2.0", "id": \#(id), "error": \#(reply.dropFirst())}"#)
            } else {
                server.respond(id: id, result: reply)
            }
        })
        defer { server.stop() }
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let connection = HermesConnection(endpoint: endpoint, token: "test-token")
        await connection.start()
        for await update in await connection.updates() {
            if case .phase(.ready) = update { break }
        }
        do {
            let value = try await body(connection, frames)
            await connection.stop()
            return value
        } catch {
            await connection.stop()
            throw error
        }
    }

    // MARK: prompt.submit

    @Test func forwardedSubmitReportsTheOwnersAdmission() async throws {
        let receipt = try await withGateway(
            ["prompt.submit": #"{"status":"queued","admission_id":"adm-1","forwarded":true}"#]
        ) { connection, _ in
            try await connection.submit(sessionID: "s1", text: "hi")
        }
        #expect(receipt == PromptSubmission(status: "queued", admissionID: "adm-1", forwarded: true))
    }

    @Test func ordinarySubmitIsNotForwarded() async throws {
        let status = try await withGateway(["prompt.submit": #"{"status":"streaming"}"#]) {
            connection, _ in
            try await connection.submitPrompt(sessionID: "s1", text: "hi")
        }
        #expect(status == "streaming")
    }

    @Test func ownerRefusalsCarryTheirReason() async throws {
        for reason in [
            HermesError.RefusalReason.sessionOwnerBusy, HermesError.RefusalReason.sessionOwnerUnconfirmed,
        ] {
            await withGatewayExpectingError(
                ["prompt.submit": #"!{"code":4090,"message":"busy","data":{"reason":"\#(reason)"}}"#]
            ) { connection in
                _ = try await connection.submit(sessionID: "s1", text: "hi")
            } check: { error in
                #expect(error.rpcReason == reason)
            }
        }
    }

    // MARK: config.set

    @Test func modelSwitchIsSessionScoped() async throws {
        let result = try await withGateway(
            ["config.set": #"{"key":"model","value":"gpt-x","warning":"slow"}"#]
        ) { connection, frames in
            let result = try await connection.setSessionModel(
                sessionID: "s1", model: "gpt-x", provider: "openai")
            #expect(frames.last?["method"] == "config.set")
            #expect(
                frames.last?["params"]
                    == ["session_id": "s1", "key": "model", "value": "gpt-x --provider openai --session"])
            return result
        }
        #expect(result.value == "gpt-x")
        #expect(result.warning == "slow")
        #expect(!result.confirmRequired)
    }

    @Test func expensiveModelAsksForConfirmationAndResendsWithIt() async throws {
        let result = try await withGateway(
            ["config.set": #"{"key":"model","confirm_required":true,"confirm_message":"Costs more"}"#]
        ) { connection, frames in
            let first = try await connection.setSessionModel(sessionID: "s1", model: "big", provider: "p")
            _ = try await connection.setSessionModel(
                sessionID: "s1", model: "big", provider: "p", confirmExpensiveModel: true)
            #expect(frames.all.first?["params"]?["confirm_expensive_model"] == nil)
            #expect(frames.last?["params"]?["confirm_expensive_model"] == true)
            return first
        }
        #expect(result.confirmRequired)
        #expect(result.confirmMessage == "Costs more")
    }

    @Test func reasoningYoloAndApprovalModeSendTheirKeys() async throws {
        try await withGateway(["config.set": #"{"key":"x","value":true}"#]) { connection, frames in
            let yolo = try await connection.setSessionYolo(sessionID: "s1", enabled: true)
            #expect(yolo.value == "on")
            #expect(frames.last?["params"] == ["session_id": "s1", "key": "yolo", "value": "on"])
            _ = try await connection.setSessionReasoning(sessionID: "s1", level: "high")
            #expect(frames.last?["params"] == ["session_id": "s1", "key": "reasoning", "value": "high"])
            _ = try await connection.setApprovalMode(.smart, profile: "work")
            #expect(
                frames.last?["params"] == ["key": "approvals.mode", "value": "smart", "profile": "work"])
        }
    }

    @Test func approvalModeReadsConfigGet() async throws {
        let mode = try await withGateway(["config.get": #"{"value":"smart"}"#]) { connection, frames in
            let mode = try await connection.approvalMode()
            #expect(frames.last?["params"] == ["key": "approvals.mode"])
            return mode
        }
        #expect(mode == .smart)
    }

    @Test func modelOptionsParseProviders() async throws {
        let options = try await withGateway([
            "model.options": #"""
                {"model":"gpt-x","provider":"openai","providers":[
                  {"slug":"openai","name":"OpenAI","models":["gpt-x","gpt-y"],"featured_models":["gpt-x"],"authenticated":true,"is_current":true},
                  {"slug":"anthropic","name":"Anthropic","models":["c"],"authenticated":false},
                  {"name":"no slug"}]}
                """#
        ]) { connection, _ in
            try await connection.loadModelOptions(sessionID: "s1")
        }
        #expect(options.currentModel == "gpt-x")
        #expect(options.providers.map(\.slug) == ["openai", "anthropic"])
        #expect(options.providers[0].featuredModels == ["gpt-x"])
        #expect(options.providers[0].isCurrent)
        #expect(!options.providers[1].authenticated)
    }

    // MARK: Slash commands

    @Test func parsesSlashCommandsButNotPaths() {
        #expect(SlashCommand("/Model gpt-x --provider p") == SlashCommand("/model gpt-x --provider p"))
        #expect(SlashCommand("/model gpt-x")?.name == "model")
        #expect(SlashCommand("/model gpt-x")?.commandText == "model gpt-x")
        #expect(SlashCommand("  /help  ")?.commandText == "help")
        #expect(SlashCommand("/usr/bin/env") == nil)
        #expect(SlashCommand("/") == nil)
        #expect(SlashCommand("hello /help") == nil)
    }

    @Test func completionsReplaceFromTheServersOffset() async throws {
        let completions = try await withGateway([
            "complete.slash":
                #"{"items":[{"text":"model","display":"/model","meta":"Switch model","kind":"command"},{"display":"no text"}],"replace_from":1}"#
        ]) { connection, frames in
            let completions = try await connection.slashCompletions(text: "/mo", sessionID: "s1")
            #expect(frames.last?["params"] == ["text": "/mo", "session_id": "s1"])
            return completions
        }
        #expect(completions.items.map(\.display) == ["/model"])
        #expect(completions.applying(completions.items[0], to: "/mo") == "/model ")
    }

    @Test func slashExecOutputComesBackAsText() async throws {
        let outcome = try await withGateway(["slash.exec": #"{"output":"Current model: x"}"#]) {
            connection, frames in
            let outcome = try await connection.runSlash(
                sessionID: "s1", command: SlashCommand("/model")!)
            #expect(frames.last?["params"] == ["session_id": "s1", "command": "model"])
            return outcome
        }
        #expect(outcome == .output("Current model: x"))
    }

    @Test func slashExecWarningIsKept() async throws {
        let outcome = try await withGateway(["slash.exec": #"{"output":"done","warning":"careful"}"#]) {
            connection, _ in
            try await connection.runSlash(sessionID: "s1", command: SlashCommand("/x")!)
        }
        #expect(outcome == .output("warning: careful\ndone"))
    }

    @Test func typedDirectivesParse() {
        #expect(SlashOutcome(result: ["type": "exec", "output": "ok"]) == .output("ok"))
        #expect(SlashOutcome(result: ["type": "alias", "target": "model"]) == .alias(target: "model"))
        #expect(
            SlashOutcome(result: ["type": "prefill", "message": "draft", "notice": "n"])
                == .prefill(message: "draft", notice: "n"))
        #expect(
            SlashOutcome(result: ["type": "send", "message": "go", "notice": "⊙ Goal set"])
                == .send(message: "go", display: nil, notice: "⊙ Goal set"))
        // A skill's message is the expanded body: the bubble must show the invocation.
        #expect(
            SlashOutcome(result: ["type": "skill", "name": "work", "message": "BODY"])
                == .send(message: "BODY", display: "/work", notice: nil))
        #expect(SlashOutcome(result: ["type": "send"]) == nil)
        #expect(SlashOutcome(result: ["type": "mystery"]) == nil)
    }

    @Test func failedSlashExecFallsBackToCommandDispatch() async throws {
        let outcome = try await withGateway([
            "slash.exec": #"!{"code":5030,"message":"slash worker timed out"}"#,
            "command.dispatch": #"{"type":"skill","name":"work","message":"BODY","display":"/work fix it"}"#,
        ]) { connection, frames in
            let outcome = try await connection.runSlash(
                sessionID: "s1", command: SlashCommand("/work fix it")!)
            #expect(frames.last?["params"] == ["session_id": "s1", "name": "work", "arg": "fix it"])
            return outcome
        }
        #expect(outcome == .send(message: "BODY", display: "/work fix it", notice: nil))
    }

    @Test func routingNoiseFromTheFallbackSurfacesTheExecError() async throws {
        await withGatewayExpectingError([
            "slash.exec": #"!{"code":5030,"message":"slash worker timed out"}"#,
            "command.dispatch": #"!{"code":4018,"message":"not a quick/plugin/bundle/skill command: new"}"#,
        ]) { connection in
            _ = try await connection.runSlash(sessionID: "s1", command: SlashCommand("/new")!)
        } check: { error in
            #expect(error.rpcMessage == "slash worker timed out")
        }
    }

    // MARK: prompt.btw

    @Test func sideQuestionReturnsItsTaskID() async throws {
        let taskID = try await withGateway(["prompt.btw": #"{"task_id":"btw-1"}"#]) {
            connection, frames in
            let taskID = try await connection.askSideQuestion(sessionID: "s1", text: "why?")
            #expect(frames.last?["params"] == ["session_id": "s1", "text": "why?"])
            return taskID
        }
        #expect(taskID == "btw-1")
    }

    // MARK: Helpers

    private func withGatewayExpectingError(
        _ replies: [String: String], _ body: (HermesConnection) async throws -> Void,
        check: (HermesError) -> Void
    ) async {
        do {
            try await withGateway(replies) { connection, _ in try await body(connection) }
            Issue.record("expected an error")
        } catch let error as HermesError {
            check(error)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
