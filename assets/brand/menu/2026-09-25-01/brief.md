# Falcon menu-bar glyph

A functional 16–18 pt macOS status symbol, commissioned on 2026-09-25. The owner requested a simpler, recognizable menu-bar mark generated through Workflow GPT Image. This is a separate monochrome interface asset; the approved multicolor app identity remains the app identity.

Generate one bold falcon profile, preserve the untouched native response, and derive a transparent system-template mask with the standard library and native AppKit. Inspect actual small sizes on both menu-bar appearances.

Generation helper: Workflow `agents/skills/agi-image-generation/scripts/generate.py`. Model: `gpt-image-2.5-sunburst`, quality high, native requested size 1024×1024. Credentials are supplied by the existing Workflow direnv environment and never archived.

The native result is 1024×1024. The template builder normalizes pixels to sRGB RGBA, maps luminance to alpha with clamp((0.96 − luminance) / 0.88), crops the occupied bounds at alpha > 0.05, and places the whole symbol with a 1 pt inset in an 18 pt square. Resources are 18/36 px template images. The 512 px template is a derived master; raw.png remains untouched.
