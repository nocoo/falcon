<p align="center"><img src="../logo.png" width="128" alt="Falcon logo" /></p>
<h1 align="center">Falcon</h1>
<p align="center">Native macOS Jev HTTP / MCP proxy and seven-day decision observer.</p>
<p align="center"><a href="../README.md">简体中文</a></p>

## What it does

Falcon is a native macOS Jev HTTP / MCP proxy and decision observer for local AI agent developers. Each source gets an independent local key that can map to the same or different upstream connections (direct to the official TypeSafe API or forwarded through a self-hosted Cloudflare Worker relay).

The app runs SwiftUI, AppKit, Swift Charts, and Swift services in a single process bound to loopback `127.0.0.1:19823`. The repository also includes an optional Cloudflare Worker relay under [`services/relay/`](../services/relay/); the native app requires no Node or Python runtime.

## Features

- **Wide Review Workspace**: Displays `state`, question definitions, options, and decision outcomes side by side; **Focus review** collapses navigation and the list, while **Usage** supports chart drill-down for latency and token metrics.
- **Review & Export**: Supports source icons (defaulting to `Unknown`, editable from the list), source and time filters, full-text search, one-click triage (**Review & next** `⌘Return`), independent flags and notes, local read-only stage replay (never re-calls Jev or implies agent execution), and JSON / CSV export.
- **Tiered Retention**: Unstarred records are retained locally for 168 hours (7 days); starred records (`⇧⌘S` or context menu) are kept indefinitely with full evidence. Unstarring an expired record deletes it after confirmation, and clearing history in Settings also clears stars.
- **Official SDK & MCP Parity**: Serves `POST /v1/systemone`, `GET /v1/models` (fetched from the bound upstream without writing history or token stats), and Streamable HTTP `/mcp` exposing the `jev_decide` tool.
- **Optional Relay**: [`services/relay/`](../services/relay/) exposes only `POST /v1/systemone`, `GET /v1/models`, and anonymous `GET /api/live` against fixed `https://api.typesafe.ai` using a Cloudflare Secret. The Worker never stores decisions, caches responses, or auto-retries; relay faults set `X-Falcon-Error-Origin: relay`, and in-flight failures report `outcome_unknown: true`.
- **Isolated Credentials**: Upstream API keys or relay tokens are stored in plaintext at `~/.config/falcon/credentials.json` (`0700` directory, `0600` file, atomic writes, no Keychain). Local source keys persist only SHA-256 digests; decision history lives in `~/Library/Application Support/Falcon`.

## Usage

Requires macOS 15+ on Apple Silicon (`arm64`).

### 1. Install or Build

