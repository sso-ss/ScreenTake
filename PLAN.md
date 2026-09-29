# Screenize Clone — Implementation Plan

> **Goal:** Build a macOS screen recording app with auto-zoom, cursor effects, timeline editing, and polished video export — a Screen Studio alternative.

---

## Reusable Code from mockup-tool

After analyzing `/Users/sso/Desktop/Claude/Double/mockup-tool`, here's the assessment:

### ❌ Not Reusable (Different Tech Stack)
The mockup-tool is a **web-based HTML/CSS/JS** screenshot mockup tool. The Screenize clone is a **native macOS Swift/SwiftUI app**. The core code (screen capture, video recording, timeline editing, Metal rendering) cannot be reused — they're entirely different technologies.

### ⚠️ Design Concepts Worth Porting (Visual Reference Only)

| mockup-tool Feature | Screenize Use | How to Port |
|---|---|---|
| **macOS window chrome** (`.browser-window`, `.titlebar`, `.traffic-lights`) | Window-mode background styling in exported videos | Replicate the visual design in `WindowModeRenderer.swift` using CoreImage — rounded corners, shadow, title bar gradient (`#3a3a3c → #2c2c2e`), traffic light colors (`#ff5f57`, `#febc2e`, `#28c840`) |
| **Wallpaper gradients** (8 presets: Sonoma, Aurora, Sunset, Ocean, Blossom, Nebula, Moss, Dusk) | Background presets for the `BackgroundStyle` model | Copy the exact CSS gradient values as `BackgroundStyle.preset` cases — each is a combination of 3-4 radial gradients + a linear gradient base |
| **Terminal themes** (Dark, Pro, Homebrew, Ocean, Dracula, Solarized) | N/A for Screenize (no terminal rendering) | Not applicable |
| **Color palette** (`#1c1c1e`, `#2c2c2e`, `#3a3a3c`, `#48484a`, `#636366`, `#98989d`, `#e5e5ea`) | DesignSystem colors — these are native macOS dark mode system grays | Use directly in `DesignColors.swift` |
| **Control panel styling** (glassmorphic sidebar, section cards, swatches) | Inspector panel visual style | SwiftUI equivalent: `.background(.ultraThinMaterial)`, grouped sections |

### ✅ Directly Portable Values

**1. Wallpaper gradient presets** → `BackgroundStyle.swift`
```swift
// From mockup-tool CSS, converted to Swift
enum WallpaperPreset {
    case sonoma   // radial(20% 50% #6a3de850) + radial(80% 20% #f472b640) + radial(60% 80% #38bdf840) + linear(160deg #1e1b4b → #0f172a)
    case aurora   // radial(10% 0% #22d3ee50) + radial(50% 10% #a78bfa40) + radial(90% 30% #34d39940) + linear(180deg #0c0a1a → #042f2e)
    case sunset   // radial(80% 80% #f97316a0) + radial(20% 60% #ec489960) + radial(60% 30% #eab30840) + linear(150deg #1c1917 → #1e1b4b)
    case ocean    // radial(70% 20% #0891b250) + radial(20% 80% #6366f150) + radial(90% 80% #14b8a630) + linear(170deg #020617 → #064e3b)
    case blossom  // radial(30% 20% #f9a8d450) + radial(70% 70% #c4b5fd50) + linear(135deg #fdf2f8 → #ede9fe)
    case nebula   // radial(60% 40% #7c3aed60) + radial(20% 70% #ec489950) + radial(85% 75% #3b82f640) + linear(135deg #0a0a0f → #0f0518)
    case moss     // radial(25% 30% #4ade8050) + radial(75% 60% #22d3ee40) + linear(160deg #022c22 → #0c1a0f)
    case dusk     // radial(50% 0% #f472b640) + radial(10% 60% #818cf850) + radial(90% 50% #c084fc40) + linear(180deg #1e1338 → #0f172a)
}
```

