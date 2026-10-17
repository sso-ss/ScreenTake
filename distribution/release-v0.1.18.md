# ScreenTake 0.1.18 — Recording processing fix

ScreenTake 0.1.18 (build 20) is a beta for Apple Silicon Macs running macOS 13 or later.

**[Download the signed and notarized DMG](https://sso-ss.github.io/ScreenTake/downloads/ScreenTake-0.1.18-build20.dmg)** · [SHA-256 checksum](https://sso-ss.github.io/ScreenTake/downloads/ScreenTake-0.1.18-build20.dmg.sha256)

## What changed

- Finish trimmed-recording audio processing without encoding the finished video again when audio levels are unchanged. This avoids the stalled processing path and preserves rendered video quality.
- Show the processing stage after audio merging completes, so later work no longer stays labeled “Merging audio”.
- Delete the selected timeline strip immediately, use smoother drag previews, and choose zoom transition motion that is retained in saved projects.
- Include the current app source alongside the installer, including the updater and long-export improvements from previous releases.

## Install or update

ScreenTake 0.1.16 and later can update through **ScreenTake → Check for Updates…**. Save your editable project before updating. For a manual installation, quit ScreenTake, open the DMG, drag **ScreenTake.app** into **Applications**, and reopen it. Versions through 0.1.15 require a manual installation.

## Validation

- The affected recording completes the corrected final audio-processing step, retaining the compressed video samples exactly. Recovered video and audio were decoded through the end, and an export completed in the rebuilt app.
- Linked-audio checks cover timing, gaps, independent clips, preview/export agreement, Undo/Redo, and project save/reopen. Volume and voiceover checks cover level changes, muting, offsets, and trimming.
- The release uses **Developer ID Application: So Eun Ahn (43LSH32H5S)**, Apple notarization, and signed Sparkle update metadata. The GitHub and website installers use identical bytes and checksums.

## Beta notes

Make a short test recording and check the exported video and audio before sharing. Smart zoom and device reliability are still being refined. Save a `.screentake` project to retain original media and editable settings.
