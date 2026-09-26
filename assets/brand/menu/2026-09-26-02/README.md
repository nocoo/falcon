# Rounded Falcon menu candidate

Owner-requested refinement of `../2026-09-26-01/template.svg` for v0.1.3.
The left and lower outline now form a rounded bird head, without the former
straight neck crop. The eye ring and hooked open beak retain their identity.

The logical template size remains 18 points. Reducing the export inset from
1/18 to 1/90 increases artwork scale by exactly 10%: `(1 - 2/90) / (1 - 2/18)`.
The new contour differs, so individual feature bounds are not identical to a
uniformly enlarged old silhouette. Native resources remain 18/36 pixels.

`template.svg` is the editable source; white regions become transparent.
`template.png` is the exported 512 px mask. `review.swift` reproducibly renders
`review.png`, comparing the previous and candidate masks in both appearances,
with enlarged and menu-size specimens. No image model was used.

Status: awaiting owner visual approval before packaging v0.1.3.
