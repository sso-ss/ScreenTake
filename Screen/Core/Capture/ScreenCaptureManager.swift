import Foundation
import ScreenCaptureKit
import CoreMedia
import Combine
import AppKit

protocol ScreenCaptureDelegate: AnyObject {
    func captureManager(_ manager: ScreenCaptureManager, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer)
    func captureManager(_ manager: ScreenCaptureManager, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer)
    func captureManager(_ manager: ScreenCaptureManager, didStopWithError error: Error?)
    func captureManager(_ manager: ScreenCaptureManager, didFinishRecordingTo url: URL)
}

extension ScreenCaptureDelegate {
    func captureManager(_ manager: ScreenCaptureManager, didFinishRecordingTo url: URL) {}
}

final class ScreenCaptureManager: NSObject, @unchecked Sendable {
    weak var delegate: ScreenCaptureDelegate?

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var contentFilter: SCContentFilter?

    private let captureQueue = DispatchQueue(label: "com.screen.capture", qos: .userInteractive)
    private(set) var isCapturing = false

    private var recordingURL: URL?
    // VFR recording manager (video only)
    var recordingManager: VFRRecordingManager?
    // System audio recorder (owned by RecordingCoordinator, set before startRecording)
    var systemAudioRecorder: SystemAudioRecorder?

    override init() {
        super.init()
    }

    // MARK: - Start Recording (VFR)

    func startRecording(
        target: CaptureTarget,
        configuration: CaptureConfiguration,
        outputURL: URL,
        backgroundStyle: BackgroundStyle? = nil,
        showCursor: Bool = true,
        cursorScale: Double = 1.0,
        highlightClicks: Bool = false,
        clickHighlightColor: ClickHighlightColor = .white
    ) async throws {
        guard !isCapturing else {
            throw CaptureError.alreadyCapturing
        }

        let filter = try await createContentFilterExcludingApp(for: target)
        self.contentFilter = filter
        self.recordingURL = outputURL

        let streamConfig = configuration.createStreamConfiguration()

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        self.stream = stream

        let output = StreamOutput(delegate: self)
        self.streamOutput = output
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)

        if configuration.capturesAudio {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: captureQueue)
        }

        // VFR recording
        let vfrManager = VFRRecordingManager(targetFrameRate: configuration.frameRate)
        try vfrManager.startRecording(
            to: outputURL,
            configuration: configuration,
            backgroundStyle: target.isWindow ? backgroundStyle : nil,
            isWindowRecording: target.isWindow,
            showCursor: showCursor,
            cursorScale: cursorScale,
            highlightClicks: highlightClicks,
            clickHighlightColor: clickHighlightColor,
            captureTarget: target
        )
        self.recordingManager = vfrManager

        do {
            try await stream.startCapture()
            isCapturing = true
            try await vfrManager.waitUntilReady()
        } catch {
            try? stream.removeStreamOutput(output, type: .screen)
            try? stream.removeStreamOutput(output, type: .audio)
            try? await stream.stopCapture()
            await withCheckedContinuation { continuation in
                captureQueue.async { continuation.resume() }
            }
            _ = await vfrManager.stopRecording()
            self.recordingManager = nil
            self.stream = nil
            self.streamOutput = nil
            self.contentFilter = nil
            self.recordingURL = nil
            isCapturing = false
            try? FileManager.default.removeItem(at: outputURL)
            Log.capture.error("Screen capture startup failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        Log.capture.info("Recording started (\(configuration.frameRate)fps): \(outputURL.path)")
    }

    // MARK: - Stop Recording

    func stopRecording(at stopTime: CMTime? = nil) async -> URL? {
        guard isCapturing, let stream else { return nil }
        let cutoff = stopTime ?? CMClockGetTime(CMClockGetHostTimeClock())

        do {
            if let output = streamOutput {
                try stream.removeStreamOutput(output, type: .screen)
                // Also remove audio output if it was added
                try? stream.removeStreamOutput(output, type: .audio)
            }
            try await stream.stopCapture()
        } catch {
            Log.capture.error("Error stopping recording: \(error)")
        }

        let result = await recordingManager?.stopRecording(at: cutoff)
        self.recordingManager = nil
        self.stream = nil
        self.streamOutput = nil
        self.contentFilter = nil
        self.recordingURL = nil
        isCapturing = false

        Log.capture.info("Recording stopped: \(result?.path ?? "nil")")
        return result
    }

    // MARK: - Content Filter

    static func refreshedTarget(_ target: CaptureTarget) async throws -> CaptureTarget {
        let content = try await availableContent()
        return try resolveTarget(target, in: content)
    }

    private static func resolveTarget(_ target: CaptureTarget, in content: SCShareableContent) throws -> CaptureTarget {
        switch target {
        case .display(let selected):
            guard let display = content.displays.first(where: { $0.displayID == selected.displayID }) else {
                throw CaptureError.targetNotFound
            }
            return .display(display)
        case .window(let selected):
            guard let window = content.windows.first(where: { $0.windowID == selected.windowID }),
                CaptureTarget.isSelectableWindow(window) else {
                throw CaptureError.targetNotFound
            }
            return .window(window)
        }
    }

    private func createContentFilterExcludingApp(for target: CaptureTarget) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let target = try Self.resolveTarget(target, in: content)
        Log.capture.info("Capture source: \(target.id, privacy: .public), \(target.width)x\(target.height)")

        let screenApp = content.applications.first { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        var excludedApps: [SCRunningApplication] = []
        if let app = screenApp {
            excludedApps.append(app)
        }

        switch target {
        case .display(let display):
            return SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )

        case .window(let window):
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    // MARK: - Available Content

    static func availableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isCapturing = false
        delegate?.captureManager(self, didStopWithError: error)
    }
}

// MARK: - StreamOutput

private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    weak var delegate: ScreenCaptureManager?

    init(delegate: ScreenCaptureManager) {
        self.delegate = delegate
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let manager = delegate else { return }

        switch type {
        case .screen:
            manager.recordingManager?.receiveFrame(sampleBuffer)
            manager.delegate?.captureManager(manager, didOutputVideoSampleBuffer: sampleBuffer)
        case .audio:
            if manager.systemAudioRecorder == nil {
                Log.capture.warning("Audio sample received but systemAudioRecorder is nil!")
            }
            manager.systemAudioRecorder?.appendSampleBuffer(sampleBuffer)
            manager.delegate?.captureManager(manager, didOutputAudioSampleBuffer: sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case alreadyCapturing
    case notCapturing
    case targetNotFound
    case permissionDenied
    case configurationFailed
    case noCompleteFrames

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing: return "Capture is already in progress"
        case .notCapturing: return "No capture in progress"
        case .targetNotFound: return "The selected display or window is no longer available. Select it again before recording."
        case .permissionDenied: return "Screen capture permission denied"
        case .configurationFailed: return "Failed to configure capture"
        case .noCompleteFrames: return "No complete screen frames were received. Make sure the selected display or window is visible, then try recording again."
        }
    }
}
