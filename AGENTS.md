# Falcon

Falcon is a native macOS Jev HTTP/MCP proxy with seven-day decision history, indefinitely retained starred decisions, and an optional Cloudflare Worker relay.
Docs: [README.md](README.md) · [Design Index](docs/README.md) · [Relay](docs/09-relay.md) · [macOS Release](docs/10-macos-release.md) · [Changelog](CHANGELOG.md) · [Retrospective](Retrospective.md)

## Commands

Swift 6 / macOS 15+ package at root (`Sources/FalconCore/{Domain,Configuration,Proxy,Persistence,Presentation}`, `Sources/Falcon/{App,Design,Features}`); independent Worker at `services/relay` (Bun 1.4.3, Node 26.12.1; no root JS workspace). Set `DEVELOPER_DIR` per command, never global `xcode-select`:

```sh
# Native Swift (root)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test --enable-code-coverage
scripts/check-sdk.sh                     # opt-in Python SDK interop (uv Python 3.12.14)
swiftlint lint --strict
xcrun swift-format lint --strict --recursive Sources Tests
scripts/build-app.sh Release             # arm64-only build/Build/Products/Release/Falcon.app
open build/Build/Products/Release/Falcon.app --args --preview  # synthetic data, marked temp DB, no listener/upstream
git diff --check

# Relay Worker (services/relay) — run locked `cf` under Node, never `bun --bun cf`
cd services/relay
bun install --frozen-lockfile   # runs prepare -> husky; add --ignore-scripts to skip
bun run typecheck               # S1: cf workers types + strict tsc
bun run lint                    # S2: Biome check-only, 0 warnings
bun run test:coverage           # L1: >=95% statements/branches/functions/lines
bun run build                   # B1: cf build --mode production
bun run test:http               # L2: prebuilt --dry-run deploy + synthetic HTTP harness
bun run dev                     # local relay harness on 127.0.0.1:7060

# Relay helper contracts (root)
bash -n scripts/relay-bootstrap-hooks.sh .husky/pre-commit && for t in scripts/relay-*.test.py; do python3 "$t"; done
```

## Invariants

- Design docs in `docs/` are Chinese; code, identifiers, comments, this handbook, and Git messages are English.
- During parallel work, only the coordinator runs SwiftPM in this checkout and owns native UI changes; workers take non-overlapping logic modules.
- Preserve full-suite coverage (via `swift test --show-codecov-path`) before `scripts/check-sdk.sh`, which overwrites SwiftPM coverage output.
- `Config/Info.plist` supplies `CFBundleIconFile`; both packaging scripts run `scripts/check-app-icon.sh` (Xcode settings alone do not prove Finder sees the icon).
- `project.yml` `MARKETING_VERSION` is the sole `X.Y.Z` product version (synced by XcodeGen and read by Worker); `CURRENT_PROJECT_VERSION` is build number; HTTP `api_version` and MCP versions are independent.
- `AppRuntime` reads bundle version: UI shows `vX.Y.Z`, `/health` and MCP `serverInfo.version` return `X.Y.Z`, and unbundled SwiftPM runs report dev builds; update [CHANGELOG.md](CHANGELOG.md) on version changes.
- Worker `build` prefers `GIT_SHA` over CI/Git fallbacks (works without `.git`; never use stale SHAs or independent versions), records `--mode production`, and aligns workerd compatibility dates (explicit if lagging).
- Keep one native SwiftUI/AppKit/Charts process (shared decision service; separate view models, domain, networking, persistence) reusing Hummingbird, official MCP SDK, and GRDB; Python SDK is dev-only interop reference.
- Bind proxy to numeric loopback only (`127.0.0.1:19823`); authenticate every local HTTP/MCP request with a source key; treat caller metadata as untrusted.
- Store upstream credentials in `~/.config/falcon/credentials.json` (`0700` dir, `0600` file, atomic writes); display local source keys once and persist only SHA-256 digests, suffixes, and IDs.
- Never forward local credentials upstream or upstream credentials downstream; never access Keychain, inspect unrelated credentials, or alter machine ACLs/certificates.
- Preserve Jev request/response semantics; never invent reasoning, infer agent execution, auto-retry inference, or reuse results unless explicitly chosen by the owner.
- Keep TypeSafe SDK parity on `POST /v1/systemone` and `GET /v1/models` (only API root/source key change), preserving optional/null fields and allowlisted headers; `GET /v1/models` writes no history or usage.
- Relay uses the existing vault and source mapping while keeping relay token, local source keys, and official key separate; changing target requires its own credential and never falls back to direct access.
- Worker forwards only `POST /v1/systemone` and `GET /v1/models` to fixed `https://api.typesafe.ai` via Cloudflare Secret, rejects redirects, bounds bodies/deadlines, and never stores payloads or retries.
- Worker preserves official bytes/status/headers; Worker errors set `X-Falcon-Error-Origin: relay` and `error.{origin,code,message,outcome_unknown}` (never claim definite non-execution after in-flight failure).
- Normalize malformed relay errors conservatively on the wire while keeping original bytes in local audit storage.
- Anonymous `GET /api/live` probes models (never inference) with bounded check, `no-store`, and rate limit; success proves tested dependency and build identity, not fixed-region egress or universal availability.
- Primary review workspace shows input, question definitions, and results together; replay is local/read-only (never calls Jev, invents per-question timing, or bypasses unstarred expiry).
- Enforce 7-day unstarred and indefinite starred retention across details, search, aggregates, previews, replay, and export; unstarring an expired item deletes it with confirmation, and clear-all clears stars.
- `AppRuntime` owns observation/maintenance tasks; shutdown stops workspace, cancels/awaits tasks, drains service, closes GRDB store, then deletes a verified preview directory.
- Keep Hummingbird's default address reuse for immediate same-port restarts while still rejecting a second live listener.
- Source icons are presentation metadata (default `Unknown`; never infer harness from name or change identity); bind source editor sheets to one identifiable item carrying the selected source.
- No production payloads, keys, or machine-private paths in fixtures or committed screenshots.
- Releases/deploys need explicit authorization: DMG follows [docs/10-macos-release.md](docs/10-macos-release.md); Worker deploy (`deploy.yml`) takes a green `main` CI run ID + exact SHA and verifies `/api/live`.

