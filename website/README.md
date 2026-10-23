# ScreenTake website

A separate redesign inspired by ElevenLabs’ spacious typography, neutral surfaces, rounded demo panels, and product-first layout. ScreenTake’s existing logo, purple accent, local screenshots, and media are retained. Gray surfaces use #F3F3F6, sampled from the supplied reference, on a white page. Main zoom, camera, timeline, and canvas features retain their image/demo cards. The AI introduction sits above six supporting feature cards, each using only a line icon, title, and description. Neutral demo stages, feature cards, and the closing panel share the same flat gray without tinted background gradients. Action buttons share the native CompactActionButtonStyle: a 6px corner radius (CornerRadius.md), purple primary fill, light-gray secondary fill, medium-weight labels, and pressed opacity.

The website is published from the repository root on GitHub Pages. Native app development is maintained separately from this publishing commit.

## Preview

From this worktree root:

```sh
python3 -m http.server 4187 --bind 127.0.0.1
```

Open http://127.0.0.1:4187/. The canonical source is `website/`; the root copies of `index.html`, `styles.css`, and `script.js` are byte-identical for the existing GitHub Pages publishing layout. The root and `/website/` versions both work. There is no package installation, build step, external font, analytics, or runtime CDN dependency.

## Layout and behavior

- Announcement, navigation, split hero, and a tab-free live editor preview. The 29-second guided loop uses a named ScreenTake cursor to change canvas format, choose a wallpaper, add and style text, switch camera layouts, and enable zoom. Direct input pauses the guide and edits the same DOM controls. Play restarts the walkthrough. Reduced-motion mode starts paused; offscreen, hidden-tab, or dialog-covered playback pauses. The full existing product film remains available from Watch the film.
- The main feature section keeps upright smart zoom, camera, and timeline illustrations, followed immediately by AI editing and the supporting feature cards. The interactive canvas/background preview follows that group. Smart zoom, camera layout, face tracking, optional filters, and manual zoom controls are described.
- A dedicated AI editing illustration explains the external client connection, shared native editor, and undo.
- Directly below AI, six image-free supporting cards cover screen/window capture, voiceover/linked audio, pause cleanup, browser cropping/phone frames, portable projects/export, and keyboard shortcuts. Supporting feature copy follows the 0.1.21 README and release notes. The live editor additionally reflects the latest local UI, including Text.
- Three-step guide, download invitation, native FAQ disclosures, and footer.
- Download dialog linked to the 0.1.21 build 23 DMG. Download links retain their destination without JavaScript or with a modifier key.
- Product film dialog with native video controls, synchronized companion audio, Escape/backdrop/close handling, playback reset, and focus restoration. The existing film is visual-only, so its local WAV companion supplies the sound.
- Responsive navigation at 860px, single-column layouts at 600px, visible keyboard focus, native modal focus containment, and reduced-motion support. The hero, zoom/cursor walkthrough, timeline editing walkthrough, and presenter clips animate automatically; the hero has a pause control and all respect reduced motion and visibility.
- Existing release notes use the new shared typography while retaining their release information and download links.

## Publishing

GitHub Pages serves `main` from the repository root. Keep root HTML, CSS, JavaScript, assets, release notes, downloads, checksums, and signed appcast byte-identical to their copies in `website/`. This release publishes the 0.1.21 build 23 notarized DMG. Never edit a signed update feed without signing it again.

## Verification

Verified the main image/demo cards and AI section with six supporting icon/title/description cards in the in-app browser. Desktop and mobile layouts have no horizontal overflow. The tab-free live editor has a manual play/pause control, and the existing download and full-film dialogs remain in place. Local asset/link and duplicate-ID checks, JavaScript syntax checks, root/website byte comparisons, and `git diff --check` pass.

## Live editor preview

`assets/editor-demo.html`, `.css`, and `.js` provide an isolated, dependency-free browser port of the current native interface. Source references are the primary checkout’s `Screen/Views/SettingsView.swift`, `Screen/Views/TextEditorPanel.swift`, `Screen/DesignSystem/DesignTokens.swift`, `Screen/Models/BackgroundStyle.swift`, and `Screen/Project/RenderSettings.swift`. This is a manually maintained web implementation, not the native SwiftUI runtime and not a recording of the app. It includes the updated Text panel, four-column wallpaper grid, six tool-rail panels, current inspector labels, native color tokens, and 6px actions. Toolbar, reset, playback, cursor, and inspector icons use consistent SVG paths rather than font-dependent symbols. The scaled iframe clips its outer document so focusing controls does not shift the editor; inspector scrolling remains available.

Automatic demonstration and manual input share state/render handlers. Ratio, wallpaper/custom image, phone frame, corner radius, text content/presets/typography, camera framing/mirroring, cursor styling, zoom, audio settings, and resolution controls update the preview. Import, recording, and final export remain native-app features; their preview buttons are disabled. Audio controls demonstrate settings silently. The local `demo-screen.mp4` comes from the existing Orbit asset. The user-supplied `1019(1).mov` provides the presenter video in the hero, camera feature card, and canvas preview: the top 160 pixels are cropped from the 1440 × 2560 source to remove its watermark, then encoded as a 576 × 960 H.264 MP4 (26.1 seconds, about 2 MB). Its audio stream is removed. `camera-presenter.jpg` is extracted from that cropped clip for the static poster. Both demo clips have no audio. No VEED footage is embedded.

The parent uses a same-origin message channel to pause/resume the guide. The child accepts messages only from its parent and the parent accepts only its iframe. The native editor and primary checkout have no code changes from this work.

The capability strip highlights native Mac support, screen + camera, text + voiceover, and AI client connection. The zoom card demonstrates a named cursor clicking, zooming, and returning to the full frame. The timeline demonstrates trimming a pause, moving a voiceover take, then playing through a twelve-second edit with a matching timecode. These are silent UI illustrations without card-level playback buttons; offscreen/hidden/dialog-covered playback stops and reduced-motion mode starts static. Direct smart-zoom input stops its guided motion.

The canvas camera overlay uses a 52px minimum in landscape and square previews; in 9:16 it grows to 28% of the frame width, with a 64px minimum, so the presenter remains readable.

Website supporting text is at least 12px and body copy is 16px on desktop and mobile. Labels inside the scaled native editor demonstration use at least 12px in its 1280px coordinate space.
