# Screen 0.1.5 - Test Build

An experimental test release for Apple Silicon Macs (M1 or newer), macOS 13 Ventura or later. Intel Macs are not supported.

## What's New

- Split clips stay adjacent on the timeline. Removing a section closes the gap automatically.
- Drag a clip earlier or later to change its position. An insertion marker shows where it will land; Move Earlier and Move Later are also available from the clip's context menu.
- Undo restores timeline changes, including clip order and removed sections.
- Preview and export follow the arranged clip order, keeping audio and recorded cursor, zoom, and webcam effects tied to their source footage.
- Recording and editing panels now share matching cursor, device layout, and webcam controls.
- Timeline thumbnails use precise source times to better reflect each clip.

## Checks and Limitations

- Automated checks cover native dragging in both directions, Undo, selection and gap-closing deletion, compact timeline layout, reordered video frames and audio samples, source/output seeking, and recorded effects in live preview.
- Keep the original recording and review the preview and exported result before sharing. Editing recorded cursor and webcam effects depends on source files retained in the current app session.
- This is a locally signed test build, not notarized by Apple. Installation on another Mac, physical microphone/camera reliability, lip-sync, real multi-monitor recording, and Liquid Glass on macOS 26 remain incompletely verified.
- Smart zoom is experimental. Some devices can have intermittent microphone stalls, and a brief black webcam opening frame remains a known limitation.
- Make a short test recording before important use.

## Download and Update

Download **Screen-share-0.1.5-build6.zip**, quit Screen, extract the ZIP, and replace Screen.app in Applications.

The ZIP contains only the compiled macOS app and runtime resources, not app source code or the development project. GitHub's automatically generated source archives contain only the download repository's public documentation and screenshot.

This build may be blocked because it is not notarized. Only if you trust the download, use **System Settings > Privacy & Security > Open Anyway**, if offered. Do not disable macOS security protections. macOS may request recording, microphone, camera, or accessibility permission again.

Keep your previous app before replacing it. To roll back, quit Screen and restore that copy, or download v0.1.4 from the earlier release. Previous releases remain available.