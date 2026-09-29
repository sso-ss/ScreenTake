# ScreenTake 0.1.8 - Test Build

An experimental test release for Apple Silicon Macs (M1 or newer), macOS 13 Ventura or later. Intel Macs are not supported.

**[Download ScreenTake 0.1.8 (DMG, recommended)](https://github.com/sso-ss/screen-recorder-mac/releases/download/v0.1.8/ScreenTake-0.1.8-build9.dmg)**

[Alternative ZIP download](https://github.com/sso-ss/screen-recorder-mac/releases/download/v0.1.8/ScreenTake-share-0.1.8-build9.zip)

## What's New

- Refined recording and editing panels, including click-highlight colors and zoom focus controls on the timeline.
- Expanded webcam options with rotation, mirroring, circle or rounded-square overlays, and more placement choices. Preview and export use the chosen shape.
- Aligned desktop canvas corner rounding between preview and export.

## Checks and Limitations

- Built for arm64 with the Screen Local Development signature. Both installer formats contain the same signed ScreenTake 0.1.8 build 9 app; the DMG and ZIP integrity checks passed.
- The canvas UI check passed. Hardware capture and installation on another Mac have not been verified for this build.
- This app is not notarized by Apple. Real-time preview smoothness across devices, microphone/camera reliability, lip-sync, multi-monitor recording, and Liquid Glass on macOS 26 remain incompletely verified.
- Smart zoom is experimental. Intermittent microphone stalls on some devices and a brief black webcam opening frame remain known limitations.
- Cursor and zoom re-editing require the original recording data retained in the current app session. Imported finished videos do not regain editable cursor or zoom data.
- Make a short test recording and review the exported result before important use.

## Download and Update

Download **ScreenTake-0.1.8-build9.dmg** (recommended). Save your current recording and quit all Screen or ScreenTake copies. Open the DMG, drag **ScreenTake.app** onto the **Applications** shortcut, eject **Install ScreenTake 0.1.8**, then launch the app from Applications.

**Alternative:** download **ScreenTake-share-0.1.8-build9.zip**, extract it, and move ScreenTake.app to Applications. The ZIP remains available for existing update checks.

These packages contain the compiled macOS app, not app source code, private recordings, or the iPhone prototype. Only if you trust the download, use **System Settings > Privacy & Security > Open Anyway**, if offered. Do not disable macOS security protections. macOS may ask for permissions again.

Keep your previous app until you have tested this build. To roll back, quit ScreenTake and restore your previous copy, or download v0.1.7 from the earlier release.