import Foundation

// The shared queue of a session owned by a v0.23+ session authority, and the
// revision-fenced `session.mutate` the authority uses for session edits. Only
// a connection that `speaksSessionAuthority` has either: on the legacy wire a
// busy session's prompt is forwarded to its owner (`PromptSubmission.forwarded`)
// and no queue is visible.
//
// Shapes are hermes-agent v0.23.0 (`2bd378ed1b`): `gateway/session_queued_controls.py`,
// `tui_gateway/contracts/canonical.py`, `hermes_state_mutations.validate_action`,
// live-checked against a throwaway Webapp listener.

/// One admission in a session's queue, from `session.info.pending` or a
/// create/resume snapshot's `pending`. The queue is the session's, not this
/// device's: rows another client admitted are listed too.
public struct QueuedPrompt: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case queued
        /// The running turn took it (or is taking it as a steer).
        case started
        /// The owner restarted mid-turn and can't tell whether it ran.
        case unknown
        case other(String)

        init(_ raw: String?) {
            switch raw {
            case "queued": self = .queued
            case "started": self = .started
            case "unknown": self = .unknown
            default: self = .other(raw ?? "")
            }
        }
    }

    /// What the owner lets a client do with a queued row. Only these are
    /// offered: an owner that lists none (an older one, a row with
    /// attachments, a hidden row) gets no row actions beyond cancel.
    public enum Control: String, Sendable, CaseIterable {
        /// Hand its text to the running turn now (`prompt.steer_queued`).
        case steer
        /// Edit it (`prompt.replace_queued`).
        case replace
    }

    public var admissionID: String
    public var sequence: Int
    public var text: String
    public var status: Status
    public var controls: Set<Control>
    /// Being handed to the running turn as a steer.
    public var steering: Bool
    /// The turn generation an `unknown` row was lost in (`prompt.resolve_unknown`).
    public var executionGeneration: Int?
    public var id: String { admissionID }

    public init?(row: JSONValue) {
        guard let admissionID = row["admission_id"]?.stringValue, !admissionID.isEmpty else {
            return nil
        }
        self.admissionID = admissionID
        sequence = row["sequence"]?.intValue ?? 0
        text = row["text"]?.stringValue ?? ""
        status = Status(row["status"]?.stringValue)
        controls = Set(
            (row["controls"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Control.init) })
        steering = row["steering"]?.boolValue ?? false
        executionGeneration = row["execution_generation"]?.intValue
    }

    /// The queue a `session.info` payload or snapshot carries, oldest first;
    /// nil when it carries none (a legacy payload, or a `session.info` that
    /// isn't a queue fanout). An empty array means the queue emptied.
    public static func list(from payload: JSONValue) -> [QueuedPrompt]? {
        guard let rows = payload["pending"]?.arrayValue else { return nil }
        return rows.compactMap(QueuedPrompt.init(row:)).sorted { $0.sequence < $1.sequence }
    }
}

/// `prompt.receipt` — where one admission stands.
public struct AdmissionReceipt: Sendable, Equatable {
    public var admissionID: String
    /// `queued`, `started`, `terminal` or `unknown`.
    public var status: String?
    /// Set once terminal: `completed`, `cancelled`, `failed`, `steering`…
    public var outcome: String?
    public var executionGeneration: Int?

    init(result: JSONValue, admissionID: String) {
        self.admissionID = result["admission_id"]?.stringValue ?? admissionID
        status = result["status"]?.stringValue
        outcome = result["outcome"]?.stringValue
        executionGeneration = result["execution_generation"]?.intValue
    }
}

extension HermesConnection {
    // MARK: Queue

    /// `prompt.cancel` — retire a queued admission. One the running turn has
    /// already started is interrupted in the same call.
    @discardableResult
    public func cancelQueued(sessionID: String, admissionID: String) async throws -> AdmissionReceipt {
        try requireAuthority("prompt.cancel")
        let result = try await request(
            "prompt.cancel",
            params: ["session_id": .string(sessionID), "admission_id": .string(admissionID)])
        return AdmissionReceipt(result: result, admissionID: admissionID)
    }

    /// `prompt.replace_queued` — cancel a still-queued admission and admit
    /// `text` in its place, at the back of the queue, in one write. Offered
    /// only when the row's `controls` has `.replace`. `submissionID` makes a
    /// retry of the same edit idempotent: reuse it for that edit's retries.
    /// Refused (`HermesError.rpcReason`) when the turn already took the row:
    /// keep the user's edit then.
    @discardableResult
    public func replaceQueued(
        sessionID: String, admissionID: String, text: String, submissionID: String
    ) async throws -> AdmissionReceipt {
        try requireAuthority("prompt.replace_queued")
        let result = try await request(
            "prompt.replace_queued",
            params: [
                "session_id": .string(sessionID), "admission_id": .string(admissionID),
                "text": .string(text), "submission_id": .string(submissionID),
            ])
        return AdmissionReceipt(result: result, admissionID: result["admission_id"]?.stringValue ?? admissionID)
    }

