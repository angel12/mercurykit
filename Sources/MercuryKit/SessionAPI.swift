import Foundation
import os

/// Outcome of `session.close`. The server replies `{"closed": true}` when the
/// runtime session actually shut down; anything else means it may still be
/// holding resources (sockets, profile DB handles) on the backend.
/// `prompt.submit`'s receipt.
public struct PromptSubmission: Sendable, Equatable {
    /// `streaming`, `queued`, `redirected` or `steered`; nil from older backends.
    public var status: String?
    /// The owner's admission id for a queued prompt.
    public var admissionID: String?
    /// True when the prompt joined the queue of the gateway that owns this
    /// session rather than running here.
    public var forwarded: Bool

    public init(status: String?, admissionID: String? = nil, forwarded: Bool = false) {
        self.status = status
        self.admissionID = admissionID
        self.forwarded = forwarded
    }
}

public enum SessionCloseOutcome: Sendable, Equatable {
    /// Server confirmed `closed: true`.
    case closed
    /// RPC succeeded but the server did not confirm (`closed` missing/false).
    case unconfirmed
    /// The request itself failed (transport error, timeout, not connected).
    case failed(String)
}

/// Result of `image.attach_bytes`: where the gateway staged the image.
public struct ImageAttachment: Sendable, Equatable {
    /// Gateway-side staging path — the `image.detach` key.
    public var path: String
    /// How many images are now staged on the session.
    public var count: Int?

    public init(path: String, count: Int? = nil) {
        self.path = path
        self.count = count
    }
}

/// Result of `file.attach`: the staged file plus the `@file:` directive
/// line the SUBMITTED prompt must carry for the agent to see the file —
/// staging alone attaches nothing to a turn.
public struct FileAttachment: Sendable, Equatable {
    /// Display name the gateway recorded for the staged file.
    public var name: String
    /// Gateway-side staging path.
    public var path: String
    /// The `@file:` line to append to the submitted prompt text.
    public var refText: String
}

/// Result of `pdf.attach`: the rendered page images now staged in
/// `attached_images` (drained by the next `prompt.submit`, each detachable
/// via `image.detach` like any staged image).
public struct PDFAttachment: Sendable, Equatable {
    /// Gateway-side staging paths of the rendered pages, in page order.
    public var pagePaths: [String]
    /// How many pages the gateway says it staged.
    public var pagesAttached: Int
}

/// Typed wrappers over the gateway RPC methods the app uses.
extension HermesConnection {
    /// Column count reported to the backend; matches the desktop client.
    private static let cols = 96
    private static let source = "desktop"
    private static let logger = Logger(subsystem: "MercuryKit", category: "SessionAPI")

    /// os_log serializes each message into a ~1 KB buffer; anything larger is
    /// truncated at emission and renders as "<decode: bad range>" — the payload
    /// is lost everywhere, including Console.app. Clamp diagnostic dumps well
    /// under the limit so the interesting prefix always survives.
    private static func clampForLog(_ s: String, max: Int = 800) -> String {
        s.count <= max ? s : "\(s.prefix(max))… [\(s.count - max) more chars truncated]"
    }

    // MARK: Sessions

    /// `session.create` — `cwd` binds the session to a project directory;
    /// omit for "no workspace". The DB row appears lazily on first prompt.
    ///
    /// A `cwd` is always sent as a deliberate pick (`cwd_explicit`), so a
    /// named profile's `terminal.cwd` doesn't replace it (hermes-agent
    /// `a9972dc3f9`). A backend from before that change refuses the key with
    /// 4000 and doesn't override the cwd anyway, so the create is resent
    /// without it.
    public func createSession(
        cwd: String? = nil, profile: String? = nil, title: String? = nil
    ) async throws -> SessionHandle {
        var params: [String: JSONValue] = [
            "cols": .number(Double(Self.cols)),
            "source": .string(Self.source),
        ]
        if let cwd, !cwd.isEmpty {
            params["cwd"] = .string(cwd)
            params["cwd_explicit"] = .bool(true)
        }
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        if let title, !title.isEmpty { params["title"] = .string(title) }

        if speaksSessionAuthority {
            let result = try await request(
                "session.create", params: .object(AuthorityWire.createParams(params)))
            return try adoptAuthoritySnapshot(result, method: "session.create")
        }

        let result: JSONValue
        do {
            result = try await request("session.create", params: .object(params))
        } catch let error as HermesError
            where params["cwd_explicit"] != nil && error.isUnknownParameter
            && error.rpcMessage?.contains("cwd_explicit") == true
        {
            params["cwd_explicit"] = nil
            result = try await request("session.create", params: .object(params))
        }
        guard let handle = SessionHandle(result: result) else {
            throw HermesError.malformedResponse("session.create returned no session_id")
        }
        return handle
    }

