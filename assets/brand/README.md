# Falcon identity

The first independent Logo is the owner-approved faceted bird head from Hexly
study `2026-09-25-03`, finishing `02`.

![Falcon](icon-rounded.png)

- `../../logo.png`: transparent foreground, native 2048-square canvas; small app
  and browser marks derive from this source without another tile or CSS mask.
- `icon.png`: square presentation for large promotional surfaces.
- `icon-rounded.png`: rounded presentation for README and social use.
- Transparent SHA-256: `f3fedf54cd8415a607d41727c9126c4eddb282c8c1dc11abab44c2d51ab9af68`.
- Complete source, prompt, variants and usage: https://hexly.ai/projects/falcon#brand

Azure OpenAI `gpt-image-2.5-sunburst` generated the source. The owner approved its
exact bytes. White-matte extraction and separate presentation layers are recorded
in Hexly; no original source image existed. Preserve the species, faceted colors
and off-center framing. Artwork rights follow the project owner's generated
identity; support documentation follows the repository license.

## Native application consumers

The native app uses the approved identity in its sidebar, empty state,
Settings footer and Dock. `Sources/Falcon/Resources/FalconMark.png`
and its 2x variant retain the entire transparent canvas and original colors.
Small in-app marks have no background tile or extra mask. The menu bar uses
an optically simplified monochrome tracing of the approved logo: the head enters
from the lower left, with a large eye, cheek cutout and open hooked beak.
The editable SVG, transparent master and light/dark size review are archived in
[menu/2026-09-26-01](menu/2026-09-26-01/). The previous generated centered profile
remains in its original archive, but is no longer an input to the exporter.
The exporter preserves the full composition instead of cropping to ink bounds.
`FalconMenu.png` and its 2x variant provide the native template with transparent
negative space. `FalconAssets` sets the image's logical size and template flag
before passing it to `MenuBarExtra`.

`Sources/Falcon/Resources/Falcon.icns` contains the ten standard macOS icon
representations. Each places the approved rounded presentation at 824/1024
of the canvas width, centered on transparency, preserving the whole tile.
`CFBundleIconFile` selects this icon in the packaged app. SwiftPM and Xcode
load their own resource bundles through `FalconAssets`.

Regenerate these derivatives from the repository root with the native toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/build-brand-assets.swift
```

The same script renders the [harness icon assets](../harness/README.md).
The full-resolution masters and SVG sources are not bundled in the app.
This application adoption is local; it does not publish or notarize a release.