    /// `prompt.steer_queued` — hand a still-queued admission's text to the
    /// running turn as a steer. Offered only when `controls` has `.steer`.
    @discardableResult
    public func steerQueued(sessionID: String, admissionID: String) async throws -> AdmissionReceipt {
        try requireAuthority("prompt.steer_queued")
        let result = try await request(
            "prompt.steer_queued",
            params: ["session_id": .string(sessionID), "admission_id": .string(admissionID)])
        return AdmissionReceipt(result: result, admissionID: admissionID)
    }

    /// `prompt.receipt` for an admission this client submitted or controls.
    public func promptReceipt(sessionID: String, admissionID: String) async throws -> AdmissionReceipt {
        try requireAuthority("prompt.receipt")
        let result = try await request(
            "prompt.receipt",
            params: ["session_id": .string(sessionID), "admission_id": .string(admissionID)])
        return AdmissionReceipt(result: result, admissionID: admissionID)
    }

    /// `prompt.resolve_unknown` — acknowledge a turn lost across an owner
    /// restart (`QueuedPrompt.Status.unknown`) so the queue behind it resumes.
    /// It never requeues the lost input.
    public func resolveUnknown(sessionID: String, prompt: QueuedPrompt) async throws {
        try requireAuthority("prompt.resolve_unknown")
        guard let generation = prompt.executionGeneration ?? executionGenerations[sessionID] else {
            throw HermesError.malformedResponse("no execution_generation for the lost admission")
        }
        _ = try await request(
            "prompt.resolve_unknown",
            params: [
                "session_id": .string(sessionID), "admission_id": .string(prompt.admissionID),
                "execution_generation": .number(Double(generation)),
            ])
    }

    // MARK: Prompts raised as events

    /// Answer a clarify a session authority raised as a `clarify.request`
    /// event (`ClarifyRequest.serverRequestID == nil`): `clarify.respond`
    /// by `prompt_id` and the generation it was raised in. Batch clarify,
    /// sudo and secret still arrive as server requests there and are answered
    /// with `answerServerRequest`.
    public func respondClarifyPrompt(
        sessionID: String, promptID: String, answer: String, executionGeneration: Int?
    ) async throws -> PromptResponseStatus {
        try requireAuthority("clarify.respond")
        guard let generation = executionGeneration ?? executionGenerations[sessionID] else {
            throw HermesError.malformedResponse("clarify has no execution_generation to answer")
        }
        let result = try await request(
            "clarify.respond",
            params: AuthorityWire.clarifyParams(
                sessionID: sessionID, generation: generation, promptID: promptID, answer: answer))
        return try PromptResponseStatus(result: result)
    }

    // MARK: Mutations

    /// `session.mutate` with this connection's newest revision (and, when
    /// `fenced`, execution generation) for the session. A
    /// `revision_conflict` or `stale_generation` refusal carries the fresh
    /// fences; the edit is retried once with them and a new request id.
    func mutateSession(
        sessionID: String, operation: String, payload: [String: JSONValue], fenced: Bool
    ) async throws -> JSONValue {
        var revision = sessionRevisions[sessionID]
        var generation = executionGenerations[sessionID]
        for attempt in 0..<2 {
            guard let expected = revision else {
                throw HermesError.malformedResponse(
                    "no revision known for \(sessionID); reopen the session before editing it")
            }
            var params: [String: JSONValue] = [
                "session_id": .string(sessionID), "request_id": .string(UUID().uuidString.lowercased()),
                "expected_revision": .number(Double(expected)), "operation": .string(operation),
                "payload": .object(payload),
            ]
            if fenced {
                guard let generation else {
                    throw HermesError.malformedResponse(
                        "no execution_generation known for \(sessionID); cannot \(operation)")
                }
                params["expected_generation"] = .number(Double(generation))
            }
            do {
                let result = try await request("session.mutate", params: .object(params), timeout: 300)
                if let next = result["revision"]?.intValue { noteRevision(next, for: sessionID) }
                if let next = result["execution_generation"]?.intValue {
                    noteExecutionGeneration(next, for: sessionID)
                }
                return result
            } catch let HermesError.rpcError(_, _, data)
                where attempt == 0
                && ["revision_conflict", "stale_generation"].contains(data?["reason"]?.stringValue ?? "")
            {
                if let fresh = data?["revision"]?.intValue {
                    noteRevision(fresh, for: sessionID)
                    revision = fresh
                }
                if let fresh = data?["execution_generation"]?.intValue {
                    noteExecutionGeneration(fresh, for: sessionID)
                    generation = fresh
                }
            }
        }
        throw HermesError.malformedResponse("session.mutate retry loop exited")  // unreachable
    }

    func requireAuthority(_ method: String) throws {
        guard speaksSessionAuthority else {
            throw HermesError.rpcError(
                code: -32601, message: "\(method) needs a session-authority connection", data: nil)
        }
    }
}