    /// A canonical create/resume snapshot as a `SessionHandle`, recording
    /// this socket's subscription and the session's execution generation.
    private func adoptAuthoritySnapshot(
        _ result: JSONValue, method: String
    ) throws -> SessionHandle {
        let normalized = AuthorityWire.legacySnapshot(result)
        guard let handle = SessionHandle(result: normalized) else {
            throw HermesError.malformedResponse("\(method) returned no session_id")
        }
        if let subscription = result["subscription_id"]?.stringValue, !subscription.isEmpty {
            authoritySubscriptions[handle.runtimeID] = subscription
        }
        if let generation = result["execution_generation"]?.intValue {
            noteExecutionGeneration(generation, for: handle.runtimeID)
        }
        return handle
    }

    /// `session.resume` by **stored** id. Pass the session's owning profile —
    /// cross-profile resume opens that profile's state DB. The result's
    /// `resumed` field may differ from the requested id (compression
    /// continuation chains are followed to the live tip); the returned
    /// handle's `storedID` is re-anchored to it.
    public func resumeSession(
        storedID: String, profile: String? = nil, omitMessages: Bool = true, deferHistory: Bool = false
    ) async throws -> SessionHandle {
        var params: [String: JSONValue] = [
            "session_id": .string(storedID),
            "cols": .number(Double(Self.cols)),
            "source": .string(Self.source),
            "omit_messages": .bool(omitMessages),
        ]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }

