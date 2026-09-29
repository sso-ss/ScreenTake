# ScreenTake for iPhone

Native iOS 18+ editor for recordings made with iPhone's built-in screen recording. Wallpaper images are shared read-only from the existing asset catalog.

## Current Workflow

- Import one video from Photos or Files.
- Preview, scrub, trim, and mute its audio.
- Choose original, 9:16, 1:1, or 16:9 framing; adjust padding and corners.
- Choose one of four bundled wallpapers or a white/black background.
- Add one timed zoom segment with smooth transitions and adjustable horizontal/vertical focus.
- Export MP4, save to Photos, or share to Files and other apps.
- Restore the current video and edits after relaunch. Importing another video replaces this single draft; there is no project library yet.

All processing stays on-device. Photos access is requested only when saving; import uses the system picker. Exports retain source audio unless muted. Fixed formats use 1080 x 1920, 1080 x 1080, or 1920 x 1080; original format preserves aspect ratio with an even-pixel longest edge of at most 1920. Output is SDR at up to 60 fps.

## Run

Open `iOS/ScreenMobile.xcodeproj`, choose the ScreenMobile scheme, choose an iPhone simulator, and run. Install the iOS runtime from Xcode Settings > Components if necessary. To run on a physical iPhone, choose your own development team in Signing & Capabilities first.

The project can be regenerated from the repository root without touching the Mac project:

```sh
xcodegen generate --spec iOS/project.yml --project iOS
```

## Checks

Run the pure editing checks on macOS:

```sh
swiftc iOS/ScreenMobile/EditSettings.swift iOS/Tests/EditSettingsChecks.swift -o /tmp/screen-mobile-settings-checks
/tmp/screen-mobile-settings-checks
```

Run ScreenMobile's tests in Xcode on an iPhone simulator. Video workflow tests generate a four-second recording with an audio tone and verify duration, output pixels, retained/muted audio, rotation, cancellation, invalid import handling, wallpaper availability, and draft restoration. The five video tests passed on iPhone 17 / iOS 26.2 and Mac Catalyst. The standalone editing checks also passed.

The interface test requires a video in the simulator's Photos library and Photos add access granted to `com.screen.mobile`. Seed those before running `ScreenMobileUITests`:

```sh
xcrun simctl addmedia booted /path/to/sample.mov
xcrun simctl privacy booted grant photos-add com.screen.mobile
```

The interface test passed on iPhone 17, covering Photos import, frame/background/zoom controls, portrait and landscape layout, export, and saving to Photos. It retains screenshots in the test results. Permission prompts and denial paths are not covered by that test. Tests replace the single draft with generated sample footage, so run them on a dedicated simulator, not a personal device with a draft you need.

On this machine, Xcode 26.3's iOS 26.2 SDK expects runtime build 23C57, but the downloaded runtime is 23C52. The simulator destination became available after `xcrun simctl runtime match set iphoneos26.2 23C52`. This is a local Xcode setting, not an app requirement; clear it with `xcrun simctl runtime match set iphoneos26.2 --default` after installing a matching runtime.

## Boundaries

This is a local development build, not an App Store or TestFlight release. It does not capture other apps, track touches, record camera overlays, or implement Duo-specific folding APIs. There is no production app icon or configured distribution signing yet. Device performance, HDR source footage, iCloud downloads, permission denial, and long exports need real-device testing. Keep Screen in the foreground during export.