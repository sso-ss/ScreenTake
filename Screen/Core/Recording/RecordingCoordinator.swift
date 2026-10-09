import Foundation
import CoreMedia
import AppKit
import AVFoundation

/// Recording result
struct RecordingResult {
    var videoURL: URL?
    var mouseDataURL: URL?
    var micAudioURL: URL?
    var systemAudioURL: URL?
    var webcamVideoURL: URL?
    var micAudioStartOffset: CMTime = .zero
    var systemAudioStartOffset: CMTime = .zero
    var browserContentRect: CGRect?
}

/// Recording session state machine
enum RecordingSessionState {
    case idle
    case preparing
    case recording
    case paused
    case stopping
    case completed
}

/// Orchestrates screen capture + mouse tracking + audio recording
@MainActor
final class RecordingCoordinator: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentDuration: TimeInterval = 0
    private(set) var isMicrophoneEnabled = false

    // MARK: - Private Properties

    private var captureManager: ScreenCaptureManager?
    private var mouseDataRecorder: MouseDataRecorder?
    private var microphoneRecorder: MicrophoneRecorder?
    private var systemAudioRecorder: SystemAudioRecorder?
    private(set) var webcamRecorder: WebcamRecorder?

    /// Allow external callers (e.g. mid-recording webcam toggle) to supply a recorder.
    func setWebcamRecorder(_ recorder: WebcamRecorder) {
        self.webcamRecorder = recorder
    }

    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private var mediaStartTime: CMTime?
    private var pauseStartTime: CMTime?
    private var completedPausedDuration: CMTime = .zero
    private var captureConfiguration: CaptureConfiguration?
    private var captureTarget: CaptureTarget?
    private var captureBounds: CGRect = .zero
    private var browserContentRect: CGRect?

    private(set) var outputURL: URL?

    // MARK: - Start Recording

    func startRecording(
        target: CaptureTarget,
        backgroundStyle: BackgroundStyle?,
        frameRate: Int,
        showCursor: Bool,
        cursorScale: Double,
        highlightClicks: Bool,
        clickHighlightColor: ClickHighlightColor = .white,
        isSystemAudioEnabled: Bool,
        isMicrophoneEnabled: Bool,
        microphoneDevice: AVCaptureDevice?,
        isWebcamEnabled: Bool = false,
        webcamDevice: AVCaptureDevice? = nil
    ) async throws {
        let target = try await ScreenCaptureManager.refreshedTarget(target)
        // Generate output URL
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Screen", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let outputURL = outputDir.appendingPathComponent("recording-\(timestamp).mov")
        self.outputURL = outputURL
        self.captureTarget = target

        var startupCompleted = false
        defer {
            if !startupCompleted {
                microphoneRecorder?.tearDown()
                webcamRecorder?.tearDown()
                microphoneRecorder = nil
                webcamRecorder = nil
            }
        }

        // Calculate capture bounds
        self.captureBounds = calculateCaptureBounds(for: target)

        // Setup capture configuration — always hide system cursor, we draw our own
        var captureConfig = CaptureConfiguration.forTarget(target, frameRate: frameRate, showsCursor: false)
        captureConfig.capturesAudio = isSystemAudioEnabled
        self.captureConfiguration = captureConfig

        // Ensure microphone and camera permissions are granted before starting
        // devices. This prevents the system permission dialog from appearing
        // mid-recording and blocking capture sessions.
        var microphoneAccessGranted = false
        if isMicrophoneEnabled {
            microphoneAccessGranted = await AVCaptureDevice.requestAccess(for: .audio)
            if !microphoneAccessGranted {
                Log.recording.warning("Microphone permission denied — skipping mic recording")
            }
        }
        if isWebcamEnabled {
            let camGranted = await AVCaptureDevice.requestAccess(for: .video)
            if !camGranted {
                Log.recording.warning("Camera permission denied — skipping webcam recording")
            }
        }

        // Prepare webcam FIRST so camera is warm before recording starts
        if isWebcamEnabled {
            let camRecorder = WebcamRecorder()
            do {
                try camRecorder.prepare(device: webcamDevice)
                self.webcamRecorder = camRecorder
            } catch {
                Log.recording.warning("Webcam prepare failed (non-fatal): \(error)")
            }
        }

        if microphoneAccessGranted {
            let micRecorder = MicrophoneRecorder()
            do {
                try micRecorder.prepare(device: microphoneDevice, outputURL: Self.generateMicOutputURL(for: outputURL))
                self.microphoneRecorder = micRecorder
            } catch {
                micRecorder.tearDown()
                Log.recording.warning("Mic prepare failed (non-fatal): \(error)")
            }
        }

        do {
            try await microphoneRecorder?.waitUntilReady()
            try await webcamRecorder?.waitUntilReady()
        } catch {
            microphoneRecorder?.tearDown()
            webcamRecorder?.tearDown()
            microphoneRecorder = nil
            webcamRecorder = nil
            throw error
        }

        browserContentRect = await BrowserContentDetector.recordedBounds(for: target)

        // Start screen capture
        captureManager = ScreenCaptureManager()

        // Start system audio recording (must be set before startRecording so SCStream audio routes here)
        Log.recording.info("Audio config: systemAudio=\(isSystemAudioEnabled), mic=\(isMicrophoneEnabled)")
        if isSystemAudioEnabled {
            let sysRecorder = SystemAudioRecorder()
            let sysURL = SystemAudioRecorder.generateOutputURL(for: outputURL)
            do {
                try sysRecorder.startRecording(to: sysURL)
                self.systemAudioRecorder = sysRecorder
                captureManager?.systemAudioRecorder = sysRecorder
                Log.recording.info("SystemAudioRecorder assigned to captureManager")
            } catch {
                Log.recording.warning("System audio recording failed (non-fatal): \(error)")
            }
        } else {
            Log.recording.info("System audio disabled — skipping")
        }

        do {
            try await captureManager?.startRecording(
                target: target,
                configuration: captureConfig,
                outputURL: outputURL,
                backgroundStyle: backgroundStyle,
                showCursor: false,  // Cursor is drawn during export from mouse position data
                cursorScale: cursorScale,
                highlightClicks: highlightClicks,
                clickHighlightColor: clickHighlightColor
            )
        } catch {
            let failedAudioURL = await systemAudioRecorder?.stopRecording()
            if let failedAudioURL { try? FileManager.default.removeItem(at: failedAudioURL) }
            systemAudioRecorder = nil
            captureManager = nil
            throw error
        }

        // Start mouse recording
        let mediaStartTime = captureManager?.recordingManager?.startTime
        self.mediaStartTime = mediaStartTime
        pauseStartTime = nil
        completedPausedDuration = .zero
        if let mediaStartTime {
            systemAudioRecorder?.setRecordingStartTime(mediaStartTime)
        }
        mouseDataRecorder = MouseDataRecorder()
        mouseDataRecorder?.startRecording(
            screenBounds: captureBounds,
            scaleFactor: captureConfig.scaleFactor,
            captureFrameRate: captureConfig.frameRate,
            startTime: mediaStartTime ?? CMClockGetTime(CMClockGetHostTimeClock())
        )

        // Start microphone recording
        if let micRecorder = microphoneRecorder {
            let micURL = Self.generateMicOutputURL(for: outputURL)
            do {
                try micRecorder.startWriting(to: micURL, startTime: mediaStartTime)
            } catch {
                micRecorder.tearDown()
                microphoneRecorder = nil
                Log.recording.warning("Mic recording failed (non-fatal): \(error)")
            }
        }

        // Start webcam file writing (session already running from prepare)
        if let camRecorder = webcamRecorder {
            let camURL = Self.generateWebcamOutputURL(for: outputURL)
            do {
                try camRecorder.startWriting(to: camURL, startTime: mediaStartTime)
            } catch {
                Log.recording.warning("Webcam writing failed (non-fatal): \(error)")
            }
        }

        isRecording = true
        self.isMicrophoneEnabled = microphoneRecorder != nil
        isPaused = false
        recordingStartTime = Date()
        startupCompleted = true

        Log.recording.info("Recording started: \(target.displayName)")
    }

    // MARK: - Stop Recording

    func stopRecording() async -> RecordingResult {
        guard isRecording else {
            return RecordingResult()
        }

        isRecording = false
        isMicrophoneEnabled = false
        isPaused = false
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())

        // Stop capture
        let videoURL = await captureManager?.stopRecording(at: stopTime)
        captureManager = nil

        // Stop mouse tracking
        let mouseRecording = mouseDataRecorder?.stopRecording()
        mouseDataRecorder = nil

        // Save mouse data
        var mouseDataURL: URL?
        if let recording = mouseRecording, let outURL = outputURL {
            let mouseURL = Self.generateMouseDataURL(for: outURL)
            do {
                try MouseDataRecorder.save(recording, to: mouseURL)
                mouseDataURL = mouseURL
            } catch {
                Log.recording.error("Failed to save mouse data: \(error)")
            }
        }

        // Stop microphone
        let micURL = await microphoneRecorder?.stopRecording()
        let micOffset = microphoneRecorder?.startOffset ?? .zero
        microphoneRecorder = nil

        // Stop system audio
        let systemAudioURL = await systemAudioRecorder?.stopRecording()
        let systemOffset = systemAudioRecorder?.startOffset ?? .zero
        systemAudioRecorder = nil

        // Stop webcam
        let webcamURL = await webcamRecorder?.stopRecording(at: stopTime)
        webcamRecorder = nil

        // Keep audio files separate — mux happens AFTER export/zoom to avoid distortion
        Log.recording.info("Recording stopped: video=\(videoURL?.lastPathComponent ?? "nil"), sysAudio=\(systemAudioURL?.lastPathComponent ?? "nil"), mic=\(micURL?.lastPathComponent ?? "nil")")

        // Use the accessibility hint only when bounds match at the start and end.
        var stableBrowserRect: CGRect?
        if let initial = browserContentRect, let target = captureTarget,
           let refreshed = try? await ScreenCaptureManager.refreshedTarget(target),
           let final = await BrowserContentDetector.recordedBounds(for: refreshed),
           BrowserContentDetector.agree(initial, final) {
            stableBrowserRect = initial
        }

        return RecordingResult(
            videoURL: videoURL,
            mouseDataURL: mouseDataURL,
            micAudioURL: micURL,
            systemAudioURL: systemAudioURL,
            webcamVideoURL: webcamURL,
            micAudioStartOffset: micOffset,
            systemAudioStartOffset: systemOffset,
            browserContentRect: stableBrowserRect
        )
    }

    // MARK: - Pause/Resume

    func setMicrophoneEnabled(_ enabled: Bool, device: AVCaptureDevice?) async throws {
        try Task.checkCancellation()
        guard isRecording else { throw CancellationError() }
        if let microphoneRecorder {
            microphoneRecorder.setMuted(!enabled)
            isMicrophoneEnabled = enabled
            return
        }
        guard enabled else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw MicrophoneRecorderError.permissionDenied
        }
        try Task.checkCancellation()
        guard isRecording, let outputURL else { throw CancellationError() }

        let recorder = MicrophoneRecorder()
        var adopted = false
        defer { if !adopted { recorder.tearDown() } }
        let micURL = Self.generateMicOutputURL(for: outputURL)
        try recorder.prepare(device: device, outputURL: micURL)
        try await recorder.waitUntilReady()
        try Task.checkCancellation()
        guard isRecording else { throw CancellationError() }

        // A mic enabled later uses the screen timeline, excluding earlier pauses.
        let origin = mediaStartTime.map { CMTimeAdd($0, completedPausedDuration) }
        try recorder.startWriting(to: micURL, startTime: origin)
        if let pauseStartTime { recorder.pause(at: pauseStartTime) }
        microphoneRecorder = recorder
        isMicrophoneEnabled = true
        adopted = true
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        pauseStartTime = time
        isPaused = true
        captureManager?.recordingManager?.pause(at: time)
        mouseDataRecorder?.pause(at: time)
        microphoneRecorder?.pause(at: time)
        systemAudioRecorder?.pause(at: time)
        webcamRecorder?.pause(at: time)
        Log.recording.info("Recording paused")
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        if let pauseStartTime {
            completedPausedDuration = CMTimeAdd(completedPausedDuration, CMTimeSubtract(time, pauseStartTime))
        }
        pauseStartTime = nil
        isPaused = false
        captureManager?.recordingManager?.resume(at: time)
        mouseDataRecorder?.resume(at: time)
        microphoneRecorder?.resume(at: time)
        systemAudioRecorder?.resume(at: time)
        webcamRecorder?.resume(at: time)
        Log.recording.info("Recording resumed")
    }

    func toggleZoom() {
        guard let recorder = mouseDataRecorder else {
            Log.recording.warning("toggleZoom: mouseDataRecorder is nil")
            return
        }
        Log.recording.info("toggleZoom: forwarding to mouseDataRecorder")
        recorder.recordZoomToggle()
    }

    // MARK: - Helpers

    /// Bounds in Cocoa screen coordinates, matching the space mouse positions are sampled in.
    private func calculateCaptureBounds(for target: CaptureTarget) -> CGRect {
        switch target {
        case .display(let display):
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == display.displayID
            }) {
                return screen.frame
            }
            return CGRect(x: 0, y: 0, width: display.width, height: display.height)
        case .window(let window):
            // SCWindow.frame uses Quartz coords (Y origin at the top of the primary display).
            let quartzFrame = window.frame
            let primaryHeight = NSScreen.screens.first?.frame.height ?? quartzFrame.height
            return CGRect(
                x: quartzFrame.origin.x,
                y: primaryHeight - quartzFrame.origin.y - quartzFrame.height,
                width: quartzFrame.width,
                height: quartzFrame.height
            )
        }
    }

    private static func generateMouseDataURL(for videoURL: URL) -> URL {
        let dir = videoURL.deletingLastPathComponent()
        let name = videoURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(name).mouse.json")
    }

    private static func generateMicOutputURL(for videoURL: URL) -> URL {
        let dir = videoURL.deletingLastPathComponent()
        let name = videoURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(name)_mic.caf")
    }

    static func generateWebcamOutputURL(for videoURL: URL) -> URL {
        let dir = videoURL.deletingLastPathComponent()
        let name = videoURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(name)_webcam.mov")
    }
}
