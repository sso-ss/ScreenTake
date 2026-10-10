# ScreenTake — storyboard film

New Remotion production based on `storyboard-local.html`, supplied from `/Users/sso/output/screentake-promo/storyboard-local.html`. The previous promo remains in `../promo-remotion/`.

## Deliverables

- `out/screentake-storyboard.mp4`: 48 seconds, 1920 × 1080, 30 fps.
- `out/screentake-storyboard-vertical.mp4`: 20 seconds, 1080 × 1920, 30 fps. Selected scene excerpts are laid out for portrait.
- H.264, Rec.709, AAC stereo. Original synthesized music and UI sound at 150 BPM; no narration.

## Production

The interface is drawn in code from ScreenTake controls and design tokens, following the supplied storyboard. This is an animated product visualization, not a live recording. The webcam uses the supplied still photo, cropped tightly to the face; it has no lip animation or speech. No website video is replaced or published.

CSS perspective and camera dolly produce parallax between document, cursor, panels and wallpaper layers. Depth of field is simulated from the focus plane, with selective focus masks. Fast movements use sub-frame motion samples. Captions stay sharp after arrival.

The macro opening leads into the title, recording settings, experimental smart zoom (up to 3×), cursor shapes and 50–300% sizing, six click colours, webcam/audio, the tilted editor, framing, and the end card. The editor shows split → reorder → review 2 pauses → Remove 2 → Undo. The photo remains in the preview and framing shots. The iPhone is a frame option.

Cuts follow the 0.4-second beat grid. The storyboard’s rounded ranges are adapted slightly, preserving its scene order and 48-second length. `src/lib/timeline.json` controls all timings, sound cues and the exact 20-second vertical edit.

## Edit and render

```sh
npm ci
npm run setup
npm run audio
npm run typecheck
npm run studio
npm run stills
npm run render
npm run render:vertical
```

The local checkout shares the installed Remotion 4.0.529 runtime from `../promo-remotion/node_modules` through a link. For a fresh copy, run `npm ci` to install the locked dependencies. Setup reads the adjacent ScreenTake repository; set `SCREENTAKE_REPO` if its location changes. Local SF fonts are prepared on macOS and are not redistributed.

- `src/scenes/S01…S09`: individual scenes.
- `src/components/Space.tsx`: camera, depth planes, focus blur and motion sampling.
- `src/components/Demo.tsx`: illustrated recording, dolly zoom and photo overlay.
- `src/lib/timeline.json`: master timing and vertical excerpts.
- `scripts/audio.py`: music and synchronized UI sounds.
- `scripts/render.mjs`: review stills and both exports.

The beta and experimental zoom labels follow the supplied storyboard. There are no version, App Store, Intel or iPhone-capture claims.