## Quality & Local Gates

Follows `system1-quality`; Worker CI slots and macOS SwiftLint (`SwiftLint (macOS)`) live in `.github/workflows/quality-slots.yml` (`quality / Z1: Gate` required on `main`). `.github/workflows/ci.yml` also runs `helpers` and `l1-native-swift`, checked on the same SHA by `CI Gate`. Status vocabulary: `enforced`, `planned`, `manual`, `N/A`.

- **Worker enforced**: `S1/S2/S3/G1/G2/B1/L1/L2/Z1` (`L1` >=95% on `services/relay/src/**/*.ts`, excluding harness/declarations; `G2` scans `services/relay/bun.lock`).
- **Slot gaps**: `L3 Integration` is `N/A` in `quality-slots.yml` (covered by L1/L2 + `l1-native-swift`); `P1 Package` is `N/A` (private); `L4 E2E` is `manual` (automated UI/a11y/perf/disk-fault `planned`).
- **Native Swift gaps**: `L1` 95% floor is `planned` (functions/lines <95%, LLVM statements/branches unavailable, `AppRuntime` is not a pure-View exemption); `G2` (`Package.resolved`) is `planned`.
- **Local hooks**: `bun install --frozen-lockfile` in `services/relay` (or `scripts/relay-bootstrap-hooks.sh`) sets `core.hooksPath=.husky/_`; `BUN_CONFIG_REGISTRY` sets `falcon.relayRegistry` (never `bun.lock`/global).
- **Hook scope**: `.husky/pre-commit` runs staged `scripts/relay-check-index.py` in an isolated snapshot (offline copyfile) for Worker `S1/S2/L1`; native pre-commit and `pre-push` are `planned` (no placeholder gates).

## Resources & Isolation

| Lane | Endpoint / State | Boundary |
| --- | --- | --- |
| Dev (Native) | `127.0.0.1:19823`, `~/Library/Application Support/Falcon`, `~/.config/falcon/credentials.json` | Daily local data; preserve running server and credentials |
| Dev (Relay) | `https://falcon.dev.hexly.ai` -> `127.0.0.1:7060` (`bun run dev`, `harness-relay-token`, intercepted upstream) | Never let fake-key dev server hit real TypeSafe API; keep in Herdr tab `dev server` for acceptance |
| Preview / Tests | Ephemeral loopback ports, per-run temp dir + `_test_marker`, memory or isolated file creds | Verify `_test_marker` before mutation/cleanup; separate from daily-dev, prod, and real upstream |
| Prod | `https://falcon.hexly.ai` (Cloudflare Secrets), `/Applications/Falcon.app` | Read-only checks unless deployment or macOS release is authorized |

## Retrospective

Record real incidents in [Retrospective.md](Retrospective.md); promote recurring project constraints to `Invariants` above and enforceable safeguards to tests/hooks; update related docs when contracts change.
