# MercuryKit

Shared Swift protocol client for Mercury Chat and Mercury Voice, connecting to Hermes Agent.

**Status:** standalone reconciliation in progress. Neither consumer has migrated. This package is not yet released or verified for adoption.

## Platforms

Swift 6; iOS 17+, macOS 14+, visionOS 2+. Apple networking and Keychain APIs require an Apple SDK; Linux is not a supported build target. No third-party SDK dependencies.

## Local verification

```sh
swift test
```

The GitHub Actions workflow runs this suite on standard hosted macOS. Hosted execution remains pending publication.

## Boundaries

The package contains transport, authentication, credential storage mechanisms, wire models, session RPC and REST. App UI, audio engines, transcript reducers and network-path monitoring remain in consumers.

Endpoint inference is caller-owned: `ServerEndpoint.parse(_:)` defaults to `.httpsExceptLoopback`; Voice uses `.voiceLANDefaults` at schemeless input boundaries. Explicit schemes are authoritative. Keychain service identifiers are injected by each app, never shared by default.

The package and module are named `MercuryKit`; protocol-facing `Hermes*` type names intentionally remain unchanged.

## Source provenance

- Mercury Chat: `70633d3af7630cff96589a17adbea1f196ffc487`
- Mercury Voice: `3792ac146e0299c17295f928661b7339bb625510`

Consumer cutovers are separate changes after standalone verification. No migration exports or personal service credentials belong in this repository.
