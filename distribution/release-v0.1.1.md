# Screen 0.1.1 - Test Build

Requires an Apple Silicon Mac (M1 or newer) running macOS 13 Ventura or later. Intel Macs are not supported by this build.

## Changes

- Keeps the webcam updating while the screen is static, during zoom animation, and through the end of exported videos.
- Replaces the black screen at the start of new recordings with the first captured screen image without shifting the recording timeline.
- Preserves the stable local signing identity used by the previous download.

## Verification and Known Limitations

- Webcam timeline, opening-frame, recording-duration, audio sample-preservation, and save checks passed locally.
- Recent local recordings passed checks for clipping and repeated audio. Microphone behavior varies by device; intermittent Insta360 input-delivery stalls remain under investigation. Make a short test recording before important use.
- The webcam circle can still be black for roughly the first 0.04-0.07 seconds.
- An automated click-zoom test still fails: closely spaced clicks can make the view return to an earlier target. Disable automatic zoom when reliable framing is essential.
- This is a locally signed development test build, not notarized by Apple. Installation and recording on another Mac have not been verified. Lip-sync has not been independently verified.

## Install or Update

Download the **Screen-share-0.1.1-build2.zip** asset, quit Screen, unzip the download, and replace Screen.app in Applications. Keep a copy of the previous app if you need to roll back.

Do not download GitHub's automatic source code archives; this is a download-only repository. See the repository README for macOS security prompts and recording permissions. Do not disable macOS security protections.

The previous v0.1.0 download remains available under Releases.