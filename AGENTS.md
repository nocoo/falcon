# Falcon

Falcon is a native macOS Jev proxy and seven-day decision observability app with a working local implementation.
Human overview: [README.md](README.md). Design index: [docs/README.md](docs/README.md).

## Scope and current state

- This file applies throughout the repository. There are no nested instruction files.
- The owner authorized implementation on main, atomic commits, and appropriate Herdr delegation on 2026-09-25.
- The coordinator owns the native UI; workers may implement nonoverlapping logic modules.
- Build an end-to-end usable app from the reviewed design; document incomplete gates honestly.
- Design recommendations are not completed features or measured performance claims.
- Keep this file as the only project handbook; do not create a CLAUDE.md copy or alias.
- Detailed decisions belong in numbered docs; accident narratives belong in Retrospective.md.

## Documentation and commands

Human-facing design documents are Chinese, as explicitly requested by the owner.
Code, identifiers, comments, this handbook, and Git messages are English.
Run documentation checks from the repository root:

```sh
git diff --check
git status --short
```

Check local Markdown links and document status before committing.
The package is implemented using Swift 6 and macOS 15+. Select Xcode per command without changing machine settings:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Package and verify with the actual entrypoints:

```sh
scripts/build-app.sh Release
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-code-coverage
scripts/check-sdk.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint lint --strict
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift-format lint --strict --recursive Sources Tests
```

The app is at `build/Build/Products/Release/Falcon.app`; the script defaults to the host architecture.
Preview with `open build/Build/Products/Release/Falcon.app --args --preview` uses synthetic data,
a marked temporary database, and no listener, Keychain access, or upstream calls.
Only the coordinator runs SwiftPM in this checkout during parallel work.
Preserve full-suite coverage before the opt-in SDK run replaces SwiftPM's coverage output.
SwiftLint needs the Xcode `DEVELOPER_DIR` above; do not change global xcode-select.

## Implemented modules

- `FalconCore/Domain`: bounded JSON values, source/request models and usage snapshots.
- `FalconCore/Configuration`: credential lifecycle and immutable source-to-upstream snapshots.
- `FalconCore/Proxy`: audited decision pipeline, URLSession upstream, Hummingbird and official MCP SDK.
- `FalconCore/Persistence`: GRDB storage, reservations, retention, shared filters and aggregate queries.
- `FalconCore/Presentation`: observable workspace, truthful replay and export formatting.
- `Falcon/App`, `Design`, `Features`: application lifecycle and native SwiftUI/AppKit/Charts views.

## Project boundaries

- Prefer native SwiftUI, AppKit where needed, Swift Charts, and Swift concurrency.
- Use one app process; UI and transports call the same decision service.
- Separate observable view models, domain models, networking, and persistence.
- Reuse mature HTTP/MCP/SQLite libraries instead of writing protocol parsers or an ORM.
- The implementation follows the recommended pure Swift runtime; the official Python SDK is a development interoperability reference.
- Only bind the proxy to numeric loopback. Never expose it to LAN interfaces by default.
- Authenticate every local API/MCP request with a source key; caller metadata is untrusted.
- Upstream credentials belong only in Falcon-scoped Keychain items.
- Never forward local credentials upstream, or upstream credentials downstream.
- Do not inspect unrelated Keychain items or alter machine ACLs/certificates.
- Preserve Jev request and response semantics. Never invent reasoning or infer agent execution.
- Keep input, question definitions, and results visible together in the primary review workspace.
- Historical replay is local and read-only; never call Jev, invent per-question timing, or bypass expiry with the playback clock.
- Do not implement result reuse unless the owner explicitly chooses it.
- No automatic inference retry; each incoming call represents one observable attempt.
- Keep seven-day retention and deletion consistent across details, search, and aggregates.
- No production payloads, keys, or machine-private paths in fixtures or committed screenshots.

## Testing and quality contract

Statuses: enforced means configured execution with evidence; planned means incomplete;
manual means explicitly performed; N/A requires a concrete reason.

| Dimension | Required contract | Current status |
| --- | --- | --- |
| L1 | Unit statements/branches/functions/lines each ≥95%; strict types and check-only lint/format, zero errors/warnings; pre-commit failure blocking | Incomplete. Meaningful tests and strict static checks exist; functions/lines remain below 95%, statements/branches are unavailable, and no commit hook is installed. |
| L2 | Real local HTTP for every endpoint/method, MCP interoperability, SQLite lifecycle and retention integration | Implemented local HTTP, official MCP client, retention/configuration integration and separate official Python SDK checks. External disk exhaustion and real Keychain faults remain unverified. |
| L3 | Isolated native critical journeys, appearance and accessibility checks | Manual synthetic app captures cover both appearances, focus, compact, empty, replay and usage. Automated UI journeys and full accessibility/performance matrices remain unverified. |
| G2 | Dependency and secret scanning; missing required tools fail | Dependencies are pinned in Package.resolved. No enforced dependency/secret-scanning gate is present. |
| D1 | Separate per-run test storage, ports and key namespace; guards before cleanup | Test fixtures use per-run temporary directories, ephemeral ports, in-memory credentials and verified SQLite run markers. Production credentials are not used. |

Pre-commit target: L1 against the index snapshot, under 30 seconds.
Pre-push target: L2 and G2 against stdin push refs, under three minutes.
These are targets, not current enforcement. Do not lower requirements or bypass failures.
Swift metrics absent from tool output remain an explicit gap, not a passing score.
AppRuntime is not a pure View; its current application-target coverage gap remains explicit.
The current L1 audit belongs only in nmem: `6dq-audit-github.com-nocoo-falcon-l1`.
Do not install an always-failing hook or ship a placeholder gate as enforcement.
Use a per-run SQLite `_test_marker` verified before fixture mutation or deletion.
Tests must not use daily-development data, production data, or real upstream credentials.

## Completion

- Update related docs when a contract changes; keep README as the entrypoint.
- Stage explicit paths and commit each complete logical change atomically.
- Report what was actually inspected and tested, including unavailable evidence.
- Review records identify the exact content revision and disposition of findings.
- Implementation is authorized; publication and release remain outside this task.
- Record actual incidents in [Retrospective.md](Retrospective.md); do not invent incidents.
