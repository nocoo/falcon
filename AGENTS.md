# Falcon

Falcon is a native macOS Jev proxy with seven-day decision history and indefinitely retained starred decisions.
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

The app is at `build/Build/Products/Release/Falcon.app`; the script builds only arm64 (Apple Silicon).
Preview with `open build/Build/Products/Release/Falcon.app --args --preview` uses synthetic data,
a marked temporary database, and no listener, production credential access, or upstream calls.
Only the coordinator runs SwiftPM in this checkout during parallel work.
Preserve full-suite coverage before the opt-in SDK run replaces SwiftPM's coverage output.
SwiftLint needs the Xcode `DEVELOPER_DIR` above; do not change global xcode-select.

## Versioning

- `project.yml` → `MARKETING_VERSION` is the single authoritative X.Y.Z product version. XcodeGen synchronizes the generated Xcode project and the app's `CFBundleShortVersionString`.
- AppRuntime reads the bundle version. The sidebar, Settings and native About panel display vX.Y.Z; authenticated `/health` and MCP `serverInfo.version` report X.Y.Z.
- `CURRENT_PROJECT_VERSION` is the native build number. HTTP `api_version` and MCP protocol versions are independent contracts.
- Unbundled SwiftPM executables identify themselves as development builds instead of claiming a release version.
- Maintain root [CHANGELOG.md](CHANGELOG.md), rebuild with `scripts/build-app.sh`, and verify the actual bundle and runtime metadata when changing the product version.

## Standard macOS release procedure

- Follow `system0-github-versioning`; `project.yml` remains the version authority.
  Compare the previous release (or initial development version for the first
  release), update `MARKETING_VERSION`, increment `CURRENT_PROJECT_VERSION`,
  regenerate the Xcode project, and write the root changelog.
- Inspect Gecko and Lyre as references, not proof of distribution trust: Gecko
  uses Apple Development for installed builds; Lyre requires Developer ID in
  its release script, while older installed artifacts may be ad-hoc.
- Use the owner's free Apple Development signing through Xcode automatic
  signing, team `93WWLTN9XU`. The owner authorized this personal-use signing
  route on 2026-09-26, including Xcode's account-managed provisioning.
  `xcodebuild -allowProvisioningUpdates` obtained the identity when direct
  codesign initially found none. Do not treat an empty local identity list as
  proof that the signed-in Xcode account cannot sign. No Developer ID or
  notarization is claimed; never silently switch to ad-hoc, inspect unrelated
  Keychain contents, or modify ACLs.
- Run full Swift tests with coverage, preserve the actual `codecov` directory
  before the SDK-only run, then run `scripts/check-sdk.sh`, strict SwiftLint,
  strict swift-format, and `git diff --check`. Existing L1/G2/L3 gaps remain
  disclosed; do not describe the release as having passed absent gates.
- Run `scripts/build-dmg.sh`.
  It builds Release only for arm64 with Xcode automatic signing, rejects any
  other executable architecture, verifies its signature, and creates `build/Falcon-X.Y.Z-arm64.dmg` with an
  Applications link and a sibling `.sha256`. Use ULMO (LZMA) compression,
  supported since macOS 10.15 and compatible with our macOS 15 minimum.
  Compression changes download size, not installed app size. It does not notarize. Never
  overwrite published release assets; correct them in a new version.
- Mount the DMG read-only, verify its app signature, bundle version/build,
  architectures, and resource contents; compare the packaged executable to
  the built app, then detach. Inspect the menu symbol at actual 18-point size
  in both appearances, including its template behavior and off-center framing.
- Commit explicit paths through normal hooks, push the release commit, create
  and push `vX.Y.Z` at that exact revision, then use `gh release create` with
  the DMG, checksum and `--notes-file`. Check remote tags/releases before any
  retry. Release notes must include changes, macOS 15+ / Apple Silicon requirements,
  actual signing and notarization status, checksum verification, installation,
  and the scoped Gatekeeper workaround below.
