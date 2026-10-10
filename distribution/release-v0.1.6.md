# ScreenTake 0.1.6 - Test Build

An experimental test release for Apple Silicon Macs (M1 or newer), macOS 13 Ventura or later. Intel Macs are not supported.

## What's New

- Screen is now called ScreenTake in the app, recording filenames, permission prompts, and update messages.
- The app bundle is now ScreenTake.app. The bundle identifier remains com.screen.Screen to retain existing app data and permissions where macOS allows.
- Recording and timeline editing features from 0.1.5 remain available. There is no AI control plugin in this release.

## Checks and Limitations

- The app builds with the local development signing identity. Automated checks cover update compatibility with both the old Screen ZIP names and the new ScreenTake ZIP name.
- This build is not notarized by Apple. Installation on another Mac, microphone/camera reliability, lip-sync, multi-monitor recording, and Liquid Glass on macOS 26 remain incompletely verified.
- Smart zoom is experimental. Some devices can have intermittent microphone stalls and a brief black webcam opening frame.
- Make a short test recording and review the exported result before important use.

## Download and Update

Download **ScreenTake-share-0.1.6-build7.zip**, quit Screen, extract the ZIP, and move ScreenTake.app to Applications. Remove the old Screen.app after confirming the new app works; do not keep both open at once.

The ZIP contains only the compiled macOS app and runtime resources, not app source code or the development project. This build may be blocked because it is not notarized. Only if you trust the download, use **System Settings > Privacy & Security > Open Anyway**, if offered. Do not disable macOS security protections. macOS may ask for permissions again.

Keep your previous app until you have tested this build. To roll back, quit ScreenTake and restore your previous copy, or download v0.1.5 from the earlier release.