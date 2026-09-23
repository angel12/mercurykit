import Foundation

/// A server→client JSON-RPC request (desktop contract ≥ 7, hermes-agent
/// `d3a44784b1`): the backend asks this client a question and waits for an
/// answer keyed by `id` (`srq-<12hex>`, `tui_gateway/server_requests.py`).
///
/// A live one reaches the app as a `GatewayEvent.Kind.serverRequest` event
/// (see `ServerRequestPolicy`); a reconnect restores unanswered ones from
/// `open_requests`. Either way it is answered with
/// `HermesConnection.answerServerRequest(id:result:)` and withdrawn by a
/// `request.cancel {id, method, reason}` event.
public struct ServerRequest: Sendable, Equatable {
    public var id: String
    public var method: String
    /// `params.session_id` — the transport adds it to every request frame.
    public var sessionID: String?
    public var params: JSONValue

    /// Request methods (`tui_gateway/contracts/server_requests.py`) the kit
    /// decodes into typed prompts. Open set: a backend may send others
    /// (`vault.*`, `terminal.read`, `preview.*`, `window.read`, `tour`, …).
    public enum Method {
        public static let approval = "approval"
        public static let clarify = "clarify"
        public static let sudo = "sudo"
        public static let secret = "secret"
    }

    public init(id: String, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
        self.sessionID = params["session_id"]?.stringValue
    }

    /// A live frame: has a `method` other than `"event"` and a *string* id
    /// (client-minted ids are integers, so the two never collide).
    public init?(frame: JSONValue) {
        guard let method = frame["method"]?.stringValue, method != "event",
            let id = frame["id"]?.stringValue
        else { return nil }
        self.init(id: id, method: method, params: frame["params"] ?? .object([:]))
    }

    /// An `open_requests` entry (`ServerRequest.snapshot()` upstream):
    /// `{id, method, params}`, the same shape as a frame minus `jsonrpc`.
    public init?(snapshot: JSONValue) {
        guard let id = snapshot["id"]?.stringValue, !id.isEmpty,
            let method = snapshot["method"]?.stringValue, !method.isEmpty
        else { return nil }
        self.init(id: id, method: method, params: snapshot["params"] ?? .object([:]))
    }

    /// The `open_requests` list of a `session.resume` / `session.activate`
    /// / `session.events.since` result: the server requests still waiting
    /// for an answer, oldest first. `[]` when the field is absent (a
    /// contract-6 backend, or nothing open). Nil when it is present but not
    /// an array, or holds an entry that is not `{id, method, params}`:
    /// dropping that entry would understate what the backend is waiting on,
    /// so the caller must treat the list as unknown.
    public static func openRequests(in result: JSONValue) -> [ServerRequest]? {
        guard let field = result["open_requests"] else { return [] }
        guard let entries = field.arrayValue else { return nil }
        var requests: [ServerRequest] = []
        for entry in entries {
            guard let request = ServerRequest(snapshot: entry) else { return nil }
            requests.append(request)
        }
        return requests
    }

    /// The request a `GatewayEvent.Kind.serverRequest` event carries.
    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.serverRequest else { return nil }
        self.init(snapshot: event.payload)
    }

    /// Whether the typed prompt for this request can be built, so an app
    /// that routed it can actually put it on screen. Fail-closed: a request
    /// without a `session_id` or with a non-object `params` never is, and
    /// the four kit-typed methods must pass their typed decoders. Other
    /// methods an app opted into need only the session and object params;
    /// their content is the app's to judge.
    public var isDisplayable: Bool {
        guard let sessionID, !sessionID.isEmpty, params.objectValue != nil else { return false }
        switch method {
        case Method.approval: return ApprovalRequest(serverRequest: self) != nil
        case Method.clarify: return ClarifyRequest(serverRequest: self) != nil
        case Method.sudo: return SudoRequest(serverRequest: self) != nil
        case Method.secret: return SecretRequest(serverRequest: self) != nil
        default: return true
        }
    }
}

