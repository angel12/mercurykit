# Standalone MercuryKit verification

Released as `0.1.0` (`58d303f`). Mercury Chat uses it (angel12/mercurychat#81 and #82), and its app-level and live checks are recorded there and in angel12/mercurychat#27. Mercury Voice hasn't migrated. `0.2.0` and `0.3.0` are not yet released; the sections below record standalone verification of branches ahead of `0.1.0`, pending each one's own tag.

## Profile editor branch (`feat/profile-editor`)

Run on 2026-09-23, macOS 26.7 (arm64), Swift 6.3.3 / Xcode 26.6 (17F113). Upstream hermes-agent audited at `520fead094`, then extended the same day to `upstream/main` head `67f7e1d6b3` (fetched fresh; `git log --oneline 520fead094..67f7e1d6b3` is a single `fmt(js)` commit), both read from exported trees (`git archive`), never a checkout.

### Verified

- `swift test`, from a clean `.build`: **466 tests / 64 suites passed**. This task adds no code or tests; A1–A3 already brought the suite here (453 / 63 on the prior `feat/profiles-create` baseline).
- `swift build` and `swift build --build-tests`, from a clean `.build`: no warnings.
- `python3 scripts/check-api-constraints.py`: passed.
- `actionlint .github/workflows/*.yml`: passed with no findings.
- Generic iOS Simulator and generic visionOS Simulator `xcodebuild` package builds, unsigned: both succeeded.
- Param-key audit: `profiles.describe {name}`; `profiles.configure` with `{name, soul}`, the maximal shape (`name`, `soul`, `description`, `model`, `provider`, `confirm_expensive_model`, `disabled_skills`, `enabled_toolsets`, `enabled_mcp_servers`), `{name, enabled_mcp_servers: []}` and `{name, soul, disabled_skills: []}`; and `model.options {profile}` all pass `tui_gateway.contracts.registry.validate_params` at `520fead094` **and again at `67f7e1d6b3`**, unchanged.
- Result-shape audit: the test fixtures `described`, `appliedAll`, the confirm reply (`aGuardedModelAsksForConfirmation`) and the `{"ok": false, ...}` reply (`aFailedSectionIsReported`) validate against `ProfilesDescribeResult` / `ProfilesConfigureResult`. `inventory`, with its one deliberately invalid provider row (`{"name": "no slug, skipped"}`) removed, validates against `ModelOptionsResult`. That row exists in the test fixture to prove the kit skips provider rows without a `slug`, by design: `ModelOptionsResult.providers[].slug` is required by the contract (confirmed by re-validating the fixture with the row left in, which fails with `providers.2.slug: Field required`), so a row without one is not a valid provider and the kit is right to drop it rather than surface it. Re-run at `67f7e1d6b3` with identical results.
- Upstream drift `16fe260aab..520fead094` (8 commits, all `fix(desktop)`/`fix(agent)`) **and extended to `16fe260aab..67f7e1d6b3`** (9 commits total, the 9th being a `fmt(js)` merge-formatting commit; none touch `tui_gateway/contracts`): the JSON schemas of all 62 contracts the kit uses (every method, event and server request named in `Sources/`, now including `profiles.describe` and `model.options` added by A1–A3) are unchanged at both `520fead094` and at head `67f7e1d6b3`. `METHODS`/`EVENTS`/`SERVER_REQUESTS` totals are identical (235 / 73 / 13) at `16fe260aab`, `520fead094` and `67f7e1d6b3`, and no method, event or server request was added or removed upstream across the whole range, so there is nothing new the kit doesn't use to report.
- A2 mutation check (from the A2 report, `.superpowers/sdd/2026-09-23-bot-advanced-editor/task-A2-report.md`): dropping empty-array handling in `ProfileChanges.params(name:)` fails `anEmptyListIsSent` and `everySectionMapsToItsDeclaredKey`; returning an empty `failedSections` fails `aFailedSectionIsReported`. Both mutations were reverted and the suite re-passed.

### Not run or pending

- No live-backend call (left to Chat's advanced-editor PR).
- Hosted CI, review, and the `0.3.0` tag.

## Profile creation branch (`feat/profiles-create`)

Run on 2026-09-23, macOS 26.7 (arm64), Swift 6.3.3 / Xcode 26.6 (17F113). Upstream hermes-agent `main` at `16fe260aab`, read from an exported tree (`git archive`), never a checkout.

### Verified

- `swift test`: **453 tests / 63 suites passed** (445 / 62 before the branch).
- `swift build` and `swift build --build-tests`, from a clean `.build`: no warnings.
- `python3 scripts/check-api-constraints.py`: passed. `Fixtures/ExternalConsumer.swift` calls `createProfile`, `ProfileCreateOptions`, `CreatedProfile` and the new error codes without `@testable`.
- `actionlint .github/workflows/*.yml`: passed with no findings.
- Generic iOS Simulator and generic visionOS Simulator `xcodebuild` package builds, unsigned: both succeeded with no warnings.
- Mutation check, by hand and then reverted: dropping explicit `false` options fails `anExplicitFalseIsSent` and `everyOptionMapsToItsDeclaredKey`.
- Param-key audit: `profiles.create {name}`, `{name, mirror_credentials: false}` and the maximal set (`name`, `description`, `clone_from`, `clone_all`, `clone_channels`, `no_skills`, `no_alias`, `soul`, `model`, `provider`, `share_auth`, `mirror_credentials`) all pass `validate_params`. Results with `mirrored.auth` `true`, `false` and `"shared"` validate against `ProfilesCreateResult`, and the contract rejects any other `auth`, as the decoder does.
- Error codes, from `tui_gateway/methods_profiles.py`: 4061 name required, 4062 invalid or taken name or missing `clone_from` (the message says which), 5062 anything else.
- Upstream drift `9fe737aef2..16fe260aab` (661 commits): the JSON schemas of all 62 contracts the kit uses (every method, event and server request named in `Sources/`, plus `profiles.create`) are unchanged. Upstream added a `display.*` method family and a `display.install.sudo` server request, which the kit doesn't use; it leaves that request for other clients.

### Not run or pending

- No live-backend call of `profiles.create`. It creates a real profile, so it's left to Chat's create-bot PR.
- Hosted CI for this branch, reviewer acceptance and the `0.2.0` tag.

## Bot Mode parity branch (`feat/bot-mode-parity`)

Run on 2026-09-22, macOS 26.7 (arm64), Swift 6.3.3 / Xcode 26.6 (17F113). References: Chat `f94bfaf` (Bot Mode PRs #78, #79 over `44abd62`), upstream hermes-agent `main` at `9fe737aef2`, read from an exported tree (`git archive`), never a checkout.

### Verified

- `swift test`: **445 tests / 62 suites passed** (401 / 56 before the branch).
- `swift build` and `swift build --build-tests`, from a clean `.build`: no warnings.
- `python3 scripts/check-api-constraints.py`: passed. `Fixtures/ExternalConsumer.swift` calls every Bot Mode type, property and method without `@testable`, and extends `BotChatPolicy` from outside the module. Making `metaWriteOutcome` internal fails the check (run by hand, then reverted).
- `actionlint .github/workflows/*.yml`: passed with no findings. The branch does not change the workflows.
- Generic iOS Simulator and generic visionOS Simulator `xcodebuild` package builds, unsigned: both succeeded with no warnings. These are builds, not simulator execution.
- Hosted CI on GitHub's `macos-15-arm64` image (release `20260907.0337`) with Xcode 16.4 / Swift 6.1.2, an older toolchain than the local run: **445 tests passed** with no compiler warnings, and `check-api-constraints.py` passed. That was on the pull request (run `35815107162`, `ff33536`) and on `main` after the merge (run `35815259895`, `58d303f`).
- Published: merged as angel12/mercurykit#2 (`58d303f`) and tagged `0.1.0`.
- Mutation check, run by hand and then reverted: making `findCanonicalBotChat` swallow request errors into `nil` fails all three fail-closed cases in `BotModeRPCTests`.
- Cron tool failures: `cron.manage` passes the cron tool's JSON through, so a failure such as an unknown job id arrives as a successful RPC result with `success: false` and `error` (`tool_error` in `tools/cronjob_tools.py`). `listCronJobs`, `setCronJobEnabled` and `removeCronJob` throw `CronManageError` on an explicit `success: false`; a result without `success` (optional in `CronManageResult`) is not a failure. This is a deliberate change from Chat's embedded kit, which returned normally. Before the check was wired in, all four `toolLevelFailureThrows` cases failed. Chat's three call sites already catch and show `errorDescription`, so the app needs no change.
- `CronJob.displayName` strips the `[bot:<name>]` tag case-insensitively, matching `belongsToBot` and the desktop's `BOT_TAG_RE` (`/i`). Chat's embedded kit only stripped a lowercase `[bot:`, so `[Bot:x] y` belonged to bot x but displayed with its tag.
- Upstream rules, confirmed at `9fe737aef2` and cited in doc comments:
  - `"Bot Chat"` is `BOT_CHAT_TITLE` in `tools/bot_mode_probe.py`, used by `agent/system_prompt.py`, `agent/turn_context.py`, `cron/scheduler_delivery.py` and `session.list`'s title lookup.
  - `hermes-bots` is the `ui_meta` key read by `tools/bot_mode_probe.py` and `hermes_cli/profiles.py` and written by the desktop plugin (`apps/desktop/src/plugins/hermes-bots/data.ts`).
  - `[bot:<name>]` is `BOT_TAG_RE` in `apps/desktop/src/plugins/hermes-bots/cron.tsx`, documented in `website/docs/user-guide/bot-mode.md` and in the `cron.manage` handler.
- Param-key audit: every params object the Bot Mode calls send, at its maximal key set, passes `tui_gateway.contracts.registry.validate_params` on `9fe737aef2`:
  - `profiles.list {include_sessions}`
  - `session.list {profile, title, include_hidden, limit}`
  - `session.compress {session_id}`
  - `profiles.get_asset {name, asset}`
  - `profiles.set_asset {name, asset, data}` and `{name, asset, clear}`
  - `profiles.configure {name, ui_meta, ui_meta_expected_revisions}`, with and without the revisions
  - `cron.manage {action, include_disabled, profile}` and `{action, name, profile}` for pause, resume and remove

  The tests pin that the CAS revision is sent as a JSON integer, which upstream requires (`isinstance(wanted, int)`).
- Result-shape audit: these validate against the result models:
  - `profiles.list` rows with `ui_meta`, `ui_meta_revisions`, `last_session`, `canonical_session` and `worker_session`, and a bare row;
  - `profiles.configure` applied and CAS-conflict results;
  - `profiles.get_asset` found and absent;
  - `profiles.set_asset` stored and cleared;
  - `session.compress` compressed and pending;
  - `session.list` title-lookup and empty results;
  - `cron.manage` list, pause/resume and tool-failure results.

  `cron.changed` is a declared event. Fields the decoders read that upstream does not declare:
  - `session.list` rows (`SessionListRow`, closed) have no `root_title` or `last_active`. `findCanonicalBotChat` therefore matches on `title`, which on the title lookup is the root row's title, and its stub's `lastActive` is always nil.
  - `CronJobRow` (open) declares `job_id`, `prompt_preview` and ISO string timestamps. The `id`, `prompt` and epoch-second fallbacks are for older stores.
- Upstream drift `d3b25b52ad..9fe737aef2` (10 commits): no change to `tui_gateway/contracts`, `server_requests.py` or events.
  - The `gateway.standalone` topology work keeps standalone profiles servable for profile-scoped calls (`launch_profile_policy.py`).
  - Connection operations gained the `plugin` and `skill` kinds (`tools/connectors/contract.py`). `ConnectionRequest.kind` is a `String`, so they decode.
  - No kit change was needed.
- Test drift: in `70633d3..f94bfaf` only `BotRosterTests.swift` changed under Chat's `MercuryKitTests`. Every other Chat kit test name exists in MercuryKit except the five live-Keychain tests the inventory already records as replaced.
- Chat compatibility, in a throwaway clone of Chat `f94bfaf` with `Sources/MercuryKit` replaced by this branch and `extension BotChatPolicy { public static func isCompactCommand(_:) }` (Chat's code, verbatim) added to ChatCore:
  - `swift build --target ChatCore`, from clean: no errors or warnings.
  - ChatCoreTests: **95 tests / 6 suites passed**. With Chat's two `isCompactCommand` tests moved into ChatCoreTests: 97 / 7 passed. Chat's own kit-test copy was excluded. It has the 12 known errors plus 9 from its `isCompactCommand` cases, which move to ChatCore.
  - App sources (`Mercury/**/*.swift`, including `BotViews.swift`, `BotEditViews.swift`, `SidebarView.swift`, `AppModel.swift` and `ChatController.swift`) typechecked on macOS with `swiftc -typecheck` against the built modules. The branch adds **no errors and no warnings**. The final diagnostics are identical to Chat `44abd62` typechecked against MercuryKit `main` with the same shims.
  - Known errors, pre-existing adoption work, shimmed in the throwaway copies only:
    - the seven recorded below: five in `AppModel.swift` and two `rpcError` patterns in `ChatController.swift`;
    - an **eighth not previously recorded**: `StatusViews.swift` switches over `ConnectionPhase` without `.refused(reason:)`. It reproduces with Chat `44abd62` + MercuryKit `main`. The earlier check stopped before reaching that file.
  - Known warnings: eight deprecations. They are the seven recorded below, plus `builtAgainstDesktopContract` in `StatusViews.swift`, which went unrecorded for the same reason.

### Not run or pending

- No live-backend, app-build, Chat or Voice cutover, or rollback verification. The Chat migration is planned separately.
- App typecheck on iOS or visionOS SDKs (macOS only, as before).
- Independent review. The branch was merged by the maintainer.

## Contract 7/8 parity branch (`feat/contract-7-parity`)

Run on 2026-09-22, macOS 26 (arm64), Swift 6.3.3 / Xcode 17F113. References: Chat `44abd62b`, Voice `b403c5e`, upstream hermes-agent `main` at `d3b25b52ad` (desktop contract 8; `git ls-remote` confirmed nothing newer).

### Verified

- `swift test`: **401 tests / 56 suites passed** (baseline before the branch: 308 / 50). The full run takes about 1.2 s. No loopback test waits out the 5 s capabilities timeout, because the helper auto-answers by default.
- `swift build` and `swift build --build-tests`: no warnings.
- `python3 scripts/check-api-constraints.py`: passed. `Fixtures/ExternalConsumer.swift` now calls the contract-7 API without `@testable`, and VoiceClientConfig still rejects Encodable and Decodable.
- `actionlint .github/workflows/*.yml`: passed with no findings (run by the maintainer on this machine). The branch does not change the workflows.
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

- No live-backend, app-build, Chat or Voice cutover, or rollback verification. These belong to each app's adoption PR.
- Independent review. The branch was merged by the maintainer.

Since done: published as angel12/mercurykit#1 (`0f16659`). Hosted CI on `macos-15-arm64` with Xcode 16.4 / Swift 6.1.2 passed 401 tests on the pull request (run `35808872117`) and on `main` (run `35808960773`).

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
- ~~Authorized publication and actual GitHub-hosted CI execution.~~ Done: hosted CI on `macos-15-arm64` with Xcode 16.4 / Swift 6.1.2 passed 308 tests on `main` at `c32e682` (run `34304222649`, 2026-09-09).
- Generic visionOS Xcode build when the platform component is available; SDK build/typecheck evidence is separate.
- All app cutover, app-build, live-server and rollback gates remain separate future work.
