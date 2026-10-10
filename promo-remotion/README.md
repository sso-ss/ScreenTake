# ScreenTake promo — Remotion

48-second, 1920 × 1080, 30 fps promotional visualization with original instrumental music and captions. Nine scenes follow `../docs/promo-storyboard.md`.

This first cut uses native ScreenTake screenshot assets and a reconstructed example interface/workflow. It is labeled as a product visualization in the film. It does not contain live feature-interaction capture or a presenter, and does not overwrite the earlier website promo. The existing open ScreenTake recording was preserved.

## Preview and render

```sh
npm ci
npm run setup
npm run audio
npm run typecheck
npm run studio
npm run render
```

The result is `out/screentake-promo.mp4`. `npm run render:preview` creates a 960 × 540 review version. `npm run stills` renders scene checkpoints for visual review.

## Source

- `src/Root.tsx` — timeline, scene compositions and score.
- `src/scenes.tsx` — nine scene implementations.
- `src/visuals.tsx` — layered perspective, selective focus, sampled motion blur, native screenshot surfaces, cursor and example footage.
- `scripts/audio.py` — original deterministic instrumental score and action accents; no sampled commercial music.
- `scripts/prepare-assets.py` — native screenshot assets and local macOS production fonts. Fonts are ignored by Git and are not redistributed.

## Depth and blur

CSS perspective and independent layer transforms provide 2.5D depth. Foreground surfaces remain sharp while background surfaces soften. The focus mask blends a sharp layer with a blurred copy. Fast surface motion uses three sub-frame transform samples; captions stay sharp. This is simulated DOF rather than a physical lens render.

## Footage replacement

To make a recording-led public demo, replace the reconstructed action layers in Record, Zoom, Cursor, Edit, Voiceover and Result with corresponding real captures of the same example workflow. Preserve the composition framing and timing. Capture zoom/cursor editing from a ScreenTake-origin recording with retained mouse data. The source screenshots and control labels were checked against the native app source, but the depicted action timing is illustrative.

No publishing, installer changes or website-video replacement are included.