**2. Window chrome dimensions** → `WindowModeRenderer.swift`
```swift
// From mockup-tool CSS
let titleBarHeight: CGFloat = 52
let tabBarHeight: CGFloat = 36
let trafficLightSize: CGFloat = 12
let trafficLightGap: CGFloat = 8
let titleBarGradient = (top: Color(hex: "#3a3a3c"), bottom: Color(hex: "#2c2c2e"))
let windowCornerRadius: CGFloat = 12
let windowShadow = (blur: 60, opacity: 0.35)  // box-shadow: 0 25px 60px rgba(0,0,0,0.35)
```

**3. Color system** → `DesignColors.swift`
```swift
// macOS dark mode grays from mockup-tool
static let windowBackground = Color(hex: "#1c1c1e")
static let controlBackground = Color(hex: "#2c2c2e")
static let separatorColor = Color(hex: "#1a1a1c")
static let inputBackground = Color(hex: "#3a3a3c")
static let inputBorder = Color(hex: "#48484a")
static let tertiaryLabel = Color(hex: "#636366")
static let secondaryLabel = Color(hex: "#98989d")
static let primaryLabel = Color(hex: "#e5e5ea")
```

### 📋 Summary

| Category | Reusable? | Effort to Port |
|---|---|---|
| Core logic (JS → Swift) | ❌ No | N/A |
| Screen capture code | ❌ No (uses web APIs) | N/A |
| Wallpaper gradient values | ✅ Yes (8 presets) | 30 min |
| Window chrome design specs | ✅ Yes (dimensions, colors) | 30 min |
| Dark mode color palette | ✅ Yes (8 colors) | 15 min |
| Panel/control UI patterns | ⚠️ Visual reference only | Reimplemented in SwiftUI |

**Bottom line:** The mockup-tool gives you **design values** (gradient presets, window chrome specs, and a color palette) but no reusable code. The useful bits save about **1 hour** of design work in Phase 1 (DesignSystem) and Phase 6 (Background Styling).

---

## Architecture Overview

