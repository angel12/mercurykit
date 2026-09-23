# Baseline test movement inventory

This maps every Swift file in the selected kit test directories. “Moved” describes standalone inclusion, not deletion from a consumer: both consumer trees remain unchanged. Helper files are identified separately. Aggregate counts are not the preservation proof; this map accompanies Grok’s source/test comparison and Codex’s independent consumer typechecks.

## mercury

Baseline `70633d3af7630cff96589a17adbea1f196ffc487`; source directory `Packages/MercuryCore/Tests/MercuryKitTests/`. Destinations below are under `Tests/MercuryKitTests/`.

| Source file | Classification | Destination / rationale |
|---|---|---|
| `BotModeSupportTests.swift` | Moved/adapted | BotModeSupportTests.swift |
| `ContractProbeTests.swift` | Moved/adapted | ContractProbeTests.swift |
| `GatewayClientTests.swift` | Moved/adapted | GatewayClientTests.swift |
| `HermesAuthenticatorTests.swift` | Moved/adapted | HermesAuthenticatorTests.swift |
| `HermesConnectionTests.swift` | Moved/adapted | HermesConnectionTests.swift |
| `JSONValueTests.swift` | Moved/adapted | JSONValueTests.swift |
| `KeychainTokenStoreTests.swift` | Combined/replaced | KeychainTokenStoreTests.swift — injected Voice-style fakes replace five live-Keychain round-trip/write/delete tests; no production Keychain access |
| `LoopbackRedirectListenerTests.swift` | Moved/adapted | LoopbackRedirectListenerTests.swift |
| `ModelsTests.swift` | Moved/adapted | ModelsTests.swift |
| `RESTClientTests.swift` | Moved/adapted | RESTClientTests.swift |
| `ServerCredentialsTests.swift` | Moved/adapted | ServerCredentialsTests.swift |
| `ServerEndpointTests.swift` | Moved/adapted | ServerEndpointTests.swift |
| `SessionAPIAttachmentsTests.swift` | Moved/adapted | SessionAPIAttachmentsTests.swift |
| `TestServers.swift` | Moved test helper | TestServers.swift |
## mercury-voice

Baseline `3792ac146e0299c17295f928661b7339bb625510`; source directory `Packages/MercuryVoiceCore/Tests/HermesKitTests/`. Destinations below are under `Tests/MercuryKitTests/`.

| Source file | Classification | Destination / rationale |
|---|---|---|
| `ConnectFormStateTests.swift` | Retained in consumer | App-owned form behavior; relocate into Voice app tests during its later migration, not into MercuryKit |
| `ConnectionBudgetTests.swift` | Moved/adapted | TransportUnionConnectionBudgetTests.swift |
| `ConnectionRefusalTests.swift` | Moved/adapted | TransportUnionConnectionRefusalTests.swift |
| `ConnectionRestartTests.swift` | Moved/adapted | TransportUnionConnectionRestartTests.swift |
| `GatewayCloseTests.swift` | Moved/adapted | TransportUnionGatewayCloseTests.swift |
| `GatewayRefusalTests.swift` | Moved/adapted | TransportUnionGatewayRefusalTests.swift |
| `GatewayRequestCancellationTests.swift` | Moved/adapted | TransportUnionGatewayRequestCancellationTests.swift |
| `HTTPErrorDetailTests.swift` | Moved/adapted | HTTPErrorDetailTests.swift |
| `HTTPPolicyTests.swift` | Moved/adapted | HTTPPolicyTests.swift |
| `JSONValueEncodingTests.swift` | Moved/adapted | JSONValueEncodingTests.swift |
| `KeychainTokenStoreTests.swift` | Moved/adapted | KeychainTokenStoreTests.swift |
| `LiveSessionSnapshotTests.swift` | Moved/adapted | UnionLiveSessionSnapshotTests.swift |
| `LoopbackGatewayServer.swift` | Moved test helper | TransportUnionLoopbackGatewayServer.swift |
| `NativeOAuthTests.swift` | Moved/adapted | OAuthVoiceReconciliationTests.swift — full callback URL / split PKCE API; OAuthReconciliationTests.swift adds provider fallback |
| `PendingPromptDecodingTests.swift` | Moved/adapted | UnionPendingPromptDecodingTests.swift |
| `ProfileInfoDecodingTests.swift` | Moved/adapted | UnionProfileInfoDecodingTests.swift |
| `ProjectDecodingTests.swift` | Moved/adapted | UnionProjectDecodingTests.swift |
| `RESTRefusalTests.swift` | Moved/adapted | RESTRefusalTests.swift |
| `RPCErrorReasonTests.swift` | Moved/adapted | TransportUnionRPCErrorReasonTests.swift |
| `ReconnectVoiceDecodingTests.swift` | Moved/adapted | UnionReconnectVoiceDecodingTests.swift |
| `RoutedHTTPServer.swift` | Moved test helper | RoutedHTTPServer.swift |
| `ScriptedGatewaySocket.swift` | Moved test helper | TransportUnionScriptedGatewaySocket.swift |
| `ScriptedHTTPServer.swift` | Moved test helper | ScriptedHTTPServer.swift |
| `ServerCredentialsTests.swift` | Moved/adapted | VoiceServerCredentialsTests.swift |
| `ServerEndpointTests.swift` | Combined | EndpointPolicyTests.swift + ServerEndpointTests.swift + JSONValueTests.swift — explicit Voice scheme policy, Chat default retained; exact integer checks shared |
| `SessionUsageDecodingTests.swift` | Moved/adapted | UnionSessionUsageDecodingTests.swift |

