import Foundation

/// Product-owned retry behavior; only one stop rule applies at a time.
public struct ReconnectPolicy: Sendable, Equatable {
    public enum StopRule: Sendable, Equatable {
        case failureWindow(TimeInterval)
        case failedHandshakeLimit(Int)
    }
    public let stopRule: StopRule
    public let restartOnPoke: Bool
    public init(stopRule: StopRule, restartOnPoke: Bool) {
        self.stopRule = stopRule
        self.restartOnPoke = restartOnPoke
    }
    public static let chat = Self(stopRule: .failureWindow(120), restartOnPoke: true)
    public static let voice = Self(stopRule: .failedHandshakeLimit(10), restartOnPoke: false)
}


/// Owns the lifecycle of a server connection: dial, stay connected, reconnect
/// with full-jitter exponential backoff, and republish gateway events across
/// socket generations as one stable stream.
///
/// Consumers watch `updates`; a `.phase(.ready(isReconnect: true))` element is
/// the cue to re-`session.resume` by **stored** id (runtime ids are recycled
/// across backend restarts).
public actor HermesConnection {
    public enum Phase: Sendable, Equatable {
        case disconnected(reason: String?)
        case connecting(attempt: Int)
        case ready(isReconnect: Bool)
        case stopped
        /// The caller-selected retry budget is exhausted. Explicit start
        /// begins a fresh cycle; poke restarts only if the policy allows it.
        case unreachable(reason: String?)
        /// Password-mode refresh token is dead; redialing is pointless. The
        /// supervisor has stopped — the app must prompt for a fresh sign-in.
        case authExpired
        /// The server refused this client's access (WS 4403, or 403 on the
        /// HTTP upgrade). Terminal like `authExpired`, but *not* an auth
        /// story: the credentials were never in question, so a re-login
        /// fixes nothing and every redial is refused identically. The
        /// supervisor has stopped; the app shows `reason` and leaves the
        /// next move to the user.
        case refused(reason: String?)
    }

    public enum Update: Sendable {
        case phase(Phase)
        case event(GatewayEvent)
    }

    public nonisolated let endpoint: ServerEndpoint
    public nonisolated let authenticator: HermesAuthenticator
    public nonisolated let rest: HermesRESTClient

    public private(set) var phase: Phase = .stopped
    private var gateway: (any GatewayDialing)?
    private var supervisor: Task<Void, Never>?
    private var supervisorLifetime: UUID?
    private var everConnected = false
    private var reconnectPoke: CheckedContinuation<Void, Never>?
    private var backoffTimer: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<Update>.Continuation] = [:]

    /// Internal scheduling seam. Nil in shipping initializers; tests delay
    /// existing suspension boundaries without replacing gateway behavior.
    enum SupervisorCheckpoint: Sendable {
        case connected, connectFailed, eventsSubscribed, eventReceived, eventsEnded
        case closeCauseRead, closeReasonRead, finished
    }
    private let supervisorCheckpoint: (@Sendable (SupervisorCheckpoint) async -> Void)?
    /// Tests hold retries until an explicit poke; shipping keeps full jitter.
    private let backoffDelay: TimeInterval?

    private let reconnectPolicy: ReconnectPolicy
    private let now: @Sendable () -> TimeInterval
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let makeClient: @Sendable (ServerEndpoint, HermesAuthenticator) -> any GatewayDialing

    public init(endpoint: ServerEndpoint, authenticator: HermesAuthenticator,
                reconnectPolicy: ReconnectPolicy = .chat) {
        self.init(endpoint: endpoint, authenticator: authenticator,
                  reconnectPolicy: reconnectPolicy, supervisorCheckpoint: nil)
    }

    init(endpoint: ServerEndpoint, authenticator: HermesAuthenticator,
         reconnectPolicy: ReconnectPolicy = .chat,
         supervisorCheckpoint: (@Sendable (SupervisorCheckpoint) async -> Void)?,
         backoffDelay: TimeInterval? = nil,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleeper: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
         makeClient: @escaping @Sendable (ServerEndpoint, HermesAuthenticator) -> any GatewayDialing = {
             GatewayClient(endpoint: $0, authenticator: $1)
         }) {
        self.supervisorCheckpoint = supervisorCheckpoint
        self.backoffDelay = backoffDelay
        self.reconnectPolicy = reconnectPolicy
        self.now = now
        self.sleeper = sleeper
        self.makeClient = makeClient
        self.endpoint = endpoint
        self.authenticator = authenticator
        self.rest = HermesRESTClient(endpoint: endpoint, authenticator: authenticator)
    }

    // Preserve Chat's clock/dialer injection surface.
    init(endpoint: ServerEndpoint, authenticator: HermesAuthenticator,
         giveUpAfter: TimeInterval,
         now: @escaping @Sendable () -> TimeInterval,
         sleeper: @escaping @Sendable (TimeInterval) async -> Void,
         makeClient: @escaping @Sendable (ServerEndpoint, HermesAuthenticator) -> any GatewayDialing) {
        self.init(endpoint: endpoint, authenticator: authenticator,
                  reconnectPolicy: .init(stopRule: .failureWindow(giveUpAfter), restartOnPoke: true),
                  supervisorCheckpoint: nil, now: now, sleeper: sleeper, makeClient: makeClient)
    }

    public init(endpoint: ServerEndpoint, token: String?, reconnectPolicy: ReconnectPolicy = .chat) {
        self.init(endpoint: endpoint,
                  authenticator: HermesAuthenticator(endpoint: endpoint,
                      credentials: token.map { .sessionToken($0) }),
                  reconnectPolicy: reconnectPolicy)
    }

    // MARK: Subscriptions

    public func updates() -> AsyncStream<Update> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(.phase(phase))
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func publish(_ update: Update) {
        if case .phase(let phase) = update { self.phase = phase }
        for sub in subscribers.values { sub.yield(update) }
    }

    // MARK: Lifecycle

    public func start() {
        guard supervisor == nil else { return }
        let lifetime = UUID()
        supervisorLifetime = lifetime
        supervisor = Task {
            await runSupervisor(lifetime: lifetime)
            if let supervisorCheckpoint { await supervisorCheckpoint(.finished) }
        }
    }

    public func stop() {
        supervisorLifetime = nil
        supervisor?.cancel()
        supervisor = nil
        backoffTimer?.cancel()
        backoffTimer = nil
        reconnectPoke?.resume()
        reconnectPoke = nil
        let gateway = gateway
        self.gateway = nil
        Task { await gateway?.close(reason: "stopped") }
        publish(.phase(.stopped))
    }

    /// Skip the current backoff delay — call on app-foreground or
    /// network-path change.
    public func pokeReconnect() {
        if case .unreachable = phase, supervisor == nil, reconnectPolicy.restartOnPoke {
            start()
            return
        }
        backoffTimer?.cancel()
        backoffTimer = nil
        reconnectPoke?.resume()
        reconnectPoke = nil
    }

    // MARK: RPC passthrough

    public func request(
        _ method: String, params: JSONValue? = nil, timeout: TimeInterval = 60
    ) async throws -> JSONValue {
        // A caller that already gave up gets its own answer: reporting the
        // socket's state instead would blame the server for a local decision
        // (and, while ready, would still put the frame on the wire).
        try Task.checkCancellation()
        guard let gateway, case .ready = phase else { throw HermesError.notConnected }
        return try await gateway.request(method, params: params, timeout: timeout)
    }

    /// `replay_epoch` from the current socket's `gateway.ready`; nil while
    /// disconnected or against a backend without the replay contract.
    public var replayEpoch: String? {
        get async {
            let lifetime = supervisorLifetime
            let epoch = await gateway?.replayEpoch
            guard supervisorLifetime == lifetime, case .ready = phase else { return nil }
            return epoch
        }
    }

    /// Probe a seemingly-ready connection with `gateway.ping`. The app has no
    /// read timeout (quiet sockets during a busy turn are healthy), so a
    /// half-open socket — carrier NAT dropped us, the Mac slept — looks
    /// exactly like a long turn until a write fails. A failed/timed-out ping
    /// closes the socket so the supervisor redials immediately instead of
    /// waiting for the next RPC to hang. No-op when not ready (the supervisor
    /// is already redialing). A backend without the method still answers
    /// (method-not-found error), which proves liveness — only transport
    /// failures and timeouts count as dead.
    public func verifyConnection(timeout: TimeInterval = 5) async {
        guard case .ready = phase, let gateway else { return }
        do {
            _ = try await gateway.request("gateway.ping", params: nil, timeout: timeout)
        } catch is CancellationError {
            // The probe was abandoned locally; that is no evidence about the
            // socket, and dropping a healthy one would cost a reconnect.
            return
        } catch let error as HermesError {
            if case .rpcError = error { return }  // server answered — alive
            await gateway.close(reason: "heartbeat probe failed")
        } catch {
            await gateway.close(reason: "heartbeat probe failed")
        }
    }

    // MARK: Supervisor

    private func ownsSupervisor(_ lifetime: UUID) -> Bool {
        supervisorLifetime == lifetime && !Task.isCancelled
    }

    private func runSupervisor(lifetime: UUID) async {
        var attempt = 0
        var failedDials = 0
        var failingSince: TimeInterval?
        while ownsSupervisor(lifetime) {
            publish(.phase(.connecting(attempt: attempt)))

            let client = makeClient(endpoint, authenticator)
            do {
                try await client.connect(timeout: 10)
                if let supervisorCheckpoint { await supervisorCheckpoint(.connected) }
            } catch {
                // Read the cause and reason before close() — close() is a
                // no-op once the socket already closed itself, but what it
                // recorded is what distinguishes a rejected credential from
                // a refused client from a dropped network.
                let cause = await client.closeCause
                let closeReason = await closeReason(of: client)
                await client.close(reason: nil)
                if let supervisorCheckpoint { await supervisorCheckpoint(.connectFailed) }
                guard ownsSupervisor(lifetime) else { return }  // stop() published .stopped
                if cause == .unauthorized {
                    // The handshake was refused with 4401, or 401 on the
                    // upgrade itself (a dead token can be rejected either
                    // mid-flight or on the next dial, depending on when the
                    // backend restarted). Terminal either way.
                    publish(.phase(.authExpired))
                    supervisor = nil
                    return
                }
                if cause == .forbidden {
                    // 4403, or 403 on the upgrade: an access refusal, not a
                    // credential failure. Stop with the explanation instead
                    // of redialing a "no" that will not change, and without
                    // asking for credentials the server never objected to.
                    publish(.phase(.refused(reason: closeReason)))
                    supervisor = nil
                    return
                }
                if case HermesError.sessionExpired = error {
                    // The refresh token is dead — every redial would fail the
                    // same way. Stop; the user must sign in again.
                    publish(.phase(.authExpired))
                    supervisor = nil
                    return
                }
                let reason = (error as? HermesError)?.errorDescription ?? error.localizedDescription
                failedDials += 1
                if giveUp(failingSince: &failingSince, failedDials: failedDials, reason: reason) { return }
                publish(.phase(.disconnected(reason: reason)))
                attempt += 1
                await backoff(attempt: attempt, lifetime: lifetime)
                continue
            }

            // stop() during the handshake only sees the published `gateway`
            // (still nil here) — the local client must be closed explicitly
            // or its socket and receive loop outlive the connection.
            if !ownsSupervisor(lifetime) {
                await client.close(reason: "stopped")
                return
            }

            gateway = client
            failedDials = 0
            failingSince = nil
            attempt = 0
            publish(.phase(.ready(isReconnect: everConnected)))
            everConnected = true

            // Pump this socket generation's events into the stable stream;
            // the event stream finishing is the disconnect signal.
            let events = await client.events()
            if let supervisorCheckpoint { await supervisorCheckpoint(.eventsSubscribed) }
            for await event in events {
                if let supervisorCheckpoint { await supervisorCheckpoint(.eventReceived) }
                if !ownsSupervisor(lifetime) { break }
                publish(.event(event))
            }
            if let supervisorCheckpoint { await supervisorCheckpoint(.eventsEnded) }
            // stop() makes a new lifetime possible before this task exits.
            // Retired cleanup owns only its local client, never the shared
            // gateway or the replacement supervisor's phase/task handle.
            guard ownsSupervisor(lifetime) else {
                await client.close(reason: "stopped")
                return
            }
            gateway = nil

            let cause = await client.closeCause
            if let supervisorCheckpoint { await supervisorCheckpoint(.closeCauseRead) }
            guard ownsSupervisor(lifetime) else { return }
            if cause == .unauthorized {
                // The server rejected these credentials mid-flight (WS close
                // 4401) — in token mode that is what a backend restart looks
                // like, since the token rotates with it. Redialing can only
                // be refused the same way, so stop and let the app ask for
                // fresh credentials instead of spinning "Reconnecting…"
                // forever against a dead token.
                publish(.phase(.authExpired))
                supervisor = nil
                return
            }
            if cause == .forbidden {
                // Mid-flight 4403: the server withdrew this client's access.
                // Terminal, and never an auth prompt — same reasoning as the
                // dial-time branch above.
                let reason = await closeReason(of: client)
                guard ownsSupervisor(lifetime) else { return }
                publish(.phase(.refused(reason: reason)))
                supervisor = nil
                return
            }
            let reason = await closeReason(of: client)
            guard ownsSupervisor(lifetime) else { return }
            if giveUp(failingSince: &failingSince, failedDials: failedDials, reason: reason) { return }
            publish(.phase(.disconnected(reason: reason)))
            attempt += 1
            await backoff(attempt: attempt, lifetime: lifetime)
        }
    }

    private func giveUp(failingSince: inout TimeInterval?, failedDials: Int, reason: String?) -> Bool {
        let terminalReason: String?
        switch reconnectPolicy.stopRule {
        case .failureWindow(let duration):
            let start = failingSince ?? now()
            failingSince = start
            guard now() - start >= duration else { return false }
            terminalReason = reason
        case .failedHandshakeLimit(let limit):
            guard failedDials >= max(1, limit) else { return false }
            terminalReason = "Server unreachable after \(limit) failed connection attempts. "
                + "Check your network and server, then retry. " + (reason ?? "")
        }
        publish(.phase(.unreachable(reason: terminalReason)))
        supervisor = nil
        return true
    }

    private func closeReason(of client: any GatewayDialing) async -> String? {
        let state = await client.state
        if let supervisorCheckpoint { await supervisorCheckpoint(.closeReasonRead) }
        if case .closed(let reason) = state { return reason }
        return nil
    }

    /// Full-jitter exponential backoff:
    /// `delay = random() * min(15s, 300ms * 2^attempt)`, skippable via
    /// `pokeReconnect()`.
    private func backoff(attempt: Int, lifetime: UUID) async {
        guard ownsSupervisor(lifetime) else { return }
        let cap = min(15.0, 0.3 * pow(2.0, Double(attempt)))
        let delay = backoffDelay ?? Double.random(in: 0...cap)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            reconnectPoke = cont
            // The timer must die with the wait it belongs to: a stale timer
            // surviving a pokeReconnect() would resume the NEXT backoff's
            // continuation early and collapse the exponential delay.
            backoffTimer = Task {
                await sleeper(delay)
                guard ownsSupervisor(lifetime) else { return }
                self.finishBackoff()
            }
        }
    }

    private func finishBackoff() {
        backoffTimer = nil
        reconnectPoke?.resume()
        reconnectPoke = nil
    }
}