```
Screen/
├── Screen.xcodeproj
├── Screen/
│   ├── App/                        # Phase 1
│   │   ├── ScreenApp.swift         # @main entry point
│   │   ├── AppState.swift          # Global state singleton (@MainActor)
│   │   ├── AppDelegate.swift       # NSApplicationDelegate for file open
│   │   ├── CaptureSettings.swift   # Audio/video capture preferences
│   │   ├── RecordingState.swift    # Recording lifecycle state
│   │   ├── NavigationState.swift   # UI navigation state
│   │   └── Log.swift               # Unified logging (os.Logger)
│   │
│   ├── Models/                     # Phase 1
│   │   ├── CaptureTarget.swift     # display/window/region enum
│   │   ├── CaptureMode.swift       # entireScreen / window enum
│   │   └── BackgroundStyle.swift   # solid/gradient/image background
│   │
│   ├── Core/                       # Phase 1–2
│   │   ├── Capture/
│   │   │   ├── ScreenCaptureManager.swift    # SCStream wrapper
│   │   │   ├── CaptureConfiguration.swift    # width/height/fps/codec config
│   │   │   └── PermissionsManager.swift      # Screen recording + accessibility
│   │   │
│   │   ├── Recording/
│   │   │   ├── RecordingCoordinator.swift     # Orchestrates capture + mouse + mic
│   │   │   ├── RecordingSession.swift         # State machine (idle→preparing→recording→stopping)
│   │   │   ├── VideoWriter.swift              # AVAssetWriter wrapper (HEVC/H.264)
│   │   │   ├── VFRRecordingManager.swift      # Variable frame rate recording
│   │   │   ├── MouseDataRecorder.swift        # Mouse position + click sampling
│   │   │   ├── MicrophoneRecorder.swift       # AVCaptureSession mic recording
│   │   │   ├── SystemAudioWriter.swift        # System audio sidecar (.m4a)
│   │   │   └── EventStreamWriter.swift        # Poly-format event JSON writer
│   │   │
│   │   ├── Tracking/
│   │   │   ├── AccessibilityInspector.swift   # AX API for UI element detection
│   │   │   └── EventMonitorManager.swift      # Centralized CGEvent monitors
│   │   │
│   │   └── EventMonitoring/
│   │       ├── KeyboardEventHandler.swift
│   │       ├── ScrollEventHandler.swift
│   │       └── DragEventHandler.swift
│   │
│   ├── Project/                    # Phase 2
│   │   ├── ScreenizeProject.swift  # Main project model (Codable)
│   │   ├── PackageManager.swift    # .screenize bundle CRUD
│   │   ├── ProjectManager.swift    # Save/load/recent projects
│   │   ├── ProjectCreator.swift    # Factory from recording or video
│   │   ├── MediaAsset.swift        # Video + mouse data paths
│   │   ├── RenderSettings.swift    # Codec, quality, resolution, background
│   │   ├── CaptureMeta.swift       # Display bounds, scale factor
│   │   └── InteropBlock.swift      # Event stream locations
│   │
│   ├── Timeline/                   # Phase 3
│   │   ├── Timeline.swift          # Tracks array + trim range
│   │   ├── Track.swift             # CameraTrack, CursorTrackV2, KeystrokeTrackV2, AudioTrack
│   │   ├── Segments.swift          # CameraSegment, CursorSegment, KeystrokeSegment, AudioSegment
│   │   ├── Keyframe.swift          # TransformKeyframe, CursorStyleKeyframe, etc.
│   │   └── EasingCurve.swift       # Easing functions (linear, easeIn, spring, etc.)
│   │
│   ├── Generators/                 # Phase 4
│   │   ├── SmartGeneration/
│   │   │   ├── Analysis/
│   │   │   │   ├── EventTimeline.swift       # Unified event stream
│   │   │   │   └── IntentClassifier.swift    # User intent detection
│   │   │   ├── Planning/
│   │   │   │   └── ShotPlanner.swift         # Zoom shot plan from intents
│   │   │   ├── Emission/
│   │   │   │   ├── CursorTrackEmitter.swift
│   │   │   │   └── KeystrokeTrackEmitter.swift
│   │   │   └── Types/
│   │   │       ├── UserIntent.swift
│   │   │       └── TimedTransform.swift
│   │   │
│   │   └── SegmentCamera/
│   │       ├── SegmentCameraGenerator.swift  # Main generation entry point
│   │       ├── SegmentPlanner.swift          # Intent → camera segments
│   │       └── SegmentSpringSimulator.swift  # Spring-based smooth transitions
│   │
│   ├── Render/                     # Phase 5
│   │   ├── ExportEngine.swift              # Export orchestrator
│   │   ├── ExportEngine+VideoExport.swift  # MP4/MOV export
│   │   ├── ExportEngine+GIFExport.swift    # GIF export
│   │   ├── FrameEvaluator.swift            # Evaluate timeline state at time T
│   │   ├── Renderer.swift                  # CoreImage + Metal compositing
│   │   ├── RenderContext.swift             # CIContext + Metal + pixel buffer pool
│   │   ├── RenderCoordinator.swift         # Background render scheduling
│   │   ├── RenderPipelineFactory.swift     # Factory for evaluator + renderer
│   │   ├── PreviewEngine.swift             # Real-time preview with caching
│   │   ├── VideoFrameExtractor.swift       # AVAssetImageGenerator wrapper
│   │   ├── TransformApplicator.swift       # Zoom/pan transform math
│   │   ├── EffectCompositor.swift          # Cursor + keystroke overlay
│   │   ├── WindowModeRenderer.swift        # Background + shadow for windows
│   │   ├── SpringCursorSimulator.swift     # Damped spring cursor smoothing
│   │   └── AudioMixer.swift               # Mix system + mic audio
│   │
│   ├── Views/                      # Phase 1–5 (parallel with each phase)
│   │   ├── ContentView.swift               # Root view (welcome vs editor)
│   │   ├── MainWelcomeView.swift           # Landing screen
│   │   ├── PermissionSetupWizardView.swift # First-launch permissions
│   │   ├── EditorMainView.swift            # HSplitView: preview + timeline + inspector
│   │   ├── PreviewView.swift               # Metal-backed video preview
│   │   │
│   │   ├── Recording/
│   │   │   ├── CaptureToolbarPanel.swift   # Floating NSPanel for record UI
│   │   │   ├── CaptureToolbarView.swift    # SwiftUI toolbar content
│   │   │   ├── CaptureOverlayController.swift # Screen/window highlight overlays
│   │   │   └── CountdownPanel.swift        # 3-2-1 countdown
│   │   │
│   │   ├── Timeline/
│   │   │   ├── TimelineView.swift          # Multi-track timeline
│   │   │   ├── TimelineView+SegmentBlock.swift
│   │   │   ├── TimelineView+Gestures.swift # Drag/resize segments
│   │   │   ├── TimelineView+MultiMove.swift
│   │   │   └── TimeRulerView.swift         # Time ruler with ticks
│   │   │
│   │   ├── Inspector/
│   │   │   ├── InspectorView.swift         # Right panel: segment properties
│   │   │   └── InspectorView+SegmentBindings.swift
│   │   │
│   │   ├── Export/
│   │   │   ├── ExportView.swift            # Export sheet
│   │   │   └── ExportView+Settings.swift   # Codec/quality/resolution pickers
│   │   │
│   │   └── Settings/
│   │       └── GenerationSettingsView.swift # Smart generation tuning
│   │
│   ├── ViewModels/                 # Phase 3–5
│   │   ├── EditorViewModel.swift                   # Timeline editing state
│   │   ├── EditorViewModel+SegmentOperations.swift # Add/delete/update segments
│   │   ├── EditorViewModel+SmartGeneration.swift   # Generate button logic
│   │   ├── EditorViewModel+Clipboard.swift         # Copy/paste/duplicate
│   │   └── PermissionWizardViewModel.swift
│   │
│   ├── DesignSystem/               # Phase 1
│   │   ├── DesignColors.swift      # Track colors, backgrounds
│   │   ├── Typography.swift        # Font tokens
│   │   └── Spacing.swift           # Layout tokens
│   │
│   └── Assets.xcassets/            # App icon, cursor images
│
└── ScreenTests/                    # Tests per phase
```

