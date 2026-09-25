# Harness icons

Falcon bundles eight SVG-derived marks from Manifest, now `mnfst/llm-gateway`, under its MIT license. Exact paths, immutable revision and source hashes are in [provenance.json](provenance.json); original SVG bytes are preserved in [originals/](originals/). See [LICENSE](LICENSE). Grok uses Manifest’s `providers/xai.svg`, whose title is Grok.

The source picker defaults to Unknown and never guesses identity from a source name. Pi uses a native typographic π glyph because this Manifest inventory has no Pi asset; Unknown uses a native question mark. Neither is presented as a downloaded brand asset.

Codex, Grok, OpenCode and Hermes use native template rendering for both appearances. Claude Code, Gemini, OpenClaw and Qwen retain their source colors. The app bundles 40/80 px PNGs, generated with AppKit from these vectors, and the required notice. Original vectors stay outside the application bundle.

Rebuild with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/build-brand-assets.swift`.

## Hermes preparation

CoreSVG rejects several compact arc commands in the Hermes SVG. Its 512 px transparent prepared master was rendered with the existing Hexly `sharp` installation (0.35.4 / librsvg); the original SVG remains untouched. Rebuild just this master from the Falcon repository:

```sh
node - <<'JS'
const { createRequire } = require('node:module');
const { resolve } = require('node:path');
const sharp = createRequire(resolve('../hexly.ai/package.json'))('sharp');
sharp('assets/harness/originals/hermes.svg', { density: 1536 })
  .resize(512, 512).png().toFile('assets/harness/prepared/hermes.png');
JS
```

Then run the native brand-asset builder above. Runtime and application builds use the checked-in PNGs and require no JavaScript or SVG-rendering dependency.
