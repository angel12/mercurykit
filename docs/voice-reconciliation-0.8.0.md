# Mercury Voice → MercuryKit reconciliation for 0.8.0

Voice range: `b403c5e..b0be0c1` (angel12/mercury-voice), paths
`Packages/MercuryVoiceCore/Sources/HermesKit`. Previous reconciliation:
`b403c5e` (PR #126, contract 7).

| Voice commit | Subject | Disposition | Kit task |
|---|---|---|---|
| `b0be0c1` | session-authority wire | ported, opt-in (`adoptsSessionAuthority`) | Task 6 |
| `20251d1` | transcribe-stream | ported (`transcribeStreamURL`, `sttStreaming`) | Task 2 |
| `c3b8548` | `voice_turn` on `prompt.submit` | ported, opt-in (`voiceTurn:`) | Task 4 |
| `3738964` | xAI direct STT format/model | ported (`VoiceClientConfig`) | Task 2 |
| `de63cfa` | replay-eviction comments | ported | Task 3 |
| `7373728` | decline window-owned bridges (4404) | ported, adapted to `routeServerRequest` | Task 5 |
| `7febc95` | `approval.cancelled` | ported | Task 3 |
| `b6c39ef` | agent failure copy | ported (`AgentErrorCopy`, 5032) | Task 3 |
| `73f4378` | stt-lease | ported (`sttLease(name:active:profile:)`) | Task 2 |
| `00d65f8` | clarify `null` answer | ported | Task 3 |
| `ff6399a` | `cwd_explicit` | already in kit 0.4.1 | — |
| `e0e135c` | direct STT error/filler filter | ported (`STTHallucinationFilter`) | Task 2 |
| `a26f897` | size-scaled audio timeouts | ported | Task 2 |
| `30b5521` | NativeOAuth / budget test races | skipped: files not in kit | — |
| `601ec8b` | merge (#133) | kit half = `2b34053`; engine half in `MercuryVoiceEngine` | Task 3, 7 |
| `2b34053` | REST object `detail.message` | ported | Task 3 |
| `a39dffd` | `UnanswerableRequest` | deferred to Mercury Chat Voice tab (sub-project 2) | — |
| `859cdc1` | log undecodable approval/clarify | skipped, divergent: kit refuses with -32602 by design | — |
| `9742704` | pre-ready deaths count against dial budget | superseded by union supervisor; pinned by a test | Task 6 |
