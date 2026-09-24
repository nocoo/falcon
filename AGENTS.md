# Falcon

Falcon is a planned native macOS Jev proxy and seven-day decision observability app.
Human overview: [README.md](README.md). Design index: [docs/README.md](docs/README.md).

## Scope and current state

- This file applies throughout the repository. There are no nested instruction files.
- The repository is documentation-only. No app, package manifest, tests, hooks, or CI exist yet.
- The current authorized deliverable is Chinese design documentation and independent Codex review.
- Do not begin application implementation until the owner approves that next phase.
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
No build, lint, app launch, or test command is available yet. Do not invent one.
Future command names must be recorded from actual scripts and manifests when implemented.

## Planned project boundaries

- Prefer native SwiftUI, AppKit where needed, Swift Charts, and Swift concurrency.
- Use one app process; UI and transports call the same decision service.
- Separate observable view models, domain models, networking, and persistence.
- Reuse mature HTTP/MCP/SQLite libraries instead of writing protocol parsers or an ORM.
- The runtime SDK decision remains a design recommendation pending owner confirmation.
- Only bind the proxy to numeric loopback. Never expose it to LAN interfaces by default.
- Authenticate every local API/MCP request with a source key; caller metadata is untrusted.
- Upstream credentials belong only in Falcon-scoped Keychain items once implemented.
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
| L1 | Unit statements/branches/functions/lines each ≥95%; strict types and check-only lint/format, zero errors/warnings; pre-commit failure blocking | Planned; no code or gate exists. Swift coverage metric availability must be proven. |
| L2 | Real local HTTP for every endpoint/method, MCP interoperability, SQLite lifecycle and retention integration | Planned; no server exists. |
| L3 | Isolated native critical journeys, appearance and accessibility checks | Planned; no UI exists. |
| G2 | Dependency and secret scanning; missing required tools fail | Planned; no lockfile or scanner gate exists. |
| D1 | Separate per-run test storage, ports and key namespace; guards before cleanup | Planned; documentation research used synthetic SDK input only. |

Pre-commit target: L1 against the index snapshot, under 30 seconds.
Pre-push target: L2 and G2 against stdin push refs, under three minutes.
These are targets, not current enforcement. Do not lower requirements or bypass failures.
Swift metrics absent from tool output remain an explicit gap, not a passing score.
Use a per-run SQLite `_test_marker` verified before fixture mutation or deletion.
Tests must not use daily-development data, production data, or real upstream credentials.

## Completion

- Update related docs when a contract changes; keep README as the entrypoint.
- Stage explicit paths and commit each complete logical change atomically.
- Report what was actually inspected and tested, including unavailable evidence.
- Review records identify the exact content revision and disposition of findings.
- Independent review approval does not authorize implementation, publication, or release.
- Record actual incidents in [Retrospective.md](Retrospective.md); do not invent incidents.
