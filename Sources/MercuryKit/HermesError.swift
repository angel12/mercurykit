import Foundation

public enum HermesError: Error, LocalizedError, Sendable {
    case notConnected
    case unauthorized
    case invalidCredentials
    case sessionExpired
    case httpError(status: Int, detail: String?)
    case rpcError(code: Int, message: String, data: JSONValue? = nil)
    case malformedResponse(String)
    case connectionClosed(String?)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to the Hermes server."
        case .unauthorized:
            return "The session token was rejected. Paste a fresh dashboard URL — the token changes every time the backend restarts."
        case .invalidCredentials:
            return "Invalid username or password."
        case .sessionExpired:
            return "Your session has expired. Sign in again."
        case .httpError(let status, let detail):
            return "Server error \(status)\(detail.map { ": \($0)" } ?? "")"
        case .rpcError(let code, let message, _):
            // Refusal reasons are the machine contract (the prose is server
            // wording that will change); map the known ones to copy that is
            // safe to speak aloud — no pids, paths, or session ids.
            if let reason = rpcReason {
                switch reason {
                case RefusalReason.sessionNotOwned:
                    return
                        "Another app is running this session. Close it there or wait for it to finish, then try again."
                case RefusalReason.maxConcurrentSessions:
                    return "The server is at its session limit. Try again in a moment."
                case RefusalReason.coordinationUnavailable:
                    return
                        "The server can't verify who owns this session. Its active-session registry needs repair — check the backend."
                default:
                    break
                }
            }
            if code == RPCCode.sessionStorageUnavailable {
                return
                    "The server couldn't save your message — its session storage needs repair."
            }
            if code == RPCCode.unknownParameter {
                return "This app and the Hermes server are out of sync. Update both, then try again."
            }
            if code == RPCCode.profileUnavailable {
                return "That profile isn't available on this server."
            }
            if code == RPCCode.backendRetiring {
                return "The Hermes server is restarting. Try again in a moment."
            }
            return "Hermes error \(code): \(message)"
        case .malformedResponse(let why):
            return "Unexpected response from server: \(why)"
        case .connectionClosed(let reason):
            return "Connection closed\(reason.map { ": \($0)" } ?? "")."
        case .timeout(let what):
            return "Timed out waiting for \(what)."
        }
    }

    /// Gateway error codes with defined meanings (tui_gateway).
    public enum RPCCode {
        /// A param key the backend's contract does not declare (upstream
        /// validates every method's params with `extra="forbid"` since
        /// 2026-09-14): the client and backend are out of sync.
        public static let unknownParameter = 4000
        public static let sessionIDRequired = 4006
        /// Also "session no longer live; retry resume" from a reattaching
        /// RPC (see `isSessionNotLive`).
        public static let sessionNotFound = 4007
        /// Also "session disconnect interrupt settling" (see
        /// `isInterruptSettling`).
        public static let sessionBusy = 4009
        /// A `profile` param named a missing or invalid profile.
        public static let profileUnavailable = 4064
        /// The backend is retiring (cooperative restart); any RPC may get
        /// this. Retry once the connection is ready again.
        public static let backendRetiring = 5035
        public static let methodNotFound = -32601
        /// prompt.submit refused: no active-session slot. Carries
        /// `data.reason` (see RefusalReason) on backends ≥ 2026-08-31.
        public static let sessionSlotRefused = 4090
        /// prompt.submit failed: state.db could not be opened; the message
        /// was NOT saved.
        public static let sessionStorageUnavailable = 5072
    }

    /// Machine-readable `error.data.reason` values attached to 4090 refusals
    /// (hermes_cli/active_sessions.py). Open set — unknown reasons fall back
    /// to the generic description.
    public enum RefusalReason {
        public static let sessionNotOwned = "SESSION_NOT_OWNED"
        public static let maxConcurrentSessions = "MAX_CONCURRENT_SESSIONS"
        public static let coordinationUnavailable = "SESSION_COORDINATION_UNAVAILABLE"
    }

    /// The `data.reason` of an `.rpcError`, when the server attached one.
    public var rpcReason: String? {
        guard case .rpcError(_, _, let data) = self else { return nil }
        return data?["reason"]?.stringValue
    }

    /// 4000: the request carried a param key this backend does not declare.
    public var isUnknownParameter: Bool { rpcCode == RPCCode.unknownParameter }

    /// 4007 from a reattaching RPC: the live session was replaced under us
    /// ("session no longer live; retry resume"). On `prompt.submit` it is a
    /// refusal issued before the prompt is accepted, so re-resume and
    /// resubmit. Matches any 4007 (resume's "session not found" too);
    /// callers scope it to the RPC whose 4007s are all pre-acceptance.
    public var isSessionNotLive: Bool { rpcCode == RPCCode.sessionNotFound }

    /// 4009 from a reattaching RPC: a client-gone interrupt is still
    /// settling. The same code carries `prompt.submit`'s other
    /// pre-acceptance busy refusals, so a short wait and one resubmit is
    /// safe for all of them.
    public var isInterruptSettling: Bool { rpcCode == RPCCode.sessionBusy }

    /// 4064: the `profile` param named a profile this server cannot open.
    public var isProfileUnavailable: Bool { rpcCode == RPCCode.profileUnavailable }

    /// 5035: the backend is retiring. The transport deliberately does not
    /// redial on it. The code is also returned during a 30 s prepare window
    /// that can roll back, and dropping the socket would interrupt any turn
    /// it carries. A committed retirement ends in the process exiting, which
    /// closes the socket and reconnects the ordinary way. Retry the call
    /// once the connection is ready again.
    public var isBackendRetiring: Bool { rpcCode == RPCCode.backendRetiring }

    private var rpcCode: Int? {
        guard case .rpcError(let code, _, _) = self else { return nil }
        return code
    }
}