/// Which server→client requests an app answers — the per-app contract-7
/// switch. `.disabled` (the default everywhere) keeps contract-6 behaviour
/// exactly: no `client.capabilities` advertisement, and request frames are
/// ignored the way they always were, so a co-attached client that does
/// answer them is undisturbed.
///
/// When enabled (a non-empty `answerableMethods`), each new socket
/// advertises `client.capabilities {server_requests: true}` before it is
/// reported ready, and each request frame is handled one of three ways:
///
/// - **Routed**: its method is answerable and `ServerRequest.isDisplayable`
///   holds. It is published as a `GatewayEvent.Kind.serverRequest` event on
///   the ordinary event stream, so it keeps its place relative to the events
///   around it and goes through the app's replay hold.
/// - **Refused as malformed**: its method is answerable but it cannot be
///   displayed. An error reply (`-32602`) settles it at once — the agent
///   sees a skip or decline instead of waiting out its deadline for a card
///   nobody will ever show.
/// - **Unanswerable**: see `Unanswerable`.
///
/// A routed request is published to whoever is subscribed. If no screen is
/// listening, the server keeps waiting and the next resume restores it from
/// `open_requests`.
public struct ServerRequestPolicy: Sendable, Equatable {
    /// What to do with a request whose method is not in `answerableMethods`
    /// — for Chat and Voice that is every desktop-only request the backend
    /// may send: `vault.unlock_prompt`, `vault.save_login`, `vault.code`,
    /// `terminal.read`, `preview.read`, `preview.act`, `window.read` and
    /// `tour`, plus `sudo` and `secret` for Voice. The backend's full list
    /// for a socket is `HermesConnection.serverRequestMethods`.
    ///
    /// ## Why there is a choice
    ///
    /// Upstream fans each request frame out to every client attached to the
    /// session, and the first response for an id settles it for all of them
    /// (`server_requests.resolve_response`), error replies included. The two
    /// options trade one failure for the other:
    ///
    /// | | Another client attached (e.g. the desktop) | This app is the only client |
    /// |---|---|---|
    /// | `.leaveForOtherClients` | That client answers it normally. | The agent blocks until the request's server-side deadline (300 s for most prompts; the tour probe 10 s), then continues as if skipped. |
    /// | `.refuse` | The prompt is taken away from that client before the user can answer it there. | The agent continues at once as if skipped. |
    ///
    /// "As if skipped" is the backend's handling of a request that got no
    /// result: a one-string prompt (`vault.*`, GUI reads, `tour`, `sudo`,
    /// `secret`) resolves to `""` (declined or unavailable), a clarify to
    /// an empty answer (skipped), and an approval is withdrawn, so its
    /// command is cancelled rather than denied.
    ///
    /// ## What `unanswerable` does not affect
    ///
    /// - `.disabled` never refuses anything: request frames are ignored.
    /// - An *answerable* request that cannot be decoded (no `session_id`,
    ///   non-object `params`, a batch clarify that fails to decode, …) is
    ///   always refused with `-32602`, whatever this is set to. The app said
    ///   it answers that method, so no other client is being relied on, and
    ///   leaving it would make the agent wait for a card nobody shows.
    /// - `open_requests` replayed on reconnect are never refused by the
    ///   kit; the app decides what to do with entries it cannot answer.
    public enum Unanswerable: Sendable, Equatable {
        /// Default. Send nothing and let another attached client answer.
        /// The request is logged at debug level only. Choose this unless you
        /// are sure no other client shares the app's sessions: it is the
        /// only option that never takes a prompt away from the desktop.
        case leaveForOtherClients
        /// Answer at once with a JSON-RPC error response: `-32601` and the
        /// message `"<method> is not handled by this client"` (it names the
        /// method, never the app), sent on the socket the request arrived
        /// on. The agent then continues immediately instead of waiting out
        /// the deadline.
        ///
        /// Choose it only when the app knows it is the sole client of its
        /// sessions, for example against a backend no desktop connects to.
        /// Upstream's `client.capabilities` contract describes this reply
        /// as the expected behaviour for a client with no handler, but that
        /// assumes the refusing client is the only one attached.
        ///
        /// ```swift
        /// let policy = ServerRequestPolicy(
        ///     answerableMethods: ServerRequestPolicy.voice.answerableMethods,
        ///     unanswerable: .refuse)
        /// let connection = HermesConnection(
        ///     endpoint: endpoint, authenticator: authenticator,
        ///     reconnectPolicy: .voice, serverRequestPolicy: policy)
        /// ```
        case refuse
    }

