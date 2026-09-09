# Contributing

Keep changes protocol-only and preserve both consumers through explicit policies. Add regression tests before changing behavior. Run `swift test` and `actionlint .github/workflows/*.yml`; report actual results and untested platform/live-server gates separately.

Never add credentials, log tokens or unredacted server bodies, or make Voice configuration keys persistable. Use fake Keychain operations in tests. Do not introduce `pull_request_target` workflows that execute contributor code or self-hosted runners for untrusted pull requests.

App adoption requires separate consumer PRs, pinned dependency retrieval from a clean checkout, and full consumer/build/live verification. Do not treat a package-only pass as proof of app compatibility.