## mercury-voice PR #126 (contract 7)

Merged at `b403c5e19dbfbefdc8109ad403864413571d9c32`; kit diff `3792ac1..b403c5e` under `Packages/MercuryVoiceCore/Tests/HermesKitTests/`. Destinations below are under `Tests/MercuryKitTests/`.

| Source file | Classification | Destination / rationale |
|---|---|---|
| `CapabilityAdvertisementTests.swift` (new) | Moved/adapted | TransportUnionCapabilityAdvertisementTests.swift — runs with an explicit `ServerRequestPolicy` (the kit default is off); adds the switch-off path, the default auto-answer and per-socket replies |
| `ServerRequestRoutingTests.swift` (new) | Moved/adapted | TransportUnionServerRequestRoutingTests.swift — per-app answerable set; adds Chat's sudo/secret routing, wire-order preservation, the disabled path, the opt-in `.refuse` option and refusal of malformed routed requests |
| `ServerRequestAnswerTests.swift` (new) | Replaced | ServerRequestAnswerTests.swift — Voice's `ServerRequestAnswer` enum is not ported: `answerServerRequest` returns `PromptResponseStatus`, and the "unknown status → answered" case is inverted to "throws". Exercised through `HermesConnection` over `LocalGatewayServer`; adds result builders, `clarify.lock` and `connection.respond` |
| `TTSLeaseTests.swift` (new) | Moved/adapted | TTSLeaseTests.swift — kit spelling `ttsLease(name:active:profile:)`; adds a two-argument call with a swallowed 500 |
| `LoopbackGatewayServer.swift` (+137) | Moved test helper, adapted | TransportUnionLoopbackGatewayServer.swift — client-frame parsing, auto-answered `client.capabilities`, opt-out and `answerCapabilities(asError:)`; replies go only to the socket that asked (Voice broadcasts) |
| `PendingPromptDecodingTests.swift` (+99) | Moved/adapted | UnionPendingPromptDecodingTests.swift — batch questions are `ClarifyRequest.Question`; decoding is stricter (required `request_id`, qid, question and field types); sudo/secret server-request cases added |
| `LiveSessionSnapshotTests.swift` (+42) | Moved/adapted | UnionLiveSessionSnapshotTests.swift — plus `null` refusal, the `pending_approval` duplicate case and `SessionHandle.openRequests` |
| `RPCErrorReasonTests.swift` (+29) | Moved/adapted | TransportUnionRPCErrorReasonTests.swift — plus 4000, 4064 and 5035 |
| `ReconnectVoiceDecodingTests.swift` (+111) | Moved | UnionReconnectVoiceDecodingTests.swift (suite `UnionVoiceClientConfigDecodingTests`), verbatim; plus fractional values and relay-verdict cases |
| `VoiceEngineTests/DirectSpeechCompositionTests.swift`, `VoiceEngineTests/DirectVoiceTests.swift` | Retained in consumer | Audio-engine use of `min_len`, `extra_body` and `timeout_s` stays in Voice's VoiceEngine |
| `MercuryVoiceTests/*` (R32–R34, TTS lease controller, conversation support) | Retained in consumer | Prompt presentation, dedupe, 4007/4009 resubmit and lease lifecycle are app behaviour |

