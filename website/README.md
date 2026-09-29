# ScreenTake website

Open `index.html` in a browser. This is a standalone, responsive HTML/CSS/JavaScript page with no install step, build process, external fonts, or runtime CDN requests. GSAP 3.13.0 is vendored in `assets/gsap.min.js` (upstream license information is retained in the file).

The design uses ScreenTake's `#6C5CE7` accent, actual recording/editor screenshots, and Prism, Lagoon, Ember, and Midnight wallpapers. All presentation assets are local. The screen-and-play mark in `assets/mark.svg` is shared with the native Mac app icon and welcome screen. Run `swift tools/generate_app_icon.swift` from the repository root after changing it to refresh the native assets.

Website typography has a 10px minimum at every breakpoint, with most supporting text at 12–15px. Darker text colors and stronger purple surfaces improve legibility. Text within the app screenshots is part of the original image.

The capability strip is a full-width white band directly below the purple hero, with bold 18px labels and larger purple icons on desktop, 16px labels on narrower screens, and a two-column layout with 15px labels on mobile. Sections and feature cards lead with their headings, without small overline labels above them.

The page flows from hero and capability strip to workflow, features, framing, download, setup guide, beta help, and footer. Major sections use 80px vertical padding (64px on mobile). Related sections share content-width hairline dividers with 48px on each side (32px on mobile): features with framing, and setup with beta help. The guide and help share the page's quiet white surface; full-width color changes distinguish the workflow demo and download invitation.

The webcam feature card uses a local presenter photo in a large, upright frame that gently morphs between rounded-square and circle while the surrounding ripples expand. The photo itself stays still and neither the frame nor caption tilts. Motion pauses offscreen, with the page motion toggle, and for reduced-motion visitors.

Click highlighting and camera presentation share a row. Audio capture and post-recording narration share one sound surface, with a divider, matching headings, and coordinated waveform and timeline illustrations. The sound group stacks vertically on phones.

The Edit workflow image (`assets/editor.png`, 1400×850) is a fresh capture of the current native editor using generated sample footage and two imported narration samples. It shows the updated branding, full sidebar, original audio waveform, separate voiceover strips, and independent volume controls. Its caption identifies the 0.1.10 build; playback is centered beneath the video. Update the image cache version in `script.js` when replacing this screenshot.

The download invitation closes the product story immediately after framing, before the longer setup guide and beta help. It uses two left-aligned columns: headline and description on the left, download button and compatibility note on the right. It has no app icon and stacks on mobile with a divider between the groups.

Included interactions: keyboard-accessible workflow tabs, cursor style/size preview, background/format preview, mobile navigation, expandable beta help, and download details. Interactive illustrations demonstrate the design controls; they do not record or edit video in the browser.

The hero's "Explore the workflow" link opens `assets/screentake-promo.mp4` in a responsive video dialog with playback controls. Playback starts on opening and stops/resets when closed using the close button, Escape, or backdrop. Focus returns to the link on close. Without JavaScript, the link opens the video directly. The video uses `preload="none"` to avoid loading it before interaction. Keep this video with the website assets when publishing.

The design-review pass puts Record / Edit / Export after the hero and capability strip, with Edit selected to surface timeline editing. The hero contains the headline and download and promo-video links; the interactive app replica has been removed. The video-framing playground uses an original skeleton mock screen with placeholder shapes instead of written content. Framing changes the output canvas aspect ratio while keeping that scene in proportion; smart zoom visibly magnifies its content. A floating motion switch lives in the bottom-right corner on desktop and mobile, labeled "Turn off motion" or "Turn on motion". It controls the ambient loops and stays hidden for reduced-motion visitors. Navigation collapses at 1000px. Setup troubleshooting and the remaining FAQs are consolidated under Beta help.

The hero uses a lightweight local WebGL shader for softly tinted flowing lilac light and plum shadows, inspired by the organic motion on microsoft.ai rather than circular ripples. Mouse movement gently bends the field and eases away on exit; touch devices keep the ambient flow. GSAP drives the seamless loop and pointer smoothing. Rendering pauses offscreen, in background tabs, or with the shared Pause animations control. Reduced motion and unavailable WebGL leave a static gradient. Decorative layers never intercept controls. The camera illustration also loops between circular and rounded-square frames with a gentle sideways shift.

The “How to use” section (`#how-to-use`) covers installation, permissions, capture setup, a first test recording, editing, and saving. Expandable help includes first-launch instructions, shortcut scope/conflicts, beta limitations, updates, and a GitHub feedback link. Keep these instructions aligned with the distribution README as the beta changes.

Page motion includes a staggered hero entrance, one-time scroll reveals, workflow and canvas transitions, a download-dialog entrance, and subtle hover feedback. Five feature illustrations loop: independently pulsing audio bars, a pointer roaming within its canvas, an Arrow/Hand/Circle cursor cycling through sizes, a separate click-highlight card cycling through six colors, and expanding/fading camera ripples. Hovering or focusing the cursor card pauses its preview for manual control. Loops pause offscreen or in a background tab; the Pause animations button controls all five. Pointer bounds recalculate on resize. GSAP matchMedia scopes and reverts page animations when reduced motion is enabled. Content remains visible without JavaScript. Feature cards use layered lavender, plum, and peach gradients with soft shade overlays behind their content.

This website describes 0.1.10 build 12 and downloads the matching locally signed DMG from `downloads/ScreenTake-0.1.10-build12-local.dmg`. Release notes live in `release-notes.html`. The installer includes the centered playback controls. The installer is included with the website so its download link works when the site is published. The same DMG is attached to the v0.1.10 GitHub prerelease.

This page is a ScreenTake adaptation of the earlier CleanShot reference study. The original study remains in `/Users/sso/output/cleanshot-screen-recording/` for comparison. The native editor also centers its transport controls independently of the edit and zoom tools.

The Record workflow tab is the initial view and animates a demonstration cursor, click ring, recording timer, and audio meter over the recording workspace. This is an illustration, not a live browser recording. It pauses on another tab, offscreen, in a background browser tab, with the page motion switch, and for reduced-motion visitors.

The voiceover preview loops over a ten-second recording: the playhead and timer advance together while each narration take is revealed in its matching lane position. The loop pauses offscreen, in a hidden tab, and through the page motion switch. Reduced-motion mode restores both complete takes and a static midpoint playhead.
