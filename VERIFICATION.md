# Standalone MercuryKit verification

Unpublished candidate. No consumer migration or release is claimed.

## Contract 7/8 parity branch (`feat/contract-7-parity`)

Run on 2026-09-22, macOS 26 (arm64), Swift 6.3.3 / Xcode 17F113. References: Chat `44abd62b`, Voice `b403c5e`, upstream hermes-agent `main` at `d3b25b52ad` (desktop contract 8; `git ls-remote` confirmed nothing newer).

### Verified

- `swift test`: **401 tests / 56 suites passed** (baseline before the branch: 308 / 50). The full run takes about 1.2 s. No loopback test waits out the 5 s capabilities timeout, because the helper auto-answers by default.
- `swift build` and `swift build --build-tests`: no warnings.
- `python3 scripts/check-api-constraints.py`: passed. `Fixtures/ExternalConsumer.swift` now calls the contract-7 API without `@testable`, and VoiceClientConfig still rejects Encodable and Decodable.
- Generic iOS Simulator and generic visionOS Simulator `xcodebuild` package builds, unsigned: both succeeded. These are builds, not simulator execution.
- Mutation checks, run by hand and then reverted:
  - Resetting the reconnect counters before the handshake (the mercury-voice #126 ordering) fails both give-up-rule cases of `handshakeDropsCountTowardTheGiveUpRule`.
  - Broadcasting capabilities replies from the loopback helper fails `aHeldReplyReachesOnlyTheSocketThatAsked`.
- Param-key audit: every params object MercuryKit sends, at its maximal key set, validated with `tui_gateway.contracts.registry.validate_params` on `upstream/main` and on `70f5dc5f46^` (the last contract-7 tree). All keys are declared on both, and the server-request result shapes (`{choice, all?}`, `{answer}`, `{answers}`, `{}`, `{value}`) validate. The only difference is `connection.respond`: each tree accepts only its own shape (`owner` on 8, `session_id` on 7), and the kit picks the shape by `desktopContract`. The removed methods (`clarify.respond`, `sudo.respond`, `secret.respond`, `mcp.setup.respond`) have no contract, so they answer -32601.
- Chat compatibility, in a throwaway clone of Chat `44abd62b` with its `Sources/MercuryKit` replaced by this branch:
  - `swift build --target ChatCore`: clean build, no errors or warnings.
  - Chat's ChatCoreTests: **95 tests / 6 suites passed**. Chat's own kit-test copy (`MercuryKitTests`) was excluded. It fails to compile with 12 errors, and the identical 12 errors occur with Chat `70633d3` against MercuryKit `main`, so they predate this branch.
  - App sources (`Mercury/*.swift`) typechecked on macOS with `swiftc -typecheck` against the built modules. The branch adds **no errors** and 7 deprecation warnings: `builtAgainstDesktopContract` twice in `AppModel.swift`, and `respondMcpSetup`, `respondClarify`, `respondClarifyQuestion`, `respondSudo` and `respondSecret` in `ChatController.swift`. Seven errors appear with and without the branch: five in `AppModel.swift` (injected Keychain `service:`, throwing Keychain calls, the three-element `rpcError`) and two in `ChatController.swift`. They are pre-existing adoption work. They were shimmed in the throwaway copy only, to reach the later files.

### Not run or pending

- `actionlint`: not installed on this machine, so it was not run. The branch does not change `.github/workflows/`.
- No live-backend, app-build, Chat or Voice cutover, or rollback verification. These belong to each app's adoption PR.
- Reviewer acceptance of this branch, publication and hosted CI.

## Earlier candidate

### Raoden execution

- Full `swift test`: **308 tests / 50 suites passed**, exit 0. Latest full-run log: `/Users/hermes/.hermes/profiles/raoden/cache/mercurykit-codex-green.log`.
- `python3 scripts/check-api-constraints.py`: passed. Builds the module; ordinary external consumer imports and calls HTTPErrorDetail.load/displayed; separate compilation attempts reject VoiceClientConfig Encodable and Decodable for the required conformance diagnostics. CI invokes the same script.
- `actionlint .github/workflows/mercurykit-tests.yml`: passed.
- Generic iOS Simulator Xcode package build: passed, unsigned. Log: `/Users/hermes/.hermes/profiles/raoden/cache/mercurykit-ios-build.log`.
- visionOS Simulator SDK typecheck: passed. Generic visionOS Xcode build remains blocked by the missing visionOS platform component. Typechecking is not simulator execution.

### Independent reviews

**Grok:** independently passed 306 tests / 49 suites on an earlier candidate. Found missing voiceConfig and event constants; both fixed, with VoiceAPICompletenessTests. His reviewed endpoint/replay/snapshot/session/model areas were source-complete. Follow-up acceptance of corrections and inventory is pending. Report: `/Users/hermes/Projects/mercurykit-review-grok.md`.

**Codex:** independent clean run passed **308 tests / 50 suites**, actionlint, iOS and visionOS SwiftPM SDK builds, selected ChatCore/VoiceEngine source typechecks, and external consumer fixture. No unresolved source-level security/lifecycle/selected-consumer compatibility defect at fingerprint `42ddb294ab4325fa81ee086a469a85780310d609988b84f12bcce90cc65ff44a`. Report: `/Users/hermes/Projects/mercurykit-review-codex.md`. Acceptance was conditional on documentation, inventory and negative compile checks. Those artifacts are now added/updated; refreshed acceptance remains pending. The workflow/fixture additions postdate that fingerprint; do not represent the older review as unconditional acceptance of the new candidate.

### Inventory and resolved findings

`docs/test-movement-inventory.md` maps every baseline kit test/helper file to a destination or explicit consumer-retention/replacement rationale. Selected Chat `70633d3af7630cff96589a17adbea1f196ffc487`; selected Voice `3792ac146e0299c17295f928661b7339bb625510`.

- voiceConfig GET method and profile-scoped request capture added.
- Voice resume-progress/reclaimed event constants and public symbol tests added.
- HTTPErrorDetail type/load/displayed made public; other helpers remain non-public. External consumer fixture reproduced failure before the fix and passed afterward.
- VoiceClientConfig remains non-Codable, now enforced by positive-import and intended negative compilation checks in CI.

### Remaining gates

- Refreshed reviewer acceptance of corrections/documentation/test inventory.
- Authorized publication and actual GitHub-hosted CI execution.
- Generic visionOS Xcode build when the platform component is available; SDK build/typecheck evidence is separate.
- All app cutover, app-build, live-server and rollback gates remain separate future work.
