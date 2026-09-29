# Screen 0.1.3 - Test Build

An experimental test release for Apple Silicon Macs (M1 or newer), macOS 13 Ventura or later. Intel Macs are not supported.

## What's New

- Choose Arrow, Hand, or Circle cursors, adjust size from 50-300%, or hide the cursor. These settings affect the video, not your Mac's cursor.
- Apply Cursor re-exports the current recording from its clean source, preserving audio. Editing is limited to the current app session; imported finished videos and recordings reopened after quitting do not support this.
- Daily update reminders include release notes, Download Update, Remind Me Later, and Skip This Version. A manual Check for Updates command is in the Screen menu. Download opens GitHub, not an automatic installer; reminders wait during capture selection, recording, and export.
- Capture toolbar shadows no longer hit the window edges. The toolbar follows system light/dark mode, accent color, and accessibility preferences, with native Liquid Glass on macOS 26 and system material on older versions.
- Display clicks resolve the monitor under the pointer instead of a stale hover target. Returning to the toolbar preserves the target, and Record no longer silently falls back to another display or window.

![Screen with the new cursor controls](https://raw.githubusercontent.com/sso-ss/screen-recorder-mac/main/screen-interface.png)

## Checks and Limitations

- Automated checks cover cursor images and exported pixels, size and hiding, repeated-export audio retention, update-reminder behavior, simulated monitor layouts, and toolbar shadow boundaries. Native UI previews were checked locally.
- Actual multi-monitor recording, Liquid Glass on macOS 26, and installation on another Mac remain unverified. Accessibility preference behavior has not been fully tested end to end.
- This is a locally signed test build, not notarized by Apple. Physical microphone/camera reliability and lip-sync remain unverified; some devices can have intermittent microphone stalls, and a brief black webcam opening frame is a known limitation.
- Editable recording sources and separate audio files are retained locally for cursor re-export and consume disk space. No new automatic cleanup is included.
- Pause shortcuts are unchanged: Control + Space works globally, plain Space pauses when Screen receives keyboard input, and Escape stops recording. These can conflict with other workflows.
- Make a short test recording and preview the result before important use.

## Download and Update

Download **Screen-share-0.1.3-build4.zip**, quit Screen, extract the ZIP, and replace Screen.app in Applications. Users on 0.1.2 or older must install this update manually once to receive future reminders.

The ZIP contains only the compiled app and runtime resources, not app source code or the development project. GitHub's automatically generated source archives contain only the download repository's public documentation and screenshot.

This build may be blocked because it is not notarized. Only if you trust the download, use **System Settings > Privacy & Security > Open Anyway**, if offered. Do not disable macOS security protections. macOS may request recording, microphone, camera, or accessibility permission again.

Keep your previous app before replacing it. To roll back, quit Screen and restore that copy, or download v0.1.2 from the earlier release. Previous releases remain available.