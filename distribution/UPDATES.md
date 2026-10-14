# Publishing ScreenTake updates

ScreenTake 0.1.16 uses Sparkle 2.10.0. Older apps require one manual installation of 0.1.16. Automatic checks default to enabled; automatic downloads and installation on quit are opt-in in Settings → Updates.

Build with `SCREENTAKE_BUILD_CONFIGURATION=Release './Launch ScreenTake.command'`. The launcher signs every embedded Sparkle helper, then the framework and app, with the required Developer ID identity. Create the installer with `SCREENTAKE_NOTARY_PROFILE=SCREENTAKE ./distribution/build-dmg.sh .build/DerivedData/Build/Products/Release/ScreenTake.app release/ScreenTake-VERSION-buildBUILD.dmg`.

The update-signing private key is in macOS Keychain under the Sparkle account **ScreenTake**. Keep this key; never publish or export it into the repository. The matching public key is embedded in Screen/Info.plist. Both update archives and the appcast require Ed25519 signatures, and archive verification runs before extraction.

After verifying notarization, generate the feed from a directory containing the final DMG and an optional same-basename HTML notes file:

```sh
.build/SparkleTools/bin/generate_appcast --account ScreenTake --maximum-deltas 0 \
  --download-url-prefix https://sso-ss.github.io/ScreenTake/downloads/ \
  --embed-release-notes \
  --full-release-notes-url https://sso-ss.github.io/ScreenTake/release-notes.html \
  --link https://sso-ss.github.io/ScreenTake/ PATH_TO_ARCHIVES
.build/SparkleTools/bin/sign_update --account ScreenTake --verify PATH_TO_ARCHIVES/appcast.xml
```

Publish byte-identical copies of the verified DMG, checksum, and signed feed under the root and website folder. Never edit a signed appcast without signing it again. Increase CFBundleVersion for each future update. GitHub Pages serves the repository root. Also publish a normal GitHub Release for users of the older GitHub-based checker.

The updater defers checks during recording, processing, capture selection, and onboarding. Relaunch and quit additionally protect unsaved projects. A deferred restart can resume through Settings → Updates after saving; the Settings sheet closes before the installer resumes.

Run `python3 tools/run_swift_checks.py test_updates.swift` after building. Integration validation uses an isolated Developer ID signed older-version app copy, a signed localhost feed, and the production notarized DMG. Never change or replace the user's installed app during those tests.
