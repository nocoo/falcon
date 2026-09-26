# Falcon menu template

Native vector adaptation of the owner-approved root `logo.png` (SHA-256
`f3fedf54cd8415a607d41727c9126c4eddb282c8c1dc11abab44c2d51ab9af68`).
No image model was used. Preserve the lower-left entry, eye ring and hooked
open beak. Small facets are intentionally omitted for 18-point legibility.

`template.svg` is the editable source. White regions become transparent in
`scripts/build-brand-assets.swift`; the full canvas is preserved with a
one-point inset. `template.png` is the derived transparent 512 px master.
`review.png` compares enlarged and 18/36-point specimens on both appearances.
The shipped PNGs are 18/36 pixels; AppKit sets a logical 18-point template size.