---

## Phase 1: Foundation — App Shell + Screen Capture (Week 1–2)

**Goal:** Launch the app, request permissions, select a screen/window, and record raw video + mouse data.

### Task 1.1: Xcode Project Setup
- Create macOS SwiftUI app (`Screen.xcodeproj`)
- Target: macOS 13.0+, Swift 5.9+
- Add entitlements: Screen Recording, Microphone, Accessibility
- Register UTType `com.screen.project` conforming to `com.apple.package`
- Set up Info.plist with permissions descriptions
- Set up `.swiftlint.yml`

### Task 1.2: Design System
- `DesignColors.swift` — track colors (camera=blue, cursor=green, keystroke=orange, audio=yellow)
- `Typography.swift` — font tokens (display, heading, body, caption, mono)
- `Spacing.swift` — spacing tokens (xs=2, sm=4, md=8, lg=12, xl=16, xxl=20, xxxl=32)

### Task 1.3: App Architecture & State
- `ScreenApp.swift` — `@main` entry with `WindowGroup`, menu bar commands
- `AppState.swift` — `@MainActor` singleton with child state objects
- `CaptureSettings.swift` — `@AppStorage` for mic, system audio, frame rate
- `RecordingState.swift` — recording lifecycle (isRecording, isPaused, duration)
- `NavigationState.swift` — showEditor, currentProject, errorMessage
- `Log.swift` — `os.Logger` per subsystem (recording, capture, tracking, export)

### Task 1.4: Permissions Manager
- `PermissionsManager.swift` — check + request Screen Recording, Microphone, Input Monitoring, Accessibility
- `PermissionSetupWizardView.swift` — 4-step first-launch wizard

### Task 1.5: Screen Capture Core
- `CaptureConfiguration.swift` — width, height, frameRate, pixelFormat, showsCursor, capturesAudio, scaleFactor
- `ScreenCaptureManager.swift` — `SCStream` setup, content filter excluding Screenize windows, delegate for frames
- `CaptureTarget.swift` — `.display(SCDisplay)`, `.window(SCWindow)`, `.region(CGRect, SCDisplay)`
- `CaptureMode.swift` — `.entireScreen`, `.window`

