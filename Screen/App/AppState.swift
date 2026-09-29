import Foundation
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import Combine

/// Global application state coordinator.
/// Owns child state objects and provides backward-compatible facades.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Singleton

    static let shared = AppState()

    // MARK: - Child State Objects

    let capture = CaptureSettings()
    let navigation = NavigationState()
    let recording = RecordingState()
    let permissions = PermissionsManager()
    let updates = UpdateChecker()
    @Published var isExportingVideo = false
    @Published var isRecordingVoiceOver = false

    // MARK: - Capture Toolbar

    var captureToolbarCoordinator: CaptureToolbarCoordinator?

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Recording Facades

    var isRecording: Bool {
        get { recording.isRecording }
        set { recording.isRecording = newValue }
    }

    var isPaused: Bool {
        get { recording.isPaused }
        set { recording.isPaused = newValue }
    }

    var recordingDuration: TimeInterval {
        get { recording.recordingDuration }
        set { recording.recordingDuration = newValue }
    }

    var lastRecordingURL: URL? {
        get { recording.lastRecordingURL }
        set { recording.lastRecordingURL = newValue }
    }

    // MARK: - Capture Facades

    var isMicrophoneEnabled: Bool {
        get { capture.isMicrophoneEnabled }
        set { capture.isMicrophoneEnabled = newValue }
    }

    var isSystemAudioEnabled: Bool {
        get { capture.isSystemAudioEnabled }
        set { capture.isSystemAudioEnabled = newValue }
    }

    var captureFrameRate: Int {
        get { capture.captureFrameRate }
        set { capture.captureFrameRate = newValue }
    }

    var selectedTarget: CaptureTarget? {
        get { capture.selectedTarget }
        set { capture.selectedTarget = newValue }
    }

    var availableDisplays: [SCDisplay] {
        get { capture.availableDisplays }
        set { capture.availableDisplays = newValue }
    }

    var availableWindows: [SCWindow] {
        get { capture.availableWindows }
        set { capture.availableWindows = newValue }
    }

    // MARK: - Navigation Facades

    var showEditor: Bool {
        get { navigation.showEditor }
        set { navigation.showEditor = newValue }
    }

    var currentProject: Any? {
        get { navigation.currentProject }
        set { navigation.currentProject = newValue }
    }

    var errorMessage: String? {
        get { navigation.errorMessage }
        set { navigation.errorMessage = newValue }
    }

    // MARK: - Initialization

    private init() {
        recording.configure(captureSettings: capture, navigationState: navigation)
        setupBindings()
    }

    private func setupBindings() {
        // Forward recording state changes to trigger UI updates
        recording.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        capture.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        navigation.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Source Discovery (called only from confirmAndRecord)

    func refreshAvailableSources() async {
        // No-op — sources are now fetched in confirmAndRecord to avoid
        // triggering the permission prompt on toolbar show
    }

    // MARK: - Capture Toolbar

    func showCaptureToolbar() async {
        guard captureToolbarCoordinator == nil, !isRecording, !isRecordingVoiceOver,
              recording.processingStage == nil, !updates.isPresenting else { return }
        // Hide the main window
        for window in NSApplication.shared.windows where window.styleMask.contains(.titled) && window.level == .normal {
            window.orderOut(nil)
        }

        let coordinator = CaptureToolbarCoordinator(appState: self)
        self.captureToolbarCoordinator = coordinator
        await coordinator.showToolbar()
    }

    func dismissCaptureToolbar() {
        captureToolbarCoordinator = nil
    }

    /// Called by the coordinator after the toolbar window is closed
    func restoreMainWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            for window in NSApplication.shared.windows where window.styleMask.contains(.titled) && window.level == .normal {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
}
