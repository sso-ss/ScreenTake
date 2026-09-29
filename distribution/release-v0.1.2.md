# Screen 0.1.2 - Test Build

An experimental test release for Apple Silicon Macs (M1 or newer), macOS 13 Ventura or later. Intel Macs are not supported.

## Changes

- Repeated clicks extend the current automatic zoom instead of restarting separate zoom-in/out animations.
- Nearby clicks keep the camera steady; distant clicks pan to the new target. Clicks during zoom-out resume from the current camera position.
- Adds Prism, Lagoon, Ember, and Midnight backgrounds.

## Checks and Limitations

- Local automated checks passed for repeated-click zoom, rendered zoom targets, webcam export timing, recording duration with pauses, saving, and bundled background images.
- This is a locally signed test build, not notarized by Apple. Installation on another Mac, physical microphone/camera reliability, and lip-sync have not been verified for this release. Make a short test recording before important use.
- A brief black webcam opening frame and intermittent microphone input stalls on some devices remain known limitations.
- Pause shortcuts are unchanged: Ctrl+Space works globally during recording, and plain Space pauses when Screen receives the key event. Escape stops recording. These may conflict with shortcuts used in other workflows.
- macOS may require granting recording, microphone, camera, and accessibility permissions again after updating. Quit and reopen Screen when prompted.

## Download and Install

Download **Screen-share-0.1.2-build3.zip**, quit Screen, extract the ZIP, and replace Screen.app in Applications. The ZIP contains only the compiled app and its runtime resources, not the development project or source files.

This build may be blocked on first launch because it is not notarized. Only if you trust this download, use **System Settings > Privacy & Security > Open Anyway**, if offered. Do not disable macOS security protections.

GitHub's automatically generated source archives contain only the download repository's public instructions and image, not Screen's app source. Use the app ZIP above.

Keep the previous app before replacing it. To roll back, quit Screen and restore that copy, or download v0.1.1 from the earlier release. Previous releases remain available.