### Task 1.6: Recording Pipeline
- `RecordingSession.swift` — state machine: idle → preparing → recording → paused → stopping → completed
- `RecordingCoordinator.swift` — start/stop/pause orchestration, wires capture + mouse + mic
- `VideoWriter.swift` — AVAssetWriter with HEVC, pixel buffer adaptor, thread-safe queue
- `VFRRecordingManager.swift` — writes frames at actual timestamps (VFR)
- `SystemAudioWriter.swift` — sidecar .m4a for system audio
- `MicrophoneRecorder.swift` — AVCaptureSession for mic → .m4a

### Task 1.7: Mouse & Event Tracking
- `MouseDataRecorder.swift` — timer-based mouse position sampling (up to 120Hz), click/scroll/keyboard events
- `EventMonitorManager.swift` — centralized CGEvent tap management
- `KeyboardEventHandler.swift`, `ScrollEventHandler.swift`, `DragEventHandler.swift`
- `AccessibilityInspector.swift` — AXUIElement queries for focused element info

### Task 1.8: Recording UI
- `MainWelcomeView.swift` — logo, Record/Open Video/Open Project buttons, drag-and-drop
- `CaptureToolbarPanel.swift` — floating NSPanel (borderless, non-activating, stays on top)
- `CaptureToolbarView.swift` — mode picker (Screen/Window), audio toggles, FPS menu, record button
- `CaptureOverlayController.swift` — screen dimming overlays + window highlight on hover
- `CountdownPanel.swift` — 3-2-1 countdown before recording starts

### Phase 1 Deliverable
✅ App launches, requests permissions, shows welcome screen  
✅ Click "Record" → floating toolbar → hover to select target → countdown → recording starts  
✅ Raw .mov video + .mouse.json saved alongside  
✅ System audio + mic audio as separate .m4a files  

---

## Phase 2: Project System (Week 2–3)

**Goal:** Package recordings into `.screenize` bundles with JSON project files.

### Task 2.1: Data Models
- `ScreenizeProject.swift` — Codable struct (id, version, name, dates, media, captureMeta, timeline, renderSettings)
- `MediaAsset.swift` — relative paths for video + mouse data + audio, resolved URLs via `resolveURLs(from:)`
- `CaptureMeta.swift` — displayID, boundsPt, scaleFactor
- `RenderSettings.swift` — codec, quality, resolution, background, corners, shadow, padding, audio volumes
- `InteropBlock.swift` — event stream file locations within package

### Task 2.2: Package Manager
- `PackageManager.swift` — CRUD for `.screenize` package directories
  - `createPackage(name:, directory:, videoURL:)` → copies video + mouse data into `recording/` subfolder
  - `save(project:, to:)` → write `project.json`
  - `load(from:)` → read `project.json` + resolve media URLs
- `PackageInfo` struct — packageURL, projectJSONURL, videoURL, mouseDataURL, relative paths

### Task 2.3: Project Lifecycle
- `ProjectCreator.swift` — factory methods:
  - `createFromRecording(packageInfo:, captureMeta:)` — after capture stops
  - `createFromVideo(packageInfo:)` — import existing video
  - Loads video metadata via AVAsset, creates default timeline
- `ProjectManager.swift` — save/load orchestration, recent projects list (`@AppStorage`)
- `EventStreamWriter.swift` — write poly-format JSON event streams (mousemoves, clicks, keystrokes, uistates)

### Task 2.4: File Opening Flow
- `ContentView.swift` — route between welcome, editor, and permission wizard
- Support opening `.screenize` packages and raw video files
- `AppDelegate` → `NSNotificationCenter` for file open events
- Register UTType in Info.plist

### Phase 2 Deliverable
✅ Recording stops → creates `.screenize` package with project.json  
✅ Recent projects list on welcome screen  
✅ Open existing projects and video files  
✅ Project files round-trip (save → load → save)  

---

## Phase 3: Timeline System + Editor UI (Week 3–5)

