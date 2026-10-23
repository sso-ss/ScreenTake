# Development checks

These standalone checks cover recording, editing, audio, camera, timeline, and export behavior. They are development sources and are not bundled with the app.

Run from the repository root so checks can find app sources, assets, and local build products:

```sh
python3 tools/run_swift_checks.py Tests/test_editor_session.swift
python3 tools/run_swift_checks.py --render-only Tests/test_video_trim.swift
python3 tools/run_swift_checks.py Tests/test_editor_mcp.swift
python3 tools/run_swift_checks.py Tests/test_updates.swift
python3 tools/run_swift_checks.py Tests/test_canvas_corners.swift
python3 tools/run_swift_checks.py Tests/test_long_import_export.swift
python3 tools/run_swift_checks.py Tests/test_timeline_interactions.swift
python3 tools/run_swift_checks.py Tests/test_zoom_motion.swift
python3 tools/run_swift_checks.py Tests/test_zoom_region.swift
python3 tools/run_swift_checks.py Tests/test_inspector_controls.swift
python3 tools/run_swift_checks.py Tests/test_voiceover.swift
```

Bare filenames also work, and the runner defaults to `test_editor_session.swift` when no checks are specified. `--render-only` skips optional screenshot checks in checks that support it. Some checks require recording permissions, hardware, a supplied clip, or a separately built app module.

`test_timeline_interactions.swift` checks Delete and Forward Delete routing for selected strips, modified-key handling, and protection for text fields and sliders.

`test_canvas_corners.swift` checks independent desktop/phone corner settings, older project defaults, and matching preview/export pixels for the phone frame, floating island, home indicator, and screen coverage in Fit and Fill.

`test_long_import_export.swift` exports 15-minute imported projects with 300 zoom sections and audio at 1080p, using both 30 fps and sparse 1 fps sources. It checks complete frame timing, zoom pixels, and audio duration, and reports memory use. Set `SCREENTAKE_STRESS_SECONDS=6` for a quick fixture or `SCREENTAKE_STRESS_FPS=30` to select one cadence. `test_editor_session.swift` also verifies render-file cleanup after trimming, audio processing, failure, and closing.

The MCP integration check runs `Tests/test_mcp_bridge.py` with its temporary helper. It verifies text creation/defaults, positioning, independent scaling, camera style enablement, custom background import, cutout shape, wallpaper presets, output-time cuts, shared Undo/Redo, portable persistence and text pixels in actual preview/export frames. For offline protocol checks against an existing Debug app helper, run `python3 Tests/test_mcp_bridge.py`; use `--bridge` to select a different helper.

Build ScreenTake first to resolve Sparkle. The runner links the resolved framework for updater checks. `test_updates.swift` covers persistent settings and badges, update safety policy, signed-feed configuration, and actual Objective-C delegate selectors. Installer integration tests use separate signed app copies and a localhost feed; see [distribution/UPDATES.md](../distribution/UPDATES.md).

The zoom motion check verifies Smooth, Linear, Ease In, and Ease Out in actual preview and exported frames, automatic clicks and recorded zoom markers, Undo/Redo, project persistence, and compatibility with older projects.

The zoom region check verifies box bounds and corner resizing, fixed focus with cursor data, imported portrait video without cursor data, cropped source coordinates, preview/export pixels at 2× and 6×, Undo/Redo, and project compatibility.

`test_custom_background.swift` checks image import and orientation, large-image resizing, invalid files, persistent recording settings, older projects, Undo/Redo, portable project saving, centered Fill cropping, and matching backgrounds in preview and exported video.

`test_text_overlay.swift` checks Unicode and multiline text, styling, opacity, independent scaling, project compatibility, Undo/Redo, portable saving, and text timing in actual preview/export frames, including gaps after reordering. It also checks shared text rows, overlap packing, bounded timeline height and scrolling, and renders the Text panel and timeline in light/dark appearances.

`test_voiceover.swift` checks preview/export audio timing, trimming, volume, mute and decoded waveforms. It also verifies shared voiceover rows, overlap packing, row reclamation after edits, and bounded timeline scrolling in light/dark appearances.

`test_inspector_controls.swift` checks exclusive camera styles and persisted preferences, independent Zoom and Auto Zoom settings, collapsed OFF sections, and light/dark camera controls. It also sends native mouse events through text selection and dragging, checking canvas coordinates, rotated text, layer order, timing and grouped Undo/Redo.
