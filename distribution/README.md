# screen-recorder-mac

Download **ScreenTake**, a screen recording and editing app for macOS.

**Newest test build: [ScreenTake 0.1.9, build 10](https://github.com/sso-ss/screen-recorder-mac/releases/tag/v0.1.9)**

**[Download for Apple Silicon (DMG, recommended)](https://github.com/sso-ss/screen-recorder-mac/releases/download/v0.1.9/ScreenTake-0.1.9-build10.dmg)**

[Alternative ZIP download](https://github.com/sso-ss/screen-recorder-mac/releases/download/v0.1.9/ScreenTake-share-0.1.9-build10.zip)

Version 0.1.9 is an experimental test build, not a production-ready release. It improves Screen Recording permission requests and removes a misleading Xcode signing warning. It is not a verified fix for the reported screen-access failure on another Mac.

Screenshots from ScreenTake 0.1.8 build 9.

### Recording workspace

![ScreenTake recording workspace with canvas settings and background choices](screen-interface.png)

### Video editor

![ScreenTake video editor with a loaded preview, timeline, and canvas settings](screen-editor.png)

This is the download-only repository for ScreenTake. It contains installation instructions and packaged app releases, not the app's source code or development project. The installed app is named **ScreenTake**.

## What It Can Do

Use ScreenTake to record app demos, walkthroughs, tutorials, and presentations on your Mac.

- **Record your screen** with a choice of 30 or 60 FPS.
- **Capture audio** from your microphone, your Mac's system audio, or both.
- **Add a webcam overlay** with adjustable size, shape, position, rotation, and mirroring.
- **Highlight clicks with smart zoom** that automatically zooms in on clicked areas in your exported video.
- **Choose recording backgrounds**, including Prism, Lagoon, Ember, and Midnight.
- **Customize your recorded cursor** with Arrow, Hand, or Circle, a 50-300% size slider, and a visibility toggle. Apply Changes re-exports the current recording without changing your Mac's cursor.
- **Adjust zoom strength** from 1.25x to 3x for zoom-enabled recordings retained in the current editing session.
- **Use a native capture toolbar** that follows system appearance and accent color, with Liquid Glass on macOS 26 and system material on older versions.
- **Get update reminders** with release notes, Download Update, Remind Me Later, and Skip This Version. Checks run at most daily while ScreenTake is active and idle.
- **Edit on a visual timeline** by trimming, splitting, dragging clips to reorder them, and removing sections. Remaining clips close the gap automatically, and Undo restores timeline edits.
- **Review detected pauses** on the timeline before choosing which sections to remove.
- **Use consistent recording and editing controls** for cursor appearance, device layouts, and webcam settings.
- **Frame videos for different destinations** with landscape, square, and vertical canvases, device layouts, and built-in backgrounds.
- **Preview changes** inside the app before exporting recordings or imported video files.
- **Save recordings as MOV files** to share or use in your preferred video editor.

This is a test build. Recording behavior can vary by device and macOS version; make a short test recording before capturing anything important. Review detected pauses by listening to the preview before applying timeline edits.

Version 0.1.8 refines the editor controls, adds click-highlight colors and zoom focus controls, and expands webcam layout options. It retains the 60 FPS cursor export timeline and preview timing introduced in 0.1.7. Automated decoding checks confirm even preview frame timing; real-time preview smoothness across devices still needs verification. The app remains ScreenTake, with the existing bundle identifier and timeline features preserved. Cursor and zoom re-editing are limited to recordings retained in the current app session, not imported finished videos or recordings reopened after quitting. Editable video/audio sources are kept locally for re-export and consume disk space.

Smart zoom remains experimental; preview your exported recording before sharing. Actual multi-monitor recording, Liquid Glass on macOS 26, and installation on another Mac still need verification. Intermittent microphone input stalls on some devices and a brief black webcam opening frame remain known limitations.

## Requirements

- An Apple Silicon Mac (M1 or newer). This build does not support Intel Macs.
- macOS 13 Ventura or later.

## Download and Install

1. Open the [0.1.9 test release](https://github.com/sso-ss/screen-recorder-mac/releases/tag/v0.1.9).
2. Download **ScreenTake-0.1.9-build10.dmg** (recommended) under **Assets**, not GitHub's automatically generated source code archives.
3. Save your current recording, then quit all running Screen or ScreenTake copies. Keep a backup of your previous app until you have checked the new build.
4. Open the DMG and drag **ScreenTake.app** onto the **Applications** shortcut.
5. Eject **Install ScreenTake 0.1.9**, then open **ScreenTake** from your Applications folder.

Prefer a ZIP? Download **ScreenTake-share-0.1.9-build10.zip**, extract it, and move **ScreenTake.app** to Applications instead. Both downloads contain the same app.

## macOS Security Warning

This is a development build shared for testing. It is not notarized by Apple, so macOS may block it on first launch.

Only proceed if you trust the person who shared this app:

1. Try opening **ScreenTake** once.
2. Open **System Settings > Privacy & Security**.
3. Find the message about ScreenTake and click **Open Anyway**, if available.
4. Confirm the macOS prompt.

Do not disable macOS security protections. If no override is available or the app still will not open, report the exact message to the person who shared it.

## Permissions

Allow **Screen Recording** when prompted. On newer macOS versions, this setting may be called **Screen & System Audio Recording**.

If access still fails, quit all ScreenTake copies and confirm the installed app in Applications is enabled in this setting. Removing an old ScreenTake entry and re-adding the installed app may help with stale permissions, but this has not been confirmed as the cause of the reported failure. Reopen ScreenTake and make a short test recording.

Microphone and camera features also require **Microphone** and **Camera** access. You can manage these permissions in **System Settings > Privacy & Security**. Quit and reopen ScreenTake if macOS asks you to.

## Hotkey Guide

These shortcuts are active during recording:

| Shortcut | Action | Where it works |
| --- | --- | --- |
| Control + Z | Toggle manual zoom | System-wide, including while another app is focused |
| Control + Space | Pause or resume recording | System-wide, including while another app is focused |
| Escape | Stop recording | System-wide |
| Z | Toggle manual zoom | When ScreenTake receives keyboard input |
| Space | Pause or resume recording | When ScreenTake receives keyboard input |

**Watch for shortcut conflicts:** Control + Space may also be used to switch keyboard languages. Plain Space can accidentally pause a recording while ScreenTake is focused, and Escape can stop recording when you intended to dismiss something in another app. Use the toolbar's Play button to resume a paused recording.

Manual zoom toggles take priority over automatic click zoom for that recording. These shortcuts control the camera zoom, not macOS Undo.

When a recording preview is ready, **Command + S** opens the Save dialog in ScreenTake. To start recording, use the app's recording controls; Command + Shift + 2 is not connected to a working recording action in this build.

## Updates and Feedback

Starting with 0.1.3, the app can remind you about new releases. You can also choose **ScreenTake > Check for Updates...**. Download Update opens the GitHub release page; it does not install anything automatically. Reminders wait during capture selection, recording, and export.

Users on 0.1.2 or older must install a newer build manually once to receive future reminders. To update from Screen, save your recording, quit the old app, open the DMG, and drag ScreenTake.app into Applications. The ZIP remains available as an alternative. Keep your previous app or download an earlier release to roll back.

Report problems through this repository's **Issues** section. Include your macOS version, Mac model, release version, and what happened. Remove private information from screenshots and recordings before sharing them.