**Goal:** Multi-track segment timeline with drag/resize, inspector panel, and video preview.

### Task 3.1: Timeline Data Model
- `Timeline.swift` — tracks array, duration, trimStart, trimEnd
- `Track.swift`:
  - `CameraTrack` — segments of type `CameraSegment` (startTransform, endTransform, interpolation)
  - `CursorTrackV2` — segments with style, visibility, scale, click feedback
  - `KeystrokeTrackV2` — segments with displayText, position, fade durations
  - `AudioTrack` — segments with source (system/mic)
  - `AnySegmentTrack` — Codable enum wrapper
- `Segments.swift` — individual segment types with startTime, endTime, and type-specific data
- `EasingCurve.swift` — linear, easeIn, easeOut, easeInOut, springSnappy, springBouncy, custom bezier

### Task 3.2: Editor ViewModel
- `EditorViewModel.swift`:
  - Owns `ScreenizeProject`, `PreviewEngine`, `ExportEngine`
  - Playback control (play, pause, seek, loop)
  - Undo/redo via snapshot stack
  - Auto-save with debounce
- `EditorViewModel+SegmentOperations.swift` — add, delete, update, batch update segment time ranges
- `EditorViewModel+Clipboard.swift` — copy, paste, duplicate segments

### Task 3.3: Timeline View
- `TimelineView.swift`:
  - Track headers (icon + name + enable toggle) | scrollable segment area
  - Time ruler with adaptive tick interval
  - Playhead (red vertical line) synced to currentTime
  - Trim handles at start/end
  - Zoom slider (pixelsPerSecond)
- `TimelineView+SegmentBlock.swift` — colored rounded-rect segments per track
- `TimelineView+Gestures.swift` — drag to move, resize handles at edges, snap to other segments
- `TimelineView+MultiMove.swift` — Shift+click multi-select, drag moves all selected

### Task 3.4: Inspector Panel
- `InspectorView.swift` — right panel showing properties of selected segment
  - Camera: start/end zoom, center, interpolation
  - Cursor: style, visibility, scale, click feedback config
  - Keystroke: text, position, fade in/out durations
  - Audio: volume
  - Render settings tab: background, corners, shadow, padding
- `InspectorView+SegmentBindings.swift` — Binding helpers for each segment type

### Task 3.5: Editor Main View
- `EditorMainView.swift` — HSplitView layout:
  - Left: toolbar + preview + timeline (stacked vertically)
  - Right: inspector panel (260–320pt wide)
- Toolbar: generate button, play/pause, export, undo/redo
- Wire up all callbacks between timeline, inspector, and viewmodel

### Phase 3 Deliverable
✅ Open a project → see video preview + multi-track timeline  
✅ Add/delete/resize/move camera, cursor, keystroke segments  
✅ Inspector shows and edits segment properties  
✅ Playback with playhead moving along timeline  
✅ Undo/redo works across all operations  

---

## Phase 4: Smart Generation (Week 5–7)

**Goal:** Auto-generate camera zoom, cursor, and keystroke keyframes from mouse/keyboard data.

### Task 4.1: Event Stream Loading
- `EventStreamLoader.swift` — load poly-format JSON (mousemoves, clicks, keystrokes, uistates)
- `EventStreamAdapter.swift` — convert poly events → unified `MouseDataSource` format
- `MouseDataConverter.swift` — load and convert mouse data for rendering

### Task 4.2: Analysis Pipeline
- `EventTimeline.swift` — merge mouse moves, clicks, keystrokes, UI states into chronological stream
- `IntentClassifier.swift` — classify time windows into user intents:
  - `idle` — no activity
  - `reading` — slow scroll, no clicks
  - `switching` — fast mouse movement between UI areas
  - `typing` — keyboard activity
  - `clicking` — click clusters
  - `dragging` — click + hold + move

### Task 4.3: Camera Generation
- `ShotPlanner.swift` — convert intent spans into zoom "shot plans" with zoom level, center, duration
- `SegmentCameraGenerator.swift` — main entry: events → intents → shots → CameraTrack segments
- `SegmentPlanner.swift` — refine shot plans into camera segments with proper easing
- `SegmentSpringSimulator.swift` — spring-based simulation for smooth camera transitions

