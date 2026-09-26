# Reduced-padding Falcon menu candidate

Preserves every path from the owner-approved v0.1.3 rounded bird head.
Only the SVG viewBox changes from `0 0 180 180` to `4 18 156 156`, removing
unused transparent canvas without clipping the silhouette. The 18-point
logical image size and export inset remain unchanged.

The artwork grows by `180 / 156`, approximately 15.4%, relative to v0.1.3.
Its visible height increases from approximately 14.1 to 16.2 points within
the same 18-point menu image. The new viewBox preserves six source units
above and below the silhouette for antialiasing and separation.

`review.swift` renders `review.png`, comparing v0.1.3 and the candidate in
both appearances. `template.svg` is editable; `template.png` is the exported
transparent master. No image generation or anatomy changes are involved.

Status: local candidate, awaiting owner review before another release.
