# Canvas and Device Layouts

Choose **Canvas > Ratio** before recording, or adjust a recorded/imported video in **Edit Video**. Changes preview directly during playback and while paused. **Apply Changes** renders the finished video; save it using the download button.

Choose **Output > Resolution** independently of the canvas ratio, before recording or in Edit Video. **Preserve source** is the default. It expands the canvas enough for the captured content plus background margins or device frame at its original pixel scale. With no background, crop, or device frame, it keeps the source dimensions. Cropping preserves the selected pixels; zoom still enlarges a smaller portion and cannot recover detail absent from the recording.

| Ratio | 1080p | 4K |
| --- | --- | --- |
| Original | 1920-pixel long edge, source proportions | 3840-pixel long edge, source proportions |
| 16:9 | 1920 × 1080 | 3840 × 2160 |
| 16:10 | 1920 × 1200 | 3840 × 2400 |
| 1:1 | 1080 × 1080 | 2160 × 2160 |
| 4:5 | 1080 × 1350 | 2160 × 2700 |
| 9:16 | 1080 × 1920 | 2160 × 3840 |

Output shows the actual export dimensions and whether the screen will be reduced before zoom. Dimensions also appear above Apply Changes and Download. For a 3440 × 1440 recording on a 16:9 desktop canvas, Preserve source exports 3782 × 2128; its screen content remains at least 3440 × 1440. Source-preserving portrait canvases can be substantially larger than 4K. Choose a fixed preset when a smaller file or output dimension is needed.

HEVC recording masters and exports use bitrate budgets that scale with resolution and frame rate. Recording masters receive additional headroom for later editing; files may be larger. Timed imported camera overlays export from their full source resolution. Playback previews remain bounded separately.

- **Desktop** fits the source on the selected wallpaper without stretching.
- **iPhone** fits the source inside an iPhone-style frame. Import a portrait screen recording, or record an iPhone Mirroring / Simulator window on the Mac. This does not add direct USB or wireless iPhone capture.
- **Duo Closed** and **Duo Unfolded** are hidden for now. Their rendering code is retained for later; only Desktop and iPhone appear in device selectors. The experimental outer proportions follow Apple's HIG reference illustrations (554:778 closed, 1116:798 unfolded), not verified hardware pixel resolutions.
- **Crop Screen** opens after recording or importing a video in Desktop or iPhone layouts. Drag the corners to exclude title bars or existing bezels, drag the selection to move it, or adjust each inset by percentage. Reset restores the full source; Cancel discards the draft. Done updates the live preview; Apply Changes renders from the original source with the selected crop.
- **Fit** preserves the entire selected area with empty space when proportions differ. **Fill** fills the phone content area by cropping excess edges. Neither stretches the video or changes the frame proportions. The sheet previews a still frame, not animated zoom or webcam overlays.
- **Hide Browser Toolbar** is a Canvas toggle. Turn it on after recording or importing a browser video to detect and apply a crop; turn it off to restore the previous crop. New Edge, Chrome, and Safari window recordings retain the visible webpage bounds when macOS Accessibility is already available and the bounds match at the start and end; these bounds can exclude vertical tabs and sidebars. Without that metadata, local image analysis looks for macOS window controls, an address, and a toolbar boundary in three video frames. Uncertain or inconsistent detection leaves the crop unchanged and offers Crop Screen. This applies one fixed crop to the video; review it if browser controls change during the recording.
- Automatic cropping preserves any tighter manual crop and updates preview and export. Both toggle states support Undo/Redo. Applying a manual edit with Crop Screen switches the toggle off, leaving that manual crop in control. The original media is retained. Crops, the toolbar toggle’s restore point, and recorded browser bounds are saved in `.screenize` projects; a different import starts with its own settings.
- Ratios and visible device choices persist. Any previously saved Duo choice falls back to Desktop while Duo is hidden. The editable source association is kept only for the current app session.
- Apply Changes keeps the imported source for further changes during the session. Reopening an already exported video treats its frames as baked-in content.
- The live preview uses a maximum 2560-pixel long edge at 60 fps; export retains the selected output dimensions. Canvas, background, crop, Fit/Fill, and available cursor, zoom, and webcam settings update without exporting a file. Audio can be muted immediately. Recording-only controls are hidden in Edit Video, and reversible cursor/zoom/webcam edits require retained source data in the current session.

Tests: `test_canvas_sizes.swift`, `test_canvas_export.swift`, and `test_canvas_ui.swift` cover layout geometry, real video exports, original audio, orientation, legacy duo timing, cursor/zoom alignment, and native window previews.

`test_phone_crop.swift` covers crop coordinate conversion, drag limits, source isolation, layout serialization, Fit/Fill pixels, actual cropped exports, cursor alignment, and the native crop sheet for visible phone layouts. `test_canvas_ui.swift` also verifies hidden Duo selections fall back to Desktop.

`test_live_edit_preview.swift` checks the playback composition's actual frames for background, zoom, ratio, crop, webcam, cursor, and moving footage, plus native editor previews at normal and minimum window sizes.
`test_export_resolution.swift` verifies source-preserving sizing for ultrawide, Retina and portrait footage, crops, phone Fit/Fill, quality budgets, actual encoded fine detail, zoom and duration. Passing an original recording path also re-exports that take with its mouse, microphone and webcam sidecars, checks the original bytes remain unchanged, and verifies the resulting dimensions and audio.

`test_browser_crop.swift` covers browser-bound normalization (including Edge sidebars), light/dark toolbar and favorites-bar image detection, non-browser rejection, changing video layouts, undo/redo, repeated detection, saved projects, and backward compatibility.
