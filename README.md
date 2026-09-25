# MercuryKit

Shared Swift protocol client for Mercury Chat and Mercury Voice, connecting to Hermes Agent.

**Status:** latest release `0.4.0`, which reads hermes-agent's commentary projection on history rows (parity with upstream `59004a6235`). Mercury Chat uses `0.3.1` (adopted in angel12/mercurychat#81, with contract 7 in #82, bot creation in #85, the profile editor in #87 and the privacy manifest in #115) and has been checked live against a local backend; see angel12/mercurychat#27. Mercury Voice hasn't migrated yet.

## Platforms

Swift 6; iOS 17+, macOS 14+, visionOS 2+. Apple networking and Keychain APIs require an Apple SDK; Linux is not a supported build target. No third-party SDK dependencies.

## Local verification

```sh
swift test
```

The GitHub Actions workflow runs this suite and `scripts/check-api-constraints.py` on GitHub-hosted macOS (`macos-15`) for every pull request to `main` and every push to it. VERIFICATION.md records the runs.

## Boundaries

The package contains transport, authentication, credential storage mechanisms, wire models, session RPC and REST. App UI, audio engines, transcript reducers and network-path monitoring remain in consumers.

Endpoint inference is caller-owned: `ServerEndpoint.parse(_:)` defaults to `.httpsExceptLoopback`; Voice uses `.voiceLANDefaults` at schemeless input boundaries. Explicit schemes are authoritative. Keychain service identifiers are injected by each app, never shared by default.

The package and module are named `MercuryKit`; protocol-facing `Hermes*` type names intentionally remain unchanged.

Bot Mode (from Mercury Chat #78/#79) is in the kit as wire calls and decoders, plus the rules hermes-agent defines: the `"Bot Chat"` canonical title, the `hermes-bots` `ui_meta` key and the `[bot:<name>]` routine prefix. `BotChatPolicy.isCompactCommand` is not: turning `/new`, `/reset` and `/compact` into compression in the composer is a UI decision. Chat keeps it in ChatCore as `extension BotChatPolicy { public static func isCompactCommand(_:) }`. `BotChatPolicy` stays a public enum so consumers can extend it.

The profile editor (mercurychat#27 Phase 3) adds three protocol-only calls: `describeProfile(name:)` (`profiles.describe`) returns the editor snapshot — soul, model pin, skills, toolsets and MCP servers; `configureProfile(name:changes:)` (`profiles.configure`) saves any subset of those sections independently via `ProfileChanges`, reporting `failedSections` and a pending `confirmationRequired` for a guarded model pick; and `modelInventory(profile:)` (`model.options`, scoped to the profile) lists the models and providers that profile can pin. No UI strings or policy: which sections to show, and how to render a confirmation prompt, remain in consumers.

## Hermes desktop contract 7

Since contract 7, blocking prompts are JSON-RPC requests from the server (`ServerRequest`, ids `srq-<hex>`), and a socket must advertise `client.capabilities {server_requests: true}` or they are cancelled server-side. This is a per-app switch, `ServerRequestPolicy`, passed to `HermesConnection`. It defaults to `.disabled`, which behaves exactly like the contract-6 client: nothing is advertised and request frames are ignored.

- `.chat` answers approval, clarify, sudo and secret; `.voice` answers approval and clarify. Answerable requests arrive on the event stream as `GatewayEvent.Kind.serverRequest`, in wire order. They are answered with `answerServerRequest(id:result:)` and `ServerRequestResult`, and withdrawn by `request.cancel` (`ServerRequestCancel`). After a reconnect they are restored from `openRequests`, which takes priority over `pending_*`.
- A request the app can't answer (for example `vault.*`, `terminal.read` or `tour`, or `sudo` for Voice) is left for another attached client by default. `.refuse` is an opt-in; see below.
- An answerable request that can't be decoded is always refused with `-32602`, whatever the unanswerable setting, so the agent never waits on a card nobody will show.
- Each app states the backend contract it needs with `DesktopContractRequirement`. `GatewayClient.builtAgainstDesktopContract` stays at 6 and is deprecated.
- Retry orchestration for 4007 and 4009 (resubmit after reconnect) stays in the apps. `HermesError` only classifies the codes.

### Unanswerable requests: `.leaveForOtherClients` or `.refuse`

The backend sends every request frame to all clients attached to the session, and the first response settles it for all of them, even an error response. So the choice for methods the app doesn't answer is a trade-off:

| `unanswerable` | Another client (e.g. the desktop) is attached | The app is the only client |
|---|---|---|
| `.leaveForOtherClients` (default) | That client answers it normally. | The agent blocks until the server-side deadline (300 s for most prompts), then continues as if skipped. |
| `.refuse` | The prompt is taken away from that client before the user can answer it there. | The agent continues at once as if skipped. |

With `.refuse`, the kit replies on the same socket with JSON-RPC error `-32601` and the message `"<method> is not handled by this client"`. The message names the method, never the app. Choose it only when the app knows it is the sole client of its sessions:

```swift
let policy = ServerRequestPolicy(
    answerableMethods: ServerRequestPolicy.voice.answerableMethods,
    unanswerable: .refuse)
let connection = HermesConnection(
    endpoint: endpoint, authenticator: authenticator,
    reconnectPolicy: .voice, serverRequestPolicy: policy)
```

"As if skipped" means a one-string prompt (`vault.*`, GUI reads, `tour`, `sudo`, `secret`) resolves to an empty value, a clarify to an empty answer, and an approval is withdrawn (its command is cancelled, not denied).

The setting has no effect when the policy is `.disabled` (nothing is ever refused), on malformed answerable requests (always refused), or on `open_requests` replayed after a reconnect (the app decides).

## Source provenance

- Mercury Chat: `f94bfafb9e6f90b8ff7fb12562a8216083433632` (angel12/mercurychat `main`; adds Bot Mode Phase 1 and 2 from PRs #78 and #79 over `44abd62bfe93c26e07c1d7e7ef2b9e1a6fd6865d`, which added `ToolCallRef` from issue #76 over the original `70633d3af7630cff96589a17adbea1f196ffc487` reconciliation)
- Mercury Voice: `b403c5e19dbfbefdc8109ad403864413571d9c32` (angel12/mercury-voice `main`, PR #126 contract 7, over the original `3792ac146e0299c17295f928661b7339bb625510` reconciliation)
- hermes-agent: checked against upstream `main` at `59004a6235` (desktop contract 8): the only changes to contracts the kit uses since `67f7e1d6b3` are additive, and the kit reads the new commentary projection on history rows. Bot Mode parity was checked at `9fe737aef2` and the contract-7/8 parity work at `d3b25b52ad`.

Consumer cutovers are separate changes after standalone verification. No migration exports or personal service credentials belong in this repository.
