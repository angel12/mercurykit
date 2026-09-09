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

## Additional reconciliation coverage

- `EndpointPolicyTests`: both consumer defaults and encoded URL behavior.
- `UnionSessionPolicyTests`: resume flags, activation, replay, project limits and exact prompt payloads.
- `TransportUnionPolicyTests` / `TransportUnionBoundaryTests`: explicit reconnect policy and transport bounds.
- `VoiceAPICompletenessTests`: Voice public event identifiers and voice-config request capture.
- `Fixtures/ExternalConsumer.swift`: normal external import / public bounded HTTP helper API.
- `scripts/check-api-constraints.py`: positive import check plus intended Encodable and Decodable compilation failures for VoiceClientConfig.

## Out of scope

ChatCoreTests, VoiceEngineTests and app bundles stay in their consumers. Their migration, full execution and live behavior gates are not claimed by this standalone inventory.