- For a trusted download that macOS blocks because this release is not
  notarized, document these exact commands after copying the app to Applications:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Falcon.app
  open /Applications/Falcon.app
  ```

  Explain that this removes download quarantine only for Falcon; it neither
  notarizes the app nor repairs an invalid signature. Never recommend global
  Gatekeeper disabling, recursive changes to Applications, or re-signing a
  damaged download. Verify the downloaded SHA-256 before using this workaround.
- Verify the published tag SHA, asset names/sizes and downloaded checksums.
  Inspect Actions for that exact revision, with a five-minute follow-up if CI
  is pending. This repository currently has no Actions workflow; report CI as
  unavailable, not green.
- After authorized publication, quit an existing Falcon cleanly, install the
  verified DMG app at `/Applications/Falcon.app`, verify the installed signature
  and version, and open it without `--preview`. Preserve user configuration and
  history. Verify the running executable path; never claim a build-tree preview
  is the installed release.

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
- Upstream credentials live in `~/.config/falcon/credentials.json`; use directory mode 0700, file mode 0600 and atomic writes.
- Local source keys are displayed once; persist only their SHA-256 digests, suffixes and identifiers.
- Never forward local credentials upstream, or upstream credentials downstream.
- Do not access Keychain, inspect unrelated credentials, or alter machine ACLs/certificates.
- Preserve Jev request and response semantics. Never invent reasoning or infer agent execution.
- Keep input, question definitions, and results visible together in the primary review workspace.
- Historical replay is local and read-only; never call Jev, invent per-question timing, or bypass unstarred expiry with the playback clock.
- Do not implement result reuse unless the owner explicitly chooses it.
- No automatic inference retry; each incoming call represents one observable attempt.
- AppRuntime owns observation and maintenance tasks. On shutdown, stop the workspace, cancel and await those tasks, drain the service, close the store, and only then remove a verified preview directory.
- Keep Hummingbird's default address reuse so immediate same-port restarts work; a second live listener must still fail.
- Keep seven-day unstarred retention and indefinite starred retention consistent across details, search, aggregates, previews, replay and export. Unstarring an expired decision removes it; the UI confirms that deletion. Explicit clear-all also clears stars.
- Source icons are user-selected presentation metadata, defaulting to Unknown. Do not infer a harness from the source name or change source/key identity when an icon changes.
- Source editor sheets use one identifiable presentation item carrying the selected source. Keep create and edit identity together with presentation state.
- No production payloads, keys, or machine-private paths in fixtures or committed screenshots.

## Testing and quality contract

Statuses: enforced means configured execution with evidence; planned means incomplete;
manual means explicitly performed; N/A requires a concrete reason.

| Dimension | Required contract | Current status |
| --- | --- | --- |
| L1 | Unit statements/branches/functions/lines each ≥95%; strict types and check-only lint/format, zero errors/warnings; pre-commit failure blocking | Incomplete. Meaningful tests and strict static checks exist; functions/lines remain below 95%, statements/branches are unavailable, and no commit hook is installed. |
| L2 | Real local HTTP for every endpoint/method, MCP interoperability, SQLite lifecycle and retention integration | Implemented local HTTP, official MCP client, retention/configuration integration and separate official Python SDK checks. External disk exhaustion remains unverified. |
| L3 | Isolated native critical journeys, appearance and accessibility checks | Manual synthetic app captures cover both appearances, focus, compact, empty, replay and usage. Automated UI journeys and full accessibility/performance matrices remain unverified. |
| G2 | Dependency and secret scanning; missing required tools fail | Dependencies are pinned in Package.resolved. No enforced dependency/secret-scanning gate is present. |
| D1 | Separate per-run test storage, ports and key namespace; guards before cleanup | Test fixtures use per-run temporary directories, ephemeral ports, memory or isolated file credentials and verified SQLite run markers. Production credentials are not used. |

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
- Implementation and atomic commits are authorized. The owner explicitly authorized the 2026-09-26 GitHub DMG release and local installation; future publication still requires task authorization.
- Record actual incidents in [Retrospective.md](Retrospective.md); do not invent incidents.
