# Screen 0.1.4 - Test Build

An experimental test release for Apple Silicon Macs (M1 or newer), macOS 13 Ventura or later. Intel Macs are not supported.

## What's New

- Edit the current recording on a visual timeline: trim the beginning or end, split at the playhead, remove selected sections, undo timeline edits, and preview the result before export.
- Find quiet pauses using adjustable silence settings, then review each suggestion on the timeline before choosing what to remove. Screen does not delete detected pauses automatically.
- Choose landscape, square, or vertical canvases with built-in backgrounds and device layouts. Preview layout changes before applying them.
- Timeline, canvas, smart zoom, cursor, and background changes now render together in a sharper single export pass.
- Capture selection is more dependable, and recording waits for a usable first frame instead of accepting a stale or blank frame.
- Cursor movement stays smooth in exported videos even when the screen content is static, with more consistent pointer sampling during recording.

## Checks and Limitations

- Automated checks cover timeline edits, trimming, silence suggestions, preview timing, canvas output, single-pass zoom quality, capture selection, initial-frame readiness, cursor timing, and static-screen cursor motion.
- Timeline edits and silence detection should still be reviewed by listening to the preview before export. Detection does not understand speech or intent.
- Editing is designed around the current recording session. Keep the original recording until you have checked the exported result.
- This is a locally signed test build, not notarized by Apple. Installation on another Mac, physical microphone/camera reliability, lip-sync, and real multi-monitor recording remain incompletely verified.
- Some devices can have intermittent microphone stalls, and a brief black webcam opening frame remains a known limitation.
- Make a short test recording and preview the result before important use.

## Download and Update

Download **Screen-share-0.1.4-build5.zip**, quit Screen, extract the ZIP, and replace Screen.app in Applications.

The ZIP contains only the compiled app and runtime resources, not app source code or the development project. GitHub's automatically generated source archives contain only the download repository's public documentation and screenshot.

This build may be blocked because it is not notarized. Only if you trust the download, use **System Settings > Privacy & Security > Open Anyway**, if offered. Do not disable macOS security protections. macOS may request recording, microphone, camera, or accessibility permission again.

Keep your previous app before replacing it. To roll back, quit Screen and restore that copy, or download v0.1.3 from the earlier release. Previous releases remain available.