### Task 4.4: Cursor & Keystroke Generation
- `CursorTrackEmitter.swift` — create cursor visibility segments (hide during fast moves, show on click)
- `KeystrokeTrackEmitter.swift` — create keystroke overlay segments from keyboard events
- Generation settings: zoom levels, timing thresholds, dead zones

### Task 4.5: Generation UI
- `GeneratorPanelView.swift` — checkboxes for what to generate (camera, cursor, keystroke)
- `EditorViewModel+SmartGeneration.swift` — trigger generation, replace timeline tracks
- Progress indicator during generation

### Phase 4 Deliverable
✅ Click "Generate" → auto-generated zoom keyframes following mouse activity  
✅ Cursor segments auto-created with appropriate visibility  
✅ Keystroke overlays auto-placed from keyboard shortcuts  
✅ Results appear in timeline, editable as normal  

---

## Phase 5: Render Pipeline + Export (Week 7–9)

**Goal:** Real-time preview and final video export with all effects composited.

### Task 5.1: Frame Evaluation
- `FrameEvaluator.swift` — for any time T, evaluate:
  - Camera transform (zoom, center) with easing interpolation
  - Cursor state (position, style, visibility, scale, click animation)
  - Active keystroke overlays (text, position, opacity)
- `EasingCurve` evaluation — cubic bezier, spring, linear interpolation

### Task 5.2: Renderer
- `RenderContext.swift` — CIContext (Metal-backed), pixel buffer pool, output/source sizes
- `Renderer.swift` — main render pipeline:
  1. Apply camera transform (crop + scale via `TransformApplicator`)
  2. Composite background (solid/gradient/image via `WindowModeRenderer`)
  3. Overlay cursor image at computed position
  4. Overlay click ripple effect
  5. Overlay keystroke text
- `TransformApplicator.swift` — CIImage affine transforms for zoom/pan
- `EffectCompositor.swift` — cursor image + keystroke text compositing
- `WindowModeRenderer.swift` — background, rounded corners, shadow for window captures
- `SpringCursorSimulator.swift` — damped harmonic oscillator for smooth cursor following
- `CursorImageProvider.swift` — load and cache cursor images at various scales

### Task 5.3: Preview Engine
- `PreviewEngine.swift` — real-time preview with:
  - `VideoFrameExtractor` — random-access frame extraction (AVAssetImageGenerator)
  - `SequentialFrameReader` — playback-optimized frame reading (AVAssetReader)
  - `CFRFrameReader` — fill VFR gaps for constant display rate
  - `RenderCoordinator` — background render queue with texture caching
  - `PreviewTextureCache` — GPU-resident MTLTexture pool
  - DisplayLink-driven playback at source frame rate
- `PreviewView.swift` — MetalKit view displaying rendered frames
- `ScrubController.swift` — handle seek/scrub with debounce

### Task 5.4: Export Engine
- `ExportEngine.swift` — orchestrate video or GIF export:
  1. Load video frames (SequentialFrameReader)
  2. Load and interpolate mouse data
  3. Create render pipeline (FrameEvaluator + Renderer)
  4. Process each frame: evaluate → render → write pixel buffer
  5. Mix audio (system + mic with volume control)
  6. Finalize with AVAssetWriter
- `ExportEngine+VideoExport.swift` — MP4/MOV with HEVC/H.264
- `ExportEngine+GIFExport.swift` — animated GIF with custom encoder
- `AudioMixer.swift` — mix system + mic audio with volume, trim support
- Progress tracking: preparing → loading → processing(frame/total) → encoding → finalizing → completed

### Task 5.5: Export UI
- `ExportSheetView.swift` — modal sheet with:
  - Resolution picker (original, 4K, 1440p, 1080p, 720p, custom)
  - Frame rate picker (24, 30, 60, 120, custom)
  - Codec picker (H.264, HEVC, ProRes)
  - Quality picker (low, medium, high, original)
  - Color space picker
  - Format toggle (video vs GIF)
  - Progress bar with frame counter and ETA
  - Cancel / Export / Done buttons

