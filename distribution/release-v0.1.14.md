# ScreenTake 0.1.14 — Beta

Sharper screen detail, quicker editing after Stop, and a timeline that stays in sync.

**[Download ScreenTake 0.1.14 (build 16)](https://sso-ss.github.io/ScreenTake/downloads/ScreenTake-0.1.14-build16.dmg)** · Apple Silicon (M1 or newer) · macOS 13 Ventura or later

## What’s new

- Open the editor sooner after stopping. Effects render when you apply changes or download your finished video.
- Keep native screen detail, including odd-sized window captures, with original-size content placed at 1×.
- Keep the timeline ruler, playhead, and timestamp synchronized during playback and seeking.
- Save editable projects, work with separate recorded audio clips, and use browser-content cropping.
- Choose an app language independently of recording settings.
- Connect AI clients to the local editor to inspect, edit, save, and export an open project.
- Apply optional face-tracked camera beauty and makeup filters, with faster live previews.
- Find ScreenTake in the menu bar and see an update badge until the available release is installed.
- Keep the three-panel purple app icon, per-section camera layouts, smooth transitions, and microphone selection from earlier releases.

## Install and save

Save your work and quit ScreenTake. Open **ScreenTake-0.1.14-build16.dmg**, drag **ScreenTake.app** into **Applications**, eject the installer, and reopen the app. Update reminders open the release page; installation is manual.

Use **File → Save Project…** to retain source media, capture data, and edits in a `.screentake` project. Export a MOV to share the finished video. Imported finished videos do not include the original cursor and zoom capture data.

## Verification and beta notes

The release app is signed with **Developer ID Application: So Eun Ahn (43LSH32H5S)**. Apple accepted the signed DMG for notarization, its approval ticket is attached, and disk-image integrity, signature, and Gatekeeper checks passed. The website contains the exact same installer and its SHA-256 checksum.

One 31.280-second live screen/camera/microphone recording opened its editor 1.007 seconds after Stop while retaining native dimensions. This single measurement does not guarantee the same latency on other Macs, longer recordings, or recordings with face effects. See [recording latency validation](../docs/recording-latency-validation.md) for the measurement conditions.

Make a short test recording and review your exported video and audio before sharing. Device reliability and smart zoom are still being refined. Face tracking follows one visible face; longer clips may take a moment to prepare.

[Report an issue](https://github.com/sso-ss/ScreenTake/issues)
