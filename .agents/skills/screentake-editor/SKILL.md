---
name: screentake-editor
description: Edit the video project open in ScreenTake using its local MCP tools, including timed text, zoom areas, camera effects, narration, previews and video exports. Use for operating ScreenTake, not for changing its application source code.
---

# ScreenTake Editor

Use the `screentake` MCP server to operate the same draft and Undo history as the native editor. ScreenTake must be running with its AI connection enabled. Discover the installed tool schemas; older helpers may lack recently added fields.

## Editing workflow

Read `get_project` before editing. Use the returned project `id` as `projectID` and its current `revision` as `expectedRevision` for edits, saving, rendering and analysis. Each successful mutation returns the next revision. On `stale_project`, reread and reconcile with the user's current work.

Apply related changes in one `apply_edits` call so they share one Undo step. Omitted top-level fields stay unchanged. Arrays such as `textOverlays`, `voiceOvers` and `zoomSegments` replace their entire existing values; preserve unrelated items, IDs and their full settings. Use `[]` only when removing every item is intended. `removeRanges` appends source-time cuts instead.

Use a stable UUID `requestID` when retrying an identical mutation. A changed request needs a new ID. Replacing an open project requires its revision and, when there is unsaved work, explicit authorization before using `discardUnsaved: true`.

## Text

Add or edit text through `apply_edits.edits.textOverlays` (maximum 100 layers). For a new layer, supply a new UUID `id`, `text`, `start` and `duration`. Appearance fields may be omitted for new layers and use native defaults; preserve full existing objects when editing to keep their styles. Array order is back to front.

- `start` and `duration` use seconds on the edited video, independently of source trims or reorderings. `duration` must be at least 0.05 seconds.
- `x` and `y` locate the text center on the final output canvas, normalized from the top-left (0–1). Change these to move a text box. `boxWidth` is normalized canvas width (0.1–1).
- `fontName` defaults to `System`; `fontSize` defaults to 64 and accepts 8–240. Sizes, spacing, padding, outline widths and corner radii use a 1080-point canvas height.
- `scale` and `scaleY` accept 0.1–3; `uniformScale: true` uses `scale` on both axes. For independent scaling, set `uniformScale: false` and supply both scales. `rotation` uses degrees (−180–180).
- Colors use `#RRGGBB`; opacity uses 0–1. `alignment` is `Left`, `Center` or `Right`; `letterCase` is `Original`, `UPPERCASE`, `lowercase` or `Title Case`.
- Enable outlines with `strokeEnabled` and backgrounds with `backgroundEnabled`. Background style is `Block` or `Per Line`. Consult the tool schema for the remaining styling fields and limits.

To delete one layer, send the remaining layers with their original IDs and settings. Text filmstrip rows pack automatically: sequential clips share a row and overlapping clips use extra rows. Row indices are presentation state and must not be sent as edits.

## Camera, zoom and audio

Use `cameraEffectSelection: {"style":"natural","intensity":0.5}` or style `peachMakeup`, together with `cameraEffectsEnabled`, for the exclusive camera style picker. Intensity accepts 0.05–1. Changing selection alone preserves the current on/off state. Turning effects off remembers the chosen style and intensity; turning them back on restores them. Makeup components remain available in `faceMakeup`; preserve the complete component object when customizing it. The new selection fields take precedence over legacy effect amounts in the same batch.

`zoomEnabled` is the editor Zoom master. `zoomSegments` supplies explicit sections; `[]` leaves no sections. `restoreAutomaticZooms: true` clears the explicit override and restores generated sections, while preserving the master toggle. Capture Auto Zoom is a separate pre-recording preference and is not exposed by editor MCP commands. For a fixed zoom area, use the segment's `manualRegion` schema: normalized cropped-screen coordinates, square dimensions 0.125–1. Zoom segment timing uses source-video seconds.

Narration in `voiceOvers` uses edited-video `start` plus source-audio `sourceStart`/`duration` in seconds. Preserve local file URLs, source duration and IDs. Use `audioEnabled`/`originalAudioVolume` and `voiceOverEnabled`/`voiceOverVolume` for independent levels (0–1). Sequential voiceovers share a filmstrip row; overlaps use extra rows. Text and voiceover tracks share the timeline's 240-point maximum track viewport and internal scrolling, with no row-setting API.

## Verify and deliver

Render representative edited timestamps with `render_preview` (1–12 times). Poll `get_job` to a terminal state, then view actual PNGs through `get_preview_frame`; a queued job is not proof that the edit rendered. Include times inside and outside timed text when checking timing.

Save editable work with `save_project` to an absolute `.screentake` path. Export a finished video with `export_video` to the user's destination and poll until it succeeds. Local paths must be absolute; media fields require `file:///` URLs. A saved project and an exported movie serve different purposes; choose the result the user requested.

If a necessary field is missing from the installed helper's schema, report that it requires an updated helper rather than attempting unsupported arguments. The project documents setup and typed commands in `docs/ai-native-editor.md`; the public schema is maintained in `ScreenTakeMCP/MCPToolCatalog.swift`.
