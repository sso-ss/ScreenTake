# ScreenTake 0.1.7 - Test Build

An experimental test release for Apple Silicon Macs (M1 or newer), macOS 13 Ventura or later. Intel Macs are not supported.

**[Download ScreenTake 0.1.7 (DMG, recommended)](https://github.com/sso-ss/screen-recorder-mac/releases/download/v0.1.7/ScreenTake-0.1.7-build8.dmg)**

[Alternative ZIP download](https://github.com/sso-ss/screen-recorder-mac/releases/download/v0.1.7/ScreenTake-share-0.1.7-build8.zip)

## What's New

- Adjust zoom strength from 1.25x to 3x in Edit Video for zoom-enabled recordings retained in the current session. Preview and export use the same value.
- Cursor-enabled exports use a fixed 60 FPS timeline to avoid uneven motion from variable-rate source recordings.
- Live preview now requests fixed 60 FPS timing, matching the cursor export cadence.
- Export progress updates throughout frame rendering, including static sections, instead of remaining at 0% until completion.

## Checks and Limitations

- Automated regression checks cover cursor positioning, zoom-follow alignment, preview edits, export duration, and intermediate progress updates.
- The recent 23.42-second recording decoded through the preview composition at 1,406 evenly spaced frames. This confirms frame timing, not real-time playback performance on every Mac.
- This build is not notarized by Apple. Installation on another Mac, real-time preview smoothness across devices, microphone/camera reliability, lip-sync, multi-monitor recording, and Liquid Glass on macOS 26 remain incompletely verified.
- Smart zoom is experimental. Intermittent microphone stalls on some devices and a brief black webcam opening frame remain known limitations.
- Cursor and zoom re-editing require the original recording data retained in the current app session. Imported finished videos do not regain editable cursor or zoom data.
- Make a short test recording and review the exported result before important use.

## Download and Update

Download **ScreenTake-0.1.7-build8.dmg** (recommended). Save your current recording before quitting all Screen or ScreenTake copies. Open the DMG, drag **ScreenTake.app** onto the **Applications** shortcut, then eject **Install ScreenTake** and launch the app from Applications. The app remains ScreenTake with bundle identifier com.screen.Screen.

**Alternative:** download **ScreenTake-share-0.1.7-build8.zip**, extract it, and move ScreenTake.app to Applications. Both downloads contain the same app; the ZIP also remains available for compatibility with existing update checks.

The packages contain the compiled macOS app, runtime resources, and installer presentation assets, not app source code, private recordings, or the iPhone prototype. Neither format is notarized. Only if you trust the download, use **System Settings > Privacy & Security > Open Anyway**, if offered. Do not disable macOS security protections. macOS may ask for permissions again.

Keep your previous app until you have tested this build. To roll back, quit ScreenTake and restore your previous copy, or download v0.1.6 from the earlier release.