### Phase 5 Deliverable
✅ Real-time Metal-backed preview with all effects applied  
✅ Export to MP4/MOV/GIF with codec/quality/resolution options  
✅ Audio mixing (system + mic) with volume controls  
✅ Progress tracking with cancel support  

---

## Phase 6: Polish & Advanced Features (Week 9–11)

### Task 6.1: Keyboard Shortcuts
| Shortcut | Action |
|---|---|
| ⌘⇧2 | Toggle recording (global hotkey) |
| ⌘R | Start/stop recording |
| ⌘P | Pause/resume |
| ⌘E | Export |
| Space | Play/pause preview |
| ⌘Z / ⌘⇧Z | Undo / redo |
| ⌘C / ⌘V / ⌘D | Copy / paste / duplicate segments |
| Delete | Delete selected segments |
| ← / → | Frame step |

### Task 6.2: Click Effects
- Configurable ripple animation on mouse clicks
- Parameters: scale, duration, color, opacity
- Rendered as expanding circle overlay in compositor

### Task 6.3: Custom Cursors
- Replace system cursor with styled alternatives
- Arrow, pointer, hand, crosshair, text styles
- Scale per segment, click feedback (scale down on press)

### Task 6.4: Background Styling
- Solid color, linear/radial gradient, or image
- Rounded corners with configurable radius
- Drop shadow (blur, offset, color, opacity)
- Padding around recording

### Task 6.5: Motion Blur
- Optional motion blur during camera transitions
- Sample multiple sub-frames and blend

### Task 6.6: Auto-Update (Sparkle)
- Integrate Sparkle for auto-updates
- EdDSA key generation, appcast.xml

---

## Estimated Timeline

| Phase | Duration | Cumulative |
|---|---|---|
| Phase 1: Foundation | 2 weeks | Week 2 |
| Phase 2: Project System | 1 week | Week 3 |
| Phase 3: Timeline + Editor | 2 weeks | Week 5 |
| Phase 4: Smart Generation | 2 weeks | Week 7 |
| Phase 5: Render + Export | 2 weeks | Week 9 |
| Phase 6: Polish | 2 weeks | Week 11 |

**Total: ~11 weeks** for feature parity with Screenize v0.4.0

---

## Key Technical Dependencies

| Framework | Purpose |
|---|---|
| **ScreenCaptureKit** | Screen/window capture (macOS 13+) |
| **AVFoundation** | Video read/write, audio recording |
| **CoreImage** | Image transforms, compositing |
| **Metal / MetalKit** | GPU-accelerated rendering, preview display |
| **CoreGraphics** | Coordinate transforms, color spaces |
| **Accessibility (AX)** | UI element detection for smart zoom |
| **SwiftUI + AppKit** | UI (NSPanel, NSWindow for overlays) |
| **Combine** | Reactive state management |
| **os.Logger** | Structured logging |
| **Sparkle** | Auto-updates (optional) |

---

## Risk Mitigation

| Risk | Mitigation |
|---|---|
| ScreenCaptureKit API changes | Pin to macOS 13+, test on each release |
| Metal rendering bugs | Fallback to software CIContext |
| VFR video timing issues | CFRFrameReader normalizes to constant rate |
| Large video memory | Stream frames sequentially, pool pixel buffers |
| Accessibility permission denied | Graceful degradation — smart zoom without AX data |
| Complex undo system | Snapshot-based undo (copy full timeline on each edit) |

---

## Getting Started (Phase 1, Task 1.1)

```bash
# 1. Create Xcode project
#    macOS > App > SwiftUI > "Screen"
#    Bundle ID: com.screen.Screen
#    Deployment target: macOS 13.0

# 2. Add entitlements
#    - com.apple.security.device.audio-input
#    - com.apple.security.device.camera  (for screen capture)

# 3. Add Info.plist keys
#    - NSScreenCaptureUsageDescription
#    - NSMicrophoneUsageDescription
#    - NSAccessibilityUsageDescription
```

Want me to start building Phase 1?
