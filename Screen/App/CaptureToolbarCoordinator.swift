import Foundation
import ScreenCaptureKit
import AppKit
import SwiftUI
import Combine

/// Borderless window that properly accepts keyboard events.
private class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Orchestrates the capture toolbar flow
@MainActor
final class CaptureToolbarCoordinator: ObservableObject {

    // MARK: - Published State

    @Published var captureMode: CaptureMode = .entireScreen
    @Published var toolbarPhase: ToolbarPhase = .selecting
    @Published var isPaused: Bool = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var statusMessage: String = ""
    @Published var isZoomedIn: Bool = false
    @Published var isWebcamActive: Bool = false
    @Published var isWebcamAvailable: Bool = false

    // Source picker state
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var selectedDisplay: SCDisplay?
    @Published var selectedWindow: SCWindow?
    @Published var isLoadingSources: Bool = false
    @Published private(set) var isStarting: Bool = false

    // Options state
    @Published var isMicrophoneEnabled: Bool = false
    @Published var isSystemAudioEnabled: Bool = true
    @Published var currentFrameRate: Int = 60
    @Published var needsRelaunch: Bool = false

    // MARK: - Private

    private var toolbarWindow: NSWindow?
    private var permissionAttempts = 0
    private let overlayController = CaptureOverlayController()
    private let zoomIndicator = ZoomIndicatorOverlay()
    private let webcamPiPOverlay = WebcamPiPOverlay()
    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        self.isMicrophoneEnabled = appState.capture.isMicrophoneEnabled
        self.isSystemAudioEnabled = appState.capture.isSystemAudioEnabled
        self.currentFrameRate = appState.capture.captureFrameRate
        self.isWebcamActive = appState.capture.isWebcamEnabled
        self.isWebcamAvailable = !appState.capture.availableWebcams.isEmpty
        setupAppStateBindings()
        setupOverlayCallbacks()
    }

    private func setupAppStateBindings() {
        appState?.recording.$isPaused
            .receive(on: RunLoop.main)
            .assign(to: &$isPaused)

        appState?.recording.$recordingDuration
            .receive(on: RunLoop.main)
            .assign(to: &$recordingDuration)
    }

    private func setupOverlayCallbacks() {
        overlayController.onScreenHovered = { [weak self] display in
            self?.selectedDisplay = display
        }
        overlayController.onWindowHovered = { [weak self] window in
            self?.selectedWindow = window
        }
        overlayController.onScreenClicked = { [weak self] display in
            self?.selectedDisplay = display
        }
        overlayController.onWindowClicked = { [weak self] window in
            self?.selectedWindow = window
        }
        overlayController.onDeselected = { [weak self] in
            guard let self else { return }
            switch self.captureMode {
            case .entireScreen:
                self.selectedDisplay = nil
            case .window:
                self.selectedWindow = nil
            }
        }
    }

    // MARK: - Mode Change

    func setCaptureMode(_ mode: CaptureMode) {
        guard captureMode != mode else { return }
        captureMode = mode
        selectedDisplay = nil
        selectedWindow = nil
        if !displays.isEmpty {
            overlayController.updateMode(mode)
        }
    }

    // MARK: - Options

    func toggleMicrophone() {
        isMicrophoneEnabled.toggle()
        appState?.capture.isMicrophoneEnabled = isMicrophoneEnabled
    }

    func toggleSystemAudio() {
        isSystemAudioEnabled.toggle()
        appState?.capture.isSystemAudioEnabled = isSystemAudioEnabled
    }

    func setFrameRate(_ fps: Int) {
        currentFrameRate = fps
        appState?.capture.captureFrameRate = fps
    }

    // MARK: - Show Toolbar

    func showToolbar() async {
        guard let appState else { return }

        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true

        let view = CaptureToolbarView(coordinator: self)
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        overlayController.ignoredWindow = window

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: sf.midX - size.width / 2, y: sf.maxY - size.height - 40))
        }

        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.toolbarWindow = window

        // Fetch sources and thumbnails in background
        await loadSources()
    }

    // MARK: - Load Sources

    func loadSources() async {
        isLoadingSources = true
        defer { isLoadingSources = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            self.displays = content.displays
            self.windows = content.windows.filter(CaptureTarget.isSelectableWindow)

            selectedDisplay = nil
            selectedWindow = nil

            self.permissionAttempts = 0
            self.appState?.permissions.refreshAll()
            self.statusMessage = ""

            // Activate hover overlay
            overlayController.activate(mode: captureMode, displays: displays, windows: windows)
        } catch {
            let hasScreenRecordingAccess = self.appState?.permissions.checkScreenRecordingAccess() ?? false
            Log.recording.error("Unable to load capture sources: \(error)")

            if hasScreenRecordingAccess {
                self.statusMessage = "Unable to load screens. Try Record again."
            } else {
                self.permissionAttempts += 1
                if self.permissionAttempts >= 2 {
                    self.statusMessage = "Allow ScreenTake in Screen Recording, then quit and reopen it."
                } else {
                    self.statusMessage = "Enable Screen Recording, then click Record."
                    self.appState?.permissions.requestScreenRecording()
                }
            }
        }
    }

    // MARK: - Record

    func confirmAndRecord() {
        guard let appState, !isStarting, toolbarPhase == .selecting,
              !appState.isRecording, appState.recording.processingStage == nil else { return }

        isStarting = true
        statusMessage = "Starting..."

        Task { [weak self] in
            guard let self else { return }
            defer { self.isStarting = false }

            // Re-fetch sources if empty (e.g. permission was just granted)
            if self.displays.isEmpty {
                await self.loadSources()
            }

            appState.availableDisplays = self.displays
            appState.availableWindows = self.windows

            guard !self.displays.isEmpty else {
                return
            }

            switch self.captureMode {
            case .entireScreen:
                guard let selected = self.selectedDisplay,
                      let display = self.displays.first(where: { $0.displayID == selected.displayID }) else {
                    self.statusMessage = "Select the display you want to record."
                    return
                }
                appState.selectedTarget = .display(display)
            case .window:
                guard let selected = self.selectedWindow,
                      let window = self.windows.first(where: { $0.windowID == selected.windowID }) else {
                    self.statusMessage = "Select the window you want to record."
                    return
                }
                appState.selectedTarget = .window(window)
            }

            Log.recording.info("Recording target: \(appState.selectedTarget?.displayName ?? "nil")")
            self.overlayController.deactivate()

            do {
                try await appState.recording.startRecording(appState: appState)
                self.toolbarPhase = .recording
                self.statusMessage = ""
                Log.recording.info("Recording started")
                self.zoomIndicator.showBorder(captureBounds: self.captureTargetBounds())
                self.showWebcamPiPIfNeeded()
                self.startRecordingShortcuts()
            } catch {
                Log.recording.error("Recording failed: \(error)")
                self.statusMessage = "Failed: \(error.localizedDescription)"
                self.toolbarPhase = .selecting
                self.overlayController.activate(mode: self.captureMode, displays: self.displays, windows: self.windows)
            }
        }
    }

    // MARK: - Stop

    func stopRecording() {
        guard let appState, !isStarting, appState.isRecording,
              appState.recording.processingStage == nil else { return }
        stopRecordingShortcuts()
        webcamPiPOverlay.hide()

        Task { [weak self] in
            await appState.recording.stopRecording()
            self?.safeDismiss()
        }
    }

    func togglePause() {
        appState?.recording.togglePause()
    }

    func toggleZoom() {
        Log.app.info("CaptureToolbarCoordinator.toggleZoom() called, isZoomedIn was \(self.isZoomedIn)")
        appState?.recording.toggleZoom()
        isZoomedIn.toggle()
        if isZoomedIn {
            zoomIndicator.enterZoom()
        } else {
            zoomIndicator.exitZoom()
        }
        // No need to call bringToFront() — the PiP window is at .screenSaver
        // level (1000) which is far above the zoom overlay at .floating-1 (2).
        // Calling orderFrontRegardless() triggers a WindowServer recomposition
        // that stalls the AVCaptureVideoPreviewLayer's IOSurface rendering pipeline.
    }

    func toggleWebcam() {
        isWebcamActive.toggle()
        appState?.capture.isWebcamEnabled = isWebcamActive

        if isWebcamActive {
            // If webcam was toggled ON mid-recording but the recorder wasn't prepared
            // at recording start, prepare it now on-the-fly.
            if toolbarPhase == .recording,
               appState?.recording.recordingCoordinator?.webcamRecorder == nil {
                Task { [weak self] in
                    await self?.prepareWebcamMidRecording()
                    self?.showWebcamPiPIfNeeded()
                }
            } else {
                showWebcamPiPIfNeeded()
            }
        } else {
            webcamPiPOverlay.hide()
        }
    }

    /// Prepare webcam recorder when toggling webcam ON during an active recording.
    private func prepareWebcamMidRecording() async {
        guard let coordinator = appState?.recording.recordingCoordinator else { return }
        let camRecorder = WebcamRecorder()
        do {
            try camRecorder.prepare(device: appState?.capture.selectedWebcamDevice)
            try await Task.sleep(nanoseconds: 300_000_000) // 0.3s warmup
            guard camRecorder.isSessionRunning else {
                Log.recording.warning("Webcam session failed to start mid-recording")
                return
            }
            coordinator.setWebcamRecorder(camRecorder)

            // Start writing to a sidecar file
            if let outputURL = coordinator.outputURL {
                let camURL = RecordingCoordinator.generateWebcamOutputURL(for: outputURL)
                try camRecorder.startWriting(to: camURL)
            }
        } catch {
            Log.recording.warning("Mid-recording webcam prepare failed: \(error)")
        }
    }

    /// Show the live webcam PiP overlay if the webcam is active and session is available.
    private func showWebcamPiPIfNeeded() {
        guard isWebcamActive,
              let recorder = appState?.recording.recordingCoordinator?.webcamRecorder,
              recorder.isSessionRunning,
              let capture = appState?.capture else {
            Log.app.debug("showWebcamPiPIfNeeded guard failed: active=\(self.isWebcamActive) recorder=\(self.appState?.recording.recordingCoordinator?.webcamRecorder != nil) running=\(self.appState?.recording.recordingCoordinator?.webcamRecorder?.isSessionRunning ?? false)")
            return
        }

        // Position the PiP relative to the capture target so it matches the
        // final export layout. For window recordings this places the circle
        // inside the recorded window; for display recordings it uses the screen.
        let bounds = captureTargetBounds()
        webcamPiPOverlay.show(
            webcamRecorder: recorder,
            position: capture.webcamPiPPosition,
            pipSize: capture.webcamPiPSize,
            shape: capture.webcamPiPShape,
            screenBounds: bounds
        )
    }

    /// Returns the screen frame (Cocoa coords) on which the capture target resides.
    /// Used for features that need full-screen bounds (e.g. zoom border).
    private func screenBoundsForPiP() -> CGRect {
        guard let target = appState?.selectedTarget else {
            return NSScreen.main?.frame ?? .zero
        }
        switch target {
        case .display(let scDisplay):
            if let screen = NSScreen.screens.first(where: {
                $0.frame.width == CGFloat(scDisplay.width)
                && $0.frame.height == CGFloat(scDisplay.height)
            }) {
                return screen.frame
            }
            return NSScreen.main?.frame ?? .zero
        case .window(let scWindow):
            // Find the screen that contains the window's center
            let qFrame = scWindow.frame
            let screenH = NSScreen.main?.frame.height ?? qFrame.height
            let cocoaCenter = NSPoint(
                x: qFrame.midX,
                y: screenH - qFrame.midY
            )
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoaCenter) }) {
                return screen.frame
            }
            return NSScreen.main?.frame ?? .zero
        }
    }

    /// Returns the capture target bounds in Cocoa screen coordinates.
    private func captureTargetBounds() -> CGRect {
        guard let target = appState?.selectedTarget else {
            return NSScreen.main?.frame ?? .zero
        }
        switch target {
        case .display:
            // For display recordings, use the matching NSScreen frame (Cocoa coords)
            if case .display(let scDisplay) = target,
               let screen = NSScreen.screens.first(where: {
                   $0.frame.width == CGFloat(scDisplay.width)
                   && $0.frame.height == CGFloat(scDisplay.height)
               }) {
                return screen.frame
            }
            return NSScreen.main?.frame ?? .zero
        case .window(let scWindow):
            // SCWindow.frame is in Quartz coords (Y origin at top of main display).
            // Convert to Cocoa coords (Y origin at bottom of main display).
            let qFrame = scWindow.frame
            let screenH = NSScreen.main?.frame.height ?? qFrame.height
            return CGRect(
                x: qFrame.origin.x,
                y: screenH - qFrame.origin.y - qFrame.height,
                width: qFrame.width,
                height: qFrame.height
            )
        }
    }

    // MARK: - Dismiss

    func dismiss() {
        safeDismiss()
    }

    private func safeDismiss() {
        zoomIndicator.deactivate()
        webcamPiPOverlay.hide()
        overlayController.deactivate()
        let window = toolbarWindow
        toolbarWindow = nil

        DispatchQueue.main.async { [weak self] in
            window?.orderOut(nil)
            self?.appState?.captureToolbarCoordinator = nil
            self?.appState?.restoreMainWindow()
        }
    }

    // MARK: - Recording Shortcuts

    private func startRecordingShortcuts() {
        let hotkeys = GlobalHotkeyManager.shared
        hotkeys.onPauseResume = { [weak self] in
            self?.togglePause()
        }
        hotkeys.onStopRecording = { [weak self] in
            self?.stopRecording()
        }
        hotkeys.onToggleZoom = { [weak self] in
            self?.toggleZoom()
        }
        hotkeys.startRecordingKeyMonitor()
    }

    private func stopRecordingShortcuts() {
        let hotkeys = GlobalHotkeyManager.shared
        hotkeys.stopRecordingKeyMonitor()
        hotkeys.onPauseResume = nil
        hotkeys.onStopRecording = nil
        hotkeys.onToggleZoom = nil
    }
}