        if deferHistory { params["defer_history"] = .bool(true) }
        let raw = try await request("session.resume", params: .object(params), timeout: 120)
        let result: JSONValue
        if speaksSessionAuthority {
            // The canonical resume tolerates every flag above as sent.
            result = AuthorityWire.legacySnapshot(raw)
            _ = try adoptAuthoritySnapshot(raw, method: "session.resume")
        } else {
            result = raw
        }
        guard var handle = SessionHandle(result: result) else {
            throw HermesError.malformedResponse("session.resume returned no session_id")
        }
        // resume names the durable id `session_key`/`resumed`, not
        // `stored_session_id`.
        handle.storedID =
            result["resumed"]?.stringValue
            ?? result["session_key"]?.stringValue
            ?? handle.storedID
            ?? storedID
        return handle
    }

    ///
    /// A session authority serves no `session.activate`; there the same
    /// re-read is a `session.resume` on this socket (`AuthorityWire`), whose
    /// snapshot is mapped onto the live-session payload shape.
    public func activateSession(sessionID: String) async throws -> LiveSessionSnapshot {
        if speaksSessionAuthority {
            // The authority does not serve session.activate; a resume on this
            // socket re-reads the same state (AuthorityWire).
            let raw = try await request(
                "session.resume", params: AuthorityWire.activateParams(sessionID: sessionID),
                timeout: 120)
            let handle = try adoptAuthoritySnapshot(raw, method: "session.resume")
            guard handle.runtimeID == sessionID,
                let snapshot = LiveSessionSnapshot(result: AuthorityWire.legacySnapshot(raw))
            else {
                throw HermesError.malformedResponse(
                    "session.resume did not return a live-session payload")
            }
            return snapshot
        }
        let result = try await request("session.activate", params: [
            "session_id": .string(sessionID), "omit_messages": .bool(true)])
        guard let snapshot = LiveSessionSnapshot(result: result) else {
            throw HermesError.malformedResponse("session.activate did not return a live-session payload")
        }
        return snapshot
    }

    /// `prompt.submit` returns `{"status":"streaming"}` immediately — the
    /// reply arrives only via events; never await this for completion. Set
    /// `interrupted` on the first submit after a barge-in so the backend
    /// prepends a "your spoken reply was cut off" note for the model.
    /// Returns the server's dispatch status: `"streaming"` (turn started),
    /// or — when submitted mid-turn — `"queued"`, `"redirected"`, or
    /// `"steered"` per the server's busy-input policy. Nil when the result
    /// carries no status (older backends).
    ///
    /// `voiceTurn` marks a spoken turn: the backend runs it on the
    /// `auxiliary.voice_chat` model with reasoning off by default (upstream
    /// 6cc1efd8f9). Backends that predate the key reject it with 4000 before
    /// the handler runs; the turn is retried once without it and the key
    /// stays off for the rest of this gateway connection.
    @discardableResult
    public func submitPrompt(
        sessionID: String, text: String, interrupted: Bool = false, voiceTurn: Bool = false
    ) async throws -> String? {
        try await submit(
            sessionID: sessionID, text: text, interrupted: interrupted, voiceTurn: voiceTurn
        ).status
    }

    /// `submitPrompt` with the whole receipt. Since v0.22.0 one gateway owns
    /// each session: when it is already running a turn in this chat (a bot,
    /// cron, the CLI or Desktop), the server queues the prompt in that
    /// owner's FIFO and answers `forwarded: true`. It runs once, after the
    /// current turn. A refusal comes back as a 4090 whose `rpcReason` is
    /// `RefusalReason.sessionOwnerBusy` or `.sessionOwnerUnconfirmed`. On a
    /// session authority every admission carries an `admission_id` and is
    /// never `forwarded`: the socket already talks to the owner.
    public func submit(
        sessionID: String, text: String, interrupted: Bool = false, voiceTurn: Bool = false
    ) async throws -> PromptSubmission {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "text": .string(text),
        ]
        if interrupted { params["interrupted"] = .bool(true) }
        if speaksSessionAuthority {
            // The authority knows voice_turn, so there is no retry to make;
            // the submission id is what makes the admission idempotent.
            if voiceTurn { params["voice_turn"] = .bool(true) }
            let receipt = try await request(
                "prompt.submit",
                params: .object(
                    AuthorityWire.submitParams(params, submissionID: UUID().uuidString)),
                timeout: 1800)
            if let generation = receipt["execution_generation"]?.intValue {
                noteExecutionGeneration(generation, for: sessionID)
            }
            return Self.promptSubmission(receipt)
        }
        if voiceTurn && sendsVoiceTurn { params["voice_turn"] = .bool(true) }
        // Desktop uses a 30-minute timeout here.
        do {
            let result = try await request("prompt.submit", params: .object(params), timeout: 1800)
            return Self.promptSubmission(result)
        } catch HermesError.rpcError(4000, let message, _)
            where params["voice_turn"] != nil && message.contains("voice_turn")
        {
            sendsVoiceTurn = false
            params["voice_turn"] = nil
            let result = try await request("prompt.submit", params: .object(params), timeout: 1800)
            return Self.promptSubmission(result)
        }
    }

    private static func promptSubmission(_ result: JSONValue) -> PromptSubmission {
        PromptSubmission(
            status: result["status"]?.stringValue,
            admissionID: result["admission_id"]?.stringValue,
            forwarded: result["forwarded"]?.boolValue ?? false)
    }

    // MARK: Attachments

    /// `image.attach_bytes` — stage an image into session state; the NEXT
    /// `prompt.submit` consumes everything staged. `path` is the gateway-side
    /// staging path and the `image.detach` key. Base64 payloads can be tens of
    /// MB, hence the long timeout. Never log the payload.
    public func attachImageBytes(
        sessionID: String, base64: String, filename: String? = nil
    ) async throws -> ImageAttachment {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "content_base64": .string(base64),
        ]
        if let filename, !filename.isEmpty { params["filename"] = .string(filename) }
        let result = try await request(
            "image.attach_bytes", params: .object(params), timeout: 300)
        guard result["attached"]?.truthy == true,
            let path = result["path"]?.stringValue
        else {
            throw HermesError.malformedResponse("image.attach_bytes did not confirm attachment")
        }
        return ImageAttachment(path: path, count: result["count"]?.intValue)
    }

    /// `image.detach` — unstage one attached image. Called on failed sends so
    /// an orphaned staged image isn't silently consumed by the next prompt.
    public func detachImage(sessionID: String, path: String) async throws {
        _ = try await request(
            "image.detach",
            params: ["session_id": .string(sessionID), "path": .string(path)])
    }

    /// `file.attach` — stage a non-image file into the session workspace.
    /// Unlike images, staged files are NOT drained by `prompt.submit`; the
    /// returned `refText` must be appended to the submitted text. There is no
    /// detach RPC and none is needed: an unreferenced staged file is inert.
    /// Payloads can be tens of MB of base64, hence the long timeout. Never log
    /// the payload.
    public func attachFile(
        sessionID: String, dataURL: String, name: String? = nil
    ) async throws -> FileAttachment {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "data_url": .string(dataURL),
        ]
        if let name, !name.isEmpty { params["name"] = .string(name) }
        let result = try await request("file.attach", params: .object(params), timeout: 300)
        // An EMPTY `ref_text` fails the same way a missing one does: the
        // caller appends it to the submitted prompt, so an empty string would
        // send a message that points at nothing while the staged file sits
        // unreferenced — the attachment silently dropped.
        guard result["attached"]?.truthy == true,
            let path = result["path"]?.stringValue,
            let refText = result["ref_text"]?.stringValue, !refText.isEmpty
        else {
            throw HermesError.malformedResponse("file.attach did not confirm attachment")
        }
        return FileAttachment(
            name: result["name"]?.stringValue ?? (path as NSString).lastPathComponent,
            path: path, refText: refText)
    }

    /// `pdf.attach` — render a PDF's pages to PNGs server-side and stage them
    /// as vision images. Requires poppler on the gateway; error 5028 means it
    /// is missing (callers fall back to `attachFile`). `first_page`/`last_page`
    /// are deliberately omitted: the server renders from page 1 up to its
    /// 25-page cap. 50 MB server cap (4018 above it). Never log the payload.
    public func attachPDF(
        sessionID: String, base64: String, filename: String? = nil
    ) async throws -> PDFAttachment {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "content_base64": .string(base64),
        ]
        if let filename, !filename.isEmpty { params["filename"] = .string(filename) }
        let result = try await request("pdf.attach", params: .object(params), timeout: 600)
        guard result["attached"]?.truthy == true,
            let pages = result["pages"]?.arrayValue
        else {
            throw HermesError.malformedResponse("pdf.attach did not confirm attachment")
        }
        // `attached: true` with no usable page paths staged nothing: an empty
        // success let the send go out with neither vision pages nor any sign
        // the PDF was lost. Fail it instead, so the echo can go `.failed` and
        // offer a retry.
        let paths = pages.compactMap { $0["path"]?.stringValue }
        guard !paths.isEmpty else {
            throw HermesError.malformedResponse("pdf.attach staged no pages")
        }
        return PDFAttachment(
            pagePaths: paths,
            pagesAttached: result["pages_attached"]?.intValue ?? paths.count)
    }

    /// Cancel the in-flight turn (used on barge-in while still generating).
    ///
    /// A session authority fences it by `execution_generation`: the newest
    /// one this connection has seen for the session goes with it.
    public func interruptSession(sessionID: String) async throws {
        if speaksSessionAuthority {
            guard let generation = executionGenerations[sessionID] else {
                throw HermesError.malformedResponse(
                    "no execution_generation known for \(sessionID); cannot interrupt")
            }
            let handle = try await request(
                "session.interrupt",
                params: AuthorityWire.interruptParams(sessionID: sessionID, generation: generation))
            if let next = handle["execution_generation"]?.intValue {
                noteExecutionGeneration(next, for: sessionID)
            }
            return
        }
        _ = try await request("session.interrupt", params: ["session_id": .string(sessionID)])
    }

    /// Detach politely when leaving a session, verifying the server's answer:
    /// an unconfirmed or failed close means the backend may still hold the
    /// session's sockets and profile DB handles. Every outcome is logged so
    /// leak investigations don't have to guess whether End reached the server.
    ///
    /// A session authority serves no `session.close`: leaving is
    /// `session.detach` of this socket's subscription, confirmed by
    /// `detached: true`. The session itself stays the owner's to keep.
    @discardableResult
    public func closeSession(sessionID: String) async -> SessionCloseOutcome {
        if speaksSessionAuthority { return await detachSession(sessionID: sessionID) }
        do {
            let result = try await request(
                "session.close", params: ["session_id": .string(sessionID)])
            if result["closed"]?.truthy == true {
                Self.logger.info(
                    "session.close confirmed for \(sessionID, privacy: .public)")
                return .closed
            }
            Self.logger.error(
                "session.close NOT confirmed for \(sessionID, privacy: .public): \(Self.clampForLog("\(result)"), privacy: .public)"
            )
            return .unconfirmed
        } catch {
            let reason = (error as? HermesError)?.errorDescription ?? "\(error)"
            Self.logger.error(
                "session.close failed for \(sessionID, privacy: .public): \(Self.clampForLog(reason), privacy: .public)"
            )
            return .failed(reason)
        }
    }

    /// Session authority: `session.close` is not served; detach this
    /// socket's subscription instead.
    private func detachSession(sessionID: String) async -> SessionCloseOutcome {
        guard let subscription = authoritySubscriptions[sessionID] else {
            Self.logger.error(
                "session.detach skipped for \(sessionID, privacy: .public): no subscription on this socket")
            return .failed("no subscription on this socket")
        }
        do {
            let result = try await request(
                "session.detach",
                params: AuthorityWire.detachParams(sessionID: sessionID, subscriptionID: subscription))
            authoritySubscriptions[sessionID] = nil
            if result["detached"]?.truthy == true {
                Self.logger.info("session.detach confirmed for \(sessionID, privacy: .public)")
                return .closed
            }
            Self.logger.error(
                "session.detach NOT confirmed for \(sessionID, privacy: .public): \(Self.clampForLog("\(result)"), privacy: .public)"
            )
            return .unconfirmed
        } catch {
            let reason = (error as? HermesError)?.errorDescription ?? "\(error)"
            Self.logger.error(
                "session.detach failed for \(sessionID, privacy: .public): \(Self.clampForLog(reason), privacy: .public)"
            )
            return .failed(reason)
        }
    }

    /// Probe the backend's `desktop_contract`. The gateway advertises it only
    /// in session-info shapes (`gateway.ready` carries no such field), so the
    /// cheapest read is a throwaway lazy session — no DB row until first
    /// prompt — created and closed immediately.
    ///
    /// The close is guaranteed (issue #49): it runs in an unstructured task so
    /// caller cancellation between create and close can't strand a live
    /// runtime session — a ghost in `session.list` and every client's sidebar
    /// — and an unconfirmed/failed close is retried once. `closeSession`
    /// already logs every outcome for leak investigations.
    ///
    /// Returns nil when the backend predates the field. Throws only when the
    /// create itself fails (then there is nothing to clean up).
    public func probeDesktopContract() async throws -> Int? {
        let handle = try await createSession()
        let sessionID = handle.runtimeID
        let close = Task {
            var outcome = await self.closeSession(sessionID: sessionID)
            if outcome != .closed {
                outcome = await self.closeSession(sessionID: sessionID)
            }
            return outcome
        }
        // Await it (an unstructured task ignores the caller's cancellation)
        // so the probe never resolves while its cleanup is still in flight.
        _ = await close.value
        return handle.desktopContract
    }

    // MARK: Projects

    /// `projects.tree` — the authoritative sidebar grouping (explicit
    /// projects, auto repo projects, `__no_project__` Home bucket). Pass the
    /// selected `profile` — the RPC is profile-scoped and defaults to the
    /// gateway's launch profile when the param is omitted.
    public func projectsTree(
        previewLimit: Int = 3, profile: String? = nil
    ) async throws -> ProjectTree {
        var params: [String: JSONValue] = [
            "preview_limit": .number(Double(previewLimit))
        ]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await request("projects.tree", params: .object(params))
        return ProjectTree(json: result)
    }

    public func projectSessions(
        projectID: String, profile: String? = nil, sessionLimit: Int? = nil
    ) async throws -> [SessionSummary] {
        var params: [String: JSONValue] = ["project_id": .string(projectID)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        if let sessionLimit { params["session_limit"] = .number(Double(sessionLimit)) }
        let result = try await request("projects.project_sessions", params: .object(params))
        if let project = result["project"] { return ProjectInfo.hydratedSessions(in: project) }
        return result["sessions"]?.arrayValue?.compactMap(SessionSummary.init(json:)) ?? []
    }

    // MARK: Prompt-family responses

    /// `approval.respond` — absent choice means deny server-side, so always
    /// pass one of the event's choices. Without `requestID` the server
    /// resolves the OLDEST queued approval; pass the event's id when it has
    /// one so the answer lands on the exact card the user saw.
    ///
    /// The contract-6 path. The method still exists on contract ≥ 7, but an
    /// `ApprovalRequest` with a `serverRequestID` came from a server request
    /// and is answered with `answerServerRequest(id:result:)` instead.
    ///
    /// On a session authority the response names the prompt instead:
    /// `{session_id, execution_generation, prompt_id, choice}`, with
    /// `requestID` as the prompt id and the prompt's own generation
    /// (`ApprovalRequest.executionGeneration`; the session's newest when nil).
    public func respondApproval(
        sessionID: String, choice: String, requestID: String? = nil,
        executionGeneration: Int? = nil
    ) async throws {
        if speaksSessionAuthority {
            // The authority answers exactly {session_id, execution_generation,
            // prompt_id, choice}; prompt_id is the approval's request id.
            guard let promptID = requestID, !promptID.isEmpty,
                let generation = executionGeneration ?? executionGenerations[sessionID]
            else {
                throw HermesError.malformedResponse(
                    "approval has no prompt_id/execution_generation to answer")
            }
            _ = try await request(
                "approval.respond",
                params: AuthorityWire.approvalParams(
                    sessionID: sessionID, generation: generation,
                    promptID: promptID, choice: choice))
            return
        }
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID), "choice": .string(choice),
        ]
        if let requestID, !requestID.isEmpty { params["request_id"] = .string(requestID) }
        _ = try await request("approval.respond", params: .object(params))
    }

    /// `clarify.respond` — empty answer = skip. A late respond after expiry
    /// returns `{"status":"expired"}`, never an error — a successful
    /// transport call is NOT delivery; check the returned status.
    ///
    /// On a BATCH clarify, calling this without a question id cancels the
    /// whole batch (server resolves every question with this one answer).
    ///
    /// On a session authority: `{session_id, execution_generation,
    /// prompt_id, answer}`, the prompt id being `requestID`; pass the
    /// request's `sessionID` and `executionGeneration` (the session's newest
    /// is used when the generation is nil).
    @available(*, deprecated, message: "Contract-6 only: a contract ≥ 7 backend removed clarify.respond and answers -32601. Use answerServerRequest(id:result:) with ServerRequestResult.clarify.")
    public func respondClarify(
        requestID: String, answer: String, sessionID: String? = nil,
        executionGeneration: Int? = nil
    ) async throws -> PromptResponseStatus {
        if speaksSessionAuthority {
            guard let sessionID,
                let generation = executionGeneration ?? executionGenerations[sessionID]
            else {
                throw HermesError.malformedResponse(
                    "clarify has no session_id/execution_generation to answer")
            }
            let result = try await request(
                "clarify.respond",
                params: AuthorityWire.clarifyParams(
                    sessionID: sessionID, generation: generation,
                    promptID: requestID, answer: answer))
            return try PromptResponseStatus(result: result)
        }
        let result = try await request(
            "clarify.respond",
            params: ["request_id": .string(requestID), "answer": .string(answer)])
        return try PromptResponseStatus(result: result)
    }

    /// Answer ONE question of a batch clarify. Returns the qids still
    /// unanswered (nil when the request had already expired); the batch
    /// resolves server-side when the list empties. A locked answer stays
    /// editable until then — re-responding the same qid overwrites it.
    @available(*, deprecated, message: "Contract-6 only: a contract ≥ 7 backend removed clarify.respond and answers -32601. Use lockClarifyAnswer(requestID:questionID:answer:).")
    public func respondClarifyQuestion(
        requestID: String, questionID: String, answer: String
    ) async throws -> [String]? {
        let result = try await request(
            "clarify.respond",
            params: [
                "request_id": .string(requestID),
                "question_id": .string(questionID),
                "answer": .string(answer),
            ])
        if case .expired = try PromptResponseStatus(result: result) { return nil }
        return result["remaining"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    // MARK: Server requests (contract ≥ 7)

    /// `request.answer {id, result}` — answer an open server→client request.
    /// `result` is one of the `ServerRequestResult` objects; the backend
    /// refuses a non-object (4002) and undeclared keys (4000).
    ///
    /// Answered through an acknowledged RPC rather than a bare response
    /// frame, so the caller learns whether it landed, and so it works from
    /// a socket that never received the request (a reconnect restoring
    /// `open_requests`). `.expired` means the request had already ended
    /// (timeout, cancel, or answered from another client) and the agent
    /// never saw this answer; any other status throws.
    public func answerServerRequest(
        id: String, result: JSONValue
    ) async throws -> PromptResponseStatus {
        let reply = try await request(
            "request.answer", params: ["id": .string(id), "result": result])
        return try PromptResponseStatus(result: reply)
    }

    /// `clarify.lock {request_id, question_id, answer}` — lock one answer of
    /// a batch clarify server request before the rest are answered, the way
    /// the desktop does. `requestID` is the request's id
    /// (`ClarifyRequest.serverRequestID`). Returns the qids still
    /// unanswered; the lock that empties the list resolves the request with
    /// every locked answer. A locked answer stays editable until then. Nil
    /// when the request already ended (`status: "expired"`, not an error).
    ///
    /// Optional: one `answerServerRequest` with
    /// `ServerRequestResult.clarify(answers:)` also resolves the batch, and
    /// the backend merges any answers locked here into it.
    public func lockClarifyAnswer(
        requestID: String, questionID: String, answer: String
    ) async throws -> [String]? {
        let result = try await request(
            "clarify.lock",
            params: [
                "request_id": .string(requestID),
                "question_id": .string(questionID),
                "answer": .string(answer),
            ])
        if case .expired = try PromptResponseStatus(result: result) { return nil }
        return result["remaining"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// `connection.respond` — the card's answer to a `ConnectionRequest`.
    /// Returns whether the operation settled.
    ///
    /// The params changed shape at contract 8 (hermes-agent 70f5dc5f46): the
    /// session moved from `session_id` into `owner: {type: "session",
    /// session_id}`. Each backend refuses the other shape with 4000, so pass
    /// the session's `desktopContract`: 7 sends `session_id`; 8, newer, or
    /// unknown sends `owner` (connection operations do not exist before 7).
    @discardableResult
    public func respondConnection(
        sessionID: String, opID: String, answer: ConnectionAnswer, desktopContract: Int?
    ) async throws -> Bool {
        var params: [String: JSONValue] = ["op_id": .string(opID), "result": answer.json]
        if let desktopContract, desktopContract < 8 {
            params["session_id"] = .string(sessionID)
        } else {
            params["owner"] = ["type": "session", "session_id": .string(sessionID)]
        }
        let result = try await request("connection.respond", params: .object(params))
        guard result["status"]?.stringValue == "ok", let settled = result["settled"]?.boolValue else {
            throw HermesError.malformedResponse("connection.respond returned no ok status")
        }
        return settled
    }
}

/// Outcome of answering a blocking prompt (contract-6 clarify / sudo /
/// secret, contract ≥ 7 `request.answer` and `clarify.lock`). The server
/// resolves a late answer with `{"status": "expired"}` instead of an error,
/// so transport success alone must never be treated as delivery. Any other
/// status, or none, throws `malformedResponse` rather than reading as
/// delivered.
public enum PromptResponseStatus: Sendable, Equatable {
    /// The answer reached the waiting agent.
    case accepted
    /// The request had already expired server-side — the answer was
    /// discarded and the agent never saw it.
    case expired

    init(result: JSONValue) throws {
        switch result["status"]?.stringValue {
        // `resolved` is a v0.23 session authority's answer to
        // `approval.respond` / `clarify.respond` (`AuthorityWire`).
        case "ok", "resolved": self = .accepted
        case "expired": self = .expired
        case let other:
            throw HermesError.malformedResponse(
                "respond returned unrecognized status \(other ?? "<missing>")")
        }
    }
}

// MARK: - Session management + mid-turn controls

extension HermesConnection {
    /// `session.steer` — inject text into the next tool result of the
    /// running turn without interrupting. Returns true when the agent
    /// accepted it (`status: "queued"`). False is `"rejected"`, which the
    /// server sends when no turn is running: nothing was stored, so send the
    /// text as the next `prompt.submit` or it's lost.
    @discardableResult
    public func steerSession(sessionID: String, text: String) async throws -> Bool {
        let result = try await request(
            "session.steer",
            params: ["session_id": .string(sessionID), "text": .string(text)])
        return result["status"]?.stringValue == "queued"
    }

    /// `session.redirect` — redirect the active model turn, preserving valid
    /// work. Returns true when the server took it: `"redirected"` (the
    /// active turn was redirected) or `"queued"` (sent during the turn-build
    /// window, so it runs as the next turn instead). `"rejected"` — the
    /// agent refused — is false.
    @discardableResult
    public func redirectSession(sessionID: String, text: String) async throws -> Bool {
        let result = try await request(
            "session.redirect",
            params: ["session_id": .string(sessionID), "text": .string(text)])
        let status = result["status"]?.stringValue
        return status == "redirected" || status == "queued"
    }

    /// `session.title` — set (or, with nil, fetch/settle) the session title.
    /// Returns the resolved title.
    @discardableResult
    public func setSessionTitle(sessionID: String, title: String?) async throws -> String? {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let title { params["title"] = .string(title) }
        let result = try await request("session.title", params: .object(params))
        return result["title"]?.stringValue
    }

    /// `session.delete` — delete a **stored** session and its transcript
    /// files. The server refuses to delete a session live in this gateway,
    /// and answers 4023 while a turn or compression anywhere still owns the
    /// row (hermes-agent `40523600b0`); the row is kept, so keep it listed.
    public func deleteSession(storedID: String, profile: String? = nil) async throws {
        var params: [String: JSONValue] = ["session_id": .string(storedID)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        _ = try await request("session.delete", params: .object(params))
    }

    /// Compatibility spelling; replay validation is shared with Voice.
    public typealias EventReplayPage = EventReplayBatch

    public func sessionEventsSince(sessionID: String, lastSeen: Int) async throws -> EventReplayBatch {
        let result = try await request("session.events.since", params: [
            "session_id": .string(sessionID), "last_seen": .number(Double(lastSeen))])
        return EventReplayBatch(result: result)
    }

    public func eventsSince(sessionID: String, lastSeen: Int) async throws -> EventReplayBatch {
        try await sessionEventsSince(sessionID: sessionID, lastSeen: lastSeen)
    }

    /// `session.branch` — fork the session's history into a new session.
    /// `count` limits how many history messages carry over. Returns the new
    /// session's handle when the result carries one.
    public func branchSession(
        sessionID: String, name: String? = nil, count: Int? = nil
    ) async throws -> SessionHandle? {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let name, !name.isEmpty { params["name"] = .string(name) }
        if let count, count > 0 { params["count"] = .number(Double(count)) }
        let result = try await request("session.branch", params: .object(params), timeout: 120)
        return SessionHandle(result: result)
    }

    /// `model.options` — populate a model picker. The payload shape is
    /// provider-grouped; flatten to options where recognizable.
    public func modelOptions(sessionID: String? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = [:]
        if let sessionID { params["session_id"] = .string(sessionID) }
        return try await request(
            "model.options", params: params.isEmpty ? nil : .object(params), timeout: 120)
    }

    // MARK: Secure blocking-prompt responses

    /// `sudo.respond` — answer field is `password` (empty = decline). Never
    /// log or persist the value. Late answers return `{"status":"expired"}`;
    /// check the returned status before reporting delivery.
    @available(*, deprecated, message: "Contract-6 only: a contract ≥ 7 backend removed sudo.respond and answers -32601. Use answerServerRequest(id:result:) with ServerRequestResult.value(_:).")
    public func respondSudo(
        requestID: String, password: String
    ) async throws -> PromptResponseStatus {
        let result = try await request(
            "sudo.respond",
            params: ["request_id": .string(requestID), "password": .string(password)])
        return try PromptResponseStatus(result: result)
    }

    /// `secret.respond` — answer field is `value` (empty = skip). Never log
    /// or persist the value. Late answers return `{"status":"expired"}`;
    /// check the returned status before reporting delivery.
    @available(*, deprecated, message: "Contract-6 only: a contract ≥ 7 backend removed secret.respond and answers -32601. Use answerServerRequest(id:result:) with ServerRequestResult.value(_:).")
    public func respondSecret(
        requestID: String, value: String
    ) async throws -> PromptResponseStatus {
        let result = try await request(
            "secret.respond",
            params: ["request_id": .string(requestID), "value": .string(value)])
        return try PromptResponseStatus(result: result)
    }

    /// `mcp.setup.respond` — answer field is `result`, a JSON **string** of
    /// the setup card's outcome. `status` must be one of installed | enabled
    /// | authorized | declined | error; on declined the agent continues
    /// without the server and must not re-ask.
    @available(*, deprecated, message: "Contract-6 only: a contract ≥ 7 backend removed mcp.setup.respond and answers -32601. Use respondConnection(sessionID:opID:answer:desktopContract:).")
    public func respondMcpSetup(
        requestID: String, status: String, server: String, detail: String? = nil
    ) async throws -> PromptResponseStatus {
        var outcome: [String: JSONValue] = [
            "status": .string(status), "server": .string(server),
        ]
        if let detail, !detail.isEmpty { outcome["detail"] = .string(detail) }
        let result = try await request(
            "mcp.setup.respond",
            params: [
                "request_id": .string(requestID),
                "result": .string(JSONValue.object(outcome).encodedString()),
            ])
        return try PromptResponseStatus(result: result)
    }
}
