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
    let editorSession = EditorSession()
    lazy var editorCommands = EditorCommandDispatcher(session: editorSession)
    lazy var editorConnection = EditorLocalServer(commands: editorCommands)
    let permissions = PermissionsManager()
    let updates = UpdateChecker()
    @Published var isExportingVideo = false
    @Published var isRecordingVoiceOver = false
    @Published var isRecordingCameraOverlay = false
    var isRecordingEditorMedia: Bool { isRecordingVoiceOver || isRecordingCameraOverlay }

    // MARK: - Capture Toolbar

    var captureToolbarCoordinator: CaptureToolbarCoordinator?
    @Published private var unsavedVideoSessions = Set<UUID>()
    var hasUnsavedVideoWork: Bool { !unsavedVideoSessions.isEmpty }
    private(set) var isConfirmingVideoReplacement = false

    func updateUnsavedVideoWork(session: UUID, hasUnsavedWork: Bool) {
        if hasUnsavedWork {
            unsavedVideoSessions.insert(session)
        } else {
            unsavedVideoSessions.remove(session)
        }
    }

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
        editorSession.configure(appState: self)
        recording.configure(captureSettings: capture, navigationState: navigation)
        setupBindings()
    }

    private func setupBindings() {
        editorSession.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
        guard captureToolbarCoordinator == nil, !isRecording, !isRecordingEditorMedia,
              recording.processingStage == nil, !updates.isPresenting,
              !isExportingVideo, !isConfirmingVideoReplacement,
              NSApplication.shared.modalWindow == nil,
              !NSApplication.shared.windows.contains(where: { $0.attachedSheet != nil }) else { return }
        if hasUnsavedVideoWork {
            let approved = await confirmVideoReplacement(.record)
            guard approved, captureToolbarCoordinator == nil, !isRecording,
                  recording.processingStage == nil, !isExportingVideo else { return }
        }
        // Hide the main window
        for window in NSApplication.shared.windows where window.styleMask.contains(.titled) && window.level == .normal {
            window.orderOut(nil)
        }

        let coordinator = CaptureToolbarCoordinator(appState: self)
        self.captureToolbarCoordinator = coordinator
        await coordinator.showToolbar()
    }

    func confirmVideoReplacement(_ action: VideoReplacementAction) async -> Bool {
        guard !isConfirmingVideoReplacement else { return false }
        isConfirmingVideoReplacement = true
        defer { isConfirmingVideoReplacement = false }
        NSApplication.shared.activate(ignoringOtherApps: true)

        let editorWindows = NSApplication.shared.windows.filter {
            $0.styleMask.contains(.titled) && $0.level == .normal && !($0 is NSPanel)
        }
        let window = editorWindows.first(where: { $0.isKeyWindow })
            ?? editorWindows.first(where: { $0.isMainWindow })
            ?? editorWindows.first
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 440, height: 210),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: VideoReplacementDialog(action: action) { discard in
            let response: NSApplication.ModalResponse = discard ? .OK : .cancel
            if let window {
                window.endSheet(panel, returnCode: response)
            } else {
                NSApplication.shared.stopModal(withCode: response)
            }
        })
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        defer { panel.orderOut(nil); panel.contentView = nil }
        if let window {
            window.makeKeyAndOrderFront(nil)
            return await withCheckedContinuation { decision in
                window.beginSheet(panel) { response in
                    decision.resume(returning: response == .OK)
                }
            }
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        return NSApplication.shared.runModal(for: panel) == .OK
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
