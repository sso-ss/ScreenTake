# ScreenTake

ScreenTake is a native screen recorder and editor for Mac. Record your screen, then shape the video with cursor effects, smart zoom, backgrounds, a webcam overlay, and voiceover narration.

**Latest release: 0.1.10 (build 12)** · Apple Silicon (M1 or newer) · macOS 13 Ventura or later

[Visit the website](https://sso-ss.github.io/ScreenTake/) · [Download the DMG](https://github.com/sso-ss/ScreenTake/releases/download/v0.1.10/ScreenTake-0.1.10-build12.dmg) · [Release notes](https://github.com/sso-ss/ScreenTake/releases/tag/v0.1.10)

## See the app

### Edit and add your voice

![ScreenTake editor showing centered playback controls, a video timeline, original audio waveform, two narration takes, and separate original audio and voiceover volume controls](assets/editor.png)

The native editor in 0.1.10, shown with sample footage and narration. Record a voiceover while the video plays, then move or trim each take on its own audio strip.

### Set up a recording

![ScreenTake recording workspace showing canvas ratio, desktop and phone framing, corner radius, and built-in background choices](assets/recording.png)

Choose your canvas, background, cursor, camera, and audio settings before recording. The workspace above shows the recording preview with placeholder content.

## What you can do

| Area | Features in the Mac app |
| --- | --- |
| Screen capture | Choose a display or window; record at 30 or 60 FPS; pause, resume, and stop from the native capture toolbar or keyboard shortcuts. |
| Recording audio | Capture microphone audio, system audio, or both. Choose an available microphone. |
| Voiceover | Record narration while watching your video, starting at the playhead, or import an audio file. Move, trim, and remove individual takes. View original audio and narration waveforms. Adjust volume and mute separately for original audio and the voiceover group. |
| Timeline editing | Import a video or edit a new recording. Trim, split, remove sections, and drag clips to reorder them. Undo and redo timeline edits; zoom the timeline and scrub the preview. |
| Pause cleanup | Detect pauses, preview the suggestions, and choose which to remove. Undo restores removed sections. |
| Cursor and clicks | Show or hide the recorded cursor; choose Arrow, Hand, or Circle; adjust its size from 50–300%; enable click highlighting and choose its color. |
| Zoom | Use automatic click zoom or toggle manual zoom during recording. Add, move, trim, and remove zoom sections in the editor; adjust zoom strength and focus for eligible recordings. |
| Camera and overlays | Record a webcam overlay or import a video overlay. Adjust its shape, size, and position. |
| Canvas and framing | Choose Original, 16:9, 16:10, 1:1, 4:5, or 9:16. Use desktop or phone framing, adjust desktop corners, and crop phone content with Fit or Fill. |
| Backgrounds | Choose built-in wallpapers, including Prism, Lagoon, Ember, and Midnight. Toggle the background for an original-size desktop canvas. |
| Preview and export | Preview your edits, apply changes, and save a MOV file. Playback controls stay centered beneath the video. Recordings and editable source files stay on your Mac. |

Voiceover recording uses your Mac’s default microphone and mutes preview sound while recording. Takes keep their timeline positions when video clips change, so check narration alignment after rearranging your video.

## Install

1. Download the DMG on an Apple Silicon Mac.
2. If updating, save your work and quit ScreenTake first.
3. Open the DMG and drag **ScreenTake.app** into **Applications**.
4. Open ScreenTake and allow Screen Recording, Microphone, and Camera access when needed.
5. Make a short test recording and check the exported video and audio before sharing.

This build is signed with a Developer ID certificate and notarized by Apple. If macOS blocks the first launch, confirm you downloaded the current DMG and report the exact message. Do not disable macOS security protections.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Control + Z | Toggle manual zoom during recording. |
| Control + Space | Pause or resume recording. |
| Escape | Stop recording. |
| Command + S | Open the Save dialog when the recording preview is ready. |

The recording shortcuts work across apps. Plain Z and Space also toggle zoom and pause when ScreenTake has keyboard focus. Control + Space can conflict with macOS input-language switching; use the capture toolbar if needed.

## Current limitations and updates

- Smart zoom and recording reliability are still being refined. Some devices may experience microphone stalls or a brief black frame at the start of the webcam overlay. Check the exported result.
- Cursor and zoom re-editing need capture data retained in the current app session. Imported finished videos and recordings reopened after quitting do not restore that data.
- Editable source media uses local disk space. Saving a finished MOV does not preserve all capture data for later editing.
- Build 12’s built-in update checker and feedback shortcut still point to the previous repository. Use this repository’s [releases](https://github.com/sso-ss/ScreenTake/releases) and [issues](https://github.com/sso-ss/ScreenTake/issues) for current downloads and feedback. Installation is manual.

## Feedback

[Report an issue](https://github.com/sso-ss/ScreenTake/issues) with your Mac model, macOS version, ScreenTake version, and steps to reproduce the problem. Remove private information from screenshots and recordings before sharing them.

## Build from source (macOS)

The native Mac app source is in [`Screen/`](Screen/), with the Xcode project in [`Screen.xcodeproj/`](Screen.xcodeproj/). You need a Mac running macOS 13 or later and Xcode 15 or later.

Open `Screen.xcodeproj`, select the **Screen** scheme, and press **Run**. Or build from Terminal:

```sh
xcodebuild -project Screen.xcodeproj -scheme Screen -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The app asks macOS for Screen Recording, Microphone, and Camera permissions when those features are used. To regenerate the Xcode project from [`project.yml`](project.yml), install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and run `xcodegen generate`.

The downloadable release above is the Mac app.

## Open source

ScreenTake is released under the [MIT License](LICENSE). Contributions and feedback are welcome.

The screenshots show the native Mac app; website animations are demonstrations.
