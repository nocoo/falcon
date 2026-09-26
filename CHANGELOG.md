# Changelog

## v0.1.4 — 2026-09-26

- Reduce unused menu-icon padding, increasing the visible bird head by approximately 15.4% without changing its silhouette.
- Use lossless LZMA DMG compression to reduce download size while preserving the signed application bytes.

## v0.1.3 — 2026-09-26

- Enlarge the menu-bar artwork by 10% while retaining the native 18-point template size.
- Round the bird head silhouette to remove the straight left and bottom crop, preserving the eye and hooked beak.

## v0.1.2 — 2026-09-26

- Ship only arm64 for Apple Silicon Macs; remove Intel from native builds and DMG packaging.
- Verify that release executables contain exactly the arm64 architecture.

## v0.1.1 — 2026-09-26

- Preserve the Falcon logo’s off-center head, large eye and hooked beak in the monochrome menu-bar icon.
- Preserve menu artwork framing when exporting native 18/36 px template assets.
- Add explicit-signing universal macOS DMG packaging, SHA-256 checksums and a documented GitHub release and installation procedure.

## v0.1.0 — 2026-09-25

Initial local development version.

- Native macOS workspace built with SwiftUI, AppKit and Swift Charts.
- Authenticated loopback HTTP and MCP proxy for Jev, with per-source keys and upstream connection mapping.
- Local file credentials and seven-day SQLite history of inputs, question definitions, typed decisions and timing.
- Live request updates, searchable history, review notes, recorded-stage replay, usage charts and JSON/CSV export.
- Compact activity rows, stable selection and scrolling, smooth detail changes and reliable database reopening.
- Bundle-derived version information in the sidebar, Settings, About, health response and MCP initialization.
- User-selected harness icons, a generated monochrome menu-bar symbol, and an iPhone 5c-inspired candy palette.
- One-click review and next-unread navigation, with separate flags and notes.
- Indefinite retention of complete starred decisions and an all-time starred view.
- Safe preview shutdown, immediate proxy restart, and correctly populated source editing.