Kit-only changes for the same work: `TransportUnionPolicyTests.swift` (the fake accepts `client.capabilities`; switch-off, advertisement, contract-6 refusal, handshake-drop give-up and 5035 cases), `TransportUnionConnectionRestartTests.swift` (every case also runs with the handshake on), `UnionSessionPolicyTests.swift` (redirect/steer statuses, desktop contract requirement), `ModelsTests.swift` (tool calls, project object), `VoiceAPICompletenessTests.swift` and `Fixtures/ExternalConsumer.swift` (contract-7 public API).

## mercury (Chat) after the baseline

`70633d3..44abd62` adds `ToolCallRef` / `TranscriptMessage.toolCalls` (issue #76). Its tests live in `ChatCoreTests/TranscriptStoreTests.swift` and stay in Chat; the kit decoding is covered by `ModelsTests.swift` (`TranscriptMessageTests`).

## mercury (Chat) Bot Mode

Merged at `f94bfafb9e6f90b8ff7fb12562a8216083433632` (PRs #78, #79); kit diff `44abd62..f94bfaf` under `Packages/MercuryCore/Tests/MercuryKitTests/`. No other kit test file changed in `70633d3..f94bfaf`. Destinations below are under `Tests/MercuryKitTests/`.

| Source file | Classification | Destination / rationale |
|---|---|---|
| `BotRosterTests.swift` (new) | Moved/adapted | BotRosterTests.swift — throwing `json(_:)` helper instead of `try!`; adds CronJob `id`/`prompt_preview`/name/epoch/offset/zero fallbacks, exact timestamps, the raw `ui_meta` namespace and CAS revision, malformed rows and the canonical-title constant. The two `isCompactCommand` tests (`compactCommandsAreIntercepted`, `everythingElsePassesThrough`) are retained in the consumer: they move to ChatCoreTests with the ChatCore extension |

Kit-only changes for the same work: `BotModeRPCTests.swift` (request capture for every Bot Mode call, the CAS revision present and absent, integer revisions on the wire, and fail-closed canonical lookup, and `CronManageError` on a cron tool `success: false`), `VoiceAPICompletenessTests.swift` (`cron.changed`) and `Fixtures/ExternalConsumer.swift` (Bot Mode public API and an external `BotChatPolicy` extension).

## Kit additions after Chat's migration

`ProfileCreateTests.swift` (new): `profiles.create` request capture, result decoding and errors, for mercurychat #27 Phase 3. It has no consumer counterpart: Chat never had this call.

## Additional reconciliation coverage

- `EndpointPolicyTests`: both consumer defaults and encoded URL behavior.
- `UnionSessionPolicyTests`: resume flags, activation, replay, project limits and exact prompt payloads.
- `TransportUnionPolicyTests` / `TransportUnionBoundaryTests`: explicit reconnect policy and transport bounds.
- `VoiceAPICompletenessTests`: Voice public event identifiers and voice-config request capture.
- `Fixtures/ExternalConsumer.swift`: normal external import / public bounded HTTP helper API.
- `scripts/check-api-constraints.py`: positive import check plus intended Encodable and Decodable compilation failures for VoiceClientConfig.

## Out of scope

ChatCoreTests, VoiceEngineTests and app bundles stay in their consumers. Their migration, full execution and live behavior gates are not claimed by this standalone inventory.
