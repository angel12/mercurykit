# Standalone MercuryKit verification

Uncommitted/unpublished candidate. No consumer migration or release is claimed.

## Raoden execution

- Full `swift test`: **308 tests / 50 suites passed**, exit 0. Latest full-run log: `/Users/hermes/.hermes/profiles/raoden/cache/mercurykit-codex-green.log`.
- `python3 scripts/check-api-constraints.py`: passed. Builds the module; ordinary external consumer imports and calls HTTPErrorDetail.load/displayed; separate compilation attempts reject VoiceClientConfig Encodable and Decodable for the required conformance diagnostics. CI invokes the same script.
- `actionlint .github/workflows/mercurykit-tests.yml`: passed.
- Generic iOS Simulator Xcode package build: passed, unsigned. Log: `/Users/hermes/.hermes/profiles/raoden/cache/mercurykit-ios-build.log`.
- visionOS Simulator SDK typecheck: passed. Generic visionOS Xcode build remains blocked by the missing visionOS platform component. Typechecking is not simulator execution.

## Independent reviews

**Grok:** independently passed 306 tests / 49 suites on an earlier candidate. Found missing voiceConfig and event constants; both fixed, with VoiceAPICompletenessTests. His reviewed endpoint/replay/snapshot/session/model areas were source-complete. Follow-up acceptance of corrections and inventory is pending. Report: `/Users/hermes/Projects/mercurykit-review-grok.md`.

**Codex:** independent clean run passed **308 tests / 50 suites**, actionlint, iOS and visionOS SwiftPM SDK builds, selected ChatCore/VoiceEngine source typechecks, and external consumer fixture. No unresolved source-level security/lifecycle/selected-consumer compatibility defect at fingerprint `42ddb294ab4325fa81ee086a469a85780310d609988b84f12bcce90cc65ff44a`. Report: `/Users/hermes/Projects/mercurykit-review-codex.md`. Acceptance was conditional on documentation, inventory and negative compile checks. Those artifacts are now added/updated; refreshed acceptance remains pending. The workflow/fixture additions postdate that fingerprint; do not represent the older review as unconditional acceptance of the new candidate.

## Inventory and resolved findings

`docs/test-movement-inventory.md` maps every baseline kit test/helper file to a destination or explicit consumer-retention/replacement rationale. Selected Chat `70633d3af7630cff96589a17adbea1f196ffc487`; selected Voice `3792ac146e0299c17295f928661b7339bb625510`.

- voiceConfig GET method and profile-scoped request capture added.
- Voice resume-progress/reclaimed event constants and public symbol tests added.
- HTTPErrorDetail type/load/displayed made public; other helpers remain non-public. External consumer fixture reproduced failure before the fix and passed afterward.
- VoiceClientConfig remains non-Codable, now enforced by positive-import and intended negative compilation checks in CI.

## Remaining gates

- Refreshed reviewer acceptance of corrections/documentation/test inventory.
- Authorized publication and actual GitHub-hosted CI execution.
- Generic visionOS Xcode build when the platform component is available; SDK build/typecheck evidence is separate.
- All app cutover, app-build, live-server and rollback gates remain separate future work.