    /// The request methods this app shows and answers. Empty disables the
    /// contract-7 switch entirely (see `.disabled`).
    public var answerableMethods: Set<String>
    /// What happens to every other request method. Defaults to
    /// `.leaveForOtherClients`; see `Unanswerable` before choosing
    /// `.refuse`.
    public var unanswerable: Unanswerable

    /// - Parameters:
    ///   - answerableMethods: the methods this app answers, e.g.
    ///     `ServerRequestPolicy.chat.answerableMethods`.
    ///   - unanswerable: what to do with any other method. Leave the default
    ///     unless the app is certain to be the only client of its sessions.
    public init(answerableMethods: Set<String>, unanswerable: Unanswerable = .leaveForOtherClients) {
        self.answerableMethods = answerableMethods
        self.unanswerable = unanswerable
    }

    /// Contract-6 behaviour: nothing advertised, routed, or refused.
    public static let disabled = Self(answerableMethods: [])
    /// The prompts Mercury Chat renders.
    public static let chat = Self(answerableMethods: [
        ServerRequest.Method.approval, ServerRequest.Method.clarify,
        ServerRequest.Method.sudo, ServerRequest.Method.secret,
    ])
    /// The prompts Mercury Voice renders.
    public static let voice = Self(answerableMethods: [
        ServerRequest.Method.approval, ServerRequest.Method.clarify,
    ])

    /// Whether the contract-7 handshake and routing are on.
    public var isEnabled: Bool { !answerableMethods.isEmpty }
}

/// `result` objects for `HermesConnection.answerServerRequest(id:result:)`,
/// exactly as `tui_gateway/contracts/server_requests.py` declares them. The
/// backend refuses undeclared keys (4000), so build answers here rather than
/// by hand.
public enum ServerRequestResult {
    /// `approval` → `{choice}` (once | session | always | deny), plus
    /// `all: true` to resolve every queued approval with the same choice.
    public static func approval(choice: String, all: Bool = false) -> JSONValue {
        var result: [String: JSONValue] = ["choice": .string(choice)]
        if all { result["all"] = .bool(true) }
        return .object(result)
    }

    /// Single-question `clarify` → `{answer}`; `""` skips the question.
    public static func clarify(answer: String) -> JSONValue {
        .object(["answer": .string(answer)])
    }

    /// Batch `clarify` → `{answers: {qid: answer}}` for the whole set. The
    /// server merges answers already locked with `clarify.lock`, so this may
    /// carry only the ones still open.
    public static func clarify(answers: [String: String]) -> JSONValue {
        .object(["answers": .object(answers.mapValues(JSONValue.string))])
    }

    /// `clarify` with neither `answer` nor `answers` (`{}`): cancel every
    /// question of the request.
    public static let clarifyCancelAll: JSONValue = .object([:])

    /// `sudo` and `secret` → `{value}`; `""` declines. Never log the value.
    public static func value(_ value: String) -> JSONValue {
        .object(["value": .string(value)])
    }
}

extension GatewayEvent {
    /// Carries a server request down the event pipeline, so it inherits the
    /// app's ordering, replay hold and prompt handling. Never seq-stamped:
    /// it is not part of the replay ring (`open_requests` is its replay).
    public init(serverRequest request: ServerRequest) {
        self.init(
            type: Kind.serverRequest,
            sessionID: request.sessionID,
            payload: .object([
                "id": .string(request.id),
                "method": .string(request.method),
                "params": request.params,
            ]))
    }
}

/// `request.cancel {id, method, reason}` — the backend withdrew an open
/// server request (timeout | interrupted | shutdown | resolved |
/// session_closed, or a tool's own wording). Clear the matching card only.
public struct ServerRequestCancel: Sendable, Equatable {
    public var id: String
    public var method: String
    public var reason: String
    public var sessionID: String?

    public init?(event: GatewayEvent) {
        guard event.type == GatewayEvent.Kind.requestCancel,
            let id = event.payload["id"]?.stringValue, !id.isEmpty
        else { return nil }
        self.id = id
        self.method = event.payload["method"]?.stringValue ?? ""
        self.reason = event.payload["reason"]?.stringValue ?? ""
        self.sessionID = event.sessionID
    }
}