Download the DMG and `.sha256` checksum from [GitHub Releases](https://github.com/nocoo/falcon/releases):

```sh
shasum -a 256 -c Falcon-0.2.0-arm64.dmg.sha256
```

Open the DMG and drag Falcon into Applications. v0.2.0 is signed with a personal Apple Development certificate without Apple notarization; if macOS blocks launch after checksum verification, remove only the quarantine attribute (this does not notarize the app or repair an invalid signature):

```sh
xattr -dr com.apple.quarantine /Applications/Falcon.app
open /Applications/Falcon.app
```

Or build a local Release bundle from source:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-app.sh Release
open build/Build/Products/Release/Falcon.app
```

To inspect the UI with synthetic data without upstream credentials (uses an isolated temporary DB, opens no listener, and never touches real credentials):

```sh
open build/Build/Products/Release/Falcon.app --args --preview --dark
```

### 2. Setup & Integration

1. On first launch in **Connections**, choose **Direct** (`https://api.typesafe.ai`) with a TypeSafe API key, or **Falcon relay** (preset `https://falcon.hexly.ai`) with your relay Bearer token. Switching presets clears any in-progress credential input.
2. In **Sources**, create a source, bind a connection and icon, and copy the one-time local source key.
3. Point your agent's API root to `http://127.0.0.1:19823` with that source key (closing the window keeps the server running in the menu bar; use Quit to exit).

HTTP example (official SDKs work via `TYPESAFE_BASE_URL` / `TYPESAFE_API_KEY` or `base_url` / `api_key`; `RetryPolicy(max_retries=0)` and `timeout=35` are recommended to avoid duplicate inference):

```sh
curl http://127.0.0.1:19823/v1/systemone \
  -H "Authorization: Bearer $FALCON_SOURCE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"jev-latest","state":"Review an isolated change","questions":{"execution":{"type":"choice","instructions":"Choose how to proceed.","criteria":{"local":"Enough context for a bounded task.","inspect":"Important evidence is missing."}}}}'
```

MCP client configuration:

```json
{
  "mcpServers": {
    "falcon": {
      "url": "http://127.0.0.1:19823/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_SOURCE_KEY"
      }
    }
  }
}
```

## Development

- **Native Swift**: Requires macOS 15+, Xcode (validated on Xcode 27 / Swift 6.4; [`project.yml`](../project.yml) sets `SWIFT_VERSION: "6.0"`), and XcodeGen. Product version lives solely in [`project.yml`](../project.yml) `MARKETING_VERSION` (`0.2.0`); the UI renders `vX.Y.Z`, while `/health` and MCP `serverInfo.version` return `X.Y.Z`.
- **Relay Worker**: Located in [`services/relay/`](../services/relay/), requiring Bun 1.4.3 and Node (`^22.18.0 || ^24.0.0 || >=26.0.0`).

```sh
# Native app build
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
scripts/build-app.sh Release

# Relay Worker local dev (listens on 127.0.0.1:7060, served at https://falcon.dev.hexly.ai)
cd services/relay
bun install --frozen-lockfile
bun run build
bun run dev
```

Running `bun install --frozen-lockfile` in `services/relay` installs Husky hooks via `prepare` (or run `scripts/relay-bootstrap-hooks.sh`), which inspect staged snapshots offline for Worker `typecheck`, `lint`, and `test:coverage`. If installing through a temporary registry mirror, run bootstrap with the same `BUN_CONFIG_REGISTRY` (recorded only in repo-local Git config `falcon.relayRegistry`, never mutating global config or lockfiles). The local harness uses synthetic token `harness-relay-token` against a mocked upstream and must not be used in production.

## Tests

Native Swift checks (uses temporary SQLite, in-memory or isolated file credentials, and loopback fixtures; `scripts/check-sdk.sh` runs opt-in Python SDK interop via `uv` with locked `typesafe-sdk==0.7.1`, skipped by default `swift test`):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --enable-code-coverage
scripts/check-sdk.sh
swiftlint lint --strict
xcrun swift-format lint --strict --recursive Sources Tests
git diff --check
```

Relay Worker and helper contract checks:

```sh
cd services/relay
bun run typecheck
bun run lint
bun run test:coverage
bun run test:http
```

```sh
# Root helper contract tests
bash -n scripts/relay-bootstrap-hooks.sh .husky/pre-commit && for t in scripts/relay-*.test.py; do python3 "$t"; done
```

The Worker enforces 95% coverage across all four metrics and CI gates; native Swift 95% coverage and pre-commit hooks remain planned, with verification boundaries for production Jev, full accessibility matrix, and large-dataset performance documented in [Delivery & Verification](05-delivery.md).

## Stack

| Component | Technology | Role |
| --- | --- | --- |
| Native App | Swift 6, SwiftUI, AppKit, Swift Charts | macOS 15+ desktop UI, menu bar presence, and usage charts |
| Local Server & Store | Hummingbird 2.27.0, MCP Swift SDK 0.12.1, GRDB.swift 7.11.1 | HTTP / MCP proxy, SQLite persistence, and retention cleanup |
| Build Tooling | SwiftPM, XcodeGen ([`project.yml`](../project.yml)) | Dependency management and `arm64` app bundling |
| Relay Worker | Cloudflare Workers, `cf` CLI, TypeScript, Vitest, Biome, Husky | Optional upstream relay, isolated test harness, and commit gates |

## Documentation

- [Design Index](README.md) · [Product](01-product.md) · [Architecture & Data](02-architecture.md) · [HTTP / MCP Contract](03-protocol.md)
- [Interface](04-interface.md) · [Delivery & Verification](05-delivery.md) · [Design Review](07-design-review.md) · [Review & Playback](08-review-playback.md)
- [Relay Design](09-relay.md) · [macOS Release](10-macos-release.md) · [Changelog](../CHANGELOG.md)
- [AGENTS.md](../AGENTS.md) · [Retrospective](../Retrospective.md) · [Harness Assets](../assets/harness/README.md) · [Brand Assets](../assets/brand/README.md)

## License

Released under the [MIT License](../LICENSE), Copyright (c) 2026 Zheng Li.
